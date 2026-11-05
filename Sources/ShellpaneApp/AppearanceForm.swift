import ShellpaneCore
import ShellpaneUI
import SwiftUI

/// The colour swatches and icon grid: a server's appearance, and a favorite folder's.
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

/// Something in the sidebar whose look can be changed, other than saved servers and favorite folders.
struct AppearanceItem {
    let key: String
    let title: String
    let subtitle: String
    let standardIcon: String
    let icons: [String]
    /// What "no colour of its own" looks like here.
    var automaticHelp = "Automatic: its standard colour"
    var footer = "How it looks in the sidebar."

    /// With its standard icon first if the list doesn't have it (Finder's own symbols, say).
    static func icons(_ list: [String], with standard: String) -> [String] {
        list.contains(standard) ? list : [standard] + list
    }
}

/// The edit sheet: a favorite folder's name and look, or the look of anything else in the sidebar.
@MainActor
final class AppearanceFormModel: ObservableObject {
    @Published var name: String
    @Published var colour: ConnectionColour
    @Published var icon: String
    let title: String
    let subtitle: String
    let hasName: Bool
    let icons: [String]
    let standardIcon: String
    /// The colour "Automatic" stands for in the preview.
    let automaticColour: ConnectionColour
    let automaticHelp: String
    let footer: String
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    init(title: String, subtitle: String, name: String? = nil, icon: String?, colour: String?, standardIcon: String, icons: [String],
         automaticColour: ConnectionColour = .none, automaticHelp: String, footer: String) {
        self.title = title
        self.subtitle = subtitle
        hasName = name != nil
        self.name = name ?? ""
        self.icons = icons
        self.standardIcon = standardIcon
        self.automaticColour = automaticColour
        self.automaticHelp = automaticHelp
        self.footer = footer
        self.colour = colour.flatMap(ConnectionColour.init(rawValue:)) ?? .none
        self.icon = icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? standardIcon
    }

    var canSave: Bool { !hasName || !name.trimmingCharacters(in: .whitespaces).isEmpty }
    var shownColour: ConnectionColour { colour == .none ? automaticColour : colour }
    /// What to store: nothing when it's the default, so it keeps following the standard look.
    var storedIcon: String? { icon == standardIcon ? nil : icon }
    var storedColour: String? { colour == .none ? nil : colour.rawValue }
}

struct AppearanceFormView: View {
    @ObservedObject var model: AppearanceFormModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s16) {
                ServerBadge(icon: model.icon, colour: model.shownColour, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.title).font(.title3.weight(.semibold))
                    Text(verbatim: model.subtitle)
                        .foregroundStyle(Tokens.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .padding([.horizontal, .top], Tokens.Space.s24)
            .padding(.bottom, Tokens.Space.s4)
            Form {
                if model.hasName { TextField("Name", text: $model.name) }
                Section {
                    AppearancePicker(colour: $model.colour, icon: $model.icon, icons: model.icons,
                                     offersAutomatic: true, automaticHelp: model.automaticHelp)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text(verbatim: model.footer)
                        .font(.callout)
                        .foregroundStyle(Tokens.Colors.textMuted)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Use Default") {
                    model.colour = .none
                    model.icon = model.standardIcon
                }
                .help("Back to its standard icon and colour")
                Spacer()
                Button("Cancel", role: .cancel) { model.onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            .padding(Tokens.Space.s16)
        }
        .frame(width: Tokens.Size.sheetWidth + 60)
        .frame(minHeight: 520)
    }
}
