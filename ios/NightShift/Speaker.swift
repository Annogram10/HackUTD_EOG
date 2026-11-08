import AudioToolbox
import AVFoundation
import os

/// Text-to-speech for NightShift. Speaks text exactly as given (the backend writes
/// it), in one calm style. Announcements play one at a time, in the order they were
/// queued: an optional chime, then the text.
@MainActor
final class Speaker: NSObject {
    static let shared = Speaker()

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
        pendingCount += 1
        let task = Task { @MainActor in
            await previous?.value
            Self.activateAudioSession()
            if chime {
                await Self.playChime()
            }
            await self.speakNow(text)
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
        utterance.rate = 0.46
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
    static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playAndRecord,
                                     mode: .spokenAudio,
                                     options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        }
        try? session.setActive(true)
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
