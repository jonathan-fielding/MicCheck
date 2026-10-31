// Settings for the voice chain that runs on "MicDeck Microphone":
//
//   high-pass → noise gate → 5-band EQ → de-esser → compressor → output gain → limiter

import Foundation

public struct EQBand: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case lowShelf, peak, highShelf }

    public var id: Int
    public var kind: Kind
    public var frequency: Double
    public var gainDB: Double
    /// Bandwidth for peaks; slope for shelves (0.7 ≈ gentle).
    public var q: Double

    public init(id: Int, kind: Kind, frequency: Double, gainDB: Double = 0, q: Double) {
        self.id = id; self.kind = kind; self.frequency = frequency; self.gainDB = gainDB; self.q = q
    }

    /// What each of the five bands is for, in the order they're stored.
    public static let roles: [(name: String, range: ClosedRange<Double>)] = [
        ("Body", 60...300),
        ("Warmth", 120...500),
        ("Boxiness", 300...1500),
        ("Presence", 1500...7000),
        ("Air", 6000...16000),
    ]
    public var role: (name: String, range: ClosedRange<Double>) { Self.roles[min(max(id, 0), Self.roles.count - 1)] }
}

public struct VoiceSettings: Codable, Equatable, Sendable {
    public var highPassEnabled = true
    public var highPassFrequency = 80.0

    public var gateEnabled = false
    public var gateThresholdDB = -55.0

    public var bands: [EQBand] = VoiceSettings.flatBands

    public var deEsserEnabled = false
    public var deEsserFrequency = 6500.0
    public var deEsserThresholdDB = -30.0

    public var compressorEnabled = false
    public var compressorThresholdDB = -24.0
    public var compressorRatio = 3.0

    public var outputGainDB = 0.0

    public var limiterEnabled = true
    public var limiterCeilingDB = -1.0

    public init() {}

    public static let flatBands: [EQBand] = [
        EQBand(id: 0, kind: .lowShelf, frequency: 120, q: 0.7),
        EQBand(id: 1, kind: .peak, frequency: 250, q: 1.0),
        EQBand(id: 2, kind: .peak, frequency: 600, q: 1.8),
        EQBand(id: 3, kind: .peak, frequency: 3500, q: 1.0),
        EQBand(id: 4, kind: .highShelf, frequency: 10000, q: 0.7),
    ]

    /// Nothing but the safety limiter: what the mic sounds like untouched.
    public static let neutral = VoiceSettings()

    /// Combined magnitude of the high-pass and EQ bands at `frequency`, in dB.
    public func eqResponseDB(at frequency: Double, sampleRate: Double = 48000) -> Double {
        var db = 0.0
        if highPassEnabled {
            for c in BiquadCoeffs.highPass24(frequency: highPassFrequency, sampleRate: sampleRate) {
                db += c.magnitudeDB(at: frequency, sampleRate: sampleRate)
            }
        }
        for b in bands where abs(b.gainDB) > 0.01 {
            db += BiquadCoeffs.band(b, sampleRate: sampleRate).magnitudeDB(at: frequency, sampleRate: sampleRate)
        }
        return db
    }
}
