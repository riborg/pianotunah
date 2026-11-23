#if canImport(CoreAudio) && os(macOS)
import CoreAudio
import Foundation
import Observation

/// An audio input: a Core Audio device with input streams.
public struct InputDevice: Sendable, Hashable, Identifiable {
    /// Core Audio's UID: stable across launches and replugging, so it is
    /// what the settings keep.
    public let uid: String
    public let name: String
    public var id: String { uid }
}

/// The audio inputs, kept up to date as devices come and go or the system
/// default changes.
///
/// Threads: main actor. Core Audio calls its listener on the main queue.
/// The listener stays registered for the life of the process, which is the
/// life of this object in the app.
@MainActor @Observable
public final class InputDevices {
    public private(set) var devices: [InputDevice] = []
    /// The system's default input, or nil if there is none.
    public private(set) var defaultUID: String?
    /// Called after every change of ``devices`` or ``defaultUID``.
    @ObservationIgnored public var onChange: (() -> Void)?

    public init() {
        refresh()
        watch()
    }

    public func refresh() {
        let now = Self.list()
        let def = CoreAudioHAL.defaultInput().flatMap { CoreAudioHAL.string($0, kAudioDevicePropertyDeviceUID) }
        guard now != devices || def != defaultUID else { return }
        devices = now
        defaultUID = def
        onChange?()
    }

    /// The inputs now, in Core Audio's order.
    public nonisolated static func list() -> [InputDevice] {
        CoreAudioHAL.deviceIDs().compactMap { id in
            guard CoreAudioHAL.hasInput(id), let uid = CoreAudioHAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return InputDevice(uid: uid, name: CoreAudioHAL.string(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    private func watch() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = CoreAudioHAL.address(selector)
            AudioObjectAddPropertyListenerBlock(CoreAudioHAL.system, &address, DispatchQueue.main, block)
        }
    }
}

/// Small wrappers around the Core Audio HAL's property calls. Any thread.
enum CoreAudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    /// A CFString property such as the UID or the name.
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { p in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, p)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    static func defaultInput() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// The input device with this UID, if it is connected.
    static func input(uid: String) -> AudioDeviceID? {
        deviceIDs().first { hasInput($0) && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }
}
#endif
