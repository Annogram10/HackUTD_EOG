//
// AlarmSiren.swift
//
// A loud, looping two-tone siren generated in code (no audio file). Plays on the
// current output route: the glasses when they are the Bluetooth output, or the phone
// speaker (Settings > Audio out). Requires Speaker.isAlarmMode to be on first.
// Plays at a constant level at whatever volume the phone is set to: the app never
// changes the volume, ducks other audio, or fades. It pauses while the alarm text is
// spoken. Generated at the output's own sample rate (no resampling on the 16 kHz
// Bluetooth headset route) and restarted if the audio route changes while it plays
// (a route change stops an AVAudioEngine).
//

import AVFoundation

@MainActor
final class AlarmSiren {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var buffer: AVAudioPCMBuffer?
  private var configChangeTask: Task<Void, Never>?
  /// True while the alarm text is spoken.
  private var isPaused = false

  /// Needs the engine running too: an interruption stops the engine but can leave the
  /// player node marked as playing.
  var isPlaying: Bool { engine?.isRunning == true && player?.isPlaying == true }

  func start() {
    guard engine == nil else { return }
    Speaker.activateAudioSession()
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    self.engine = engine
    self.player = player
    isPaused = false
    guard play(on: engine, player: player) else {
      self.engine = nil
      self.player = nil
      return
    }
    // A route change (glasses connecting, the output override, the mic switching)
    // stops the engine; rebuild the connection at the new rate and keep going.
    configChangeTask = Task { @MainActor [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: engine) {
        guard let self, let engine = self.engine, let player = self.player else { return }
        player.stop()
        _ = self.play(on: engine, player: player)
      }
    }
  }

  /// Pauses the siren while the alarm text is spoken, then resumes it.
  func setPaused(_ paused: Bool) {
    isPaused = paused
    guard let player, engine?.isRunning == true else { return }
    if paused {
      player.pause()
    } else {
      player.play()
    }
  }

  func stop() {
    configChangeTask?.cancel()
    configChangeTask = nil
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    buffer = nil
  }

  /// Connects the player at the output's current sample rate, starts the engine, loops
  /// the siren. Returns false if the engine couldn't start.
  private func play(on engine: AVAudioEngine, player: AVAudioPlayerNode) -> Bool {
    let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    let sampleRate = outputRate > 0 ? outputRate : 44_100
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
    if buffer?.format.sampleRate != sampleRate {
      buffer = Self.makeSirenBuffer(format: format)
    }
    guard let buffer else { return false }
    engine.disconnectNodeOutput(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.prepare()
    do {
      try engine.start()
    } catch {
      NSLog("[NightShift] Siren failed to start: \(error)")
      return false
    }
    player.scheduleBuffer(buffer, at: nil, options: .loops)
    if !isPaused {
      player.play()
    }
    return true
  }

  /// One second of a rising-then-falling wail (700 to 1500 Hz), lightly soft-clipped
  /// for loudness, looped seamlessly.
  private static func makeSirenBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let sampleRate = format.sampleRate
    let frames = AVAudioFrameCount(sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let samples = buffer.floatChannelData?[0]
    else { return nil }
    buffer.frameLength = frames
    var phase = 0.0
    for i in 0..<Int(frames) {
      let t = Double(i) / sampleRate
      // Triangle sweep: up for half a second, down for the other half.
      let sweep = t < 0.5 ? t / 0.5 : (1 - t) / 0.5
      let frequency = 700 + 800 * sweep
      phase += 2 * .pi * frequency / sampleRate
      // Gentler clipping than before (2.5x): fewer high harmonics, which alias into a
      // buzz on the narrowband Bluetooth headset route.
      let value = tanh(1.6 * sin(phase)) * 0.95
      samples[i] = Float(value)
    }
    return buffer
  }
}
