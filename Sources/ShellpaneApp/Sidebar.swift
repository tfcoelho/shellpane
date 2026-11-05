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
    var onEditGroup: (FavoriteGroup) -> Void = { _ in }
    var onDeleteGroup: (FavoriteGroup) -> Void = { _ in }
    var onMoveFavorite: (Favorite, String?) -> Void = { _, _ in }

    var ungrouped: [Favorite] {
        let ids = Set(groups.map(\.id))
        return favorites.filter { $0.groupID.map { !ids.contains($0) } ?? true }
    }

    func favorites(in group: FavoriteGroup) -> [Favorite] { favorites.filter { $0.groupID == group.id } }
    var onOpenBookmark: (Bookmark) -> Void = { _ in }
    var onEditBookmark: (Bookmark) -> Void = { _ in }
    var onDeleteBookmark: (Bookmark) -> Void = { _ in }

    /// Chosen looks for what isn't a saved server or a favorite folder, by `AppearanceKey`.
    @Published var appearances: [String: Appearance] = [:]
    var onEditAppearance: (AppearanceItem) -> Void = { _ in }
    var onEditSynclet: (Synclet) -> Void = { _ in }

    func reloadAppearances() {
        appearances = (try? ConnectionManager.shared.appearances.all()) ?? [:]
    }

    /// The icon to draw: the chosen one, or `standard` if none was chosen or it isn't known on this Mac.
    func symbol(_ key: String, standard: String) -> String {
        if let icon = appearances[key]?.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil { return icon }
        return standard
    }

    /// The chosen colour, if any.
    func ownColour(_ key: String) -> ConnectionColour? {
        appearances[key]?.colour.flatMap(ConnectionColour.init(rawValue:))
    }

    func hostItem(_ host: String) -> AppearanceItem {
        AppearanceItem(key: AppearanceKey.host(host), kind: "SSH Config Host", title: host, standardIcon: "terminal",
                       icons: AppearanceItem.icons(ServerIcons.all, with: "terminal"),
                       footer: "How it looks in the sidebar and on the path bar. Your ~/.ssh/config isn't changed.",
                       details: [.init(label: "Defined in", value: "~/.ssh/config")], connection: .sshAlias(host))
    }

    func placeItem(_ place: Place) -> AppearanceItem {
        AppearanceItem(key: AppearanceKey.place(place.path), kind: "Mac Favorite", title: place.title, standardIcon: place.symbol,
                       icons: AppearanceItem.icons(FolderIcons.all, with: place.symbol),
                       footer: "How it looks in Shellpane. Finder's own sidebar isn't changed.",
                       details: [.init(label: "Path", value: place.path)])
    }

    func syncletItem(_ s: Synclet) -> AppearanceItem {
        let standard = "arrow.triangle.2.circlepath"
        return AppearanceItem(key: AppearanceKey.synclet(s.id), kind: "Synclet", title: s.name, standardIcon: standard,
                              icons: AppearanceItem.icons(FolderIcons.all, with: standard))
    }

    func groupItem(_ g: FavoriteGroup) -> AppearanceItem {
        let count = favorites(in: g).count
        return AppearanceItem(key: AppearanceKey.group(g.id), kind: "Group", title: g.name, standardIcon: "folder", icons: FolderIcons.all,
                              details: [.init(label: "Servers", value: "\(count)")])
    }

    func tagItem(_ t: FinderTag) -> AppearanceItem {
        let standard = "circle.fill"
        return AppearanceItem(key: AppearanceKey.tag(t.name), kind: "Tag", title: t.name, standardIcon: standard,
                              icons: AppearanceItem.icons(FolderIcons.all, with: standard), automaticHelp: "Automatic: the tag's colour in Finder",
                              footer: "How it looks in Shellpane. The tag itself isn't changed in Finder.")
    }

    func reloadBookmarks() {
        bookmarks = (try? ConnectionManager.shared.bookmarks.all()) ?? []
    }

    /// A favorite folder's tint: its own colour, or else its server's, so it reads as belonging to that server.
    func placeColour(_ b: Bookmark) -> Color? {
        if let own = b.colour.flatMap(ConnectionColour.init(rawValue:)), own != .none { return own.color }
        guard case let .favorite(id) = b.place, let fav = favorites.first(where: { $0.id == id }) else { return nil }
        return (fav.colour.flatMap(ConnectionColour.init(rawValue:)) ?? .none).color
    }

    /// The colour a favorite folder here has with none of its own: its server's, grey on this Mac.
    func automaticColour(at place: Bookmark.Place) -> ConnectionColour {
        guard case let .favorite(id) = place, let fav = favorites.first(where: { $0.id == id }) else { return .none }
        return fav.colour.flatMap(ConnectionColour.init(rawValue:)) ?? .none
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

    /// Its chosen icon and colour; with no colour chosen, the same as a plain Label's icon.
    @ViewBuilder
    private func lookIcon(_ item: AppearanceItem) -> some View {
        let symbol = Image(systemName: model.symbol(item.key, standard: item.standardIcon))
        if let colour = model.ownColour(item.key) { symbol.foregroundStyle(colour.color) } else { symbol }
    }

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
                        let item = model.groupItem(group)
                        Label {
                            Text(group.name)
                        } icon: {
                            Image(systemName: model.symbol(item.key, standard: item.standardIcon))
                                .foregroundStyle(model.ownColour(item.key)?.color ?? Tokens.Colors.textMuted)
                        }
                            .contextMenu {
                                Button("Edit…") { model.onEditGroup(group) }
                                Divider()
                                Button("Delete", role: .destructive) { model.onDeleteGroup(group) }
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
                                    Image(systemName: FolderIcons.symbol(for: b))
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
                            Divider()
                            Button("Edit…") { model.onEditBookmark(b) }
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
                        let item = model.hostItem(host)
                        Button { model.onOpenHost(host) } label: {
                            HStack(spacing: Tokens.Space.s6) {
                                ServerBadge(icon: model.symbol(item.key, standard: item.standardIcon), colour: model.ownColour(item.key) ?? .none)
                                Text(host).lineLimit(1)
                                Spacer()
                                if model.state(of: key) != .disconnected {
                                    ConnectionDot(colour: model.ownColour(item.key) ?? model.connected[key] ?? .none, state: model.state(of: key))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Connect") { model.onOpenHost(host) }
                            Button("Save as Favorite…") { model.onSaveHost(host) }
                            Divider()
                            Button("Edit…") { model.onEditAppearance(item) }
                        }
                        .accessibilityLabel("\(host), from SSH config, \(model.state(of: key) == .connected ? "connected" : "not connected")")
                    }
                }
            }

            if !model.synclets.isEmpty {
                Section("Synclets") {
                    ForEach(model.synclets) { s in
                        Button { model.onOpenSynclet(s) } label: {
                            Label {
                                Text(s.name)
                            } icon: {
                                lookIcon(model.syncletItem(s))
                            }
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(s.leftPath) ↔ \(s.rightPath)")
                        .contextMenu {
                            Button("Open") { model.onOpenSynclet(s) }
                            Divider()
                            Button("Edit…") { model.onEditSynclet(s) }
                            Divider()
                            Button("Delete", role: .destructive) { model.onDeleteSynclet(s) }
                        }
                    }
                }
            }

            Section("Mac Favorites") {
                ForEach(model.places) { place in
                    Button { model.onOpenPlace(place) } label: {
                        Label {
                            Text(place.title)
                        } icon: {
                            lookIcon(model.placeItem(place))
                        }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(place.path)
                    .contextMenu {
                        Button("Open") { model.onOpenPlace(place) }
                        Divider()
                        Button("Edit…") { model.onEditAppearance(model.placeItem(place)) }
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
                        Button { model.onOpenTag(tag) } label: {
                            Label {
                                Text(tag.name).lineLimit(1)
                            } icon: {
                                let item = model.tagItem(tag)
                                if model.appearances[item.key] == nil {
                                    TagDot(colour: tag.nsColor)
                                } else {
                                    Image(systemName: model.symbol(item.key, standard: item.standardIcon))
                                        .foregroundStyle(model.ownColour(item.key)?.color ?? tag.nsColor.map { Color(nsColor: $0) } ?? Tokens.Colors.textMuted)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Everything tagged “\(tag.name)”")
                        .contextMenu {
                            Button("Open") { model.onOpenTag(tag) }
                            Divider()
                            Button("Edit…") { model.onEditAppearance(model.tagItem(tag)) }
                        }
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
            Menu("Move to Group") {
                Button("No Group") { model.onMoveFavorite(fav, nil) }.disabled(fav.groupID == nil)
                if !model.groups.isEmpty { Divider() }
                ForEach(model.groups) { g in
                    Button(g.name) { model.onMoveFavorite(fav, g.id) }.disabled(fav.groupID == g.id)
                }
                Divider()
                Button("New Group…") { model.onNewGroup(fav) }
            }
            Divider()
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
