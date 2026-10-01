import Foundation
import AVFoundation

// Overlap the tail with the head instead of fading the loop to silence.
// The output wraps from head[overlap - 1] to head[overlap].
func seamlessLoop(_ source: AVAudioPCMBuffer, seconds: Double = 1.5) -> AVAudioPCMBuffer {
 let count = Int(source.frameLength)
 let overlap = min(Int(source.format.sampleRate * seconds), count / 4)
 guard overlap > 1, let input = source.floatChannelData,
       let result = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count - overlap)),
       let output = result.floatChannelData else { return source }
 result.frameLength = AVAudioFrameCount(count - overlap)
 let middle = count - 2 * overlap
 for channel in 0..<Int(source.format.channelCount) {
  for i in 0..<middle { output[channel][i] = input[channel][i + overlap] }
  for i in 0..<overlap {
   let phase = Double(i) / Double(overlap - 1) * .pi / 2
   output[channel][middle + i] = input[channel][count - overlap + i] * Float(cos(phase)) + input[channel][i] * Float(sin(phase))
  }
 }
 return result
}
/// Reads a recording into memory, at most `maxSeconds` of it. Decoded audio is far larger than an MP3,
/// so long imported files are cut rather than filling the memory (an hour of stereo audio is over 1 GB).
func loadRecording(_ url:URL, maxSeconds: Double = .infinity) throws -> AVAudioPCMBuffer {
 let file=try AVAudioFile(forReading:url)
 let limit = maxSeconds.isFinite ? AVAudioFramePosition(file.processingFormat.sampleRate * maxSeconds) : file.length
 let frames = AVAudioFrameCount(max(0, min(file.length, limit)))
 guard frames > 0, let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:frames) else {
  throw NSError(domain:"Brisa",code:4,userInfo:[NSLocalizedDescriptionKey:"This audio file is empty or can't be read."])
 }
 try file.read(into:buffer, frameCount: frames)
 return buffer
}
func recordingURL(_ path:String) throws -> URL {
 guard let root=Bundle.main.resourceURL else {throw NSError(domain:"Brisa",code:1,userInfo:[NSLocalizedDescriptionKey:"Audio folder not found."])}
 let url=root.appendingPathComponent("Audio").appendingPathComponent(path)
 guard FileManager.default.fileExists(atPath:url.path) else {throw NSError(domain:"Brisa",code:2,userInfo:[NSLocalizedDescriptionKey:"Recording missing: \(path)"])}
 return url
}

/// A smooth volume change for one sound. `smoothstep` keeps the start and end gentle so mixes blend instead of cutting.
struct VolumeRamp {
 var start: Float, target: Float, startTime: TimeInterval, duration: TimeInterval
 func value(at time: TimeInterval) -> Float {
  guard duration > 0 else { return target }
  let p = Float(min(max((time - startTime) / duration, 0), 1))
  return start + (target - start) * (p * p * (3 - 2 * p))
 }
 func isFinished(at time: TimeInterval) -> Bool { time - startTime >= duration }
}

/// Decides how a sound's volume should move when the mix changes.
enum Crossfade {
 static let fadeSeconds = 1.6      // a sound entering or leaving the mix
 static let blendSeconds = 0.7     // a sound that stays but changes a lot
 static let smoothSeconds = 0.06   // slider drags and small tweaks

 /// Returns nil when nothing needs to move.
 static func plan(current: Float, target: Float, enabled: Bool, now: TimeInterval) -> VolumeRamp? {
  guard abs(current - target) > 0.0001 else { return nil }
  guard enabled else { return VolumeRamp(start: current, target: target, startTime: now, duration: 0) }
  let entersOrLeaves = current < 0.0005 || target < 0.0005
  let bigChange = abs(target - current) / max(current, target) > 0.4
  let duration = entersOrLeaves ? fadeSeconds : (bigChange ? blendSeconds : smoothSeconds)
  return VolumeRamp(start: current, target: target, startTime: now, duration: duration)
 }
}

final class AudioBank {
 let engine = AVAudioEngine()
 var players: [String: AVAudioPlayerNode] = [:]
 var buffers: [String: AVAudioPCMBuffer] = [:]
 var importedURL: ((String) -> URL?)?
 /// Fade sounds in and out when the mix changes instead of cutting.
 var crossfadeEnabled = true
 /// How far the living mix moves each volume (0 = off). Eases in and out so switching it never jumps.
 var livingDepth = 0.0 { didSet { startTickerIfNeeded() } }
 private var appliedDepth = 0.0
 private var playing = false
 private var ramps: [String: VolumeRamp] = [:]
 /// Each sound's volume before the living mix moves it.
 private var baseVolumes: [String: Float] = [:]
 private var ticker: Timer?
 private var lastTick: TimeInterval = 0
 /// Longest stretch of an imported file that is kept in memory and looped.
 static let importedMaxSeconds = 20.0 * 60
 /// Called on the main thread when a buffer that was being prepared is ready, or failed.
 var onBufferReady: ((Error?) -> Void)?
 private var preparing: Set<String> = []

 /// A ready buffer, or nil while it is being prepared in the background. Generating noise or decoding a file
 /// takes long enough to stall the interface, so it never happens on the main thread.
 func buffer(_ id: String) throws -> AVAudioPCMBuffer? {
  if let b = buffers[id] { return b }
  var importedFile: URL?
  if id.hasPrefix("imported-") {
   guard let url = importedURL?(id), FileManager.default.fileExists(atPath: url.path) else {
    throw NSError(domain: "Brisa", code: 3, userInfo: [NSLocalizedDescriptionKey: "Imported audio is unavailable. Relink or remove it from the library."])
   }
   importedFile = url
  }
  guard preparing.insert(id).inserted else { return nil }
  DispatchQueue.global(qos: .userInitiated).async { [weak self] in
   let result = Result { try AudioBank.makeBuffer(id, importedFile: importedFile) }
   DispatchQueue.main.async {
    guard let self else { return }
    self.preparing.remove(id)
    switch result {
    case .success(let b): self.buffers[id] = b; self.onBufferReady?(nil)
    case .failure(let error): self.onBufferReady?(error)
    }
   }
  }
  return nil
 }

 private static let recordings = [
  "keyboard": "keyboard-ambient.wav",
  "realFireplace": "real/real-fireplace.wav",
  "beachWaves": "real/real-beach-waves.wav",
  "coffeeShop": "real/real-coffee-shop.wav",
  "realRain": "real/real-rain.wav",
  "realForest": "real/real-forest.wav",
  "realCity": "real/real-city.wav"
 ]

 /// Builds a sound's loop. Pure work with no shared state, so it can run off the main thread.
 static func makeBuffer(_ id: String, importedFile: URL?) throws -> AVAudioPCMBuffer {
  if let importedFile { return seamlessLoop(try loadRecording(importedFile, maxSeconds: importedMaxSeconds)) }
  if let path = recordings[id] { return seamlessLoop(try loadRecording(recordingURL(path))) }
  if let color = SoundSynthesis.NoiseColor(rawValue: id) { return SoundSynthesis.noiseBuffer(color) }
  if let tone = SoundSynthesis.binauralTones[id] { return SoundSynthesis.toneBuffer(tone) }
  let rate = 24000.0, count = 24000 * 16
  let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:1)!
  let b = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count))!
  b.frameLength = AVAudioFrameCount(count)
  let p = b.floatChannelData![0]
  var low = 0.0, slow = 0.0, pink = 0.0
  var seed: UInt64 = 934821
  func rand() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 33) / Double(UInt32.max) * 4 - 1 }
  for i in 0..<count {
   let t = Double(i)/rate, n = rand()
   low += 0.025*(n-low); slow += 0.002*(n-slow); pink += 0.12*(n-pink)
   let swell = 0.6 + 0.4*sin(2 * .pi*t/8)
   var x: Double = 0
   switch id {
   case "rain": x=n*0.12+pink*0.35
   case "heavy": x=n*0.22+low*0.7
   case "tent": x=pink*0.8+(n > 0.995 ? n*0.25 : 0)
   case "thunder": x=slow*4*pow(max(0,sin(2 * .pi*t/16)),4)+pink*0.15
   case "creek": x=pink*0.6 + sin(2 * .pi*650*t + 5*sin(2 * .pi*3*t))*0.018*swell
   case "ocean": x=(pink*0.7+n*0.1)*swell
   case "waterfall": x=low*0.8+pink*0.6+n*0.1
   case "wind": x=low*1.5*swell
   case "fire": x=low*0.7+(n > 0.998 ? n*0.65 : 0)
   case "night": x=sin(2 * .pi*3200*t)*pow(max(0,sin(2 * .pi*4*t)),12)*0.07 + low*0.15
   case "birds": x=sin(2 * .pi*1800*t+30*sin(2 * .pi*2*t))*pow(max(0,sin(2 * .pi*t/4)),24)*0.09+pink*0.08
   case "fan": x=low*1.1+sin(2 * .pi*120*t)*0.025
   case "cabin": x=slow*2.2+pink*0.3
   case "train": x=low*0.9+n*0.1*pow(max(0,sin(2 * .pi*2*t)),16)
   default: x=0
   }
   p[i]=Float(tanh(x))
  }
  return seamlessLoop(b)
 }
 /// After the output device changes the engine stops and its player nodes go stale.
 /// Tear them down so the next `update` rebuilds a clean graph on the new device.
 func reset() {
  for node in players.values { node.stop(); engine.detach(node) }
  players.removeAll()
  ramps.removeAll()
  baseVolumes.removeAll()
  stopTicker()
  engine.stop()
 }
 func discardBuffer(for id: String) { buffers.removeValue(forKey: id) }
 func update(_ levels: [String:Double], pans: [String:Double] = [:], playing: Bool, master: Double) throws {
  self.playing = playing
  guard playing else {
   for node in players.values { node.pause() }
   ramps.removeAll()
   stopTicker()
   return
  }
  for (id,level) in levels where level > 0 {
   if players[id] == nil {
    guard let b=try buffer(id) else { continue }   // joins the mix once it's ready
    let node=AVAudioPlayerNode(); engine.attach(node)
    engine.connect(node,to:engine.mainMixerNode,format:b.format)
    node.volume = 0; baseVolumes[id] = 0
    node.scheduleBuffer(b,at:nil,options:.loops); players[id]=node
   }
  }
  if !engine.isRunning { try engine.start() }
  engine.mainMixerNode.outputVolume=Float(master)
  let now = ProcessInfo.processInfo.systemUptime
  for (id,node) in players {
   let target = Float(levels[id] ?? 0)
   // Continue from where a running fade currently is, so quick successive changes never jump.
   let current = ramps[id]?.value(at: now) ?? baseVolumes[id] ?? 0
   if let ramp = Crossfade.plan(current: current, target: target, enabled: crossfadeEnabled, now: now) {
    if ramp.duration == 0 { ramps[id] = nil; baseVolumes[id] = target } else { ramps[id] = ramp; baseVolumes[id] = current }
   } else { ramps[id] = nil; baseVolumes[id] = target }
   // Binaural tones rely on each ear hearing its own pitch, so they always stay centred.
   node.pan = SoundSynthesis.isBinaural(id) ? 0 : Float(min(max(pans[id] ?? 0, -1), 1))
   applyVolume(id, node, at: now)
   if !node.isPlaying { node.play() }
  }
  startTickerIfNeeded()
 }

 /// Used by the sleep timer's fade, which changes every second without touching the sounds.
 func setMasterVolume(_ volume: Double) { engine.mainMixerNode.outputVolume = Float(volume) }

 private func applyVolume(_ id: String, _ node: AVAudioPlayerNode, at time: TimeInterval) {
  let base = baseVolumes[id] ?? 0
  node.volume = min(1, base * Float(LivingMix.factor(for: id, at: time, depth: appliedDepth)))
 }

 /// Fast while a fade runs, slow while only the living mix drifts, stopped when nothing moves.
 private func startTickerIfNeeded() {
  let moving = livingDepth > 0 || appliedDepth > 0
  let interval: TimeInterval? = !playing ? nil : !ramps.isEmpty ? 1.0 / 60 : moving ? 1.0 / 15 : nil
  guard ticker?.timeInterval != interval else { return }
  stopTicker()
  guard let interval else { return }
  lastTick = ProcessInfo.processInfo.systemUptime
  ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
 }

 private func stopTicker() { ticker?.invalidate(); ticker = nil }

 private func tick() {
  let now = ProcessInfo.processInfo.systemUptime
  let elapsed = now - lastTick
  lastTick = now
  // Reach a new living depth over a couple of seconds instead of at once.
  let step = elapsed * 0.25
  appliedDepth = livingDepth > appliedDepth ? min(livingDepth, appliedDepth + step) : max(livingDepth, appliedDepth - step)
  for (id, ramp) in ramps {
   let finished = ramp.isFinished(at: now)
   baseVolumes[id] = finished ? ramp.target : ramp.value(at: now)
   if finished { ramps[id] = nil }
  }
  for (id, node) in players { applyVolume(id, node, at: now) }
  startTickerIfNeeded()
 }
}
