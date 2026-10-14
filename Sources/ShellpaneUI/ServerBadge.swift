import AppKit
import SwiftUI

/// The icons a server can have in the sidebar: kinds of machine, then kinds of work, so people can tell
/// "the client's shop" from "the research box" at a glance. Line symbols, as in Finder's sidebar.
public enum ServerIcons {
    public static let standard = "server.rack"
    public static let all: [String] = [
        "server.rack", "externaldrive.connected.to.line.below", "cloud", "globe", "network", "cpu", "display", "terminal",
        "house", "building.2", "briefcase", "cart", "flask", "graduationcap", "lock.shield", "wrench.and.screwdriver",
        "photo", "film", "music.note", "doc.text", "shippingbox", "chart.bar", "gamecontroller", "leaf",
    ]

    /// A stored name, or the standard icon when there's none (servers saved before icons) or it's unknown.
    public static func resolve(_ name: String?) -> String {
        guard let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return standard }
        return name
    }
}

/// A server's icon as Finder draws its sidebar: a line symbol in the server's colour, no background.
public struct ServerBadge: View {
    let icon: String
    let colour: ConnectionColour
    let size: CGFloat

    public init(icon: String?, colour: ConnectionColour, size: CGFloat = 18) {
        self.icon = ServerIcons.resolve(icon)
        self.colour = colour
        self.size = size
    }

    public var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.82, weight: .regular))
            .foregroundStyle(colour == .none ? Tokens.Colors.textMuted : colour.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
