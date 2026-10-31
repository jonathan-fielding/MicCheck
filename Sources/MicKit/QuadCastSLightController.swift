import Foundation

/// Controls the RGB lighting on a HyperX QuadCast S microphone.
public final class QuadCastSLightController: @unchecked Sendable {
    public let transport: LightingTransport

    /// Called when a send fails. Called with a message on error, or nil when errors clear.
    /// May be called on a background queue.
    public var onError: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "com.jonathanfielding.micdeck.lighting", qos: .default)
    private var lastErrorMessage: String?
    private var streaming = false
    private var streamingColors: (top: LEDColor, bottom: LEDColor)?
    private var keepAliveTimer: DispatchSourceTimer?

    public init(transport: LightingTransport) {
        self.transport = transport
    }

    deinit {
        // The caller usually drops the controller right after stop(), whose queued block
        // then finds self gone, so cancel the keep-alive timer here as well.
        keepAliveTimer?.cancel()
        transport.close()
    }

    /// Sends colors to the LEDs and keeps them active via keep-alive updates.
    public func show(top: LEDColor, bottom: LEDColor) {
        queue.async { [weak self] in
            self?.showSync(top: top, bottom: bottom)
        }
    }

    /// Stops streaming colors.
    public func stop() {
        queue.async { [weak self] in
            self?.stopSync()
        }
    }

    /// Saves colors to the microphone's memory.
    public func save(top: LEDColor, bottom: LEDColor, completion: (@Sendable (String?) -> Void)? = nil) {
        queue.async { [weak self] in
            self?.saveSync(top: top, bottom: bottom, completion: completion)
        }
    }

    // MARK: - Private implementation

    /// The first call sends at once and starts the keep-alive. While streaming, later calls
    /// only replace the colours the next tick sends: an update takes 30 ms or more, so sending
    /// on every call would let a slider drag queue up seconds of stale updates.
    private func showSync(top: LEDColor, bottom: LEDColor) {
        streamingColors = (top, bottom)
        guard !streaming else { return }
        streaming = true
        sendDirectColorUpdate(top: top, bottom: bottom)
        if streaming { startKeepAliveTimer() }   // a failed send has already stopped streaming
    }

    private func stopSync() {
        streaming = false
        stopKeepAliveTimer()
    }

    private func saveSync(top: LEDColor, bottom: LEDColor, completion: (@Sendable (String?) -> Void)? = nil) {
        let sequence = quadCastSBuildSaveSequence(top, bottom)

        for (packet, delay) in sequence {
            do {
                try transport.sendFeature(packet)
                Thread.sleep(forTimeInterval: delay)
            } catch {
                let msg = error.localizedDescription
                reportError(msg)
                completion?(msg)
                return
            }
        }

        clearError()
        completion?(nil)
    }

    private func sendDirectColorUpdate(top: LEDColor, bottom: LEDColor) {
        let sequence = quadCastSBuildDirectColorUpdateSequence(top, bottom)

        for (packet, delay) in sequence {
            do {
                try transport.sendFeature(packet)
                Thread.sleep(forTimeInterval: delay)
            } catch {
                let msg = error.localizedDescription
                reportError(msg)
                streaming = false
                stopKeepAliveTimer()
                return
            }
        }

        // Successful send - clear any previous errors
        clearError()
    }

    private func startKeepAliveTimer() {
        stopKeepAliveTimer()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.050, repeating: 0.050)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.streaming, let colors = self.streamingColors else { return }
            self.sendDirectColorUpdate(top: colors.top, bottom: colors.bottom)
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    private func reportError(_ message: String) {
        if lastErrorMessage != message {
            lastErrorMessage = message
            onError?(message)
        }
    }

    private func clearError() {
        if lastErrorMessage != nil {
            lastErrorMessage = nil
            onError?(nil)
        }
    }
}
