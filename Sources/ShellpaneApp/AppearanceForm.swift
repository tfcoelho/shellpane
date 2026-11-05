import ShellpaneCore
import ShellpaneUI
import SwiftUI

/// The colour swatches and icon grid of every edit sheet.
struct AppearancePicker: View {
    @Binding var colour: ConnectionColour
    @Binding var icon: String
    let icons: [String]
    /// Offers "no colour of its own" first: a favorite folder then takes its server's colour.
    var offersAutomatic = false
    var automaticHelp = "Automatic: its standard colour"

    private var colours: [ConnectionColour] {
        ConnectionColour.allCases.filter { $0 != .none || offersAutomatic }
    }

    var body: some View {
        LabeledContent("Colour") {
            HStack(spacing: Tokens.Space.s8) {
                ForEach(colours, id: \.self) { c in
                    Button { colour = c } label: {
                        ZStack {
                            if c == .none {
                                Circle().strokeBorder(Tokens.Colors.textMuted, lineWidth: 1.5).frame(width: 16, height: 16)
                            } else {
                                Circle().fill(c.color).frame(width: 16, height: 16)
                            }
                            if colour == c {
                                Circle().strokeBorder(Tokens.Colors.text, lineWidth: 2).frame(width: 22, height: 22)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(c == .none ? automaticHelp : c.rawValue.capitalized)
                    .accessibilityLabel(c == .none ? "Automatic colour" : c.rawValue.capitalized)
                    .accessibilityAddTraits(colour == c ? .isSelected : [])
                }
            }
        }
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: Tokens.Space.s8), count: 8),
                  spacing: Tokens.Space.s8) {
            ForEach(icons, id: \.self) { name in
                Button { icon = name } label: {
                    // Line icons as in Finder; the chosen one in its colour with a thin ring, no fill.
                    let chosen = icon == name
                    Image(systemName: name)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(chosen ? colour.color : Tokens.Colors.textMuted)
                        .frame(width: 32, height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(chosen ? colour.color : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name.replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(icon == name ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Space.s4)
    }
}

/// What a favorite folder can look like: folders first, then kinds of work.
enum FolderIcons {
    static let all: [String] = [
        "folder", "folder.fill", "tray.full", "archivebox", "doc.text", "photo", "film", "music.note",
        "globe", "terminal", "chevron.left.forwardslash.chevron.right", "server.rack", "cloud", "shippingbox", "briefcase", "cart",
        "house", "flask", "graduationcap", "chart.bar", "lock.shield", "wrench.and.screwdriver", "star", "tag",
    ]

    /// A folder with no icon of its own: outlined on this Mac, filled on a server.
    static func standard(for place: Bookmark.Place) -> String { place == .local ? "folder" : "folder.fill" }

    /// The symbol to draw, falling back to the standard one if the stored name isn't known on this Mac.
    static func symbol(for b: Bookmark) -> String {
        if let icon = b.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil { return icon }
        return standard(for: b.place)
    }
}

/// A line of an edit sheet that says something and can't be changed here.
struct DetailLine: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// Something in the sidebar with a look of its own, other than saved servers and favorite folders.
struct AppearanceItem {
    let key: String
    /// What it is, for the sheet's title: "Edit \(kind)".
    let kind: String
    let title: String
    let standardIcon: String
    let icons: [String]
    /// What "no colour of its own" looks like here.
    var automaticHelp = "Automatic: its standard colour"
    var footer = "How it looks in the sidebar."
    var details: [DetailLine] = []
    /// Where ssh goes for it, when it stands for a server.
    var connection: Bookmark.Place?

    /// With its standard icon first if the list doesn't have it (Finder's own symbols, say).
    static func icons(_ list: [String], with standard: String) -> [String] {
        list.contains(standard) ? list : [standard] + list
    }
}

/// The edit sheet of everything in the sidebar but servers, which have more to say and their own form on the
/// same pieces. Details first (what can't change here is shown, not hidden), then the look.
@MainActor
final class AppearanceFormModel: ObservableObject {
    /// What it looks like with nothing chosen.
    struct Look {
        let standardIcon: String
        let automaticColour: ConnectionColour
        let automaticHelp: String
    }

    struct PathField {
        let label: String
        var value: String
        var isLocal: Bool
    }

    struct PlaceChoice: Identifiable {
        let place: Bookmark.Place
        let title: String
        var id: Bookmark.Place { place }
    }

    /// The servers a favorite folder can be on, besides this Mac.
    struct PlaceChoices {
        let servers: [PlaceChoice]
        let hosts: [PlaceChoice]
    }

    @Published var name: String
    @Published var colour: ConnectionColour
    @Published var icon: String
    @Published var paths: [PathField]
    @Published var place: Bookmark.Place? { didSet { if place != oldValue { placeChanged() } } }
    @Published private(set) var look: Look
    /// Where ssh really goes for `place`, once worked out.
    @Published private(set) var connection: String?
    @Published private(set) var isResolving = false

    let kind: String
    let nameEditable: Bool
    let icons: [String]
    let footer: String
    let details: [DetailLine]
    let placeChoices: PlaceChoices?
    private let lookAt: ((Bookmark.Place) -> Look)?
    var deleteTitle: String?
    var onDelete: () -> Void = {}
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    init(kind: String, name: String, nameEditable: Bool = false, icon: String?, colour: String?, look: Look, icons: [String], footer: String,
         details: [DetailLine] = [], paths: [PathField] = [], place: Bookmark.Place? = nil,
         placeChoices: PlaceChoices? = nil, lookAt: ((Bookmark.Place) -> Look)? = nil) {
        self.kind = kind
        self.name = name
        self.nameEditable = nameEditable
        self.look = look
        self.icons = icons
        self.footer = footer
        self.details = details
        self.paths = paths
        self.place = place
        self.placeChoices = placeChoices
        self.lookAt = lookAt
        self.colour = colour.flatMap(ConnectionColour.init(rawValue:)) ?? .none
        self.icon = icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? look.standardIcon
        resolveConnection()
    }

    var title: String { "Edit \(kind)" }
    var showsConnection: Bool { place != nil && place != .local }
    var shownColour: ConnectionColour { colour == .none ? look.automaticColour : colour }
    /// What to store: nothing when it's the default, so it keeps following the standard look.
    var storedIcon: String? { icon == look.standardIcon ? nil : icon }
    var storedColour: String? { colour == .none ? nil : colour.rawValue }

    /// A path as it's saved; ~ means something only on this Mac, where it can be written out.
    func cleanedPath(_ i: Int) -> String {
        let cleaned = Bookmark.clean(path: paths[i].value)
        return paths[i].isLocal ? (cleaned as NSString).expandingTildeInPath : cleaned
    }

    private var pathsAreValid: Bool { paths.indices.allSatisfy { cleanedPath($0).hasPrefix("/") } }
    /// Only once something's been typed: an empty field speaks for itself.
    var pathProblem: String? {
        paths.indices.contains { !cleanedPath($0).isEmpty && !cleanedPath($0).hasPrefix("/") } ? Bookmark.EditError.notAbsolute.errorDescription : nil
    }

    var canSave: Bool {
        pathsAreValid && (!nameEditable || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func useDefault() {
        colour = .none
        icon = look.standardIcon
    }

    private func placeChanged() {
        guard let place else { return }
        if let new = lookAt?(place) {
            // A folder still on its standard icon keeps following it.
            if icon == look.standardIcon { icon = new.standardIcon }
            look = new
        }
        for i in paths.indices { paths[i].isLocal = place == .local }
        resolveConnection()
    }

    private func resolveConnection() {
        connection = nil
        guard showsConnection, let place else {
            isResolving = false
            return
        }
        isResolving = true
        Task { @MainActor in
            let address = await ConnectionManager.shared.address(of: place)
            guard self.place == place else { return }   // moved on while ssh was answering
            self.connection = address
            self.isResolving = false
        }
    }
}

/// The top of every edit sheet: how it will look, what kind of thing it is, and its name.
struct EditSheetHeader: View {
    let icon: String
    let colour: ConnectionColour
    let title: String
    let name: String

    var body: some View {
        HStack(spacing: Tokens.Space.s16) {
            ServerBadge(icon: icon, colour: colour, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.title3.weight(.semibold))
                Text(verbatim: name)
                    .foregroundStyle(Tokens.Colors.textMuted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding([.horizontal, .top], Tokens.Space.s24)
        .padding(.bottom, Tokens.Space.s4)
    }
}

/// The Appearance section of every edit sheet.
struct AppearanceSection: View {
    @Binding var colour: ConnectionColour
    @Binding var icon: String
    let icons: [String]
    var offersAutomatic = false
    var automaticHelp = ""
    let footer: String
    let useDefault: () -> Void

    var body: some View {
        Section {
            AppearancePicker(colour: $colour, icon: $icon, icons: icons, offersAutomatic: offersAutomatic, automaticHelp: automaticHelp)
        } header: {
            HStack {
                Text("Appearance")
                Spacer()
                Button("Use Default", action: useDefault)
                    .controlSize(.small)
                    .help("Back to its standard icon and colour")
            }
        } footer: {
            Text(verbatim: footer)
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The bottom of every edit sheet: what removes it on the left, Cancel and Save on the right.
struct EditSheetButtons<Leading: View>: View {
    var saveTitle = "Save"
    var canSave = true
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack {
            leading()
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(saveTitle, action: onSave)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(Tokens.Space.s16)
    }
}

/// A line that says something and can't be changed here; its value can be selected and copied.
struct DetailRow: View {
    let line: DetailLine

    var body: some View {
        LabeledContent(line.label) {
            Text(verbatim: line.value)
                .font(.callout.monospaced())
                .foregroundStyle(Tokens.Colors.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(line.value)
        }
    }
}

struct AppearanceFormView: View {
    @ObservedObject var model: AppearanceFormModel

    var body: some View {
        VStack(spacing: 0) {
            EditSheetHeader(icon: model.icon, colour: model.shownColour, title: model.title, name: model.name)
            Form {
                detailsSection
                AppearanceSection(colour: $model.colour, icon: $model.icon, icons: model.icons, offersAutomatic: true,
                                  automaticHelp: model.look.automaticHelp, footer: model.footer, useDefault: model.useDefault)
            }
            .formStyle(.grouped)
            EditSheetButtons(canSave: model.canSave, onCancel: model.onCancel, onSave: model.onSave) {
                if let title = model.deleteTitle {
                    Button(title, role: .destructive, action: model.onDelete)
                }
            }
        }
        .frame(width: Tokens.Size.editSheetWidth)
        .frame(minHeight: Tokens.Size.editSheetHeight)
    }

    private var detailsSection: some View {
        Section("Details") {
            if model.nameEditable {
                TextField("Name", text: $model.name)
            } else {
                DetailRow(line: .init(label: "Name", value: model.name))
            }
            if let choices = model.placeChoices {
                Picker("Location", selection: Binding(get: { model.place ?? .local }, set: { model.place = $0 })) {
                    Text("This Mac").tag(Bookmark.Place.local)
                    if !choices.servers.isEmpty {
                        Section("Saved Servers") {
                            ForEach(choices.servers) { Text(verbatim: $0.title).tag($0.place) }
                        }
                    }
                    if !choices.hosts.isEmpty {
                        Section("From ~/.ssh/config") {
                            ForEach(choices.hosts) { Text(verbatim: $0.title).tag($0.place) }
                        }
                    }
                }
            }
            if model.showsConnection {
                LabeledContent("Resolves to") {
                    if model.isResolving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(verbatim: model.connection ?? "Couldn't work it out")
                            .font(.callout.monospaced())
                            .foregroundStyle(Tokens.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(model.connection ?? "")
                    }
                }
            }
            ForEach(model.paths.indices, id: \.self) { i in
                LabeledContent(model.paths[i].label) {
                    TextField(model.paths[i].label, text: $model.paths[i].value, prompt: Text(verbatim: "/path/to/folder"))
                        .labelsHidden()
                        .font(.callout.monospaced())
                }
            }
            if let problem = model.pathProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokens.Colors.danger)
            }
            ForEach(model.details) { DetailRow(line: $0) }
        }
    }
}
