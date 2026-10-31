import CoreAudio
import Foundation
import MicKit
import AppKit
import os
import SwiftUI

@MainActor
final class MicController: ObservableObject {
    @Published var devices: [MicDevice] = []
    @Published var selectedID: String?

    @Published var gain: Double = 0.5
    @Published var muted = false
    @Published var headphoneVolume: Double = 0.5
    @Published var polarPattern: PolarPattern = .cardioid
    @Published var monitoringMix: Double = Double(DeviceCatalog.monitoringMixCenter)
    @Published var lowCut = false

    // QuadCast S lighting
    @Published var lightingEnabled = false
    @Published var topColor = Color(red: 1, green: 0, blue: 0)
    @Published var bottomColor = Color(red: 0, green: 0.4, blue: 1)
    @Published var linkColors = false
    @Published var brightness: Double = 1
    @Published var lightingStatus: String?
    @Published var lightingAvailable = false
    private var light: QuadCastSLightController?
    /// Held while colours stream. With no window open, App Nap would otherwise throttle the
    /// 50 ms keep-alive timer and the mic would fall back to its own colours.
    private var streamingActivity: NSObjectProtocol?

    /// Voice optimiser settings and the live route to "MicDeck Microphone".
    let voice = VoiceController()

    private let manager = HIDMicManager()
    private var levelObservation: PropertyObservation?
    /// What `attach()` last wired up. Compared on rediscovery so a mic that re-enumerates
    /// under the same ID (new Core Audio device, new HID object) is attached again.
    private var attachedKey: String?
    private weak var attachedHID: HIDMic?
    private var reconnectDelay: TimeInterval = 2
    private var applyingDeviceState = false
    private var gainWork: DispatchWorkItem?
    private var headphoneWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?

    var current: MicDevice? { devices.first { $0.id == selectedID } ?? devices.first }
    var features: MicFeatures { current?.features ?? [] }

    init() {
        loadLightingSettings()
        manager.onChange = { [weak self] _ in Task { @MainActor in self?.rediscover() } }
        AudioDevice.observeDeviceList { [weak self] in Task { @MainActor in self?.rediscover() } }
        let hidResult = manager.start()
        if hidResult != kIOReturnSuccess {
            DebugLog.logger.error("HID manager open failed: \(String(format: "0x%08X", hidResult), privacy: .public)")
        }
        rediscover()
    }

    func rediscover() {
        devices = MicDevice.discover(hidMics: manager.mics)
        if !devices.contains(where: { $0.id == selectedID }) { selectedID = devices.first?.id }
        if connectionKey(current) != attachedKey { attach() }
        voice.refreshDriver()   // the driver's devices come and go with the device list
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        attach()
    }

    private func connectionKey(_ d: MicDevice?) -> String? {
        guard let d else { return nil }
        return "\(d.id)|\(d.audio?.id ?? 0)|\(d.hid.map { "\(ObjectIdentifier($0))" } ?? "-")"
    }

    private func attach() {
        attachedKey = connectionKey(current)
        voice.setSource(current)
        levelObservation = nil
        // Knob and tap-to-mute events from a mic that's no longer shown must not reach the UI.
        attachedHID?.onEvent = nil
        attachedHID = current?.hid
        guard let d = current else { dropLighting(); return }
        d.hid?.onEvent = { [weak self] ev in Task { @MainActor in self?.apply(ev) } }
        levelObservation = d.audio?.observeLevels { [weak self] in Task { @MainActor in self?.refreshFromOS() } }
        refreshFromOS()
        d.hid?.requestState()
        attachLighting(d)
    }

    // MARK: lighting

    private func attachLighting(_ d: MicDevice) {
        // Offscreen layout snapshots must never talk to the mic: a second process streaming
        // alongside the running app interleaves packets and can leave the lights stuck.
        if DebugSnapshot.isRequested { lightingAvailable = true; return }
        guard d.features.contains(.rgbLighting) else {
            dropLighting(); lightingEnabled = false; lightingStatus = nil
            return
        }
        if light == nil, let t = LightingTransportFinder.find() {
            let c = QuadCastSLightController(transport: t)
            // Errors can arrive after this controller was replaced; only the current one may drop the light.
            c.onError = { [weak self, weak c] msg in
                Task { @MainActor in
                    guard let self, let c, c === self.light else { return }
                    self.lightingSendFailed(msg)
                }
            }
            light = c
            reconnectDelay = 2
            lightingStatus = "Connected via \(t.transportDescription)"
        } else if light == nil {
            lightingStatus = "Lighting interface not reachable" + (LightingTransportFinder.lastErrors.first.map { ": \($0)" } ?? "")
            scheduleLightingReconnect()
        }
        lightingAvailable = light != nil
        pushLighting()
    }

    /// The lighting interface is a separate USB device, so it can drop and come back
    /// (unplug, sleep, hub reset) without the audio device changing. A failed send means
    /// our handle is dead: drop it and look for the interface again.
    private func lightingSendFailed(_ message: String?) {
        guard let message else { return }
        DebugLog.logger.error("Lighting send failed: \(message, privacy: .public); reconnecting")
        dropLighting()
        lightingStatus = "Lighting disconnected, reconnecting…"
        scheduleLightingReconnect()
    }

    private func dropLighting() {
        reconnectWork?.cancel()
        light?.stop()
        light = nil
        lightingAvailable = false
        setStreamingActivity(false)
    }

    private func setStreamingActivity(_ on: Bool) {
        if on, streamingActivity == nil {
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Keeping the microphone's lighting colours active")
        } else if !on, let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
    }

    /// Retries after 2 s, backing off to every 10 s while the interface stays missing.
    private func scheduleLightingReconnect() {
        reconnectWork?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 10)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.light == nil, let d = self.current, d.features.contains(.rgbLighting) else { return }
            self.attachLighting(d)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Remembered between launches so lighting comes back when the app starts
    // (e.g. at login). The mic can't be relied on to store colours itself.
    private enum Key {
        static let enabled = "lighting.enabled", top = "lighting.top", bottom = "lighting.bottom"
        static let link = "lighting.link", brightness = "lighting.brightness"
    }

    private func loadLightingSettings() {
        let d = UserDefaults.standard
        lightingEnabled = d.bool(forKey: Key.enabled)
        if let h = d.string(forKey: Key.top), let c = LEDColor(hex: h) { topColor = color(c) }
        if let h = d.string(forKey: Key.bottom), let c = LEDColor(hex: h) { bottomColor = color(c) }
        linkColors = d.bool(forKey: Key.link)
        if d.object(forKey: Key.brightness) != nil { brightness = d.double(forKey: Key.brightness) }
    }

    private func saveLightingSettings() {
        let d = UserDefaults.standard
        d.set(lightingEnabled, forKey: Key.enabled)
        d.set(rgb(topColor, applyBrightness: false).hex, forKey: Key.top)
        d.set(rgb(bottomColor, applyBrightness: false).hex, forKey: Key.bottom)
        d.set(linkColors, forKey: Key.link)
        d.set(brightness, forKey: Key.brightness)
    }

    private func color(_ c: LEDColor) -> Color {
        Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    /// Colours for the menu bar icon's light band: the live LED colours while lighting
    /// is on, nil (see-through) when it's off, the app's gradient for mics without lighting.
    var menuBarBand: [NSColor]? {
        guard features.contains(.rgbLighting) else { return MenuBarIcon.defaultBand }
        guard lightingEnabled, lightingAvailable else { return nil }
        return [NSColor(topColor), NSColor(linkColors ? topColor : bottomColor)]
    }

    /// One-line state for the menu bar.
    var lightingSummary: String {
        guard features.contains(.rgbLighting) else { return current == nil ? "No microphone attached" : "No lighting on this mic" }
        if !lightingAvailable { return "Lighting not reachable" }
        return lightingEnabled ? "Lighting on" : "Lighting off (mic shows its own colours)"
    }

    func setLightingEnabled(_ on: Bool) {
        lightingEnabled = on
        lightingChanged()
    }

    private func rgb(_ c: Color, applyBrightness: Bool = true) -> LEDColor {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        func b(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        let raw = LEDColor(r: b(n.redComponent), g: b(n.greenComponent), b: b(n.blueComponent))
        return applyBrightness ? raw.scaled(brightness) : raw
    }

    private var currentColors: (LEDColor, LEDColor) {
        let top = rgb(topColor)
        return (top, linkColors ? top : rgb(bottomColor))
    }

    func lightingChanged() {
        saveLightingSettings()
        pushLighting()
    }

    /// Sends the current lighting state to the mic without touching saved settings.
    private func pushLighting() {
        guard let light else { setStreamingActivity(false); return }
        setStreamingActivity(lightingEnabled)
        if lightingEnabled {
            let (top, bottom) = currentColors
            light.show(top: top, bottom: bottom)
        } else {
            light.stop()
        }
    }

    func saveLighting() {
        guard let light else { return }
        let (top, bottom) = currentColors
        lightingStatus = "Saving to microphone…"
        light.save(top: top, bottom: bottom) { [weak self] err in
            Task { @MainActor in self?.lightingStatus = err.map { "Save failed: \($0)" } ?? "Save sequence sent. If the mic doesn't keep these colours after you quit, use Open at Login instead." }
        }
    }

    func refreshFromOS() {
        guard let audio = current?.audio else { return }
        applyingDeviceState = true
        defer { applyingDeviceState = false }
        if let v = audio.volume(kAudioDevicePropertyScopeInput) { gain = Double(v) }
        if let m = audio.muted(kAudioDevicePropertyScopeInput) { muted = m }
        if let v = audio.volume(kAudioDevicePropertyScopeOutput) { headphoneVolume = Double(v) }
    }

    private func apply(_ ev: MicEvent) {
        applyingDeviceState = true
        defer { applyingDeviceState = false }
        switch ev {
        case .muted(let m): muted = m
        case .polarPattern(let p): polarPattern = p
        case .monitoringBalance(let v):
            let range = DeviceCatalog.monitoringMixRange   // the byte comes from the device; keep it on the fader
            monitoringMix = Double(min(max(Int(v), range.lowerBound), range.upperBound))
        case .highPassFilter(let on): lowCut = on
        case .inputLevel: break   // gain is owned by CoreAudio
        }
    }

    // MARK: user changes

    func gainChanged() {
        guard !applyingDeviceState, let audio = current?.audio else { return }
        // Debounce slider writes: only the last value in each 50 ms burst is sent.
        gainWork?.cancel()
        let value = Float(gain)
        let work = DispatchWorkItem { audio.setVolume(value, kAudioDevicePropertyScopeInput) }
        gainWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func headphoneVolumeChanged() {
        guard !applyingDeviceState, let audio = current?.audio else { return }
        headphoneWork?.cancel()
        let value = Float(headphoneVolume)
        let work = DispatchWorkItem { audio.setVolume(value, kAudioDevicePropertyScopeOutput) }
        headphoneWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func mutedChanged() {
        guard !applyingDeviceState else { return }
        current?.audio?.setMuted(muted, kAudioDevicePropertyScopeInput)
        current?.hid?.send(RealtekV7.setMuted(muted))
    }

    func polarPatternChanged() {
        guard !applyingDeviceState else { return }
        current?.hid?.send(RealtekV7.setPolarPattern(polarPattern))
    }

    func monitoringMixChanged() {
        guard !applyingDeviceState else { return }
        current?.hid?.send(RealtekV7.setMonitoringBalance(UInt8(monitoringMix.rounded())))
    }

    func lowCutChanged() {
        guard !applyingDeviceState else { return }
        current?.hid?.send(RealtekV7.setHighPassFilter(lowCut))
    }

    // MARK: voice optimiser

    /// What the optimiser may suggest changing on the mic itself.
    var hardwareState: MicHardwareState {
        MicHardwareState(hasLowCut: features.contains(.lowCutFilter), lowCutOn: lowCut,
                         hasPolarPattern: features.contains(.polarPattern), pattern: polarPattern,
                         canAdjustGain: current?.audio?.canAdjustDecibels(kAudioDevicePropertyScopeInput) ?? false)
    }

    func perform(_ action: VoiceNote.Action) {
        switch action {
        case .adjustHardwareGain(let db):
            current?.audio?.adjustVolume(byDecibels: db, kAudioDevicePropertyScopeInput)
            refreshFromOS()
        case .enableLowCut:
            lowCut = true
            lowCutChanged()
        case .useCardioid:
            polarPattern = .cardioid
            polarPatternChanged()
        }
    }
}
