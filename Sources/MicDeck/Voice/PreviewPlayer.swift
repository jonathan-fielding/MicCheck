import AVFoundation
import Foundation
import MicKit
import Synchronization

/// Plays the test take through the default output. Every block runs through the voice
/// chain, and `optimised` picks which signal is heard, so A/B switching is instant and
/// settings changes are heard while playing.
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published var optimised = true { didSet { state.optimised.store(optimised, ordering: .relaxed) } }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var timer: Timer?
    private let state = State()

    final class State: @unchecked Sendable {
        var samples: [Float] = []          // replaced only while stopped
        var processor: VoiceProcessor?
        let position = Atomic<Int>(0)
        let optimised = Atomic<Bool>(true)
        let finished = Atomic<Bool>(false)
        let resetRequested = Atomic<Bool>(false)
        var startAt = 0
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        deinit { scratch.deallocate() }
    }

    func load(_ samples: [Float], sampleRate: Double, startAt: Int, settings: VoiceSettings) {
        stop()
        if let s = source {
            engine.disconnectNodeOutput(s)
            engine.detach(s)
        }
        state.samples = samples
        state.startAt = min(max(startAt, 0), max(samples.count - 1, 0))
        state.position.store(state.startAt, ordering: .relaxed)
        state.processor = VoiceProcessor(sampleRate: sampleRate, settings: settings)
        state.optimised.store(optimised, ordering: .relaxed)
        progress = 0

        let st = state
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self), let proc = st.processor else { return noErr }
            if st.resetRequested.exchange(false, ordering: .relaxed) { proc.reset() }
            let n = min(Int(frameCount), 8192)
            let pos = st.position.load(ordering: .relaxed)
            let avail = max(0, min(n, st.samples.count - pos))
            st.samples.withUnsafeBufferPointer { src in
                for i in 0..<avail { st.scratch[i] = src[pos + i] }
            }
            for i in avail..<n { st.scratch[i] = 0 }
            if st.optimised.load(ordering: .relaxed) {
                proc.process(st.scratch, count: n)
                for i in 0..<n { out[i] = st.scratch[i] }
            } else {
                for i in 0..<n { out[i] = st.scratch[i] }
                proc.process(st.scratch, count: n)   // keep the chain's state warm for an instant switch
            }
            st.position.store(pos + avail, ordering: .relaxed)
            if pos + avail >= st.samples.count { st.finished.store(true, ordering: .relaxed) }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }

    func update(_ settings: VoiceSettings) { state.processor?.update(settings) }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard source != nil, !state.samples.isEmpty else { return }
        if state.finished.load(ordering: .relaxed) || state.position.load(ordering: .relaxed) >= state.samples.count {
            restart()
        }
        do {
            try engine.start()
        } catch {
            DebugLog.write("preview start failed: \(error)")
            return
        }
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        engine.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        engine.stop()
    }

    /// Jumps to a point (0…1 of the part after the room tone).
    func seek(_ fraction: Double) {
        let span = state.samples.count - state.startAt
        guard span > 0 else { return }
        state.position.store(state.startAt + Int(Double(span) * min(max(fraction, 0), 1)), ordering: .relaxed)
        state.finished.store(false, ordering: .relaxed)
        state.resetRequested.store(true, ordering: .relaxed)
        progress = fraction
    }

    private func restart() {
        state.position.store(state.startAt, ordering: .relaxed)
        state.finished.store(false, ordering: .relaxed)
        state.resetRequested.store(true, ordering: .relaxed)
        progress = 0
    }

    private func tick() {
        let span = Double(max(state.samples.count - state.startAt, 1))
        progress = Double(state.position.load(ordering: .relaxed) - state.startAt) / span
        if state.finished.load(ordering: .relaxed) {
            pause()
            restart()
        }
    }
}
