import ShellpaneCore
import ShellpaneUI
import SwiftUI

/// Where you choose what to open, like Safari's favourites: the whole window with no panes, or one new pane.
/// A tile opens in the pane it's shown in (the window makes one if there's none).
struct StartPage: View {
    /// A pane restored from last time that was on a server.
    struct Resume {
        let title: String
        let path: String
        let action: () -> Void
    }

    @ObservedObject var model: SidebarModel
    var resume: Resume?
    /// Before a tile acts: this pane becomes the active one.
    var onActivate: () -> Void = {}
    /// In a pane: its header, to close it or drag it. nil on the empty window.
    var onClose: (() -> Void)?
    var onDrag: (PaneDragPhase) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: Tokens.Space.s8, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            if let onClose { header(onClose) }
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s20) {
                    if onClose == nil {
                        Text("Open a server or a folder")
                            .font(.title2.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, Tokens.Space.s24)
                    }
                    if let resume { resumeRow(resume) }
                    section("Servers") {
                        ForEach(model.favorites) { fav in
                            tile(fav.name) { model.onOpenFavorite(fav) } icon: {
                                ServerBadge(icon: fav.icon ?? "terminal", colour: fav.colour.flatMap(ConnectionColour.init(rawValue:)) ?? .none, size: 34)
                            }
                        }
                        ForEach(model.unsavedHosts, id: \.self) { host in
                            tile(host) { model.onOpenHost(host) } icon: { symbol(model.hostItem(host)) }
                        }
                        tile("Add Server…") { model.onAddServer() } icon: { symbol("plus") }
                    }
                    if !model.bookmarks.isEmpty {
                        section("Favorite Folders") {
                            ForEach(model.bookmarks) { b in
                                tile(b.name) { model.onOpenBookmark(b) } icon: {
                                    if b.icon == nil && b.colour == nil {
                                        Image(nsImage: PaneViewController.folderIcon(size: 38))
                                    } else {
                                        Image(systemName: FolderIcons.symbol(for: b))
                                            .font(.system(size: 28))
                                            .foregroundStyle(model.placeColour(b) ?? Tokens.Colors.textMuted)
                                    }
                                }
                                .help(model.placeName(b).map { "\($0): \(b.path)" } ?? b.path)
                            }
                        }
                    }
                    if !model.places.isEmpty {
                        section("This Mac") {
                            ForEach(model.places) { place in
                                tile(place.title) { model.onOpenPlace(place) } icon: { symbol(model.placeItem(place)) }
                            }
                        }
                    }
                }
                .padding(Tokens.Space.s16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Tokens.Colors.bg)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onActivate() })
    }

    private func header(_ close: @escaping () -> Void) -> some View {
        HStack {
            Text("New Pane").font(.callout.weight(.medium)).foregroundStyle(Tokens.Colors.textMuted)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Close this pane (⌘W)")
            .accessibilityLabel("Close this pane")
        }
        .padding(.horizontal, Tokens.Space.s8)
        .frame(height: Tokens.Size.pathBar)
        .background(Tokens.Colors.surface)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { _ in onDrag(.changed) }
            .onEnded { _ in onDrag(.ended) })
    }

    private func resumeRow(_ r: Resume) -> some View {
        Button { onActivate(); r.action() } label: {
            HStack(spacing: Tokens.Space.s8) {
                Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 22)).foregroundStyle(Tokens.Colors.accentText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Reconnect to \(r.title)").font(.body.weight(.medium))
                    Text(verbatim: r.path).font(.callout).foregroundStyle(Tokens.Colors.textMuted).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(Tokens.Space.s12)
            .background(Tokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.Colors.border))
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(Tokens.Colors.textMuted)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Tokens.Space.s8) { content() }
        }
    }

    private func symbol(_ item: AppearanceItem) -> some View {
        symbol(model.symbol(item.key, standard: item.standardIcon), colour: model.ownColour(item.key)?.color)
    }

    private func symbol(_ name: String, colour: Color? = nil) -> some View {
        Image(systemName: name)
            .font(.system(size: 22))
            .foregroundStyle(colour ?? Tokens.Colors.textMuted)
            .frame(width: 38, height: 38)
            .background(Tokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.Colors.border))
    }

    private func tile<Icon: View>(_ title: String, _ action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        StartTile(title: title, action: { onActivate(); action() }, icon: icon())
    }
}

private struct StartTile<Icon: View>: View {
    let title: String
    let action: () -> Void
    let icon: Icon
    // Explicit State instead of the @State macro: the Command Line Tools ship no SwiftUI macro plugins.
    private let hovered = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            VStack(spacing: Tokens.Space.s6) {
                icon.frame(height: 40)
                Text(verbatim: title)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, Tokens.Space.s8)
            .padding(.horizontal, Tokens.Space.s4)
            .frame(maxWidth: .infinity)
            .background(hovered.wrappedValue ? Tokens.Colors.surface : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.wrappedValue = $0 }
        .accessibilityLabel(title)
    }
}
