// Real mic → voice chain → "MicDeck Feed" (hidden output of the MicDeck Audio driver),
// which the driver loops back out as "MicDeck Microphone".
//
// The two devices run on different clocks (and often different sample rates), so the
// feed side pulls from a ring buffer through a linear-interpolating resampler whose
// ratio is nudged to keep about 25 ms buffered. That absorbs drift without clicks.

import CoreAudio
import Foundation
import Synchronization

/// Single-producer, single-consumer ring of Float samples.
final class SampleRing: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    init(capacityPowerOfTwo: Int) {
        capacity = capacityPowerOfTwo
        mask = capacityPowerOfTwo - 1
        buffer = .allocate(capacity: capacityPowerOfTwo)
        buffer.initialize(repeating: 0, count: capacityPowerOfTwo)
    }
    deinit { buffer.deallocate() }

    var available: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }

    /// Producer. Drops the oldest audio if the consumer has stalled.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        for i in 0..<count { buffer[(w + i) & mask] = src[i] }
        writeIndex.store(w + count, ordering: .releasing)
        let r = readIndex.load(ordering: .acquiring)
        if w + count - r > capacity { _ = readIndex.compareExchange(expected: r, desired: w + count - capacity / 2, ordering: .acquiringAndReleasing) }
    }

    /// Consumer: sample at `offset` past the read position (must be < available).
    @inline(__always) func peek(_ offset: Int) -> Float { buffer[(readIndex.load(ordering: .relaxed) + offset) & mask] }

    func advance(_ n: Int) { readIndex.add(n, ordering: .releasing) }

    /// Consumer: throw away everything but the newest `keep` samples.
    func skip(keeping keep: Int) {
        let w = writeIndex.load(ordering: .acquiring), r = readIndex.load(ordering: .relaxed)
        if w - r > keep { readIndex.store(w - keep, ordering: .releasing) }
    }
}

public final class LiveVoiceRouter: @unchecked Sendable {
    public enum RouterError: Error, LocalizedError {
        case unsupportedFormat, noSampleRate, ioProc(OSStatus), start(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "The mic's audio format isn't supported"
            case .noSampleRate: "Couldn't read the mic's sample rate"
            case .ioProc(let e): "Couldn't open the audio device (\(e))"
            case .start(let e): "Couldn't start audio (\(e))"
            }
        }
    }

    public let micID: AudioObjectID
    public let feedID: AudioObjectID
    private let processor: VoiceProcessor
    private let ring = SampleRing(capacityPowerOfTwo: 1 << 15)
    private let micRate: Double, feedRate: Double
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private var micProc: AudioDeviceIOProcID?
    private var feedProc: AudioDeviceIOProcID?
    private let micQueue = DispatchQueue(label: "LiveVoiceRouter.mic", qos: .userInteractive)
    private let feedQueue = DispatchQueue(label: "LiveVoiceRouter.feed", qos: .userInteractive)

    // Feed-side resampler state (feed queue only).
    private var frac: Double = 0
    private var priming = true

    /// Output peak (0…1) for a level meter; written on the feed queue.
    public let outputPeak = Atomic<UInt32>(0)

    public init(micID: AudioObjectID, feedID: AudioObjectID, settings: VoiceSettings, bypass: Bool) throws {
        guard AudioHAL.streamsAreFloat32(micID, scope: kAudioDevicePropertyScopeInput),
              AudioHAL.streamsAreFloat32(feedID, scope: kAudioDevicePropertyScopeOutput) else { throw RouterError.unsupportedFormat }
        guard let mr = AudioHAL.nominalSampleRate(micID), let fr = AudioHAL.nominalSampleRate(feedID) else { throw RouterError.noSampleRate }
        self.micID = micID
        self.feedID = feedID
        micRate = mr
        feedRate = fr
        processor = VoiceProcessor(sampleRate: mr, settings: settings)
        processor.update(settings, bypass: bypass)
        scratch.initialize(repeating: 0, count: 8192)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    public func update(_ settings: VoiceSettings, bypass: Bool) { processor.update(settings, bypass: bypass) }

    public func start() throws {
        var proc: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&proc, micID, micQueue) { [unowned self] _, input, _, _, _ in
            self.captured(input)
        }
        guard err == noErr, let mic = proc else { throw RouterError.ioProc(err) }
        micProc = mic

        proc = nil
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, feedID, feedQueue) { [unowned self] _, _, _, output, _ in
            self.render(output)
        }
        guard err == noErr, let feed = proc else { stop(); throw RouterError.ioProc(err) }
        feedProc = feed

        err = AudioDeviceStart(micID, mic)
        guard err == noErr else { stop(); throw RouterError.start(err) }
        err = AudioDeviceStart(feedID, feed)
        guard err == noErr else { stop(); throw RouterError.start(err) }
    }

    public func stop() {
        if let p = micProc {
            AudioDeviceStop(micID, p)
            AudioDeviceDestroyIOProcID(micID, p)
            micProc = nil
        }
        if let p = feedProc {
            AudioDeviceStop(feedID, p)
            AudioDeviceDestroyIOProcID(feedID, p)
            feedProc = nil
        }
    }

    private func captured(_ input: UnsafePointer<AudioBufferList>) {
        let n = AudioHAL.downmix(input, into: scratch, capacity: 8192)
        guard n > 0 else { return }
        processor.process(scratch, count: n)
        ring.write(scratch, count: n)
    }

    private func render(_ output: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard let first = buffers.first, let data = first.mData else { return }
        let ch = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch)
        let out = data.assumingMemoryBound(to: Float.self)

        let target = Int(micRate * 0.025)
        let available = ring.available
        if priming {
            if available < target {
                for b in buffers { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
                return
            }
            priming = false
            frac = 0
        }
        if available > target * 6 { ring.skip(keeping: target) }   // fell far behind (e.g. after a stall)

        // Nudge the rate by at most ±0.5 % to hold the buffer near the target.
        let error = Double(ring.available - target) / Double(target)
        let ratio = micRate / feedRate * (1 + 0.005 * max(-1, min(1, error)))

        var peak: Float = 0
        for i in 0..<frames {
            let idx = Int(frac)
            if idx + 1 >= ring.available {
                // Underrun: the mic stopped or stalled. Fade to silence and re-prime.
                for j in i..<frames { for c in 0..<ch { out[j * ch + c] = 0 } }
                priming = true
                break
            }
            let a = ring.peek(idx), b = ring.peek(idx + 1)
            let t = Float(frac - Double(idx))
            let y = a + (b - a) * t
            for c in 0..<ch { out[i * ch + c] = y }
            peak = max(peak, abs(y))
            frac += ratio
        }
        let consumed = min(Int(frac), ring.available)
        ring.advance(consumed)
        frac -= Double(consumed)
        // Any further (non-interleaved) buffers get a copy of the first channel.
        for b in buffers.dropFirst() {
            guard let d = b.mData else { continue }
            let bch = max(Int(b.mNumberChannels), 1)
            let p = d.assumingMemoryBound(to: Float.self)
            for i in 0..<min(frames, Int(b.mDataByteSize) / (MemoryLayout<Float>.size * bch)) {
                for c in 0..<bch { p[i * bch + c] = out[i * ch] }
            }
        }
        outputPeak.store(peak.bitPattern, ordering: .relaxed)
    }
}
