import CoreAudio
import Foundation
import MicKit
import Synchronization

/// Records the test take straight from the mic (mono, the mic's own sample rate).
/// Phases: a few seconds of room tone, then the user reads the script and presses Done.
@MainActor
final class VoiceRecorder: ObservableObject {
    enum Phase: Equatable { case idle, quiet, speaking, done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0           // 0…1 over -60…0 dBFS
    @Published private(set) var quietRemaining: Double = 0
    @Published private(set) var speakingElapsed: Double = 0
    @Published private(set) var error: String?

    static let maxSpeakingSeconds = 20.0

    private(set) var sampleRate: Double = 48000
    private var capture: Capture?
    private var deviceID: AudioObjectID?
    private var procID: AudioDeviceIOProcID?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "VoiceRecorder.io", qos: .userInteractive)

    /// Preallocated so the IO thread never allocates.
    final class Capture: @unchecked Sendable {
        let capacity: Int
        let samples: UnsafeMutablePointer<Float>
        let count = Atomic<Int>(0)
        let peak = Atomic<UInt32>(0)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)

        init(capacity: Int) {
            self.capacity = capacity
            samples = .allocate(capacity: capacity)
            scratch.initialize(repeating: 0, count: 8192)
        }
        deinit { samples.deallocate(); scratch.deallocate() }

        func append(_ input: UnsafePointer<AudioBufferList>) {
            let n = AudioHAL.downmix(input, into: scratch, capacity: 8192)
            let c = count.load(ordering: .relaxed)
            let m = min(n, capacity - c)
            guard m > 0 else { return }
            var pk: Float = 0
            for i in 0..<m { samples[c + i] = scratch[i]; pk = max(pk, abs(scratch[i])) }
            count.store(c + m, ordering: .releasing)
            peak.store(pk.bitPattern, ordering: .relaxed)
        }
    }

    func start(deviceID: AudioObjectID) {
        cancel()
        error = nil
        guard AudioHAL.streamsAreFloat32(deviceID, scope: kAudioDevicePropertyScopeInput) else {
            error = "This mic's audio format isn't supported for recording."
            return
        }
        sampleRate = AudioHAL.nominalSampleRate(deviceID) ?? 48000
        let cap = Capture(capacity: Int((VoiceScript.quietSeconds + Self.maxSpeakingSeconds + 1) * sampleRate))
        var proc: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) { _, input, _, _, _ in cap.append(input) }
        guard err == noErr, let proc else { error = "Couldn't open the mic (\(err))."; return }
        err = AudioDeviceStart(deviceID, proc)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, proc)
            error = "Couldn't start the mic (\(err))."
            return
        }
        capture = cap
        self.deviceID = deviceID
        procID = proc
        phase = .quiet
        quietRemaining = VoiceScript.quietSeconds
        speakingElapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let capture else { return }
        let seconds = Double(capture.count.load(ordering: .acquiring)) / sampleRate
        let pk = Float(bitPattern: capture.peak.load(ordering: .relaxed))
        let v = min(max((20 * log10(max(pk, 1e-6)) + 60) / 60, 0), 1)
        level = v > level ? v : max(v, level - 0.05)
        switch phase {
        case .quiet:
            quietRemaining = max(0, VoiceScript.quietSeconds - seconds)
            if quietRemaining == 0 { phase = .speaking }
        case .speaking:
            speakingElapsed = seconds - VoiceScript.quietSeconds
            if speakingElapsed >= Self.maxSpeakingSeconds { finish() }
        default: break
        }
    }

    /// Stops recording and returns the take (room tone + speech).
    @discardableResult
    func finish() -> [Float]? {
        guard let capture else { return nil }
        stopDevice()
        let n = capture.count.load(ordering: .acquiring)
        let take = Array(UnsafeBufferPointer(start: capture.samples, count: n))
        self.capture = nil
        phase = .done
        level = 0
        lastTake = take
        return take
    }

    private(set) var lastTake: [Float] = []

    func cancel() {
        stopDevice()
        capture = nil
        phase = .idle
        level = 0
    }

    private func stopDevice() {
        timer?.invalidate()
        timer = nil
        if let deviceID, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = nil
    }
}
