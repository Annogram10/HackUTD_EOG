//
// FrameGrabber.swift
//
// While the camera is streaming, sends one preview frame to POST /vision/check every
// `Config.visionCheckInterval`. Frames are scaled to at most `maxFrameSide` px before
// JPEG encoding. At most one request is in flight; a tick that lands while one is
// pending is skipped. No check is sent until a facility is known. Failures, timeouts,
// unavailable checks and non-flag responses are ignored silently.
//

import Observation
import UIKit

@Observable
@MainActor
final class FrameGrabber {
  enum CheckOutcome: String {
    case flag, ok, skipped
  }

  /// Outcome and time of the most recent tick that had a frame to check.
  private(set) var lastCheck: (outcome: CheckOutcome, at: Date)?
  /// Number of frames sent to /vision/check.
  private(set) var checksSent = 0

  /// Called when the backend flags a frame: type, description, the facility id the
  /// check was sent with, and the JPEG that was sent (kept as the evidence photo).
  @ObservationIgnored var onFlag: (@MainActor (_ type: String, _ description: String?, _ facility: String, _ photo: Data) async -> Void)?
  /// Facility id sent with each check; nil means none chosen yet, so nothing is sent.
  @ObservationIgnored var facility: @MainActor () -> String? = { nil }

  @ObservationIgnored private let api: any NightShiftAPI
  @ObservationIgnored private var loopTask: Task<Void, Never>?
  @ObservationIgnored private var frameSource: (@MainActor () -> UIImage?)?
  @ObservationIgnored private var isStreaming: (@MainActor () -> Bool)?
  @ObservationIgnored private var isRequestPending = false
  /// The last frame sent, so a frozen preview (paused stream, capture sheet) isn't re-sent.
  @ObservationIgnored private weak var lastSentFrame: UIImage?

  /// Longest side of a sent frame and of the stored evidence photo.
  nonisolated static let maxFrameSide: CGFloat = 1024

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

  /// Scales `image` so its longest side is at most `maxFrameSide` px, then encodes it
  /// as JPEG (quality 0.7). Safe to call off the main actor.
  nonisolated static func scaledJPEG(_ image: UIImage) -> Data? {
    let pixelWidth = image.size.width * image.scale
    let pixelHeight = image.size.height * image.scale
    let longest = max(pixelWidth, pixelHeight)
    guard longest > 0 else { return nil }
    let factor = min(1, maxFrameSide / longest)
    let target = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())

    // Scale 1 so the renderer's points are pixels.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: target, format: format)
    return renderer.jpegData(withCompressionQuality: 0.7) { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
  }

  private func tick() {
    guard !isRequestPending, let frame = latestFrame, frame !== lastSentFrame else { return }
    guard let facility = facility() else {
      // No facility chosen: flags are blocked, so don't send.
      lastCheck = (.skipped, Date())
      return
    }

    lastSentFrame = frame
    isRequestPending = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isRequestPending = false }
      // Scaling and encoding happen off the main actor so the preview never stutters.
      let jpeg = await Task.detached(priority: .utility) {
        Self.scaledJPEG(frame)
      }.value
      guard let jpeg else {
        self.lastCheck = (.skipped, Date())
        return
      }
      self.checksSent += 1
      guard let result = try? await self.api.checkVision(jpeg: jpeg, facility: facility) else {
        self.lastCheck = (.skipped, Date())
        return
      }
      guard let type = result.flaggedType else {
        // A clean "no flag" is ok; flag without a valid type, or unavailable, is skipped.
        self.lastCheck = (result.flag || result.available == false ? .skipped : .ok, Date())
        return
      }
      self.lastCheck = (.flag, Date())
      await self.onFlag?(type, result.description, facility, jpeg)
    }
  }
}
