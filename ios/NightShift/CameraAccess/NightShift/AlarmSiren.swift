//
// AlarmSiren.swift
//
// A loud, looping two-tone siren generated in code (no audio file). Plays on the
// current output route, which is the glasses when they are the Bluetooth output.
// Requires Speaker.isAlarmMode (playback session) to be on first.
//

import AVFoundation

@MainActor
final class AlarmSiren {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?

  /// Needs the engine running too: an interruption stops the engine but can leave the
  /// player node marked as playing.
  var isPlaying: Bool { engine?.isRunning == true && player?.isPlaying == true }

  func start() {
    guard engine == nil else { return }
    Speaker.activateAudioSession()
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    guard let buffer = Self.makeSirenBuffer(format: format) else { return }
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = 1.0
    do {
      try engine.start()
    } catch {
      NSLog("[NightShift] Siren failed to start: \(error)")
      return
    }
    player.scheduleBuffer(buffer, at: nil, options: .loops)
    player.play()
    self.engine = engine
    self.player = player
  }

  /// Lowers the siren while the alarm text is spoken, so the words are audible.
  func setDucked(_ ducked: Bool) {
    player?.volume = ducked ? 0.2 : 1.0
  }

  func stop() {
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
  }

  /// One second of a rising-then-falling wail (700 to 1500 Hz), soft-clipped for
  /// loudness, looped seamlessly.
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
      let value = tanh(2.5 * sin(phase)) * 0.95
      samples[i] = Float(value)
    }
    return buffer
  }
}
