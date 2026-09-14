import AppKit
import SwiftUI

struct ConnectionLogo: View {
    let name: String
    var size: CGFloat = 48
    @Environment(\.colorScheme) private var colorScheme
    private var resource: (String, String)? {
        switch AgentSetupProfile.connectionName(name) {
        case AgentSetupProfile.cursor.rawValue: return ("connection-cursor", "icns")
        case AgentSetupProfile.claude.rawValue: return ("connection-claude", "icns")
        case AgentSetupProfile.codex.rawValue: return (colorScheme == .dark ? "connection-codex-dark" : "connection-codex-light", "png")
        case "Home Assistant": return ("connection-home-assistant", "png")
        default: return nil
        }
    }
    var body: some View {
        Group {
            if let resource, let url = Bundle.main.url(forResource: resource.0, withExtension: resource.1), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "sparkles").font(.system(size: size * 0.52, weight: .regular))
                    .frame(width: size, height: size).background(.quaternary, in: .rect(cornerRadius: size / 4))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
