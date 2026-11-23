import AppKit
import SwiftUI

/// The version, the project's links and the licences (the web's About and
/// the README's License section).
struct AboutSettings: View {
    private static let repo = URL(string: "https://github.com/riborg/pianotunah")!
    private static let releases = URL(string: "https://github.com/riborg/pianotunah/releases")!
    private static let fontLicense = URL(string: "https://github.com/riborg/pianotunah/blob/main/web/fonts/OFL.txt")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Piano Tunah")
                            .font(.title2.bold())
                        Link(destination: Self.releases) {
                            Text("Version \(version) (\(build))", tableName: "AppSettings",
                                 comment: "About: the version and build number, linking to the releases.")
                        }
                    }
                }
                Text("Piano tuner for the Mac. Listens through the microphone, computes stretch from the strings' inharmonicity and keeps the measurements for each piano.",
                     tableName: "AppSettings", comment: "About: what the app does (web app.desc).")
                Link(destination: Self.repo) {
                    Text(verbatim: "github.com/riborg/pianotunah")
                }
            }
            Section {
                Text("Piano Tunah is in the public domain under CC0 1.0. It was written with Claude as co-programmer. You can use it for anything without attribution.",
                     tableName: "AppSettings", comment: "About: the licence (README, License).")
                Text("The exception is the font with ♭ ♮ ♯, adapted from Bravura Text by Steinberg. Its licence is the SIL Open Font License 1.1.",
                     tableName: "AppSettings", comment: "About: the font's licence (README, License).")
                Link(destination: Self.fontLicense) {
                    Text(verbatim: "SIL Open Font License 1.1")
                }
            } header: {
                Text("License", tableName: "AppSettings", comment: "About: section heading.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
