#if canImport(AVFoundation) && os(macOS)
import AVFoundation
import Foundation

/// Microphone permission. A denied microphone is not an error to
/// AVAudioEngine: it starts and delivers silence. So the permission is
/// checked first, and ``denied`` is shown with a link to the settings
/// (the web version's `mic.denied`).
///
/// Any thread; `request()` may show the system prompt.
public enum MicPermission: Sendable, Equatable {
    case authorized
    case notDetermined
    /// Denied by the user, or restricted by a profile.
    case denied

    public static var current: MicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Asks the first time (needs `NSMicrophoneUsageDescription` in
    /// Info.plist); afterwards returns the answer given then.
    public static func request() async -> MicPermission {
        guard current == .notDetermined else { return current }
        return await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
    }

    /// System Settings › Privacy & Security › Microphone.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
#endif
