import ShellpaneUI
import SwiftUI

/// The tab bar above a pane's path bar. Shown only when the pane has two or more tabs.
struct TabStrip: View {
    struct Item: Identifiable {
        let index: Int
        let title: String
        let remote: ConnectionColour?
        let isCurrent: Bool
        var id: Int { index }
    }

    let items: [Item]
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: Tokens.Space.s6) {
                    if let colour = item.remote { ConnectionDot(colour: colour, state: .connected) }
                    Text(item.title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.isCurrent ? Tokens.Colors.text : Tokens.Colors.textMuted)
                    Spacer(minLength: 0)
                    Button { onClose(item.index) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Tokens.Colors.textMuted)
                        .accessibilityLabel("Close tab \(item.title)")
                }
                .padding(.horizontal, Tokens.Space.s8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(item.isCurrent ? Tokens.Colors.bg : Tokens.Colors.surface)
                .overlay(alignment: .trailing) { Rectangle().fill(Tokens.Colors.border).frame(width: 1) }
                .contentShape(Rectangle())
                .onTapGesture { onSelect(item.index) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(item.isCurrent ? [.isSelected, .isButton] : .isButton)
                .accessibilityLabel(item.title)
            }
            Button(action: onNew) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .padding(.horizontal, Tokens.Space.s8)
                .help("New tab (⌘T)")
                .accessibilityLabel("New tab")
        }
        .frame(height: Tokens.Size.tabBar)
        .background(Tokens.Colors.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.Colors.border).frame(height: 1) }
    }
}
