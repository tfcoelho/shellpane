import SwiftUI

/// Centred message for a pane with nothing to show (empty folder, no servers, no permission, disconnected).
public struct EmptyState: View {
    public enum Tone: Sendable { case neutral, danger }

    let symbol: String
    let title: String
    let message: String
    let tone: Tone
    let actionTitle: String?
    let action: () -> Void

    public init(symbol: String, title: String, message: String, tone: Tone = .neutral,
                actionTitle: String? = nil, action: @escaping () -> Void = {}) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.tone = tone
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Tokens.Space.s8) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Size.iconEmpty, weight: .light))
                .foregroundStyle(tone == .danger ? Tokens.Colors.danger : Tokens.Colors.textMuted)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Tokens.Colors.text)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.Colors.textMuted)
                .frame(maxWidth: 300)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.large)
                    .padding(.top, Tokens.Space.s4)
            }
        }
        .padding(Tokens.Space.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Full-width strip at the top of a pane: what went wrong, one action, and the raw details on request.
public struct ErrorBanner: View {
    public enum Severity: Sendable { case danger, warning }

    let severity: Severity
    let message: String
    let details: String?
    let actionTitle: String?
    let action: () -> Void
    // Explicit State instead of the @State macro: the Command Line Tools ship no SwiftUI macro plugins.
    private let expanded = State(initialValue: false)

    public init(severity: Severity, message: String, details: String? = nil,
                actionTitle: String? = nil, action: @escaping () -> Void = {}) {
        self.severity = severity
        self.message = message
        self.details = details
        self.actionTitle = actionTitle
        self.action = action
    }

    private var fg: Color { severity == .danger ? Tokens.Colors.danger : Tokens.Colors.warning }
    private var bg: Color { severity == .danger ? Tokens.Colors.dangerBg : Tokens.Colors.warningBg }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s6) {
            HStack(spacing: Tokens.Space.s8) {
                Image(systemName: severity == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(fg)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.body)
                    .foregroundStyle(Tokens.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Tokens.Space.s8)
                if details != nil {
                    Button(expanded.wrappedValue ? "Hide Details" : "Details") { expanded.wrappedValue.toggle() }
                        .buttonStyle(.link)
                        .foregroundStyle(Tokens.Colors.accentText)
                }
                if let actionTitle {
                    Button(actionTitle, action: action).controlSize(.small)
                }
            }
            if expanded.wrappedValue, let details {
                Text(details)
                    .font(.callout.monospaced())
                    .foregroundStyle(Tokens.Colors.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.s8)
                    .background(Tokens.Colors.bg, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
        }
        .padding(.horizontal, Tokens.Space.s12)
        .padding(.vertical, Tokens.Space.s8)
        .background(bg)
        .overlay(alignment: .bottom) { Rectangle().fill(fg.opacity(0.4)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(severity == .danger ? "Error: \(message)" : "Warning: \(message)")
    }
}

/// Bottom bar of a pane: selection summary on the left, connection info or free space on the right.
public struct StatusBar: View {
    let leading: String
    let trailing: String
    let busy: Bool

    public init(leading: String, trailing: String, busy: Bool = false) {
        self.leading = leading
        self.trailing = trailing
        self.busy = busy
    }

    public var body: some View {
        HStack(spacing: Tokens.Space.s6) {
            if busy { ProgressView().controlSize(.mini) }
            Text(leading)
            Spacer()
            Text(trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(Tokens.Colors.textMuted)
        .padding(.horizontal, Tokens.Space.s8)
        .frame(height: Tokens.Size.statusBar)
        .background(Tokens.Colors.surface)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.border).frame(height: 1) }
    }
}
