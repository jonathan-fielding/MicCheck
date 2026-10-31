// ngmic — command-line probe for HyperX Realtek V7 microphones.
//
//   ngmic list                      control interfaces + matching CoreAudio devices
//   ngmic monitor                   print every input report (turn knobs / tap mute)
//   ngmic get                       query mute / polar / mix / filter
//   ngmic polar cardioid|omni|stereo|bidirectional
//   ngmic mute on|off
//   ngmic mix 0..6                  mic monitoring vs playback (3 = centre)
//   ngmic lowcut on|off
//   ngmic raw <cmd> <value>         send [0x77, cmd, value] (hex or decimal)
//   ngmic led <top> [bottom] [--save] [--force]
//                                   QuadCast S colours (hex, e.g. ff0000); streams until Ctrl-C.
//                                   Refuses while MicDeck runs unless --force.
//   ngmic led off                       explains how lighting goes back to the mic's own colours

import AppKit
import CoreAudio
import Foundation
import MicKit

func hex(_ b: [UInt8]) -> String { b.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ") + (b.count > 8 ? " …" : "") }
func parseByte(_ s: String) -> UInt8? { s.lowercased().hasPrefix("0x") ? UInt8(s.dropFirst(2), radix: 16) : UInt8(s) }
func parseOnOff(_ s: String) -> Bool? { s == "on" ? true : s == "off" ? false : nil }
func usage() -> Never {
    print("usage: ngmic list|monitor|get|polar <p>|mute on|off|mix 0-6|lowcut on|off|raw <cmd> <val>|led <top> [bottom] [--save] [--force]")
    exit(2)
}

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even when piped

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { usage() }

let manager = HIDMicManager()
manager.start(runLoop: CFRunLoopGetCurrent())
CFRunLoopRunInMode(.defaultMode, 0.5, false)   // let matching callbacks fire

if verb == "led" {
    guard args.count > 1 else { usage() }
    if args[1] == "off" {
        // ngmic streams only while it runs; another process's stream can't be stopped from here.
        print("Nothing to stop: the mic shows its own colours once nothing streams to it.")
        print("If MicDeck is controlling the lights, switch lighting off from its menu bar item.")
        exit(0)
    }
    guard let top = LEDColor(hex: args[1]) else { usage() }
    var bottom = top
    if args.count > 2, !args[2].hasPrefix("--") {
        guard let b = LEDColor(hex: args[2]) else { usage() }
        bottom = b
    }
    // Two processes streaming to the lighting interface interleave packets and garble the lights.
    // Matched by bundle ID (the built app) or executable name (`swift run MicDeck`).
    let micDeckRunning = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "com.jonathanfielding.micdeck" || $0.executableURL?.lastPathComponent == "MicDeck"
    }
    if micDeckRunning && !args.contains("--force") {
        print("MicDeck is running and may be streaming to the lights; two streams garble them.")
        print("Quit MicDeck first, or pass --force if its lighting is switched off.")
        exit(1)
    }
    guard let transport = LightingTransportFinder.find() else {
        print("No QuadCast S lighting interface found.")
        for e in LightingTransportFinder.lastErrors { print("  \(e)") }
        exit(1)
    }
    print("Lighting via \(transport.transportDescription)")
    let light = QuadCastSLightController(transport: transport)
    light.onError = { print("  send error: \($0 ?? "recovered")") }
    if args.contains("--save") {
        let done = DispatchSemaphore(value: 0)
        light.save(top: top, bottom: bottom) { err in print(err.map { "save failed: \($0)" } ?? "saved to microphone"); done.signal() }
        done.wait()
        exit(0)
    }
    light.show(top: top, bottom: bottom)
    print("Streaming top \(top.hex) bottom \(bottom.hex); Ctrl-C to stop.")
    dispatchMain()
}

if verb == "list" {
    let mics = MicDevice.discover(hidMics: manager.mics)
    if mics.isEmpty { print("No supported microphone found.") }
    for d in mics {
        let control = d.hid.map { String(format: "HID PID 0x%04X (Realtek V7)", $0.productID) } ?? "OS audio only"
        print("\(d.name)  [\(control)]")
        if let a = d.audio {
            print("  audio: \(a.name)  model-uid \(a.modelUID)")
            print("  in-vol \(a.volume(kAudioDevicePropertyScopeInput).map { String(format: "%.2f", $0) } ?? "n/a")  muted \(a.muted(kAudioDevicePropertyScopeInput).map(String.init) ?? "n/a")")
        } else {
            print("  audio: no matching CoreAudio device")
        }
        print("  features: \(d.features)")
    }
    exit(0)
}

guard let mic = manager.mics.first else { print("No HID-controllable mic connected (QuadCast / QuadCast S / SoloCast have no HID commands; use `list`)."); exit(1) }
print("Using \(mic.displayName) (PID \(String(format: "0x%04X", mic.productID)))")
mic.onRawReport = { print("  <- \(hex($0))") }
mic.onEvent = { print("     \($0)") }

func send(_ r: [UInt8]) {
    let rc = mic.send(r)
    print("  -> \(hex(r))\(rc == kIOReturnSuccess ? "" : String(format: "  (IOReturn 0x%08X)", rc))")
}

switch verb {
case "monitor":
    print("Listening; Ctrl-C to stop.")
    CFRunLoopRun()
case "get":
    for c: RealtekV7.Command in [.inputMute, .polarPattern, .monitoringBalanceLevel, .globalFilters, .inputLevel] { send(RealtekV7.getReport(c)) }
case "polar":
    let map: [String: PolarPattern] = ["cardioid": .cardioid, "omni": .omnidirectional, "stereo": .stereo, "bidirectional": .bidirectional, "figure8": .bidirectional]
    guard args.count > 1, let p = map[args[1]] else { usage() }
    send(RealtekV7.setPolarPattern(p))
case "mute":
    guard args.count > 1, let on = parseOnOff(args[1]) else { usage() }
    send(RealtekV7.setMuted(on))
case "mix":
    guard args.count > 1, let v = UInt8(args[1]), DeviceCatalog.monitoringMixRange.contains(Int(v)) else { usage() }
    send(RealtekV7.setMonitoringBalance(v))
case "lowcut":
    guard args.count > 1, let on = parseOnOff(args[1]) else { usage() }
    send(RealtekV7.setHighPassFilter(on))
case "raw":
    guard args.count > 2, let c = parseByte(args[1]), let v = parseByte(args[2]) else { usage() }
    var r = [UInt8](repeating: 0, count: RealtekV7.reportLength)
    r[0] = RealtekV7.reportID; r[1] = c; r[2] = v
    send(r)
default:
    usage()
}
CFRunLoopRunInMode(.defaultMode, 0.5, false)   // collect replies
