import SwiftUI

enum AppVersion {
    // Read the installed app's metadata, never a label copied from the source version.
    static var label: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Versión \(version) · compilación \(build)"
    }
}

struct AppVersionBadge: View {
    var body: some View {
        Text(AppVersion.label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}
