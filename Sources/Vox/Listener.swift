import AVFoundation
import Accelerate
import Speech
import os

/// Microphone -> on-device SpeechAnalyzer (Neural Engine) -> streaming transcript.
///
/// Two ways to run:
///  - session (hotkey): mic and analyzer exist only while you talk; the session closes itself after a
///    stretch without new words.
///  - continuous (hands-free "Hey Vox"): the mic stays open, but a volume gate with an adaptive noise
///    floor only feeds audio to the recognizer while someone is speaking (plus 300 ms of pre-roll so the
///    first syllable isn't lost). Silence costs a vDSP RMS per 100 ms buffer and nothing else.
final class Listener: @unchecked Sendable {
    var onText: @MainActor (_ final: String, _ volatile: String) -> Void = { _, _ in }
    /// Session ended (hotkey mode) or the mic was shut down (either mode).
    var onEnded: @MainActor (_ final: String) -> Void = { _ in }
    /// Continuous mode: speech stopped for `silenceTimeout` seconds.
    var onIdle: @MainActor () -> Void = {}
    /// Mic level (0…1), delivered only while `reportsLevel` is on (i.e. while the HUD is visible).
    var onLevel: @MainActor (Float) -> Void = { _ in }
    var reportsLevel: Bool {
        get { state.withLock { $0.reportLevel } }
        set { state.withLock { $0.reportLevel = newValue } }
    }
    /// Picks the best of the recognizer's final guess and its alternatives (e.g. the one that reads as a
    /// command). Called off the main thread.
    var chooseFinal: @Sendable (_ best: String, _ alternatives: [String]) -> String = { best, _ in best }
    /// Echo cancellation + noise suppression, so commands are heard over music playing from the speakers
    /// and in noisy places. Costs a little DSP only while the mic is open.
    var voiceProcessing = false
    /// Drop mic input (e.g. while Vox itself is speaking, so it doesn't hear its own voice).
    var muted: Bool {
        get { state.withLock { $0.muted } }
        set { state.withLock { $0.muted = newValue } }
    }
    /// Which on-device recognizer to use. Dictation is tuned for short, low-latency utterances and honors
    /// custom vocabulary; Speech is the long-form model.
    enum Engine: String { case dictation, speech }
    var engine: Engine = .speech
    /// Use the Mac's own mic when the default input is a Bluetooth headset (see `AudioDevices`).
    var preferBuiltInMic = true
    /// While a command is being spoken, every buffer goes to the recognizer; the volume gate is only for
    /// waiting for "Hey Vox" (it would otherwise clip quiet words and long dictation).
    var gateBypassed: Bool {
        get { state.withLock { $0.bypassGate } }
        set { state.withLock { $0.bypassGate = newValue } }
    }
    /// The audio device went away or changed (headphones connected, etc.) and the engine stopped.
    var onConfigChange: @MainActor () -> Void = {}
    /// Seconds without any new recognized text before a command is considered over.
    var silenceTimeout: Double = 2.0
    var initialTimeout: Double = 6

    /// A fresh engine for every start: an engine binds to a microphone the first time its input node is
    /// touched, so choosing the device has to happen first, on a new engine.
    private var audio = AVAudioEngine()
    /// Used instead of the engine when listening with the built-in mic while the default input is Bluetooth.
    private var capture: MicCapture?
    /// Whether the engine's input is in use; touching `inputNode` otherwise would open the default mic.
    private var tapInstalled = false
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var locale = Locale(identifier: "en-US")
    private var contextNames: [String] = []

    private struct State {
        var lastText = 0.0, graceUntil = 0.0
        var heardAny = false, stopRequested = false, idleFired = true
        var finalText = ""
        var gateOpenUntil = 0.0
        var noiseFloor: Float = 0.004
        var reportLevel = false
        var muted = false
        var bypassGate = false
        var timeout: Double?
        var buffers = 0, gatedIn = 0
        var loudBefore = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private(set) var running = false
    private(set) var continuous = false
    /// Bumped on every start, so callbacks from an older session can't touch the current one.
    private var generation = 0
    private var stopping: Task<Void, Never>?

    // Touched only on the audio tap's thread.
    private var preroll: [AVAudioPCMBuffer] = []
    private var gateWasOpen = false

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // Only act if the change actually stopped our engine; some notifications are harmless.
                guard let self, (note.object as? AVAudioEngine) === self.audio, self.running, self.capture == nil,
                      !self.audio.isRunning else { return }
                self.onConfigChange()
            }
        }
    }

    /// One-time setup: pick the locale and make sure the on-device speech model is installed.
    func prepare(contextNames: [String]) async throws {
        self.contextNames = contextNames
        locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        NSLog("Vox: speech locale \(locale.identifier)")
        let probe = makeModule()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    private func makeModule() -> any SpeechModule {
        switch engine {
        case .speech:
            return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                     reportingOptions: [.volatileResults, .fastResults, .alternativeTranscriptions], attributeOptions: [])
        case .dictation:
            return DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults, .frequentFinalization, .alternativeTranscriptions],
                                        attributeOptions: [])
        }
    }

    /// Both recognizers' results, as (text, alternatives, isFinal).
    private func results(of module: any SpeechModule) -> AsyncThrowingStream<(String, [String], Bool), Error> {
        func clean(_ a: AttributedString) -> String { String(a.characters).trimmingCharacters(in: .whitespaces) }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    if let t = module as? SpeechTranscriber {
                        for try await r in t.results { cont.yield((clean(r.text), r.alternatives.map(clean), r.isFinal)) }
                    } else if let t = module as? DictationTranscriber {
                        for try await r in t.results { cont.yield((clean(r.text), r.alternatives.map(clean), r.isFinal)) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Forget accumulated final text (continuous mode keeps one analyzer alive for hours).
    func resetTranscript() { state.withLock { $0.finalText = ""; $0.timeout = nil } }

    /// Keep only the last few words of final text while waiting for "Hey Vox", so a TV or conversation
    /// in the background can't grow the transcript (and the work done on each update) without limit.
    func trimTranscript(keepingLast n: Int) {
        state.withLock { s in
            let w = s.finalText.split(whereSeparator: \.isWhitespace)
            if w.count > n { s.finalText = w.suffix(n).joined(separator: " ") }
        }
    }

    /// Override the silence timeout until the next `resetTranscript()` (shorter once a command has run).
    func setTimeout(_ seconds: Double?) { state.withLock { $0.timeout = seconds } }

    /// Don't report idle before this many seconds from now (e.g. right after "Hey Vox").
    func grace(_ seconds: Double) { state.withLock { $0.graceUntil = CFAbsoluteTimeGetCurrent() + seconds } }

    @MainActor
    func start(continuous: Bool = false) async throws {
        if let s = stopping { await s.value }      // the previous session must be fully closed first
        guard !running else { return }
        running = true
        self.continuous = continuous
        generation &+= 1
        let gen = generation
        do {
            try await begin(gen)
        } catch {
            // Leave nothing half-open: a listener stuck at "running" could never be restarted.
            if generation == gen {
                if running { teardown() }
                resultsTask?.cancel(); resultsTask = nil
                analyzer = nil
            }
            throw error
        }
    }

    @MainActor
    private func begin(_ gen: Int) async throws {
        func stillCurrent() throws { guard generation == gen, running else { throw CancellationError() } }
        let transcriber = makeModule()
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: continuous ? .processLifetime : .lingering))
        self.analyzer = analyzer

        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(contextNames.prefix(300))
        try? await analyzer.setContext(context)
        try stillCurrent()

        // Pick the microphone before anything opens the default one (see `AudioDevices`).
        var micFormat: AVAudioFormat
        var builtIn: AVCaptureDevice?
        if preferBuiltInMic, !voiceProcessing, let def = AudioDevices.defaultInput(), AudioDevices.isBluetooth(def) {
            builtIn = MicCapture.builtInDevice()
        }
        // The format is only known once the capture or engine exists; buffers are handled further down.
        let sink = BufferSink()
        if let builtIn, let c = MicCapture(device: builtIn, onBuffer: { sink.handle?($0) }) {
            capture = c
            micFormat = c.format
            c.onError = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen, self.running else { return }
                    self.onConfigChange()
                }
            }
            diagnostics = "using \(builtIn.localizedName) (default input is Bluetooth)"
        } else {
            audio = AVAudioEngine()
            configureVoiceProcessing()
            micFormat = audio.inputNode.outputFormat(forBus: 0)
            diagnostics = "using the default input"
        }
        if let id = capture != nil ? AudioDevices.builtInInput() : AudioDevices.defaultInput(), !voiceProcessing {
            AudioDevices.useLargeBuffers(id)
        }
        diagnostics += ", format: \(micFormat)"
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0,
              let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: micFormat),
              let converter = AVAudioConverter(from: micFormat, to: target) else {
            throw NSError(domain: "Vox", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone, or no compatible audio format"])
        }
        converter.primeMethod = .none
        try await analyzer.prepareToAnalyze(in: target)
        try stillCurrent()

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        input = continuation

        let now = CFAbsoluteTimeGetCurrent()
        state.withLock {
            $0 = State(lastText: now, graceUntil: continuous ? 0 : now + initialTimeout, idleFired: continuous,
                       reportLevel: $0.reportLevel, muted: $0.muted, bypassGate: $0.bypassGate)
        }
        preroll = []
        gateWasOpen = false

        resultsTask = Task { [weak self] in
            do {
                guard let stream = self?.results(of: transcriber) else { return }
                for try await (heard, alternatives, isFinal) in stream {
                    guard let self else { break }
                    let text = isFinal && !alternatives.isEmpty ? self.chooseFinal(heard, alternatives) : heard
                    let final = self.state.withLock { s -> String in
                        s.lastText = CFAbsoluteTimeGetCurrent(); s.heardAny = true; s.idleFired = false
                        if isFinal, !text.isEmpty { s.finalText += (s.finalText.isEmpty ? "" : " ") + text }
                        return s.finalText
                    }
                    let volatile = isFinal ? "" : text
                    await MainActor.run { if self.generation == gen { self.onText(final, volatile) } }
                }
            } catch {
                NSLog("Vox: recognizer stopped: \(error)")
            }
            await MainActor.run {
                guard let self, self.generation == gen else { return }
                // The recognizer ended on its own (an error, the model being unloaded): close the mic too,
                // so the app sees a stopped listener and can start a fresh one.
                if self.running { self.teardown(); self.analyzer = nil }
                self.onEnded(self.state.withLock { $0.finalText })
            }
        }

        sink.handle = { [weak self] buffer in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / micFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, out.frameLength > 0, !self.state.withLock({ $0.muted }) else { return }
            let level = Self.rms(buffer)
            if continuous { self.gate(out, level: level, into: continuation) } else { continuation.yield(AnalyzerInput(buffer: out)) }
            if self.state.withLock({ $0.reportLevel }) {
                let v = min(1, sqrt(level) * 3.2)
                Task { @MainActor in self.onLevel(v) }
            }
            self.checkSilence(gen)
        }
        if let capture {
            await capture.start()
            guard capture.isRunning else { throw NSError(domain: "Vox", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone didn't start"]) }
        } else {
            // ~100 ms buffers: small enough for low latency, large enough to keep wakeups rare.
            let bufferSize = AVAudioFrameCount(micFormat.sampleRate / 10)
            audio.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: micFormat) { buffer, _ in sink.handle?(buffer) }
            tapInstalled = true
            audio.prepare()
            try audio.start()
        }
        try stillCurrent()
        try await analyzer.start(inputSequence: stream)
    }

    /// How much audio the volume gate let through, and the current noise floor (for the listen test).
    var gateStats: String { state.withLock { "gate open \($0.gatedIn)/\($0.buffers) buffers, noise floor \($0.noiseFloor)" } }

    /// What `start` chose, for the listen test.
    private(set) var diagnostics = ""

    private func configureVoiceProcessing() {
        let input = audio.inputNode
        guard input.isVoiceProcessingEnabled != voiceProcessing else { return }
        do {
            try input.setVoiceProcessingEnabled(voiceProcessing)
            if voiceProcessing {
                // Don't turn the user's music down while listening.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                input.isVoiceProcessingAGCEnabled = true
            }
        } catch {
            NSLog("Vox: voice processing unavailable: \(error)")
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var v: Float = 0
        vDSP_rmsqv(ch, 1, &v, vDSP_Length(buffer.frameLength))
        return v
    }

    /// Feed the recognizer only while the room is louder than its own background noise.
    private func gate(_ out: AVAudioPCMBuffer, level: Float, into input: AsyncStream<AnalyzerInput>.Continuation) {
        let now = CFAbsoluteTimeGetCurrent()
        let open = state.withLock { s -> Bool in
            s.buffers += 1
            if s.bypassGate { s.gatedIn += 1; return true }
            // Speech stays loud for more than one 100 ms buffer; a key click or a tap on the desk doesn't, so it
            // takes two loud buffers in a row to open (the pre-roll still holds the start of "Hey").
            let loud = level > max(0.006, s.noiseFloor * 2.5)
            if loud && (s.loudBefore || now <= s.gateOpenUntil) { s.gateOpenUntil = now + 1.0 }   // hang-over keeps pauses between words
            s.loudBefore = loud
            // The floor drops quickly to the quietest level heard and creeps up under steady noise (a fan,
            // traffic, a TV), so constant noise can't hold the gate, and the recognizer, open for good.
            s.noiseFloor = level < s.noiseFloor ? s.noiseFloor * 0.8 + level * 0.2 : s.noiseFloor * 0.996 + level * 0.004
            if now <= s.gateOpenUntil { s.gatedIn += 1; return true }
            return false
        }
        if open {
            if !gateWasOpen { preroll.forEach { input.yield(AnalyzerInput(buffer: $0)) }; preroll.removeAll() }
            input.yield(AnalyzerInput(buffer: out))
        } else {
            // Speech just ended: a moment of silence lets the recognizer commit the phrase now, instead of
            // holding it until the next sound (and then putting it in front of the next command). Asking it to
            // finalize outright garbles the start of the following phrase, so it gets silence instead.
            if gateWasOpen, let silence = AVAudioPCMBuffer(pcmFormat: out.format, frameCapacity: out.frameLength) {
                silence.frameLength = out.frameLength          // a new buffer is zero-filled
                for _ in 0..<8 { input.yield(AnalyzerInput(buffer: silence)) }
            }
            preroll.append(out)
            if preroll.count > 5 { preroll.removeFirst() }   // 500 ms, so the "Hey" of "Hey Vox" survives
        }
        gateWasOpen = open
    }

    /// Runs on the audio thread at buffer rate, so timeouts need no timer of their own.
    private func checkSilence(_ gen: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let quiet = state.withLock { s -> Bool in
            guard !s.stopRequested, !s.idleFired, now > s.graceUntil else { return false }
            if now - s.lastText > (s.timeout ?? silenceTimeout) {
                s.idleFired = true
                if !continuous { s.stopRequested = true }
                return true
            }
            return false
        }
        guard quiet else { return }
        Task { @MainActor in
            guard self.generation == gen, self.running else { return }
            if self.continuous { self.onIdle() } else { await self.stop() }
        }
    }

    @MainActor
    private func teardown() {
        running = false
        if let capture { capture.stop(); self.capture = nil }
        if tapInstalled {
            audio.inputNode.removeTap(onBus: 0)
            audio.stop()
            tapInstalled = false
        }
        input?.finish()
        input = nil
    }

    /// Closes the mic and lets the recognizer deliver its last words (then `onEnded`). Never hangs: if the
    /// recognizer doesn't finish within 3 s it is cancelled, so the next start can't be blocked forever.
    @MainActor
    func stop() async {
        guard running else { await stopping?.value; return }
        teardown()
        let analyzer = self.analyzer, results = resultsTask
        self.analyzer = nil
        resultsTask = nil
        let t = Task { @MainActor in
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                NSLog("Vox: recognizer didn't finish; cancelling it")
                await analyzer?.cancelAndFinishNow()
                results?.cancel()
            }
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await results?.value
            watchdog.cancel()
        }
        stopping = t
        await t.value
        if stopping == t { stopping = nil }
    }
}

/// Lets the audio callback be created before the buffer handler that needs the final format.
private final class BufferSink: @unchecked Sendable {
    var handle: ((AVAudioPCMBuffer) -> Void)?
}
