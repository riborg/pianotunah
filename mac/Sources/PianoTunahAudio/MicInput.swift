#if canImport(AVFoundation) && os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// The microphone: an AVAudioEngine whose input node feeds an
/// AVAudioSinkNode, which writes channel 0 into a ``RingBuffer`` and, while
/// one is open, a ``Recorder``.
///
/// - The hardware sample rate is used as it is.
/// - Voice processing (echo cancellation, noise suppression, gain control)
///   is off, as the web's `echoCancellation: false`; ``start(deviceUID:ring:recorder:)``
///   refuses to run with it on.
/// - The input device is chosen by its Core Audio UID; when it is not
///   connected, the system default is used and ``Info/usedFallback`` says so.
/// - On `AVAudioEngineConfigurationChange` (a device unplugged, the format
///   changed) the engine has stopped; ``onConfigurationChange`` is called so
///   the owner can start again with a new ring.
///
/// Threads: main actor, except the sink's receiver block, which runs on the
/// real-time audio thread. That block is made in a nonisolated function, so
/// it carries no main-actor check, and it only copies into the ring and the
/// recorder: no allocation, no locks, no Objective-C messages.
@MainActor
public final class MicInput {
    public struct Info: Sendable, Equatable {
        public var sampleRate: Double
        public var channels: Int
        public var deviceName: String
        public var deviceUID: String?
        /// The chosen device was not connected; the default is in use.
        public var usedFallback: Bool
    }

    public enum Failure: Error, Equatable {
        /// No input device, or one with no channels.
        case noInput
        /// Voice processing could not be turned off.
        case voiceProcessing
        /// AVAudioEngine did not start.
        case engine(String)
    }

    /// Called on the main actor when the engine's configuration changed and
    /// it has stopped.
    public var onConfigurationChange: (() -> Void)?

    public private(set) var info: Info?
    public var isRunning: Bool { engine?.isRunning ?? false }

    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?

    public init() {}

    /// Starts the input on the device with `deviceUID` (nil: the system
    /// default). Call ``stop()`` before releasing it.
    ///
    /// The sink writes to `recorder` from its first buffer, before this
    /// returns the sample rate: close a recording that must not take these
    /// samples first.
    @discardableResult
    public func start(deviceUID: String?, ring: RingBuffer, recorder: Recorder) throws -> Info {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode

        var usedFallback = false
        if let deviceUID {
            if let id = CoreAudioHAL.input(uid: deviceUID), Self.setDevice(id, of: input) {
                // In use.
            } else {
                usedFallback = true
            }
        }

        if input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(false) }
        guard !input.isVoiceProcessingEnabled else { throw Failure.voiceProcessing }

        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
        else { throw Failure.noInput }

        let sink = AVAudioSinkNode(receiverBlock: Self.receiver(ring: ring, recorder: recorder))
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw Failure.engine(error.localizedDescription)
        }
        assert(!input.isVoiceProcessingEnabled, "voice processing must stay off")

        let device = Self.currentDevice(of: input) ?? CoreAudioHAL.defaultInput()
        let info = Info(
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount),
            deviceName: device.flatMap { CoreAudioHAL.string($0, kAudioObjectPropertyName) } ?? "",
            deviceUID: device.flatMap { CoreAudioHAL.string($0, kAudioDevicePropertyDeviceUID) },
            usedFallback: usedFallback
        )
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onConfigurationChange?() }
        }
        self.engine = engine
        self.info = info
        return info
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
        info = nil
    }

    // MARK: Core Audio

    private static func setDevice(_ id: AudioDeviceID, of input: AVAudioInputNode) -> Bool {
        guard let unit = input.audioUnit else { return false }
        var device = id
        return AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr
    }

    private static func currentDevice(of input: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = input.audioUnit else { return nil }
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    // MARK: Audio thread

    /// The sink's block: channel 0 into the ring and the recorder.
    private nonisolated static func receiver(ring: RingBuffer, recorder: Recorder) -> AVAudioSinkNodeReceiverBlock {
        { _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard buffers.count > 0, let data = buffers[0].mData else { return noErr }
            // Deinterleaved, one buffer per channel; if interleaved, every
            // mNumberChannels-th float is channel 0.
            let stride = Int(max(1, buffers[0].mNumberChannels))
            let count = min(Int(frameCount), Int(buffers[0].mDataByteSize) / (4 * stride))
            let samples = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            ring.write(samples, count: count, stride: stride)
            recorder.append(samples, count: count, stride: stride)
            return noErr
        }
    }
}
#endif
