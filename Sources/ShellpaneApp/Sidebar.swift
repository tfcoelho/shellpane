import Combine
import ShellpaneCore
import ShellpaneUI
import SwiftUI

@MainActor
final class SidebarModel: ObservableObject {
    struct Place: Identifiable, Hashable {
        let id: String
        let title: String
        let symbol: String
        let path: String
    }

    @Published var favorites: [Favorite] = []
    @Published var groups: [FavoriteGroup] = []
    @Published var collapsed: Set<String> = []
    @Published var synclets: [Synclet] = []
    @Published var bookmarks: [Bookmark] = []
    @Published var sshHosts: [String] = []
    /// Keys: favorite ids, or "alias:<host>" for unsaved ssh_config hosts.
    @Published var connecting: Set<String> = []
    @Published var connected: [String: ConnectionColour] = [:]
    @Published var failed: Set<String> = []

    var onOpenFavorite: (Favorite) -> Void = { _ in }
    var onEditFavorite: (Favorite) -> Void = { _ in }
    var onDeleteFavorite: (Favorite) -> Void = { _ in }
    var onDisconnect: (Favorite) -> Void = { _ in }
    var onOpenHost: (String) -> Void = { _ in }
    var onSaveHost: (String) -> Void = { _ in }
    var onOpenPlace: (Place) -> Void = { _ in }
    var onAddServer: () -> Void = {}
    var onNewGroup: (Favorite?) -> Void = { _ in }
    var onRenameGroup: (FavoriteGroup) -> Void = { _ in }
    var onDeleteGroup: (FavoriteGroup) -> Void = { _ in }
    var onMoveFavorite: (Favorite, String?) -> Void = { _, _ in }
    var onRecolourFavorite: (Favorite, ConnectionColour) -> Void = { _, _ in }

    var ungrouped: [Favorite] {
        let ids = Set(groups.map(\.id))
        return favorites.filter { $0.groupID.map { !ids.contains($0) } ?? true }
    }

    func favorites(in group: FavoriteGroup) -> [Favorite] { favorites.filter { $0.groupID == group.id } }
    var onOpenBookmark: (Bookmark) -> Void = { _ in }
    var onRenameBookmark: (Bookmark) -> Void = { _ in }
    var onDeleteBookmark: (Bookmark) -> Void = { _ in }

    func reloadBookmarks() {
        bookmarks = (try? ConnectionManager.shared.bookmarks.all()) ?? []
    }

    /// A favorite folder's tint: its server's colour, so it reads as belonging to that server.
    func placeColour(_ b: Bookmark) -> Color? {
        guard case let .favorite(id) = b.place, let fav = favorites.first(where: { $0.id == id }) else { return nil }
        return (fav.colour.flatMap(ConnectionColour.init(rawValue:)) ?? .none).color
    }

    /// Where a favorite folder lives, for its row: nil on this Mac, else the server's name.
    func placeName(_ b: Bookmark) -> String? {
        switch b.place {
        case .local: nil
        case let .favorite(id): favorites.first { $0.id == id }?.name ?? "server"
        case let .sshAlias(alias): alias
        }
    }

    var onOpenSynclet: (Synclet) -> Void = { _ in }
    var onDeleteSynclet: (Synclet) -> Void = { _ in }

    func reloadSynclets() {
        synclets = (try? ConnectionManager.shared.synclets.all()) ?? []
    }

    /// Finder's own Favorites (then Macintosh HD), and the tags in Finder's sidebar with their colours.
    @Published var places: [Place] = []
    @Published var tags: [FinderTag] = []
    var onOpenTag: (FinderTag) -> Void = { _ in }
    private var tagColours: [String: Int] = [:]

    /// Reads Finder's lists again (at launch and whenever Shellpane comes to the front). Colours come from
    /// Spotlight, off the main thread, and are remembered.
    func reloadMac() {
        // Published on the next turn of the run loop, and only when something changed: replacing the
        // sidebar's rows while its table is mid-update (activation arrives then) is a re-entrant table change.
        DispatchQueue.main.async { [self] in
            let newPlaces = FinderSidebar.favorites()
            if newPlaces != places { places = newPlaces }
            loadTags()
        }
    }

    private func loadTags() {
        let names = FinderTags.sidebarTagNames()
        let newTags = names.map { FinderTag(name: $0, colour: tagColours[$0] ?? 0) }
        if newTags != tags { tags = newTags }
        let missing = names.filter { tagColours[$0] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            let found = Dictionary(uniqueKeysWithValues: missing.map { ($0, FinderTags.colour(of: $0)) })
            await MainActor.run {
                self.tagColours.merge(found) { $1 }
                let coloured = self.tags.map { FinderTag(name: $0.name, colour: self.tagColours[$0.name] ?? $0.colour) }
                DispatchQueue.main.async { if coloured != self.tags { self.tags = coloured } }
            }
        }
    }

    /// ssh_config hosts not already saved as a favorite.
    var unsavedHosts: [String] {
        let saved = Set(favorites.compactMap(\.sshAlias))
        return sshHosts.filter { !saved.contains($0) }
    }

    func state(of key: String) -> ConnectionState {
        if failed.contains(key) { return .error }
        if connecting.contains(key) { return .connecting }
        return connected[key] != nil ? .connected : .disconnected
    }

    func reloadFavorites() {
        favorites = (try? ConnectionManager.shared.favorites.all()) ?? []
        groups = (try? ConnectionManager.shared.groups.all()) ?? []
    }
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        List {
            Section {
                if model.favorites.isEmpty {
                    VStack(alignment: .leading, spacing: Tokens.Space.s6) {
                        Text("No saved servers yet")
                            .foregroundStyle(Tokens.Colors.textMuted)
                        Button("Add Server…") { model.onAddServer() }
                            .controlSize(.small)
                    }
                    .padding(.vertical, Tokens.Space.s4)
                }
                ForEach(model.ungrouped) { fav in
                    favoriteRow(fav)
                }
                ForEach(model.groups) { group in
                    DisclosureGroup(isExpanded: Binding(get: { !model.collapsed.contains(group.id) },
                                                        set: { open in if open { model.collapsed.remove(group.id) } else { model.collapsed.insert(group.id) } })) {
                        ForEach(model.favorites(in: group)) { fav in favoriteRow(fav) }
                    } label: {
                        Label {
                            Text(group.name)
                        } icon: {
                            Image(systemName: "folder").foregroundStyle(Tokens.Colors.textMuted)
                        }
                            .contextMenu {
                                Button("Rename Group…") { model.onRenameGroup(group) }
                                Button("Delete Group", role: .destructive) { model.onDeleteGroup(group) }
                            }
                            .help("Deleting a group keeps its servers")
                    }
                }
            } header: {
                HStack {
                    Text("Servers")
                    Spacer()
                    Menu {
                        Button("Add Server…") { model.onAddServer() }
                        Button("New Group…") { model.onNewGroup(nil) }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add a server (⌘K) or a group")
                        .accessibilityLabel("Add server or group")
                }
            }

            if !model.bookmarks.isEmpty {
                Section("Favorite Folders") {
                    ForEach(model.bookmarks) { b in
                        let host = model.placeName(b)
                        Button { model.onOpenBookmark(b) } label: {
                            HStack(spacing: Tokens.Space.s4) {
                                Label {
                                    Text(b.name).lineLimit(1)
                                } icon: {
                                    Image(systemName: host == nil ? "folder" : "folder.fill")
                                        .foregroundStyle(model.placeColour(b) ?? Tokens.Colors.textMuted)
                                }
                                // The folder takes its server's colour; the server's name is in the tooltip.
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(host.map { "\($0): \(b.path)" } ?? b.path)
                        .contextMenu {
                            Button("Open") { model.onOpenBookmark(b) }
                            Button("Rename…") { model.onRenameBookmark(b) }
                            Divider()
                            Button("Remove from Favorite Folders", role: .destructive) { model.onDeleteBookmark(b) }
                        }
                        .accessibilityLabel("\(b.name), \(host.map { "on \($0)" } ?? "on this Mac"), \(b.path)")
                    }
                }
            }

            if !model.unsavedHosts.isEmpty {
                Section("From ~/.ssh/config") {
                    ForEach(model.unsavedHosts, id: \.self) { host in
                        let key = "alias:" + host
                        Button { model.onOpenHost(host) } label: {
                            HStack(spacing: Tokens.Space.s6) {
                                ServerBadge(icon: "terminal", colour: .none)
                                Text(host).lineLimit(1)
                                Spacer()
                                if model.state(of: key) != .disconnected {
                                    ConnectionDot(colour: model.connected[key] ?? .none, state: model.state(of: key))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Connect") { model.onOpenHost(host) }
                            Button("Save as Favorite…") { model.onSaveHost(host) }
                        }
                        .accessibilityLabel("\(host), from SSH config, \(model.state(of: key) == .connected ? "connected" : "not connected")")
                    }
                }
            }

            if !model.synclets.isEmpty {
                Section("Synclets") {
                    ForEach(model.synclets) { s in
                        Button { model.onOpenSynclet(s) } label: {
                            Label(s.name, systemImage: "arrow.triangle.2.circlepath")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(s.leftPath) ↔ \(s.rightPath)")
                        .contextMenu {
                            Button("Open") { model.onOpenSynclet(s) }
                            Button("Delete", role: .destructive) { model.onDeleteSynclet(s) }
                        }
                    }
                }
            }

            Section("Mac Favorites") {
                ForEach(model.places) { place in
                    Button { model.onOpenPlace(place) } label: {
                        Label(place.title, systemImage: place.symbol)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(place.path)
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
                        Button { model.onOpenTag(tag) } label: {
                            Label {
                                Text(tag.name).lineLimit(1)
                            } icon: {
                                TagDot(colour: tag.nsColor)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Everything tagged “\(tag.name)”")
                        .accessibilityLabel("Tag \(tag.name)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: Tokens.Size.sidebarMin)
    }

    private func favoriteRow(_ fav: Favorite) -> some View {
        let colour = fav.colour.flatMap(ConnectionColour.init(rawValue:)) ?? .none
        let state = model.state(of: fav.id)
        return Button { model.onOpenFavorite(fav) } label: {
            HStack(spacing: Tokens.Space.s6) {
                ServerBadge(icon: fav.icon, colour: colour)
                Text(fav.name).lineLimit(1)
                Spacer()
                // Only when there's something to say: the badge already carries the colour.
                if state != .disconnected { ConnectionDot(colour: model.connected[fav.id] ?? colour, state: state) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(fav.subtitle)
        .contextMenu {
            Button("Connect") { model.onOpenFavorite(fav) }
            if state == .connected { Button("Disconnect") { model.onDisconnect(fav) } }
            Divider()
            Button("Edit…") { model.onEditFavorite(fav) }
            Menu("Colour") {
                ForEach(ConnectionColour.allCases.filter { $0 != .none }, id: \.self) { c in
                    Button(c.rawValue.capitalized) { model.onRecolourFavorite(fav, c) }
                        .disabled(colour == c)
                }
            }
            Menu("Move to Group") {
                Button("No Group") { model.onMoveFavorite(fav, nil) }.disabled(fav.groupID == nil)
                if !model.groups.isEmpty { Divider() }
                ForEach(model.groups) { g in
                    Button(g.name) { model.onMoveFavorite(fav, g.id) }.disabled(fav.groupID == g.id)
                }
                Divider()
                Button("New Group…") { model.onNewGroup(fav) }
            }
            Button("Delete…", role: .destructive) { model.onDeleteFavorite(fav) }
        }
        .accessibilityLabel("\(fav.name), \(fav.subtitle), \(state == .connected ? "connected" : "not connected")")
    }
}

/// A Finder tag's colour dot: filled in its colour, or an outline for a tag with no colour.
struct TagDot: View {
    let colour: NSColor?
    var size: CGFloat = 10

    var body: some View {
        Group {
            if let colour {
                Circle().fill(Color(nsColor: colour))
            } else {
                Circle().strokeBorder(Tokens.Colors.textMuted, lineWidth: 1.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
