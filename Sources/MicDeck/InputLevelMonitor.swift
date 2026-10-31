import AVFoundation
import CoreAudio
import Foundation
import os

/// Live input meter for the selected mic. Runs only while the settings window is
/// open, so macOS's orange "microphone in use" indicator isn't shown all the time.
///
/// Reads the device directly with a Core Audio IOProc rather than AVAudioEngine:
/// the engine ties input and output to one device and is unreliable when the mic
/// isn't the system default input.
@MainActor
final class InputLevelMonitor: ObservableObject {
    /// 0…1, mapped from -60…0 dBFS.
    @Published private(set) var level: Float = 0
    @Published private(set) var peak: Float = 0
    @Published private(set) var unavailableReason: String?

    private var deviceID: AudioDeviceID?
    private var procID: AudioDeviceIOProcID?
    private var peakHeldAt = Date.distantPast
    private let ioQueue = DispatchQueue(label: "InputLevelMonitor.io")

    func start(deviceID: AudioDeviceID?) {
        guard let deviceID else { stop(); unavailableReason = nil; return }
        if procID != nil, self.deviceID == deviceID { return }
        stop()
        unavailableReason = nil   // a reason from the previous device no longer applies
        self.deviceID = deviceID

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        DebugLog.write("meter start device=\(deviceID) auth=\(status.rawValue)")
        switch status {
        case .authorized:
            run(deviceID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in
                    DebugLog.write("meter access granted=\(ok)")
                    guard self.deviceID == deviceID else { return }
                    if ok { self.run(deviceID) } else { self.unavailableReason = "Microphone access denied" }
                }
            }
        default:
            unavailableReason = "Allow MicDeck in System Settings › Privacy & Security › Microphone to see levels"
        }
    }

    func stop() {
        if let deviceID, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = nil
        level = 0
        peak = 0
    }

    private func run(_ deviceID: AudioDeviceID) {
        guard Self.inputIsFloat32(deviceID) else {
            DebugLog.write("meter input format is not Float32")
            unavailableReason = "This mic's input format can't be metered"
            return
        }
        // Accumulated on the IO queue, published at ~30 Hz.
        final class Acc: @unchecked Sendable { var maxAbs: Float = 0; var last = Date() }
        let acc = Acc()
        var proc: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, ioQueue) { [weak self] _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for b in buffers {
                guard let data = b.mData else { continue }
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(b.mDataByteSize) / MemoryLayout<Float>.size { acc.maxAbs = max(acc.maxAbs, abs(p[i])) }
            }
            let now = Date()
            guard now.timeIntervalSince(acc.last) >= 1.0 / 30 else { return }
            let db = 20 * log10(max(acc.maxAbs, 1e-6))
            acc.maxAbs = 0
            acc.last = now
            let norm = min(max((db + 60) / 60, 0), 1)
            Task { @MainActor in self?.push(norm) }
        }
        guard err == noErr, let proc else {
            DebugLog.write("meter create IOProc failed \(err)")
            unavailableReason = "Can't open the mic for metering (\(err))"
            return
        }
        err = AudioDeviceStart(deviceID, proc)
        guard err == noErr else {
            DebugLog.write("meter start failed \(err)")
            AudioDeviceDestroyIOProcID(deviceID, proc)
            unavailableReason = "Can't start metering (\(err))"
            return
        }
        procID = proc
        unavailableReason = nil
        DebugLog.write("meter running")
    }

    /// The IOProc reads every input buffer as Float32; true when each input stream delivers that.
    private static func inputIsFloat32(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &streams) == noErr else { return false }
        for stream in streams.prefix(Int(size) / MemoryLayout<AudioStreamID>.size) {
            var formatAddr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &formatAddr, 0, nil, &formatSize, &format) == noErr,
                  format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { return false }
        }
        return true
    }

    private func push(_ v: Float) {
        guard procID != nil else { return }
        // Fast attack, slower release, like a hardware meter.
        level = v > level ? v : max(v, level - 0.04)
        let now = Date()
        if v >= peak || now.timeIntervalSince(peakHeldAt) > 1.2 {
            peak = v
            peakHeldAt = now
        }
    }
}

/// Diagnostics go to the unified log: `log stream --predicate 'subsystem == "com.jonathanfielding.micdeck"'`.
enum DebugLog {
    static let logger = Logger(subsystem: "com.jonathanfielding.micdeck", category: "app")

    static func write(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
