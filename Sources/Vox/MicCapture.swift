import AVFoundation
import CoreMedia

/// Records one specific microphone (the Mac's own) without going through the system default input.
///
/// AVAudioEngine always opens the default input first, and when that is a Bluetooth headset, merely
/// opening it switches the headset into call mode, even if the engine is then pointed elsewhere. A capture
/// session opens only the device it's given. Audio arrives in ~20 ms pieces; they're joined into ~100 ms
/// buffers so the listener's timing (gate, pre-roll, silence) works the same as with the engine.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Full rate: capturing at 16 kHz cost the same CPU and recognized "Hey Vox" worse.
    static let rate = 48000.0
    let format: AVAudioFormat
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vox.mic", qos: .userInitiated)
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private var pending: AVAudioPCMBuffer      // touched only on `queue`
    var onError: () -> Void = {}
    private var observers: [NSObjectProtocol] = []

    /// The built-in microphone, if there is one.
    static func builtInDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
            .first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
    }

    init?(device: AVCaptureDevice, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1),
              let pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.rate / 10) + 16384),   // room for any chunk size
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        self.format = format
        self.pending = pending
        self.onBuffer = onBuffer
        super.init()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); return nil }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
                self?.onError()
            },
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
                self?.onError()
            },
        ]
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start() async {
        await withCheckedContinuation { cont in queue.async { self.session.startRunning(); cont.resume() } }
    }

    var isRunning: Bool { session.isRunning }

    func stop() {
        queue.sync { session.stopRunning(); pending.frameLength = 0 }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0, let dst = pending.floatChannelData?[0] else { return }
        let room = Int(pending.frameCapacity - pending.frameLength)
        let frames = min(n, room)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(dst + Int(pending.frameLength))))
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: &list) == noErr else { return }
        pending.frameLength += AVAudioFrameCount(frames)
        guard pending.frameLength >= AVAudioFrameCount(Self.rate / 10) else { return }   // 100 ms
        let out = pending
        if let fresh = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: pending.frameCapacity) { pending = fresh }
        onBuffer(out)
    }
}
