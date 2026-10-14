import SwiftUI

/// Where a pane is: optional host chip, then breadcrumb segments. Click a segment to go there.
/// Click the empty part (or ⌘L / ⇧⌘G) to type a path: the pane puts its own text field over the bar.
/// At the end: ☆ adds the folder to Favorite Folders, and the copy button copies its path.
public struct PathBar: View {
    public struct Remote: Sendable {
        public var user: String
        public var host: String
        public var colour: ConnectionColour
        /// The saved server's icon (nil for one that isn't saved).
        public var icon: String?
        public init(user: String, host: String, colour: ConnectionColour, icon: String? = nil) {
            self.user = user
            self.host = host
            self.colour = colour
            self.icon = icon
        }
    }

    let remote: Remote?
    let path: String
    let isBookmarked: Bool
    /// While the pane's path field is over the bar, the breadcrumbs aren't drawn (they'd show through).
    let isEditing: Bool
    /// Showing a Finder tag's files instead of a folder: the tag's name and colour (nil = no colour).
    let tag: (name: String, colour: Color?)?
    let onNavigate: (String) -> Void
    let onEdit: () -> Void
    /// true: as "host:/path" (or "user@host:/path"), ready for scp or rsync.
    let onCopy: (_ remoteForm: Bool) -> Void
    let onToggleBookmark: () -> Void

    public init(remote: Remote?, path: String, isBookmarked: Bool = false, isEditing: Bool = false,
                tag: (name: String, colour: Color?)? = nil,
                onNavigate: @escaping (String) -> Void = { _ in }, onEdit: @escaping () -> Void = {},
                onCopy: @escaping (_ remoteForm: Bool) -> Void = { _ in }, onToggleBookmark: @escaping () -> Void = {}) {
        self.remote = remote
        self.path = path
        self.isBookmarked = isBookmarked
        self.isEditing = isEditing
        self.tag = tag
        self.onNavigate = onNavigate
        self.onEdit = onEdit
        self.onCopy = onCopy
        self.onToggleBookmark = onToggleBookmark
    }

    /// "/var/www/site" -> [("/", "/"), ("var", "/var"), ("www", "/var/www"), ("site", "/var/www/site")]
    static func segments(of path: String) -> [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let remote { ConnectionBar(colour: remote.colour) }
            HStack(spacing: Tokens.Space.s4) {
                if let remote {
                    HStack(spacing: Tokens.Space.s4) {
                        ServerBadge(icon: remote.icon ?? "terminal", colour: remote.colour, size: 15)
                        Text(verbatim: "\(remote.user)@\(remote.host)")
                    }
                        .font(.callout.weight(.medium))
                        .padding(.leading, 3)
                        .padding(.trailing, Tokens.Space.s6)
                        .padding(.vertical, 2)
                        .background(Tokens.Colors.surfaceRaised, in: Capsule())
                        .overlay(Capsule().strokeBorder(Tokens.Colors.border))
                        .accessibilityLabel("Connected to \(remote.host) as \(remote.user)")
                        .fixedSize()          // the server never shortens; long paths do
                }
                Group {
                    if let tag {
                        HStack(spacing: Tokens.Space.s4) {
                            Circle()
                                .fill(tag.colour ?? .clear)
                                .overlay(Circle().strokeBorder(tag.colour == nil ? Tokens.Colors.textMuted : .clear))
                                .frame(width: 10, height: 10)
                            Text(verbatim: "Tagged “\(tag.name)”").font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        breadcrumbs
                    }
                }
                .layoutPriority(1)   // names get their room first, and shorten only when the pane is narrow
                .opacity(isEditing ? 0 : 1)
                Spacer(minLength: Tokens.Space.s8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { onEdit() }
                    .help("Click to type a path (⌘L)")
                if tag == nil {
                Button(action: onToggleBookmark) {
                    Image(systemName: isBookmarked ? "star.fill" : "star")
                        .foregroundStyle(isBookmarked ? Tokens.Colors.accentText : Tokens.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .help(isBookmarked ? "Remove from Favorite Folders" : "Add to Favorite Folders (⌃⌘T)")
                .accessibilityLabel(isBookmarked ? "Remove this folder from Favorite Folders" : "Add this folder to Favorite Folders")
                Button { onCopy(false) } label: {
                    Image(systemName: "doc.on.doc").foregroundStyle(Tokens.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .help(remote == nil ? "Copy the path" : "Copy the path (right-click for host:path)")
                .accessibilityLabel("Copy this folder's path")
                }
            }
            .contextMenu {
                Button("Edit Path…") { onEdit() }
                Button("Copy Path") { onCopy(false) }
                if remote != nil { Button("Copy as host:path (for scp and rsync)") { onCopy(true) } }
                Divider()
                Button(isBookmarked ? "Remove from Favorite Folders" : "Add to Favorite Folders") { onToggleBookmark() }
            }
            .padding(.horizontal, Tokens.Space.s8)
            .frame(height: Tokens.Size.pathBar - (remote == nil ? 0 : Tokens.Size.connectionBar))
            .background(Tokens.Colors.surface)
        }
    }

    private var breadcrumbs: some View {
        let segs = Self.segments(of: path)
        return HStack(spacing: Tokens.Space.s2) {
            ForEach(Array(segs.enumerated()), id: \.offset) { index, seg in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.Colors.textMuted)
                        .accessibilityHidden(true)
                }
                Button(seg.name == "/" ? (remote == nil ? "Macintosh HD" : "/") : seg.name) {
                    onNavigate(seg.path)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(index == segs.count - 1 ? Tokens.Colors.text : Tokens.Colors.textMuted)
                .lineLimit(1)
                .accessibilityLabel("Go to \(seg.name)")
            }
        }
    }
}
