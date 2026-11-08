import AudioToolbox
import AVFoundation
import os

/// Text-to-speech for NightShift. Speaks text exactly as given (the backend writes
/// it), in one calm style. Announcements play one at a time, in the order they were
/// queued: an optional chime, then the text.
@MainActor
final class Speaker: NSObject {
    static let shared = Speaker()

    /// Default speech rate (AVSpeechUtterance.rate).
    nonisolated static let defaultRate: Float = 0.46

    /// System sound played before alerts (iOS "Tri-tone").
    static let chimeSoundID: SystemSoundID = 1007

    private static let logger = Logger(subsystem: "com.meta.wearables.CameraAccess", category: "Speaker")

    private let synth = AVSpeechSynthesizer()
    private var finishContinuations: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var pendingCount = 0
    /// Chosen on first use, then reused for the rest of the launch.
    private lazy var voice: AVSpeechSynthesisVoice? = Self.bestVoice()

    /// True while anything is queued or playing. Voice commands ignore what the mic
    /// hears meanwhile, so the app doesn't react to its own voice.
    var isBusy: Bool { pendingCount > 0 }
    /// When the last queued announcement finished.
    private(set) var lastFinishedAt: Date = .distantPast
    /// The most recent phrases spoken (newest last), for rejecting the mic's echo of them.
    private(set) var recentlySpoken: [String] = []

    /// Bumped by stopAll() so queued phrases are dropped.
    private var stopGeneration = 0

    /// Stops the current phrase immediately and drops everything queued.
    func stopAll() {
        stopGeneration += 1
        synth.stopSpeaking(at: .immediate)
    }

    override private init() {
        super.init()
        synth.delegate = self
    }

    /// Speaks without a chime and without waiting (used by the Test voice button).
    func say(_ text: String) {
        enqueue(text, chime: false)
    }

    /// Plays the chime, then speaks `text`. Returns once it has been spoken.
    func announce(_ text: String) async {
        await enqueue(text, chime: true).value
    }

    /// Speaks `text` without a chime. Returns once it has been spoken.
    func speak(_ text: String) async {
        await enqueue(text, chime: false).value
    }

    /// Queues behind whatever is already playing. Synchronous so call order is play order.
    @discardableResult
    private func enqueue(_ text: String, chime: Bool) -> Task<Void, Never> {
        let previous = tail
        let generation = stopGeneration
        pendingCount += 1
        let task = Task { @MainActor in
            await previous?.value
            // Skip anything queued before the last stopAll().
            guard generation == self.stopGeneration else {
                self.pendingCount -= 1
                if self.pendingCount == 0 { self.lastFinishedAt = Date() }
                return
            }
            Self.activateAudioSession()
            if chime {
                await Self.playChime()
            }
            if generation == self.stopGeneration {
                await self.speakNow(text)
            }
            self.pendingCount -= 1
            if self.pendingCount == 0 {
                self.lastFinishedAt = Date()
            }
        }
        tail = task
        return task
    }

    private func speakNow(_ text: String) async {
        recentlySpoken = Array((recentlySpoken + [text]).suffix(3))
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // Voice speed from Settings (defaults to the original rate).
        let saved = UserDefaults.standard.object(forKey: "NightShift.voiceRate") as? Double
        utterance.rate = saved.map { Float($0) } ?? Self.defaultRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.15
        utterance.postUtteranceDelay = 0.25
        await withCheckedContinuation { continuation in
            finishContinuations[ObjectIdentifier(utterance)] = continuation
            synth.speak(utterance)
        }
    }

    fileprivate func utteranceEnded(_ id: ObjectIdentifier) {
        finishContinuations.removeValue(forKey: id)?.resume()
    }

    // MARK: - Voice selection

    /// Natural-sounding voices preferred within the same quality tier, best first.
    private static let preferredVoiceNames = ["Ava", "Zoe", "Evan"]

    /// The best installed en-US voice: highest quality (premium, enhanced, default)
    /// first, then a preferred natural voice. Novelty and Personal Voices are skipped.
    /// Premium/enhanced voices must be downloaded in Settings > Accessibility >
    /// Spoken Content > Voices.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == "en-US"
                && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        func preference(_ voice: AVSpeechSynthesisVoice) -> Int {
            let index = preferredVoiceNames.firstIndex { voice.name.hasPrefix($0) }
            return index.map { preferredVoiceNames.count - $0 } ?? 0
        }
        let best = candidates.max { lhs, rhs in
            if lhs.quality.rawValue != rhs.quality.rawValue {
                return lhs.quality.rawValue < rhs.quality.rawValue
            }
            return preference(lhs) < preference(rhs)
        }
        let voice = best ?? AVSpeechSynthesisVoice(language: "en-US")
        let quality: String
        switch voice?.quality {
        case .premium: quality = "premium"
        case .enhanced: quality = "enhanced"
        default: quality = "default"
        }
        logger.info("Speech voice: \(voice?.name ?? "system default", privacy: .public) (\(quality, privacy: .public), \(voice?.identifier ?? "-", privacy: .public)) from \(candidates.count) en-US voices")
        return voice
    }

    // MARK: - Chime and audio session

    /// Plays the chime and waits for it to finish. The completion is `@Sendable` because
    /// AudioToolbox calls it off the main thread.
    private static func playChime() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AudioServicesPlaySystemSoundWithCompletion(chimeSoundID) { @Sendable in
                continuation.resume()
            }
        }
    }

    /// Puts the shared audio session in play-and-record with the glasses' Bluetooth HFP
    /// route allowed (HFP is what carries the glasses mic). If the session is already
    /// play-and-record (for example, a video recording with mic), it is left as is so its
    /// mode isn't disturbed. `.defaultToSpeaker` sends audio to the phone's loudspeaker,
    /// not the earpiece, when the glasses aren't connected.
    /// The alarm uses the same session configuration as speech (switching it at alarm
    /// start rebuilt the Bluetooth route and garbled the siren); this only re-checks the
    /// session. It stays play-and-record (with the glasses' Bluetooth mic and output) so
    /// the operator can answer by voice ("what's the issue", "dismiss", "prioritize").
    static var isAlarmMode = false {
        didSet {
            guard isAlarmMode != oldValue else { return }
            activateAudioSession()
        }
    }

    /// One fixed session configuration for speech and the alarm alike. Changing the mode
    /// or options when an alarm starts makes iOS rebuild the Bluetooth route, which
    /// garbled the first seconds of the siren; with nothing to change this is a no-op.
    /// No `.duckOthers`: the app never turns other audio (or anything else) down.
    private static let sessionOptions: AVAudioSession.CategoryOptions = [
        .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker,
    ]

    static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.categoryOptions != sessionOptions || session.mode != .default {
            try? session.setCategory(.playAndRecord, mode: .default, options: sessionOptions)
        }
        try? session.setActive(true)
        applyOutputRoute()
    }

    /// Settings > Audio out: "Phone" plays through the iPhone speaker instead of the
    /// glasses (for demos). Only touches the route when it's wrong (each change is a
    /// route rebuild); iOS drops the override on route changes, so this is re-checked
    /// before every phrase. The glasses' Bluetooth headset link carries mic and speaker
    /// together, so in Phone mode the phone's mic is used too.
    static func applyOutputRoute() {
        let session = AVAudioSession.sharedInstance()
        let onSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        if Config.audioToPhone {
            if !onSpeaker { try? session.overrideOutputAudioPort(.speaker) }
        } else if onSpeaker, session.availableInputs?.contains(where: { $0.portType == .bluetoothHFP }) == true {
            try? session.overrideOutputAudioPort(.none)
        }
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in Speaker.shared.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in Speaker.shared.utteranceEnded(id) }
    }
}
