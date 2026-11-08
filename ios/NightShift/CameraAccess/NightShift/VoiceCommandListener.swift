//
// VoiceCommandListener.swift
//
// Continuous on-device speech recognition (SFSpeechRecognizer with
// requiresOnDeviceRecognition) that turns utterances into `VoiceCommand`s.
//
// One AVAudioEngine tap feeds the current recognition request. An utterance ends after
// a short silence; it is then parsed, and a fresh request replaces the old one so each
// command starts from an empty transcript. Anything heard while `Speaker` is talking is
// dropped so the app doesn't react to its own voice.
//

import AVFoundation
import Observation
import os
import Speech

@Observable
@MainActor
final class VoiceCommandListener {
  enum Status: Equatable {
    case off
    case listening
    case unavailable(String)
  }

  private(set) var status: Status = .off
  /// Transcript of the utterance in progress.
  @ObservationIgnored private var heardText: String = ""

  var isListening: Bool { status == .listening }

  /// True only while listening and the audio engine is actually capturing (checked on
  /// start/stop, restarts, and by the watchdog every few seconds).
  private(set) var isRunning = false

  /// The last complete phrase heard (excluding the app's own speech).
  private(set) var lastHeard: String?

  /// Called on the main actor for each recognized command.
  @ObservationIgnored var onCommand: (@MainActor (VoiceCommand) async -> Void)?
  /// Called on the main actor for a phrase that matches no command.
  @ObservationIgnored var onUnrecognized: (@MainActor (String) -> Void)?

  /// Silence that ends an utterance.
  private static let utteranceSilence: Duration = .milliseconds(1500)
  /// How long after the speaker stops before the mic is trusted again.
  private static let speakerEchoGuard: TimeInterval = 0.6
  /// Within this long after speaking, a phrase made only of words the app just said
  /// is treated as its own echo (recognition can lag the speaker by a second or more).
  private static let echoWindow: TimeInterval = 5

  @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  @ObservationIgnored private var engine: AVAudioEngine?
  @ObservationIgnored private let requestBox = RecognitionRequestBox()
  @ObservationIgnored private var task: SFSpeechRecognitionTask?
  /// Distinguishes callbacks from a replaced task from the current one.
  @ObservationIgnored private var taskGeneration = 0
  @ObservationIgnored private var silenceTask: Task<Void, Never>?
  @ObservationIgnored private var watchdogTask: Task<Void, Never>?
  @ObservationIgnored private var configChangeTask: Task<Void, Never>?
  @ObservationIgnored private var utteranceOverlapsSpeaker = false

  private static let logger = Logger(subsystem: "com.meta.wearables.CameraAccess", category: "VoiceCommands")

  // MARK: - Permissions

  /// Asks for speech recognition and microphone access. Returns true if both are granted.
  func requestPermissions() async -> Bool {
    let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
      SFSpeechRecognizer.requestAuthorization { @Sendable status in
        continuation.resume(returning: status)
      }
    }
    guard speechStatus == .authorized else {
      status = .unavailable("Speech recognition permission is off. Turn it on in Settings.")
      return false
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      status = .unavailable("Microphone permission is off. Turn it on in Settings.")
      return false
    }
    return true
  }

  // MARK: - Start / stop

  func start() async {
    guard !isListening else { return }
    guard await requestPermissions() else { return }
    guard let recognizer, recognizer.isAvailable else {
      status = .unavailable("Speech recognition isn't available right now.")
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      status = .unavailable("On-device speech recognition isn't supported for English on this iPhone.")
      return
    }

    do {
      try startEngine()
    } catch {
      Self.logger.error("Audio engine failed to start: \(error.localizedDescription)")
      status = .unavailable("Couldn't start the microphone: \(error.localizedDescription)")
      return
    }
    status = .listening
    startRecognitionTask()
    startWatchdogs()
    updateRunning()
  }

  func stop() {
    watchdogTask?.cancel()
    configChangeTask?.cancel()
    silenceTask?.cancel()
    stopRecognitionTask()
    stopEngine()
    heardText = ""
    if isListening {
      status = .off
    }
    updateRunning()
  }

  private func updateRunning() {
    isRunning = isListening && engine?.isRunning == true
  }

  // MARK: - Audio engine

  private func startEngine() throws {
    stopEngine()
    Speaker.activateAudioSession()
    let session = AVAudioSession.sharedInstance()
    // Prefer the glasses mic (Bluetooth HFP) over the phone's.
    if let glassesInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
      try? session.setPreferredInput(glassesInput)
    }

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    // A zero-channel or zero-rate format means no usable input; installTap would crash.
    guard format.channelCount > 0, format.sampleRate > 0 else {
      throw NSError(domain: "NightShift", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
    }
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(requestBox))
    engine.prepare()
    try engine.start()
    self.engine = engine
  }

  private func stopEngine() {
    guard let engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
  }

  /// Built in a nonisolated context so the tap block (called on the audio thread)
  /// carries no main-actor isolation.
  nonisolated private static func makeTapBlock(_ box: RecognitionRequestBox) -> AVAudioNodeTapBlock {
    { @Sendable buffer, _ in box.append(buffer) }
  }

  // MARK: - Recognition task

  private func startRecognitionTask() {
    guard let recognizer else { return }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.taskHint = .unspecified
    requestBox.replace(with: request)

    taskGeneration += 1
    let generation = taskGeneration
    utteranceOverlapsSpeaker = false
    task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler(generation: generation, listener: self))
  }

  private func stopRecognitionTask() {
    requestBox.replace(with: nil)?.endAudio()
    task?.cancel()
    task = nil
  }

  /// `@Sendable` handler: the recognizer calls it on a background queue.
  nonisolated private static func makeResultHandler(
    generation: Int,
    listener: VoiceCommandListener
  ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
    { @Sendable result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failed = error != nil
      Task { @MainActor in
        listener.handleResult(generation: generation, text: text, isFinal: isFinal, failed: failed)
      }
    }
  }

  private func handleResult(generation: Int, text: String?, isFinal: Bool, failed: Bool) {
    guard generation == taskGeneration, isListening else { return }

    // An error with nothing heard ("no speech detected", recognizer hiccup): restart
    // after a pause rather than immediately, so a persistent failure can't spin.
    if failed, heardText.isEmpty, text?.isEmpty ?? true {
      stopRecognitionTask()
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(1))
        guard let self, self.isListening, self.task == nil else { return }
        self.startRecognitionTask()
      }
      return
    }

    if let text, !text.isEmpty {
      if Speaker.shared.isBusy {
        utteranceOverlapsSpeaker = true
      }
      heardText = text
      scheduleUtteranceEnd()
    }

    // A final result or an error ("no speech detected", the on-device time limit)
    // ends the task; finish the utterance and keep listening with a new one.
    if isFinal || failed {
      finishUtterance()
    }
  }

  private func scheduleUtteranceEnd() {
    silenceTask?.cancel()
    silenceTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.utteranceSilence)
      guard !Task.isCancelled else { return }
      self?.finishUtterance()
    }
  }

  /// Parses what was heard, then starts a fresh recognition task.
  private func finishUtterance() {
    silenceTask?.cancel()
    let transcript = heardText
    let overlapsSpeaker = utteranceOverlapsSpeaker
      || Speaker.shared.isBusy
      || Date().timeIntervalSince(Speaker.shared.lastFinishedAt) < Self.speakerEchoGuard

    stopRecognitionTask()
    heardText = ""
    guard isListening else { return }
    startRecognitionTask()

    guard !transcript.isEmpty, !overlapsSpeaker, !isEchoOfSpeaker(transcript) else { return }
    lastHeard = transcript
    guard let command = VoiceCommand.parse(transcript) else {
      onUnrecognized?(transcript)
      return
    }
    Self.logger.info("Command: \(command.summary, privacy: .public)")
    let handler = onCommand
    Task { @MainActor in await handler?(command) }
  }

  /// True if `transcript` has two or more words, all from something the app said in
  /// the last few seconds ("leak flagged", "confirm or dismiss"). A lone word such as
  /// "confirm" is kept, since that is how the operator answers a prompt.
  private func isEchoOfSpeaker(_ transcript: String) -> Bool {
    guard Speaker.shared.isBusy || Date().timeIntervalSince(Speaker.shared.lastFinishedAt) < Self.echoWindow else {
      return false
    }
    func words(_ text: String) -> [String] {
      text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    let heard = words(transcript)
    guard heard.count >= 2 else { return false }
    let spoken = Set(Speaker.shared.recentlySpoken.flatMap(words))
    return heard.allSatisfy(spoken.contains)
  }

  // MARK: - Recovery

  /// Restarts the engine when the audio route or session changes under it (glasses
  /// connect/disconnect, a recording starting or stopping).
  private func startWatchdogs() {
    configChangeTask?.cancel()
    configChangeTask = Task { @MainActor [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
        self?.restartEngine(reason: "configuration change")
      }
    }
    watchdogTask?.cancel()
    watchdogTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self, self.isListening else { continue }
        if self.engine?.isRunning != true {
          self.restartEngine(reason: "engine stopped")
        }
        self.updateRunning()
      }
    }
  }

  private func restartEngine(reason: String) {
    guard isListening else { return }
    Self.logger.info("Restarting voice engine: \(reason, privacy: .public)")
    stopRecognitionTask()
    do {
      try startEngine()
      startRecognitionTask()
    } catch {
      // The watchdog retries in a few seconds.
      Self.logger.error("Voice engine restart failed: \(error.localizedDescription)")
    }
    updateRunning()
  }
}

/// Holds the current recognition request so the audio-thread tap can append to it
/// while the main actor swaps in a new one between utterances.
private final class RecognitionRequestBox: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock<SFSpeechAudioBufferRecognitionRequest?>(uncheckedState: nil)

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.withLockUnchecked { $0?.append(buffer) }
  }

  /// Sets the new request and returns the previous one.
  @discardableResult
  func replace(with request: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
    lock.withLockUnchecked { current in
      let previous = current
      current = request
      return previous
    }
  }
}
