// Looks at a test recording (a few seconds of room tone, then the test sentence) and
// works out suggested voice settings with plain-language reasons.

import Accelerate
import Foundation

public enum VoiceScript {
    /// Seconds of silence recorded first, to measure the room.
    public static let quietSeconds = 2.5
    /// Plosives (B, P) show pops and rumble, sibilants (S, sh, f) show harshness,
    /// long voiced vowels and nasals show body, mud and presence.
    public static let sentence = "Bobby picked up the big brown paper bag, and Sally sang softly while six fish swam past the shore."
    /// Said louder, the way you'd react on stream, so the limiter is set from a real peak.
    public static let loudLine = "Okay, let's go!"
}

public struct VoiceAnalysis: Sendable {
    public var sampleRate: Double
    /// RMS of the room tone, dBFS.
    public var noiseFloorDB: Double
    /// Highest sample, dBFS.
    public var peakDB: Double
    public var clippedSamples: Int
    /// Median / 10th / 95th percentile RMS of 20 ms speech frames, dBFS.
    public var speechLevelDB: Double
    public var quietSpeechDB: Double
    public var loudSpeechDB: Double
    public var speechSeconds: Double
    /// Average speech spectrum on 1/6-octave centres, dB relative to its 300 Hz–3 kHz average.
    public var bandFrequencies: [Double]
    public var spectrumDB: [Double]
    /// Loud sibilant frames' 4.5–10 kHz level above the typical voice-band level, dB.
    public var sibilanceExcessDB: Double
    public var sibilanceFrequency: Double
    /// Level the de-esser should start working at (peak of its band-pass detector), dBFS.
    public var sibilantThresholdDB: Double
    public var plosiveCount: Int
}

public enum VoiceAnalysisError: Error, LocalizedError {
    case tooShort, noSpeech

    public var errorDescription: String? {
        switch self {
        case .tooShort: "The recording was too short. Read the whole sentence, then press Done."
        case .noSpeech: "We couldn't hear enough speech. Check the mic isn't muted and try again a little closer."
        }
    }
}

public enum VoiceAnalyzer {
    /// Long-term average speech spectrum as fractional-octave band levels (dB relative to
    /// 400–500 Hz), smoothed from the published male/female averages (Byrne et al., 1994).
    /// Voices differ a lot, so the advice only reacts to clear departures from it.
    static let reference: [(Double, Double)] = [
        (50, -18), (63, -14), (80, -10), (100, -7), (125, -5), (160, -3.5), (200, -2), (250, -1.5), (315, -1),
        (400, 0), (500, 0), (630, -1.5), (800, -4.5), (1000, -7.5), (1250, -9), (1600, -10.5), (2000, -12.5),
        (2500, -14), (3150, -15), (4000, -16.5), (5000, -17.5), (6300, -18), (8000, -18.5), (10000, -19.5),
        (12500, -21), (16000, -23),
    ]

    public static func referenceDB(at f: Double) -> Double {
        let lf = log(f)
        if f <= reference[0].0 { return reference[0].1 }
        for i in 1..<reference.count where f <= reference[i].0 {
            let (f0, d0) = reference[i - 1], (f1, d1) = reference[i]
            let t = (lf - log(f0)) / (log(f1) - log(f0))
            return d0 + (d1 - d0) * t
        }
        return reference.last!.1
    }

    public static let bandFrequencies: [Double] = (0..<55).map { 40 * pow(2, Double($0) / 6) }.filter { $0 <= 16500 }

    public static func analyze(_ samples: [Float], sampleRate fs: Double, quietSeconds: Double = VoiceScript.quietSeconds) throws -> VoiceAnalysis {
        let quietEnd = min(Int(quietSeconds * fs), samples.count)
        guard samples.count - quietEnd > Int(1.5 * fs) else { throw VoiceAnalysisError.tooShort }

        // Room tone: skip the first 0.4 s (button click, settling) of the quiet part.
        let noiseStart = min(Int(0.4 * fs), quietEnd)
        let noiseFrames = frameRMS(samples, from: noiseStart, to: quietEnd, frame: Int(0.02 * fs))
        let noiseFloor = noiseFrames.isEmpty ? -90 : percentile(noiseFrames, 0.5)

        let speechPart = Array(samples[quietEnd...])
        var peak: Float = 0
        vDSP_maxmgv(speechPart, 1, &peak, vDSP_Length(speechPart.count))
        let clipped = speechPart.reduce(0) { $0 + (abs($1) >= 0.995 ? 1 : 0) }

        // Speech frames: clearly above the room.
        let frame = Int(0.02 * fs)
        let rms = frameRMS(speechPart, from: 0, to: speechPart.count, frame: frame)
        let gateDB = max(noiseFloor + 10, -60)
        let speech = rms.filter { $0 > gateDB }
        let speechSeconds = Double(speech.count) * 0.02
        guard speechSeconds >= 1.0 else { throw VoiceAnalysisError.noSpeech }

        let spectral = spectrum(speechPart, sampleRate: fs, speechThresholdDB: gateDB)
        let sib = sibilance(speechPart, sampleRate: fs, speechThresholdDB: gateDB)
        let plosives = plosiveCount(speechPart, sampleRate: fs, speechMedianDB: percentile(speech, 0.5))

        return VoiceAnalysis(
            sampleRate: fs, noiseFloorDB: noiseFloor, peakDB: 20 * log10(max(Double(peak), 1e-9)), clippedSamples: clipped,
            speechLevelDB: percentile(speech, 0.5), quietSpeechDB: percentile(speech, 0.1), loudSpeechDB: percentile(speech, 0.95),
            speechSeconds: speechSeconds, bandFrequencies: bandFrequencies, spectrumDB: spectral.db,
            sibilanceExcessDB: sib.excess, sibilanceFrequency: sib.frequency, sibilantThresholdDB: sib.thresholdDB,
            plosiveCount: plosives)
    }

    // MARK: measurements

    static func frameRMS(_ x: [Float], from: Int, to: Int, frame: Int) -> [Double] {
        guard frame > 0, to - from >= frame else { return [] }
        var out: [Double] = []
        out.reserveCapacity((to - from) / frame)
        x.withUnsafeBufferPointer { p in
            var i = from
            while i + frame <= to {
                var r: Float = 0
                vDSP_rmsqv(p.baseAddress! + i, 1, &r, vDSP_Length(frame))
                out.append(20 * log10(max(Double(r), 1e-9)))
                i += frame
            }
        }
        return out
    }

    static func percentile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return -90 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))]
    }

    /// Average power spectrum of speech frames, folded onto 1/6-octave bands.
    static func spectrum(_ x: [Float], sampleRate fs: Double, speechThresholdDB: Double) -> (db: [Double], perFrame: [[Float]]) {
        let n = 2048, hop = 1024
        guard x.count >= n, let dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: n, direction: .forward,
                                                                           transformType: .complexComplex, ofType: Float.self)
        else { return (bandFrequencies.map { _ in -60 }, []) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: n)
        var power = [Double](repeating: 0, count: n / 2)
        var frames = 0
        var i = 0
        while i + n <= x.count {
            let seg = Array(x[i..<(i + n)])
            i += hop
            var r: Float = 0
            vDSP_rmsqv(seg, 1, &r, vDSP_Length(n))
            guard 20 * log10(max(Double(r), 1e-9)) > speechThresholdDB else { continue }
            let (re, im) = dft.transform(real: vDSP.multiply(seg, window), imaginary: zeros)
            for k in 0..<(n / 2) { power[k] += Double(re[k] * re[k] + im[k] * im[k]) }
            frames += 1
        }
        guard frames > 0 else { return (bandFrequencies.map { _ in -60 }, []) }
        let binHz = fs / Double(n)
        var db = bandFrequencies.map { fc -> Double in
            let lo = fc * pow(2, -1.0 / 12), hi = fc * pow(2, 1.0 / 12)
            var k0 = Int((lo / binHz).rounded(.up)), k1 = Int((hi / binHz).rounded(.down))
            if k1 < k0 { k0 = Int((fc / binHz).rounded()); k1 = k0 }
            k0 = max(1, min(k0, n / 2 - 1)); k1 = max(k0, min(k1, n / 2 - 1))
            // Band level = average density × bandwidth, the same measure as the reference.
            let density = power[k0...k1].reduce(0, +) / Double(k1 - k0 + 1) / Double(frames)
            return 10 * log10(max(density * (hi - lo), 1e-20))
        }
        // Relative to the core of the voice, so recordings at different levels compare.
        let core = zip(bandFrequencies, db).filter { $0.0 >= 300 && $0.0 <= 3000 }.map(\.1)
        let ref = core.isEmpty ? 0 : core.reduce(0, +) / Double(core.count)
        db = db.map { $0 - ref }
        return (db, [])
    }

    /// Compares the loudest "s" moments with the body of the voice.
    static func sibilance(_ x: [Float], sampleRate fs: Double, speechThresholdDB: Double) -> (excess: Double, frequency: Double, thresholdDB: Double) {
        let frame = Int(0.01 * fs)
        guard x.count > frame * 10 else { return (-30, 6500, -30) }
        func filtered(_ coeffs: [BiquadCoeffs]) -> [Float] {
            var states = coeffs.map { _ in BiquadState() }
            return x.map { v in
                var y = v
                for j in coeffs.indices { y = states[j].process(y, coeffs[j]) }
                return y
            }
        }
        let sibBand = filtered([.highPass(frequency: 4500, q: 0.707, sampleRate: fs), .lowPass(frequency: 10000, q: 0.707, sampleRate: fs)])
        let voiceBand = filtered([.highPass(frequency: 300, q: 0.707, sampleRate: fs), .lowPass(frequency: 3000, q: 0.707, sampleRate: fs)])
        let full = frameRMS(x, from: 0, to: x.count, frame: frame)
        let s = frameRMS(sibBand, from: 0, to: x.count, frame: frame)
        let v = frameRMS(voiceBand, from: 0, to: x.count, frame: frame)
        let speechIdx = full.indices.filter { full[$0] > speechThresholdDB }
        guard !speechIdx.isEmpty else { return (-30, 6500, -30) }
        let sibPeak = percentile(speechIdx.map { s[$0] }, 0.97)
        let voiceTypical = percentile(speechIdx.map { v[$0] }, 0.5)

        // Centre frequency: where the sibilant frames have the most energy, 4.5–10 kHz.
        let sibFrames = speechIdx.filter { s[$0] > v[$0] }.prefix(400)
        var bestF = 6500.0
        if !sibFrames.isEmpty {
            let candidates = stride(from: 4500.0, through: 10000, by: 500).map { $0 }
            var bestE = -Double.infinity
            for f in candidates {
                let bp = filtered([.bandPass(frequency: f, q: 2, sampleRate: fs)])
                let e = sibFrames.reduce(0.0) { acc, idx in
                    var r: Float = 0
                    bp.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + idx * frame, 1, &r, vDSP_Length(frame)) }
                    return acc + Double(r * r)
                } / f   // constant-Q bands widen with frequency; compare energy per Hz
                if e > bestE { bestE = e; bestF = f }
            }
        }
        // Detector threshold: the de-esser's band-pass sees peaks ~3 dB above frame RMS.
        // Start just below the loud S's so only those are tamed.
        let loudSib = percentile(speechIdx.map { s[$0] }, 0.9)
        return (sibPeak - voiceTypical, bestF, loudSib + 3 - 4)
    }

    /// Frames where energy below 80 Hz dominates and is loud: breath hitting the capsule on P and B.
    static func plosiveCount(_ x: [Float], sampleRate fs: Double, speechMedianDB: Double) -> Int {
        let lp = [BiquadCoeffs.lowPass(frequency: 80, q: 0.5412, sampleRate: fs), .lowPass(frequency: 80, q: 1.3066, sampleRate: fs)]
        var st = [BiquadState(), BiquadState()]
        let low = x.map { v -> Float in
            var y = st[0].process(v, lp[0]); y = st[1].process(y, lp[1]); return y
        }
        let frame = Int(0.02 * fs)
        let lowRMS = frameRMS(low, from: 0, to: x.count, frame: frame)
        let full = frameRMS(x, from: 0, to: x.count, frame: frame)
        var count = 0, cooldown = 0
        for i in lowRMS.indices {
            if cooldown > 0 { cooldown -= 1; continue }
            if lowRMS[i] > speechMedianDB - 6 && lowRMS[i] > full[i] - 4 {
                count += 1
                cooldown = 10   // one pop, not one per frame
            }
        }
        return count
    }
}

// MARK: - Advice

public struct VoiceNote: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case good, change, warning, tip }
    public enum Action: Sendable, Equatable {
        case adjustHardwareGain(db: Double)
        case enableLowCut
        case useCardioid
    }

    public let id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var action: Action?
}

public struct MicHardwareState: Sendable {
    public var hasLowCut: Bool
    public var lowCutOn: Bool
    public var hasPolarPattern: Bool
    public var pattern: PolarPattern?
    public var canAdjustGain: Bool

    public init(hasLowCut: Bool = false, lowCutOn: Bool = false, hasPolarPattern: Bool = false,
                pattern: PolarPattern? = nil, canAdjustGain: Bool = false) {
        self.hasLowCut = hasLowCut; self.lowCutOn = lowCutOn; self.hasPolarPattern = hasPolarPattern
        self.pattern = pattern; self.canAdjustGain = canAdjustGain
    }
}

public struct VoiceRecommendation: Sendable {
    public var settings: VoiceSettings
    public var notes: [VoiceNote]
}

public enum VoiceAdvisor {
    /// Typical spoken level for streaming and calls (median of speech, dBFS RMS).
    public static let targetSpeechDB = -20.0

    public static func recommend(_ a: VoiceAnalysis, samples: [Float], hardware: MicHardwareState) -> VoiceRecommendation {
        var s = VoiceSettings()
        var notes: [VoiceNote] = []
        let quietEnd = min(Int(VoiceScript.quietSeconds * a.sampleRate), samples.count)
        let speech = Array(samples[quietEnd...])

        // Level first: a clipped or very quiet recording needs the mic's own gain changed.
        if a.clippedSamples > 0 || a.peakDB > -1 {
            let drop = max(6, (a.peakDB + 10).rounded())
            notes.append(VoiceNote(id: "gain", kind: .warning, title: "Your loudest moments clipped",
                                   detail: "The mic is distorting before any processing can help. Turn the mic gain down about \(Int(drop)) dB, then record again.",
                                   action: hardware.canAdjustGain ? .adjustHardwareGain(db: -drop) : nil))
        } else if a.speechLevelDB < -42 {
            let raise = min(18, (-30 - a.speechLevelDB).rounded())
            notes.append(VoiceNote(id: "gain", kind: .warning, title: "You're quite quiet",
                                   detail: "Boosting afterwards also boosts the room. Turn the mic gain up about \(Int(raise)) dB, or move closer, then record again.",
                                   action: hardware.canAdjustGain ? .adjustHardwareGain(db: raise) : nil))
        } else {
            notes.append(VoiceNote(id: "gain", kind: .good, title: "Mic level is good",
                                   detail: "Your peaks reached \(Int(a.peakDB.rounded())) dBFS, leaving room for louder moments."))
        }

        // Rumble and pops.
        s.highPassEnabled = true
        s.highPassFrequency = a.plosiveCount > 0 ? 100 : 80
        if a.plosiveCount > 0 {
            notes.append(VoiceNote(id: "plosive", kind: .tip, title: "Some P and B sounds popped",
                                   detail: "We cut below \(Int(s.highPassFrequency)) Hz to soften them. A pop filter, or angling the mic slightly off your mouth, fixes it at the source."))
        } else {
            notes.append(VoiceNote(id: "highpass", kind: .change, title: "Removing rumble below 80 Hz",
                                   detail: "Your voice has nothing useful down there; desk bumps, traffic and fans do."))
        }
        if hardware.hasLowCut && !hardware.lowCutOn {
            notes.append(VoiceNote(id: "lowcut", kind: .tip, title: "Turn on the mic's low-cut filter",
                                   detail: "It does the same job inside the mic, before the signal reaches your Mac.", action: .enableLowCut))
        }

        // Room noise.
        if a.noiseFloorDB > -62 {
            s.gateEnabled = true
            s.gateThresholdDB = min(a.noiseFloorDB + 8, a.quietSpeechDB - 6).rounded()
            notes.append(VoiceNote(id: "gate", kind: .change, title: "Hiding background noise between sentences",
                                   detail: "Your room measured \(Int(a.noiseFloorDB.rounded())) dBFS. A noise gate turns it down while you're not talking."))
            if hardware.hasPolarPattern, let p = hardware.pattern, p != .cardioid {
                notes.append(VoiceNote(id: "pattern", kind: .tip, title: "Use the cardioid pickup pattern",
                                       detail: "\(p.displayName) picks up the whole room. Cardioid listens mostly to what's in front of the mic.",
                                       action: .useCardioid))
            }
        } else {
            notes.append(VoiceNote(id: "gate", kind: .good, title: "Your room is quiet",
                                   detail: "Background noise measured \(Int(a.noiseFloorDB.rounded())) dBFS, so no noise gate is needed."))
        }

        // Tone, against a typical voice.
        let raw = zip(a.bandFrequencies, a.spectrumDB).map { ($0, $1 - VoiceAnalyzer.referenceDB(at: $0)) }
        // Level-independent: the 300 Hz–3 kHz core of the voice is the zero line.
        let core = raw.filter { $0.0 >= 300 && $0.0 <= 3000 }.map(\.1)
        let offset = core.isEmpty ? 0 : core.reduce(0, +) / Double(core.count)
        let dev = raw.map { ($0.0, $0.1 - offset) }
        func mean(_ lo: Double, _ hi: Double) -> Double {
            let v = dev.filter { $0.0 >= lo && $0.0 <= hi }.map(\.1)
            return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
        }
        func peak(_ lo: Double, _ hi: Double) -> (f: Double, d: Double) {
            dev.filter { $0.0 >= lo && $0.0 <= hi }.max { $0.1 < $1.1 } ?? ((lo + hi) / 2, 0)
        }

        let mud = mean(150, 350)
        if mud > 2.5 {
            let p = peak(150, 400)
            s.bands[1].frequency = p.f.rounded()
            s.bands[1].gainDB = -min(mud - 0.5, 6).rounded(toPlaces: 1)
            notes.append(VoiceNote(id: "mud", kind: .change, title: "Clearing up boominess around \(hz(p.f))",
                                   detail: "Being close to the mic builds up low-mid energy (the proximity effect), which makes speech sound muddy."))
        } else if mud < -4 {
            s.bands[0].gainDB = min(-mud - 2, 4).rounded(toPlaces: 1)
            notes.append(VoiceNote(id: "mud", kind: .change, title: "Adding a little body",
                                   detail: "Your voice is light in the low end; a gentle lift below 120 Hz makes it fuller."))
        }

        // A narrow resonance in the boxy region: higher than both neighbours by a margin.
        let boxCandidates = dev.enumerated().filter { $0.element.0 >= 350 && $0.element.0 <= 1000 }
        if let box = boxCandidates.max(by: { prominence(dev, $0.offset) < prominence(dev, $1.offset) }) {
            let prom = prominence(dev, box.offset)
            if prom > 2.5 {
                s.bands[2].frequency = box.element.0.rounded()
                s.bands[2].gainDB = -min(prom, 5).rounded(toPlaces: 1)
                s.bands[2].q = 2
                notes.append(VoiceNote(id: "box", kind: .change, title: "Reducing a boxy ring at \(hz(box.element.0))",
                                       detail: "Small rooms and desks add a hollow, cardboard-box sound. A narrow cut takes it out."))
            }
        }

        let presence = mean(2000, 5000)
        if presence < -2 {
            s.bands[3].gainDB = min(-presence, 5).rounded(toPlaces: 1)
            notes.append(VoiceNote(id: "presence", kind: .change, title: "Bringing your voice forward",
                                   detail: "A lift around 3.5 kHz helps words cut through game audio and music."))
        } else if presence > 4 {
            let p = peak(2000, 5000)
            s.bands[3].frequency = p.f.rounded()
            s.bands[3].gainDB = -min(presence - 2, 4).rounded(toPlaces: 1)
            notes.append(VoiceNote(id: "presence", kind: .change, title: "Softening harshness around \(hz(p.f))",
                                   detail: "Your voice is a little edgy there, which gets tiring to listen to."))
        }

        let air = mean(8000, 12500)
        if air < -5 {
            s.bands[4].gainDB = min(-air - 3, 4).rounded(toPlaces: 1)
            notes.append(VoiceNote(id: "air", kind: .change, title: "Adding some air",
                                   detail: "A gentle top-end lift adds clarity and openness."))
        }

        // Sibilance.
        if a.sibilanceExcessDB > -2 {
            s.deEsserEnabled = true
            s.deEsserFrequency = a.sibilanceFrequency
            s.deEsserThresholdDB = a.sibilantThresholdDB.rounded()
            notes.append(VoiceNote(id: "deess", kind: .change, title: "Taming sharp S sounds",
                                   detail: "Your S and SH sounds peak around \(hz(a.sibilanceFrequency)). A de-esser turns down just those moments."))
        }

        // Evenness: loud and quiet words brought closer together.
        let range = a.loudSpeechDB - a.quietSpeechDB
        s.compressorEnabled = true
        s.compressorRatio = range > 18 ? 3 : range > 12 ? 2.5 : 2
        s.compressorThresholdDB = (a.speechLevelDB - 2).rounded()
        notes.append(VoiceNote(id: "comp", kind: .change, title: "Evening out loud and quiet words",
                               detail: "Your level varied by \(Int(range.rounded())) dB. Gentle compression (\(String(format: "%g", s.compressorRatio)):1) keeps you steady without sounding squashed."))

        // Output level: measure the chain's result and set the gain to reach the target.
        s.limiterEnabled = true
        s.limiterCeilingDB = -1
        let probe = VoiceProcessor.render(speech, sampleRate: a.sampleRate, settings: s)
        let after = VoiceAnalyzer.percentile(
            VoiceAnalyzer.frameRMS(probe, from: 0, to: probe.count, frame: Int(0.02 * a.sampleRate)).filter { $0 > a.speechLevelDB - 25 }, 0.5)
        let needed = targetSpeechDB - after
        s.outputGainDB = min(max(needed, -12), 18).rounded(toPlaces: 1)
        // Lots of make-up gain lifts the room too; better to get it from the mic.
        if needed > 12, let i = notes.firstIndex(where: { $0.id == "gain" }), notes[i].kind == .good {
            let raise = min(needed - 6, 18).rounded()
            notes[i] = VoiceNote(id: "gain", kind: .tip, title: "Turn the mic gain up a little",
                                 detail: "We're adding \(Int(s.outputGainDB.rounded())) dB to reach a normal level. Raising the mic gain about \(Int(raise)) dB instead keeps background noise lower.",
                                 action: hardware.canAdjustGain ? .adjustHardwareGain(db: raise) : nil)
        }
        notes.append(VoiceNote(id: "limiter", kind: .change, title: "Safety limiter at −1 dB",
                               detail: "Sudden shouts and laughs won't distort for the people listening."))

        return VoiceRecommendation(settings: s, notes: notes)
    }

    private static func prominence(_ dev: [(Double, Double)], _ i: Int) -> Double {
        let lo = max(0, i - 6), hi = min(dev.count - 1, i + 6)   // ±1 octave
        let around = (lo...hi).filter { $0 != i && abs($0 - i) >= 3 }.map { dev[$0].1 }
        guard !around.isEmpty else { return 0 }
        return dev[i].1 - around.reduce(0, +) / Double(around.count)
    }

    static func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.1f kHz", f / 1000).replacingOccurrences(of: ".0 kHz", with: " kHz") : "\(Int(f.rounded())) Hz"
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}
