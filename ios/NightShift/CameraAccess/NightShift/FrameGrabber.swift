//
// FrameGrabber.swift
//
// While the camera is streaming, sends one preview frame to POST /vision/check every
// `Config.visionCheckInterval`. At most one request is in flight; a tick that lands
// while one is pending is skipped. Failures, timeouts and non-flag responses are
// ignored silently.
//

import UIKit

@MainActor
final class FrameGrabber {
  /// Called when the backend flags a frame, with its type and the frame that was sent.
  var onFlag: (@MainActor (String, UIImage) async -> Void)?
  /// Facility id sent with each check.
  var facility: @MainActor () -> String? = { nil }

  private let api: any NightShiftAPI
  private var loopTask: Task<Void, Never>?
  private var frameSource: (@MainActor () -> UIImage?)?
  private var isStreaming: (@MainActor () -> Bool)?
  private var isRequestPending = false
  /// The last frame sent, so a frozen preview (paused stream, capture sheet) isn't re-sent.
  private weak var lastSentFrame: UIImage?

  init(api: any NightShiftAPI) {
    self.api = api
  }

  /// Starts ticking. `frame` returns the latest preview frame; `isStreaming` gates sending.
  func start(frame: @escaping @MainActor () -> UIImage?, isStreaming: @escaping @MainActor () -> Bool) {
    frameSource = frame
    self.isStreaming = isStreaming
    loopTask?.cancel()
    loopTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Config.visionCheckInterval)
        guard !Task.isCancelled else { break }
        self?.tick()
      }
    }
  }

  func stop() {
    loopTask?.cancel()
    loopTask = nil
    frameSource = nil
    isStreaming = nil
  }

  /// The latest preview frame, if streaming (used for voice-raised flags too).
  var latestFrame: UIImage? {
    isStreaming?() == true ? frameSource?() : nil
  }

  private func tick() {
    guard !isRequestPending, let frame = latestFrame, frame !== lastSentFrame else { return }

    lastSentFrame = frame
    isRequestPending = true
    let facility = facility()
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isRequestPending = false }
      // JPEG encoding happens off the main actor so the preview never stutters.
      let jpeg = await Task.detached(priority: .utility) {
        frame.jpegData(compressionQuality: 0.7)
      }.value
      guard let jpeg,
        let result = try? await self.api.checkVision(jpeg: jpeg, facility: facility),
        result.flag
      else { return }
      await self.onFlag?(result.type ?? "issue", frame)
    }
  }
}
