import AppKit
import CoreServices
import Foundation
import SFTPKit

/// For recordings meant for others (scripts/demo-video.sh): a neutral sidebar instead of the person's own
/// Finder Favorites and tags, and a stand-in for their account name. Never set in normal use.
enum Recording {
    static var neutralSidebar: Bool { ProcessInfo.processInfo.environment["SHELLPANE_DEMO_SIDEBAR"] != nil }
    static var userName: String { ProcessInfo.processInfo.environment["SHELLPANE_DISPLAY_USER"] ?? NSUserName() }
    /// Neutral tags for the sidebar instead of the person's own: "Client:6,Review:7" (name:Finder colour).
    static var demoTags: [FinderTag] {
        (ProcessInfo.processInfo.environment["SHELLPANE_DEMO_TAGS"] ?? "").split(separator: ",").compactMap { item in
            let parts = item.split(separator: ":")
            guard let name = parts.first, !name.isEmpty else { return nil }
            return FinderTag(name: String(name), colour: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
    }
    /// Where a recording's tagged files are. Spotlight doesn't index temporary folders, so the tag view
    /// walks this folder for files carrying the tag, read from the files themselves as Finder wrote it.
    static var demoTagRoot: String? { ProcessInfo.processInfo.environment["SHELLPANE_DEMO_TAG_ROOT"] }
}

/// The person's own Finder sidebar: their Favorites, and their tags with Finder's colours.
/// Read-only: Shellpane never changes Finder's lists.
enum FinderSidebar {
    /// Finder's Favorites, in Finder's order, for folders that exist; Macintosh HD last. Falls back to the
    /// usual Home, Desktop, Documents and Downloads if Finder's list can't be read.
    static func favorites() -> [SidebarModel.Place] {
        var places: [SidebarModel.Place] = []
        var seen: Set<String> = []
        for (name, path) in (Recording.neutralSidebar ? [] : finderFavorites()) where !seen.contains(path) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            seen.insert(path)
            places.append(.init(id: path, title: name, symbol: symbol(for: path), path: path))
        }
        if places.isEmpty {
            let home = NSHomeDirectory()
            places = [
                .init(id: home, title: Recording.userName, symbol: "house", path: home),
                .init(id: home + "/Desktop", title: "Desktop", symbol: symbol(for: home + "/Desktop"), path: home + "/Desktop"),
                .init(id: home + "/Documents", title: "Documents", symbol: symbol(for: home + "/Documents"), path: home + "/Documents"),
                .init(id: home + "/Downloads", title: "Downloads", symbol: symbol(for: home + "/Downloads"), path: home + "/Downloads"),
            ]
        }
        places.append(.init(id: "/", title: "Macintosh HD", symbol: "internaldrive", path: "/"))
        return places
    }

    /// Finder's Favorites through the shared file list. Apple marks this API deprecated but still serves
    /// it; it needs no Full Disk Access, unlike reading Finder's file directly.
    @available(macOS, deprecated: 10.11)
    private static func finderFavorites() -> [(String, String)] {
        // kLSSharedFileListFavoriteItems' value; the C global itself isn't concurrency-safe in Swift 6.
        let favoriteItems = "com.apple.LSSharedFileList.FavoriteItems" as CFString
        guard let list = LSSharedFileListCreate(nil, favoriteItems, nil)?
            .takeRetainedValue() else { return [] }
        var seed: UInt32 = 0
        let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return items.compactMap { item in
            guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL?,
                  url.isFileURL else { return nil }
            let name = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
            return (name, url.path)
        }
    }

    static func symbol(for path: String) -> String {
        let home = NSHomeDirectory()
        switch path {
        case home: return "house"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Downloads": return "arrow.down.circle"
        case home + "/Movies": return "film"
        case home + "/Music": return "music.note"
        case home + "/Pictures": return "photo"
        case "/Applications": return "app.badge"
        default: return path.hasPrefix(home + "/Library/CloudStorage/") ? "cloud" : "folder"
        }
    }
}

/// A Finder tag. `colour` is Finder's number: 0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
struct FinderTag: Identifiable, Hashable, Sendable {
    var name: String
    var colour: Int
    var id: String { name }

    var nsColor: NSColor? {
        switch colour {
        case 1: .systemGray
        case 2: .systemGreen
        case 3: .systemPurple
        case 4: .systemBlue
        case 5: .systemYellow
        case 6: .systemRed
        case 7: .systemOrange
        default: nil
        }
    }
}

enum FinderTags {
    /// What a tag view lists. The self-test swaps in its own files: Spotlight doesn't index temporary folders.
    nonisolated(unsafe) static var search: @Sendable (String) -> [String] = { name in
        if let root = Recording.demoTagRoot { return filesWalking(root, tagged: name) }
        return files(tagged: name)
    }

    /// Files under `root` carrying the tag, by reading each one's tags (no Spotlight).
    static func filesWalking(_ root: String, tagged name: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        return walker.compactMap { $0 as? String }
            .map { RemotePath.join(root, $0) }
            .filter { colours(at: $0)[name] != nil }
            .sorted()
    }

    /// The tags in Finder's sidebar, in Finder's order. Without that list, Finder's seven colour tags.
    static func sidebarTagNames() -> [String] {
        if Recording.neutralSidebar { return Recording.demoTags.map(\.name) }
        let names = (UserDefaults(suiteName: "com.apple.finder")?.array(forKey: "FavoriteTagNames") as? [String] ?? [])
            .filter { !$0.isEmpty }
        if !names.isEmpty { return names }
        let labels = NSWorkspace.shared.fileLabels   // index = colour number, localized ("Red", "Vermelho"…)
        return [6, 7, 5, 2, 4, 3, 1].compactMap { labels.indices.contains($0) ? labels[$0] : nil }
    }

    /// A tag's colour. Finder stores it with each tagged file ("name\ncolour"), so one tagged file tells.
    /// A tag named after a colour label and found on no file gets that label's colour.
    static func colour(of name: String) -> Int {
        if let demo = Recording.demoTags.first(where: { $0.name == name }) { return demo.colour }
        if let path = files(tagged: name, limit: 1).first, let n = colours(at: path)[name] { return n }
        return NSWorkspace.shared.fileLabels.firstIndex(of: name) ?? 0
    }

    /// Tag name → colour number, from a file's tags.
    static func colours(at path: String) -> [String: Int] {
        let attr = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(path, attr, nil, 0, 0, 0)
        guard size > 0 else { return [:] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attr, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let tags = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [:] }
        var result: [String: Int] = [:]
        for tag in tags {
            let parts = tag.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            result[String(parts[0])] = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        }
        return result
    }

    /// Everything Spotlight knows with this tag, as Finder shows it when you click the tag.
    static func files(tagged name: String, limit: Int = 5000) -> [String] {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemUserTags == \"\(escaped)\"" as CFString, nil, nil) else { return [] }
        MDQuerySetMaxCount(query, limit)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        return (0..<MDQueryGetResultCount(query)).compactMap { i in
            guard let raw = MDQueryGetResultAtIndex(query, i) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            return MDItemCopyAttribute(item, kMDItemPath) as? String
        }
    }
}
