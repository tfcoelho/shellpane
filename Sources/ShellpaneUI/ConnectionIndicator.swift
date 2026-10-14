import SwiftUI

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case error

    var accessibilityDescription: String {
        switch self {
        case .disconnected: "not connected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .error: "connection error"
        }
    }
}

/// 8pt dot showing a server's colour tag and connection state.
/// Colour is never the only signal: the state is in the accessibility label and tooltip.
public struct ConnectionDot: View {
    let colour: ConnectionColour
    let state: ConnectionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Explicit State instead of the @State macro: the Command Line Tools ship no SwiftUI macro plugins.
    private let pulsing = State(initialValue: false)

    public init(colour: ConnectionColour, state: ConnectionState) {
        self.colour = colour
        self.state = state
    }

    public var body: some View {
        let size = Tokens.Size.connectionDot
        Group {
            switch state {
            case .connected:
                Circle().fill(colour.color)
            case .disconnected:
                Circle().strokeBorder(colour.color, lineWidth: 1.5)
            case .connecting:
                Circle().strokeBorder(colour.color, lineWidth: 1.5)
                    .opacity(pulsing.wrappedValue ? 0.35 : 1)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulsing.wrappedValue = true }
                    }
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Tokens.Colors.danger)
            }
        }
        .frame(width: state == .error ? size + 4 : size, height: state == .error ? size + 4 : size)
        .help(state.accessibilityDescription.capitalized)
        .accessibilityLabel(state.accessibilityDescription)
    }
}

/// 3pt strip across the top of a remote pane in the server's colour.
public struct ConnectionBar: View {
    let colour: ConnectionColour

    public init(colour: ConnectionColour) { self.colour = colour }

    public var body: some View {
        Rectangle()
            .fill(colour.color)
            .frame(height: Tokens.Size.connectionBar)
            .accessibilityHidden(true)
    }
}
