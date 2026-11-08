//
// FrameGrabber.swift
//
// While the camera is streaming, sends one preview frame to POST /vision/check every
// `Config.visionCheckInterval`. Frames are scaled to at most `maxFrameSide` px before
// JPEG encoding. At most one request is in flight; a tick that lands while one is
// pending is skipped. The facility (if one is set) goes with each check; without one,
// checks still run and flags are saved as "unknown facility". Failures, timeouts,
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
  @ObservationIgnored var onFlag: (@MainActor (_ type: String, _ description: String?, _ facility: String?, _ photo: Data) async -> Void)?
  /// Facility id sent with each check; nil when none is chosen yet (checks still run).
  @ObservationIgnored var facility: @MainActor () -> String? = { nil }
  /// False while no shift is active: no checks are sent and no flags raised.
  @ObservationIgnored var isEnabled: @MainActor () -> Bool = { false }

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

  /// Raw result of a "Check now" request, for display.
  struct CheckReport {
    let at: Date
    /// "HTTP 200", or the error / reason nothing was sent.
    let status: String
    let result: VisionResult?
    /// True if a pending camera flag was created.
    let createdFlag: Bool
  }

  /// Result of the last "Check now".
  private(set) var lastManualCheck: CheckReport?
  private(set) var isCheckingNow = false

  /// Sends the current frame right away, ignoring the interval. Same scaling, shift,
  /// facility and one-request-at-a-time rules as the timer.
  func checkNow() async {
    func blocked(_ reason: String) {
      lastManualCheck = CheckReport(at: Date(), status: reason, result: nil, createdFlag: false)
    }
    guard isEnabled() else { return blocked("Not sent: start a shift first.") }
    guard !isRequestPending else { return blocked("Not sent: a check is already in progress.") }
    guard let frame = latestFrame else { return blocked("Not sent: start the camera first.") }
    isCheckingNow = true
    defer { isCheckingNow = false }
    lastManualCheck = await performCheck(frame: frame, facility: facility())
  }

  private func tick() {
    guard isEnabled(), !isRequestPending, let frame = latestFrame, frame !== lastSentFrame else { return }
    let facility = facility()
    Task { @MainActor [weak self] in
      _ = await self?.performCheck(frame: frame, facility: facility)
    }
  }

  /// Scales, encodes and sends one frame; creates a flag only for a valid flag
  /// response. Callers have already checked that no request is pending.
  private func performCheck(frame: UIImage, facility: String?) async -> CheckReport {
    lastSentFrame = frame
    isRequestPending = true
    defer { isRequestPending = false }

    // Scaling and encoding happen off the main actor so the preview never stutters.
    let jpeg = await Task.detached(priority: .utility) {
      Self.scaledJPEG(frame)
    }.value
    guard let jpeg else {
      lastCheck = (.skipped, Date())
      return CheckReport(at: Date(), status: "Not sent: couldn't encode the frame.", result: nil, createdFlag: false)
    }
    checksSent += 1
    let result: VisionResult
    do {
      result = try await api.checkVision(jpeg: jpeg, facility: facility)
    } catch {
      lastCheck = (.skipped, Date())
      return CheckReport(at: Date(), status: NightShiftAPIError.describe(error), result: nil, createdFlag: false)
    }
    let status = result.httpStatus.map { "HTTP \($0)" } ?? "OK"
    guard let type = result.flaggedType else {
      // A clean "no flag" is ok; flag without a valid type, or unavailable, is skipped.
      lastCheck = (result.flag || result.available == false ? .skipped : .ok, Date())
      return CheckReport(at: Date(), status: status, result: result, createdFlag: false)
    }
    lastCheck = (.flag, Date())
    await onFlag?(type, result.description, facility, jpeg)
    return CheckReport(at: Date(), status: status, result: result, createdFlag: true)
  }
}
