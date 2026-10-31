// Real-time voice chain (mono Float32). The same code renders the preview and the live
// "MicDeck Microphone" signal, so what the user hears while tuning is what apps get.

import Foundation
import os

// MARK: - Biquad

/// Normalised biquad coefficients (a0 = 1), RBJ Audio EQ Cookbook.
public struct BiquadCoeffs: Sendable, Equatable {
    public var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    public static let identity = BiquadCoeffs()

    private static func make(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> BiquadCoeffs {
        BiquadCoeffs(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0), a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    private static func w0(_ f: Double, _ fs: Double) -> Double { 2 * .pi * min(max(f, 10), fs * 0.45) / fs }

    public static func peak(frequency f: Double, q: Double, gainDB: Double, sampleRate fs: Double) -> BiquadCoeffs {
        let A = pow(10, gainDB / 40), w = w0(f, fs), alpha = sin(w) / (2 * max(q, 0.1)), c = cos(w)
        return make(1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c, 1 - alpha / A)
    }

    public static func lowShelf(frequency f: Double, q: Double, gainDB: Double, sampleRate fs: Double) -> BiquadCoeffs {
        let A = pow(10, gainDB / 40), w = w0(f, fs), alpha = sin(w) / (2 * max(q, 0.1)), c = cos(w), s = 2 * sqrt(A) * alpha
        return make(A * ((A + 1) - (A - 1) * c + s), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - s),
                    (A + 1) + (A - 1) * c + s, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - s)
    }

    public static func highShelf(frequency f: Double, q: Double, gainDB: Double, sampleRate fs: Double) -> BiquadCoeffs {
        let A = pow(10, gainDB / 40), w = w0(f, fs), alpha = sin(w) / (2 * max(q, 0.1)), c = cos(w), s = 2 * sqrt(A) * alpha
        return make(A * ((A + 1) + (A - 1) * c + s), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - s),
                    (A + 1) - (A - 1) * c + s, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - s)
    }

    public static func highPass(frequency f: Double, q: Double, sampleRate fs: Double) -> BiquadCoeffs {
        let w = w0(f, fs), alpha = sin(w) / (2 * q), c = cos(w)
        return make((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    public static func lowPass(frequency f: Double, q: Double, sampleRate fs: Double) -> BiquadCoeffs {
        let w = w0(f, fs), alpha = sin(w) / (2 * q), c = cos(w)
        return make((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    /// Band-pass with 0 dB gain at the centre.
    public static func bandPass(frequency f: Double, q: Double, sampleRate fs: Double) -> BiquadCoeffs {
        let w = w0(f, fs), alpha = sin(w) / (2 * q), c = cos(w)
        return make(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha)
    }

    /// 4th-order Butterworth high-pass (24 dB/octave) as two biquads.
    public static func highPass24(frequency f: Double, sampleRate fs: Double) -> [BiquadCoeffs] {
        [highPass(frequency: f, q: 0.5412, sampleRate: fs), highPass(frequency: f, q: 1.3066, sampleRate: fs)]
    }

    public static func band(_ b: EQBand, sampleRate fs: Double) -> BiquadCoeffs {
        guard abs(b.gainDB) > 0.01 else { return .identity }
        switch b.kind {
        case .peak: return peak(frequency: b.frequency, q: b.q, gainDB: b.gainDB, sampleRate: fs)
        case .lowShelf: return lowShelf(frequency: b.frequency, q: b.q, gainDB: b.gainDB, sampleRate: fs)
        case .highShelf: return highShelf(frequency: b.frequency, q: b.q, gainDB: b.gainDB, sampleRate: fs)
        }
    }

    public func magnitudeDB(at f: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = Double(b0) + Double(b1) * c1 + Double(b2) * c2, ni = -(Double(b1) * s1 + Double(b2) * s2)
        let dr = 1 + Double(a1) * c1 + Double(a2) * c2, di = -(Double(a1) * s1 + Double(a2) * s2)
        let mag2 = (nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30)
        return 10 * log10(max(mag2, 1e-30))
    }
}

/// Transposed direct form II state.
struct BiquadState {
    var z1: Float = 0, z2: Float = 0

    @inline(__always)
    mutating func process(_ x: Float, _ c: BiquadCoeffs) -> Float {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

@inline(__always) func dbToLinear(_ db: Double) -> Float { Float(pow(10, db / 20)) }
/// One-pole smoothing coefficient for a time constant in seconds.
@inline(__always) func timeCoeff(_ seconds: Double, _ fs: Double) -> Float { Float(exp(-1 / (max(seconds, 1e-5) * fs))) }

// MARK: - Processor

/// Not thread-safe except `update(_:bypass:)`, which may be called from any thread while
/// another thread runs `process`. The new settings are picked up at the next block.
public final class VoiceProcessor: @unchecked Sendable {
    /// Everything the audio thread needs, precomputed off it. No arrays: copying this must not allocate.
    struct Params {
        var bypass = false
        var hpOn = false, hp1 = BiquadCoeffs.identity, hp2 = BiquadCoeffs.identity
        var gateOn = false, gateOpen: Float = 0, gateClose: Float = 0, gateFloor: Float = 0.03
        var eq0 = BiquadCoeffs.identity, eq1 = BiquadCoeffs.identity, eq2 = BiquadCoeffs.identity
        var eq3 = BiquadCoeffs.identity, eq4 = BiquadCoeffs.identity
        var deOn = false, deBand = BiquadCoeffs.identity, deThreshold: Float = 1
        var compOn = false, compThresholdDB: Float = 0, compSlope: Float = 0, compKneeLow: Float = 1
        var outGain: Float = 1
        var limOn = false, limCeiling: Float = 1
    }

    public let sampleRate: Double
    private let pending = OSAllocatedUnfairLock<Params?>(initialState: nil)
    private var p = Params()

    private var hp1 = BiquadState(), hp2 = BiquadState()
    private var eq0 = BiquadState(), eq1 = BiquadState(), eq2 = BiquadState(), eq3 = BiquadState(), eq4 = BiquadState()
    private var deBand = BiquadState()
    private var gateEnv: Float = 0, gateGain: Float = 1, gateHold = 0, gateIsOpen = true
    private var deEnv: Float = 0, deGain: Float = 1
    private var compEnv: Float = 0
    private var limGain: Float = 1

    // Time constants, fixed per sample rate.
    private let envRelease: Float, gateAttack: Float, gateRelease: Float, gateHoldSamples: Int
    private let deAttack: Float, deRelease: Float, deSmooth: Float
    private let compAttack: Float, compRelease: Float, limRelease: Float

    public init(sampleRate: Double, settings: VoiceSettings = .neutral) {
        self.sampleRate = sampleRate
        envRelease = timeCoeff(0.05, sampleRate)
        gateAttack = timeCoeff(0.002, sampleRate)
        gateRelease = timeCoeff(0.08, sampleRate)
        gateHoldSamples = Int(0.15 * sampleRate)
        deAttack = timeCoeff(0.001, sampleRate)
        deRelease = timeCoeff(0.06, sampleRate)
        deSmooth = timeCoeff(0.002, sampleRate)
        compAttack = timeCoeff(0.005, sampleRate)
        compRelease = timeCoeff(0.15, sampleRate)
        limRelease = timeCoeff(0.06, sampleRate)
        p = Self.params(settings, sampleRate: sampleRate, bypass: false)
    }

    public func update(_ settings: VoiceSettings, bypass: Bool = false) {
        let params = Self.params(settings, sampleRate: sampleRate, bypass: bypass)
        pending.withLock { $0 = params }
    }

    /// Clears filter and envelope state, e.g. before playing a recording from the start.
    public func reset() {
        hp1 = .init(); hp2 = .init(); eq0 = .init(); eq1 = .init(); eq2 = .init(); eq3 = .init(); eq4 = .init(); deBand = .init()
        gateEnv = 0; gateGain = 1; gateHold = 0; gateIsOpen = true
        deEnv = 0; deGain = 1; compEnv = 0; limGain = 1
    }

    static func params(_ s: VoiceSettings, sampleRate fs: Double, bypass: Bool) -> Params {
        var p = Params()
        p.bypass = bypass
        p.hpOn = s.highPassEnabled
        let hp = BiquadCoeffs.highPass24(frequency: s.highPassFrequency, sampleRate: fs)
        p.hp1 = hp[0]; p.hp2 = hp[1]
        p.gateOn = s.gateEnabled
        p.gateOpen = dbToLinear(s.gateThresholdDB)
        p.gateClose = dbToLinear(s.gateThresholdDB - 4)   // hysteresis so the gate doesn't chatter
        let bands = s.bands + VoiceSettings.flatBands.dropFirst(s.bands.count)
        p.eq0 = .band(bands[0], sampleRate: fs); p.eq1 = .band(bands[1], sampleRate: fs); p.eq2 = .band(bands[2], sampleRate: fs)
        p.eq3 = .band(bands[3], sampleRate: fs); p.eq4 = .band(bands[4], sampleRate: fs)
        p.deOn = s.deEsserEnabled
        p.deBand = .bandPass(frequency: s.deEsserFrequency, q: 1.4, sampleRate: fs)
        p.deThreshold = dbToLinear(s.deEsserThresholdDB)
        p.compOn = s.compressorEnabled
        p.compThresholdDB = Float(s.compressorThresholdDB)
        p.compSlope = Float(1 - 1 / max(s.compressorRatio, 1))
        p.compKneeLow = dbToLinear(s.compressorThresholdDB - 3)
        p.outGain = dbToLinear(s.outputGainDB)
        p.limOn = s.limiterEnabled
        p.limCeiling = dbToLinear(s.limiterCeilingDB)
        return p
    }

    /// Processes `count` samples in place.
    public func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        if let next = pending.withLockIfAvailable({ state -> Params? in
            defer { state = nil }
            return state
        }) ?? nil {
            p = next
        }
        let p = self.p
        if p.bypass { return }
        let kneeWidth: Float = 6

        for i in 0..<count {
            var x = buffer[i]
            if p.hpOn {
                x = hp1.process(x, p.hp1)
                x = hp2.process(x, p.hp2)
            }

            if p.gateOn {
                let a = abs(x)
                gateEnv = a > gateEnv ? a : gateEnv * envRelease
                if gateEnv >= p.gateOpen {
                    gateIsOpen = true
                    gateHold = gateHoldSamples
                } else if gateEnv < p.gateClose {
                    if gateHold > 0 { gateHold -= 1 } else { gateIsOpen = false }
                }
                let target: Float = gateIsOpen ? 1 : p.gateFloor
                let k = target > gateGain ? gateAttack : gateRelease
                gateGain = target + (gateGain - target) * k
                x *= gateGain
            }

            x = eq0.process(x, p.eq0)
            x = eq1.process(x, p.eq1)
            x = eq2.process(x, p.eq2)
            x = eq3.process(x, p.eq3)
            x = eq4.process(x, p.eq4)

            if p.deOn {
                // Split-band: only the sibilant band is turned down, the rest of the voice is untouched.
                let band = deBand.process(x, p.deBand)
                let a = abs(band)
                deEnv = a > deEnv ? a + (deEnv - a) * deAttack : deEnv * deRelease
                var target: Float = 1
                if deEnv > p.deThreshold {
                    let overDB = 20 * log10f(deEnv / p.deThreshold)
                    target = powf(10, -min(overDB * 0.75, 10) / 20)
                }
                deGain = target + (deGain - target) * deSmooth
                x -= band * (1 - deGain)
            }

            if p.compOn {
                let a = abs(x)
                let k = a > compEnv ? compAttack : compRelease
                compEnv = a + (compEnv - a) * k
                if compEnv > p.compKneeLow {
                    let over = 20 * log10f(compEnv) - p.compThresholdDB
                    let reduction: Float
                    if over >= kneeWidth / 2 {
                        reduction = over * p.compSlope
                    } else {
                        let t = over + kneeWidth / 2
                        reduction = p.compSlope * t * t / (2 * kneeWidth)
                    }
                    x *= powf(10, -reduction / 20)
                }
            }

            x *= p.outGain

            if p.limOn {
                let a = abs(x)
                let target: Float = a > p.limCeiling ? p.limCeiling / a : 1
                limGain = target < limGain ? target : min(target, 1 + (limGain - 1) * limRelease)
                x *= limGain
            }

            buffer[i] = x
        }
    }

    /// Renders a whole recording offline with fresh state.
    public static func render(_ samples: [Float], sampleRate: Double, settings: VoiceSettings) -> [Float] {
        let proc = VoiceProcessor(sampleRate: sampleRate, settings: settings)
        var out = samples
        out.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i < buf.count {
                let n = min(512, buf.count - i)
                proc.process(base + i, count: n)
                i += n
            }
        }
        return out
    }
}
