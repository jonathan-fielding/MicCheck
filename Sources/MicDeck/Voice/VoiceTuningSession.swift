import AVFoundation
import CoreAudio
import Foundation
import MicKit

/// State of one pass through the optimiser: record → analyse → tweak → apply.
@MainActor
final class VoiceTuningSession: ObservableObject {
    enum Step: Equatable { case intro, recording, analysing, tune }

    @Published var step: Step = .intro
    @Published private(set) var analysis: VoiceAnalysis?
    @Published private(set) var notes: [VoiceNote] = []
    @Published private(set) var suggested = VoiceSettings()
    @Published var draft = VoiceSettings() { didSet { if draft != oldValue { player.update(draft) } } }
    @Published var selectedBand: Int? = nil
    @Published private(set) var error: String?
    /// Hardware actions the user took; the take no longer matches the mic, so suggest recording again.
    @Published private(set) var hardwareChanged = false
    @Published var appliedMessage: String?

    let recorder = VoiceRecorder()
    let player = PreviewPlayer()

    func startRecording(deviceID: AudioObjectID?) {
        guard let deviceID else { error = "No microphone selected."; return }
        player.stop()
        error = nil
        appliedMessage = nil
        recorder.start(deviceID: deviceID)
        if let e = recorder.error { error = e; return }
        step = .recording
    }

    func cancelRecording() {
        recorder.cancel()
        step = analysis == nil ? .intro : .tune
    }

    func finishRecording(hardware: MicHardwareState) {
        guard let take = recorder.finish() else { return }
        let rate = recorder.sampleRate
        step = .analysing
        error = nil
        Task.detached(priority: .userInitiated) {
            let result: Result<(VoiceAnalysis, VoiceRecommendation), Error> = Result {
                let a = try VoiceAnalyzer.analyze(take, sampleRate: rate)
                return (a, VoiceAdvisor.recommend(a, samples: take, hardware: hardware))
            }
            await MainActor.run { self.finishedAnalysis(result, take: take, rate: rate) }
        }
    }

    private func finishedAnalysis(_ result: Result<(VoiceAnalysis, VoiceRecommendation), Error>, take: [Float], rate: Double) {
        switch result {
        case .success(let (a, rec)):
            analysis = a
            notes = rec.notes
            suggested = rec.settings
            draft = rec.settings
            hardwareChanged = false
            selectedBand = nil
            // Start playback just before the speech, after the room tone.
            player.load(take, sampleRate: rate, startAt: Int((VoiceScript.quietSeconds - 0.3) * rate), settings: draft)
            step = .tune
        case .failure(let e):
            error = e.localizedDescription
            step = analysis == nil ? .intro : .tune
        }
    }

    func resetToSuggested() { draft = suggested }

    #if DEBUG
    /// Snapshot support: analyse a file as if it had just been recorded.
    func debugLoad(path: String, hardware: MicHardwareState) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { return }
        let take = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        let rate = file.processingFormat.sampleRate
        let result: Result<(VoiceAnalysis, VoiceRecommendation), Error> = Result {
            let a = try VoiceAnalyzer.analyze(take, sampleRate: rate)
            return (a, VoiceAdvisor.recommend(a, samples: take, hardware: hardware))
        }
        finishedAnalysis(result, take: take, rate: rate)
        selectedBand = 1
    }
    #endif

    func markHardwareChanged(_ noteID: String) {
        hardwareChanged = true
        notes.removeAll { $0.id == noteID }
    }

    func startOver() {
        close()
        analysis = nil
        notes = []
        error = nil
        appliedMessage = nil
        hardwareChanged = false
        step = .intro
    }

    func close() {
        recorder.cancel()
        player.stop()
    }
}
