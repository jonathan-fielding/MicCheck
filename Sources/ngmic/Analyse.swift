import AVFoundation
import Foundation
import MicKit

/// `ngmic analyse <file> [out.wav]`: runs the voice analysis the app uses on a recording.
func analyse(path: String) {
    let args = Array(CommandLine.arguments.dropFirst())
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { exit(1) }
        try file.read(into: buf)
        let n = Int(buf.frameLength), ch = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<ch { let p = buf.floatChannelData![c]; for i in 0..<n { mono[i] += p[i] / Float(ch) } }

        let a = try VoiceAnalyzer.analyze(mono, sampleRate: format.sampleRate)
        print(String(format: "noise %.1f dBFS  peak %.1f dBFS  speech median %.1f (p10 %.1f, p95 %.1f)  %.1f s speech",
                     a.noiseFloorDB, a.peakDB, a.speechLevelDB, a.quietSpeechDB, a.loudSpeechDB, a.speechSeconds))
        print(String(format: "sibilance excess %.1f dB at %.0f Hz (threshold %.1f)  plosives %d  clipped %d",
                     a.sibilanceExcessDB, a.sibilanceFrequency, a.sibilantThresholdDB, a.plosiveCount, a.clippedSamples))
        print("spectrum (rel. dB, minus reference):")
        for (f, d) in zip(a.bandFrequencies, a.spectrumDB) {
            print(String(format: "  %6.0f Hz  %6.1f  (%+.1f)", f, d, d - VoiceAnalyzer.referenceDB(at: f)))
        }
        let rec = VoiceAdvisor.recommend(a, samples: mono, hardware: MicHardwareState(canAdjustGain: true))
        print("\nnotes:")
        for note in rec.notes { print("  [\(note.kind)] \(note.title): \(note.detail)") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try enc.encode(rec.settings), encoding: .utf8)!)

        if args.count > 2 {
            let out = VoiceProcessor.render(mono, sampleRate: format.sampleRate, settings: rec.settings)
            let outFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
            let ob = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(out.count))!
            ob.frameLength = AVAudioFrameCount(out.count)
            out.withUnsafeBufferPointer { ob.floatChannelData![0].update(from: $0.baseAddress!, count: out.count) }
            let of = try AVAudioFile(forWriting: URL(fileURLWithPath: args[2]), settings: outFormat.settings)
            try of.write(from: ob)
            of.close()
            print("wrote \(args[2])")
        }
    } catch {
        print("analyse failed: \(error.localizedDescription)")
        exit(1)
    }
}
