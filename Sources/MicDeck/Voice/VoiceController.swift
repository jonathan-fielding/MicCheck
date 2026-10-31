import AVFoundation
import CoreAudio
import Foundation
import MicKit
import Synchronization

/// Owns the applied voice settings and the live route from the real mic to
/// "MicDeck Microphone". The route only runs while some app is recording from
/// MicDeck Microphone, so the mic (and macOS's orange indicator) is idle otherwise.
@MainActor
final class VoiceController: ObservableObject {
    static let micUID = "MicDeckAudio_Mic"
    static let feedUID = "MicDeckAudio_Feed"

    enum RouteState: Equatable {
        /// No app is recording from MicDeck Microphone.
        case idle
        case active
        case failed(String)
    }

    @Published private(set) var driverInstalled = false
    /// The selected mic's profile (neutral when it hasn't been tuned).
    @Published private(set) var settings: VoiceSettings = .neutral
    /// True once the selected mic has been tuned in the optimiser.
    @Published private(set) var hasSettings = false
    /// Name of the mic model the current profile belongs to.
    @Published private(set) var profileName: String?
    @Published var processingEnabled: Bool {
        didSet { UserDefaults.standard.set(processingEnabled, forKey: Key.enabled); pushSettings() }
    }
    @Published private(set) var route: RouteState = .idle
    /// Live output level (0…1, -60…0 dBFS) while routing.
    @Published private(set) var outputLevel: Float = 0

    /// Where the "Install" button sends people. Set MicDeckAudioDriverURL in Info.plist (build-app.sh
    /// takes DRIVER_DOWNLOAD_URL); without it the install step shows manual instructions.
    let driverDownloadURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "MicDeckAudioDriverURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }

    private var virtualMicID: AudioObjectID?
    private var feedID: AudioObjectID?
    private var sourceID: AudioObjectID?
    private var runningObservation: PropertyObservation?
    private var router: LiveVoiceRouter?
    private var meterTimer: Timer?

    /// One profile per mic model, so swapping mics picks up that mic's tuning.
    private var profiles: [String: VoiceSettings] = [:]
    private var profileKey: String?

    private enum Key {
        static let profiles = "voice.profiles", enabled = "voice.enabled"
        /// Single profile from before profiles were per model; given to the first mic selected.
        static let legacySettings = "voice.settings"
    }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Key.profiles), let p = try? JSONDecoder().decode([String: VoiceSettings].self, from: data) {
            profiles = p
        }
        processingEnabled = d.object(forKey: Key.enabled) == nil ? true : d.bool(forKey: Key.enabled)
        refreshDriver()
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: Key.profiles) }
    }

    /// Profiles are keyed by model ("HyperX QuadCast S"), so two units of the same model share one,
    /// and fall back to the audio device name for mics outside the catalog.
    private static func profileKey(for mic: MicDevice?) -> String? {
        guard let mic else { return nil }
        return mic.model?.name ?? mic.audio?.name
    }

    private func loadProfile(_ key: String?) {
        profileKey = key
        profileName = key
        if let key, profiles[key] == nil, let data = UserDefaults.standard.data(forKey: Key.legacySettings),
           let legacy = try? JSONDecoder().decode(VoiceSettings.self, from: data) {
            profiles[key] = legacy
            saveProfiles()
            UserDefaults.standard.removeObject(forKey: Key.legacySettings)
        }
        let profile = key.flatMap { profiles[$0] }
        settings = profile ?? .neutral
        hasSettings = profile != nil
        pushSettings()
    }

    /// An untuned mic passes through MicDeck Microphone untouched.
    private func pushSettings() { router?.update(settings, bypass: !processingEnabled || !hasSettings) }

    // MARK: inputs from MicController

    /// Called whenever the device list changes; the driver may have been installed or removed.
    func refreshDriver() {
        let mic = AudioHAL.device(uid: Self.micUID), feed = AudioHAL.device(uid: Self.feedUID)
        driverInstalled = mic != nil && feed != nil
        guard mic != virtualMicID || feed != feedID else { evaluate(); return }
        stopRouting()
        virtualMicID = mic
        feedID = feed
        runningObservation = mic.map { AudioHAL.observeRunning($0) { [weak self] in Task { @MainActor in self?.evaluate() } } }
        evaluate()
    }

    /// The real mic to read from (the one selected in MicDeck), and whose profile to use.
    func setSource(_ mic: MicDevice?) {
        let key = Self.profileKey(for: mic)
        if key != profileKey { loadProfile(key) }
        guard mic?.audio?.id != sourceID else { return }
        stopRouting()
        sourceID = mic?.audio?.id
        evaluate()
    }

    // MARK: settings

    /// Saves `newSettings` as the selected mic's profile and uses it straight away.
    func apply(_ newSettings: VoiceSettings) {
        guard let key = profileKey else { return }
        profiles[key] = newSettings
        saveProfiles()
        settings = newSettings
        hasSettings = true
        processingEnabled = true
        pushSettings()
    }

    // MARK: routing

    private var virtualMicInUse: Bool { virtualMicID.map(AudioHAL.isRunningSomewhere) ?? false }

    private func evaluate() {
        guard driverInstalled, virtualMicInUse, let src = sourceID, let feed = feedID else {
            stopRouting()
            return
        }
        guard router == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRouting(source: src, feed: feed)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.evaluate() } }
        default:
            route = .failed("Allow MicDeck in System Settings › Privacy & Security › Microphone")
        }
    }

    private func startRouting(source: AudioObjectID, feed: AudioObjectID) {
        do {
            let r = try LiveVoiceRouter(micID: source, feedID: feed, settings: settings, bypass: !processingEnabled || !hasSettings)
            try r.start()
            router = r
            route = .active
            DebugLog.write("voice route started")
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.router else { return }
                    let peak = Float(bitPattern: r.outputPeak.load(ordering: .relaxed))
                    let db = 20 * log10(max(peak, 1e-6))
                    self.outputLevel = min(max((db + 60) / 60, 0), 1)
                }
            }
        } catch {
            route = .failed(error.localizedDescription)
            DebugLog.write("voice route failed: \(error)")
        }
    }

    private func stopRouting() {
        meterTimer?.invalidate()
        meterTimer = nil
        router?.stop()
        router = nil
        outputLevel = 0
        if case .failed = route, driverInstalled, virtualMicInUse { return }   // keep the error visible while it applies
        route = .idle
    }
}
