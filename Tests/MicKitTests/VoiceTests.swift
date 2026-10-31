@testable import MicKit
import XCTest

final class VoiceTests: XCTestCase {
    let fs = 48000.0

    // MARK: filters

    func testPeakFilterGainAtCentre() {
        let c = BiquadCoeffs.peak(frequency: 1000, q: 1, gainDB: -6, sampleRate: fs)
        XCTAssertEqual(c.magnitudeDB(at: 1000, sampleRate: fs), -6, accuracy: 0.05)
        XCTAssertEqual(c.magnitudeDB(at: 50, sampleRate: fs), 0, accuracy: 0.2)
    }

    func testHighPass24Slope() {
        var s = VoiceSettings()
        s.highPassEnabled = true
        s.highPassFrequency = 100
        XCTAssertEqual(s.eqResponseDB(at: 100, sampleRate: fs), -3, accuracy: 0.3)   // Butterworth corner
        XCTAssertLessThan(s.eqResponseDB(at: 50, sampleRate: fs), -22)              // ~24 dB/octave
        XCTAssertEqual(s.eqResponseDB(at: 1000, sampleRate: fs), 0, accuracy: 0.1)
    }

    func testRenderedBandMatchesResponse() {
        var s = VoiceSettings()
        s.highPassEnabled = false
        s.limiterEnabled = false
        s.bands[3].gainDB = 6
        let out = VoiceProcessor.render(sine(3500, seconds: 0.5, amp: 0.1), sampleRate: fs, settings: s)
        XCTAssertEqual(rmsDB(Array(out.suffix(12000))), rmsDB(sine(3500, seconds: 0.25, amp: 0.1)) + 6, accuracy: 0.3)
    }

    // MARK: dynamics

    func testLimiterHoldsCeiling() {
        var s = VoiceSettings()
        s.outputGainDB = 18
        let out = VoiceProcessor.render(sine(440, seconds: 0.5, amp: 0.5), sampleRate: fs, settings: s)
        let ceiling = Float(pow(10, -1.0 / 20))
        XCTAssertLessThanOrEqual(out.map(abs).max()!, ceiling + 1e-4)
    }

    func testGateTurnsDownQuietNoise() {
        var s = VoiceSettings()
        s.highPassEnabled = false
        s.gateEnabled = true
        s.gateThresholdDB = -40
        let noise = (0..<Int(fs)).map { _ in Float.random(in: -1...1) * 0.003 }   // ≈ -55 dBFS
        let out = VoiceProcessor.render(noise, sampleRate: fs, settings: s)
        XCTAssertLessThan(rmsDB(Array(out.suffix(24000))), rmsDB(noise) - 20)
    }

    func testCompressorReducesLoudMoreThanQuiet() {
        var s = VoiceSettings()
        s.highPassEnabled = false
        s.limiterEnabled = false
        s.compressorEnabled = true
        s.compressorThresholdDB = -30
        s.compressorRatio = 4
        let quiet = VoiceProcessor.render(sine(300, seconds: 0.5, amp: 0.01), sampleRate: fs, settings: s)   // -43 dBFS peak
        let loud = VoiceProcessor.render(sine(300, seconds: 0.5, amp: 0.3), sampleRate: fs, settings: s)     // -10 dBFS peak
        let quietChange = rmsDB(Array(quiet.suffix(12000))) - rmsDB(sine(300, seconds: 0.25, amp: 0.01))
        let loudChange = rmsDB(Array(loud.suffix(12000))) - rmsDB(sine(300, seconds: 0.25, amp: 0.3))
        XCTAssertEqual(quietChange, 0, accuracy: 0.2)
        XCTAssertLessThan(loudChange, -10)
    }

    func testBypassLeavesAudioUntouched() {
        let p = VoiceProcessor(sampleRate: fs)
        var s = VoiceSettings()
        s.outputGainDB = 12
        p.update(s, bypass: true)
        var x = sine(440, seconds: 0.01, amp: 0.2)
        let original = x
        x.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(x, original)
    }

    // MARK: analysis

    func testAnalysisFindsBoomAndNoise() throws {
        let take = syntheticTake(noise: 0.003, boomDB: 9)
        let a = try VoiceAnalyzer.analyze(take, sampleRate: fs)
        XCTAssertEqual(a.noiseFloorDB, -50.5, accuracy: 2)
        let rec = VoiceAdvisor.recommend(a, samples: take, hardware: MicHardwareState())
        XCTAssertTrue(rec.settings.gateEnabled)
        XCTAssertLessThan(rec.settings.gateThresholdDB, a.quietSpeechDB)
        XCTAssertLessThan(rec.settings.bands[1].gainDB, -2, "expected a cut for the low-mid boom")
        XCTAssertEqual(rec.settings.bands[1].frequency, 220, accuracy: 60)
    }

    func testCleanTakeNeedsNoGateOrMudCut() throws {
        let take = syntheticTake(noise: 0.0001, boomDB: 0)
        let a = try VoiceAnalyzer.analyze(take, sampleRate: fs)
        let rec = VoiceAdvisor.recommend(a, samples: take, hardware: MicHardwareState())
        XCTAssertFalse(rec.settings.gateEnabled)
        XCTAssertEqual(rec.settings.bands[1].gainDB, 0)
    }

    func testClippingAsksForLessGain() throws {
        var take = syntheticTake(noise: 0.0005, boomDB: 0)
        let peak = take.map(abs).max()!
        take = take.map { min(max($0 / peak * 1.5, -1), 1) }   // drive into clipping
        let a = try VoiceAnalyzer.analyze(take, sampleRate: fs)
        let rec = VoiceAdvisor.recommend(a, samples: take, hardware: MicHardwareState(canAdjustGain: true))
        let gain = try XCTUnwrap(rec.notes.first { $0.id == "gain" })
        XCTAssertEqual(gain.kind, .warning)
        guard case .adjustHardwareGain(let db)? = gain.action else { return XCTFail("no gain action") }
        XCTAssertLessThan(db, 0)
    }

    func testSilenceIsRejected() {
        let take = (0..<Int(8 * fs)).map { _ in Float.random(in: -1...1) * 0.0005 }
        XCTAssertThrowsError(try VoiceAnalyzer.analyze(take, sampleRate: fs))
    }

    func testSettingsRoundTrip() throws {
        var s = VoiceSettings()
        s.bands[2].gainDB = -3.5
        s.deEsserEnabled = true
        let back = try JSONDecoder().decode(VoiceSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // MARK: helpers

    func sine(_ f: Double, seconds: Double, amp: Float) -> [Float] {
        (0..<Int(seconds * fs)).map { amp * Float(sin(2 * .pi * f * Double($0) / fs)) }
    }

    func rmsDB(_ x: [Float]) -> Double {
        10 * log10(Double(x.reduce(0) { $0 + $1 * $1 }) / Double(x.count) + 1e-20)
    }

    /// Room tone, then 6 s of "speech": syllables of a 120 Hz harmonic series shaped
    /// roughly like a voice, with optional low-mid boost (proximity effect).
    func syntheticTake(noise: Float, boomDB: Double) -> [Float] {
        let quiet = Int(VoiceScript.quietSeconds * fs), speech = Int(6 * fs)
        var x = (0..<(quiet + speech)).map { _ in Float.random(in: -1...1) * noise * 1.732 }
        let boom = BiquadCoeffs.peak(frequency: 220, q: 1, gainDB: boomDB, sampleRate: fs)
        var st = BiquadState()
        // Harmonics fall off like the long-term speech spectrum.
        let harmonics = Array(1...60)
        let amps = harmonics.map { pow(10, VoiceAnalyzer.referenceDB(at: 120 * Double($0)) / 20) / Double($0).squareRoot() }
        var phase = harmonics.map { Double($0) }
        for i in 0..<speech {
            let t = Double(i) / fs
            let f0 = 120 + 15 * sin(2 * .pi * 0.7 * t)
            var v = 0.0
            for j in harmonics.indices {
                let f = f0 * Double(j + 1)
                guard f < 8000 else { break }
                phase[j] += 2 * .pi * f / fs
                v += amps[j] * sin(phase[j])
            }
            let syllable = max(0, sin(2 * .pi * 3 * t))   // three syllables a second
            let y = Float(v * 0.03 * syllable * (0.6 + 0.4 * sin(2 * .pi * 0.3 * t)))
            x[quiet + i] += st.process(y, boom)
        }
        return x
    }
}
