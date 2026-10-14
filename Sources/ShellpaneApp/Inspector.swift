import AppKit
import Combine
import ShellpaneCore
import ShellpaneUI
import SFTPKit
import SwiftUI
import TransferKit

/// The right-hand pane (⌥⌘I): S11 Info for the active pane's selection, with editable permissions,
/// and S09 the operation log.
@MainActor
final class InspectorModel: ObservableObject {
    enum Tab: String, CaseIterable { case info = "Info", log = "Log" }

    @Published var tab: Tab = .info
    @Published private(set) var location: Location?
    @Published private(set) var selection: [FileEntry] = []
    @Published var permissions: UInt32 = 0
    @Published private(set) var originalPermissions: UInt32 = 0
    @Published var octal = ""
    @Published private(set) var folderSize: (files: Int, bytes: UInt64)?
    @Published private(set) var calculating = false
    @Published private(set) var log: [LogEntry] = []
    @Published var message: String?
    private var sizeTask: Task<Void, Never>?
    var onChanged: (Location) -> Void = { _ in }

    var single: FileEntry? { selection.count == 1 ? selection[0] : nil }

    func update(location: Location, selection: [FileEntry]) {
        let locationChanged = self.location.map { !PaneViewController.same($0, location) } ?? true
        self.location = location
        let selectionChanged = selection.map(\.path) != self.selection.map(\.path) || locationChanged
        self.selection = selection
        let fresh = (single?.attributes.permissions ?? 0) & 0o7777
        if selectionChanged {
            sizeTask?.cancel()
            folderSize = nil
            calculating = false
            message = nil
            permissions = fresh
            octal = String(fresh, radix: 8)
        }
        // Refreshes keep an edit in progress; the stored value follows the file.
        originalPermissions = fresh
    }

    func bit(_ mask: UInt32) -> Binding<Bool> {
        Binding(get: { self.permissions & mask != 0 }, set: { on in
            self.permissions = on ? self.permissions | mask : self.permissions & ~mask
            self.octal = String(self.permissions, radix: 8)
        })
    }

    func octalCommitted() {
        if let v = UInt32(octal, radix: 8), v <= 0o7777 { permissions = v } else { octal = String(permissions, radix: 8) }
    }

    /// chmod on the server (SFTP setstat) or here (POSIX permissions).
    func applyPermissions() {
        guard let entry = single, let location else { return }
        let mode = permissions
        Task { @MainActor in
            do {
                let live = try await location.live()
                switch live {
                case let .remote(session, _):
                    try await session.client.setstat(entry.path, FileAttributes(permissions: mode))
                case .local:
                    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: entry.path)
                }
                ConnectionManager.shared.log.record(.chmod, path: entry.path, message: String(mode, radix: 8), favoriteID: live.session?.key)
                originalPermissions = mode
                message = "Permissions set to \(String(mode, radix: 8))."
                onChanged(location)
            } catch {
                message = error.localizedDescription
                ConnectionManager.shared.log.record(.chmod, path: entry.path, result: .failed, message: error.localizedDescription,
                                                    favoriteID: location.session?.key)
            }
        }
    }

    /// Adds up a folder (or the selection), walking it on its own filesystem. Stops at 200,000 items.
    func calculateSize() {
        guard let location else { return }
        let targets = selection.isEmpty ? [FileEntry(name: "", path: location.path, attributes: FileAttributes(permissions: 0o040000))] : selection
        calculating = true
        sizeTask = Task { @MainActor in
            defer { calculating = false }
            guard let live = try? await location.live() else { return }
            let ops = live.ops
            var files = 0
            var bytes: UInt64 = 0
            var stack = targets
            while let e = stack.popLast(), files < 200_000, !Task.isCancelled {
                if e.attributes.fileType == .directory {
                    for child in (try? await ops.list(e.path)) ?? [] { stack.append(child) }
                } else {
                    files += 1
                    bytes += e.attributes.size ?? 0
                }
                if files % 500 == 0 { folderSize = (files, bytes) }
            }
            if !Task.isCancelled { folderSize = (files, bytes) }
        }
    }

    func reloadLog() {
        log = (try? ConnectionManager.shared.log.recent(limit: 300)) ?? []
    }
}

struct InspectorView: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $model.tab) {
                ForEach(InspectorModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Tokens.Space.s12)
            Divider()
            switch model.tab {
            case .info: info
            case .log: logList
            }
        }
        .frame(minWidth: 240, idealWidth: Tokens.Size.previewPaneDefault)
        .onChange(of: model.tab) { _, tab in if tab == .log { model.reloadLog() } }
    }

    // MARK: Info

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Tokens.Colors.textMuted).frame(width: 78, alignment: .trailing)
            Text(value)
                .font(mono ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var info: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                if let e = model.single {
                    HStack(spacing: Tokens.Space.s8) {
                        Image(systemName: PaneViewController.symbol(for: e))
                            .font(.system(size: 28))
                            .foregroundStyle(e.isDirectory ? Tokens.Colors.accentText : Tokens.Colors.textMuted)
                        VStack(alignment: .leading) {
                            Text(e.name).font(.headline).textSelection(.enabled).lineLimit(2)
                            Text(PaneViewController.kind(of: e)).font(.callout).foregroundStyle(Tokens.Colors.textMuted)
                        }
                    }
                    .padding(.bottom, Tokens.Space.s4)
                    if e.isDirectory {
                        sizeRow
                    } else {
                        let size = e.attributes.size ?? 0
                        let short = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                        row("Size", size < 1000 ? short : short + " (\(size.formatted()) bytes)")
                    }
                    row("Modified", e.attributes.modificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "–")
                    row("Where", (model.location?.session.map { "\($0.label):" } ?? "") + RemotePath.parent(e.path), mono: true)
                    if let uid = e.attributes.uid, let gid = e.attributes.gid { row("Owner", "uid \(uid), gid \(gid)") }
                    Divider().padding(.vertical, Tokens.Space.s4)
                    permissionsEditor
                } else if model.selection.count > 1 {
                    Text("\(model.selection.count) items").font(.headline)
                    let bytes = model.selection.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 + ($1.attributes.size ?? 0) }
                    row("Files", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    sizeRow
                } else if let loc = model.location {
                    Text(loc.displayTitle).font(.headline)
                    row("Where", loc.path, mono: true)
                    sizeRow
                } else {
                    Text("Select a file to see its details.").foregroundStyle(Tokens.Colors.textMuted)
                }
                if let m = model.message {
                    Text(m).font(.callout).foregroundStyle(Tokens.Colors.textMuted).padding(.top, Tokens.Space.s4)
                }
            }
            .padding(Tokens.Space.s12)
        }
    }

    @ViewBuilder private var sizeRow: some View {
        if let s = model.folderSize {
            row("Contains", "\(s.files.formatted()) file\(s.files == 1 ? "" : "s"), "
                + ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file) + (model.calculating ? "…" : ""))
        } else {
            HStack {
                Text("Size").foregroundStyle(Tokens.Colors.textMuted).frame(width: 78, alignment: .trailing)
                Button(model.calculating ? "Calculating…" : "Calculate") { model.calculateSize() }
                    .controlSize(.small)
                    .disabled(model.calculating)
                Spacer()
            }
        }
    }

    private var permissionsEditor: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s6) {
            Text("Permissions").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: Tokens.Space.s12, verticalSpacing: Tokens.Space.s4) {
                GridRow {
                    Text("")
                    Text("Read").font(.callout).foregroundStyle(Tokens.Colors.textMuted)
                    Text("Write").font(.callout).foregroundStyle(Tokens.Colors.textMuted)
                    Text("Run").font(.callout).foregroundStyle(Tokens.Colors.textMuted)
                }
                ForEach(Array([("Owner", 6), ("Group", 3), ("Everyone", 0)].enumerated()), id: \.offset) { _, who in
                    GridRow {
                        Text(who.0).font(.callout)
                        ForEach([2, 1, 0], id: \.self) { b in
                            Toggle("", isOn: model.bit(UInt32(1) << UInt32(who.1 + b)))
                                .labelsHidden()
                                .accessibilityLabel("\(who.0) \(["run", "write", "read"][b])")
                        }
                    }
                }
            }
            HStack {
                TextField("Octal", text: $model.octal)
                    .font(.callout.monospaced())
                    .frame(width: 64)
                    .onSubmit { model.octalCommitted() }
                    .accessibilityLabel("Permissions as a number")
                Text(FileAttributes(permissions: model.permissions).permissionString)
                    .font(.callout.monospaced())
                    .foregroundStyle(Tokens.Colors.textMuted)
                Spacer()
                Button("Apply") { model.octalCommitted(); model.applyPermissions() }
                    .controlSize(.small)
                    .disabled(model.permissions == model.originalPermissions)
            }
        }
    }

    // MARK: Log

    private var logList: some View {
        VStack(spacing: 0) {
            if model.log.isEmpty {
                EmptyState(symbol: "list.bullet.rectangle", title: "Nothing yet",
                           message: "Connections, copies, renames and deletes are listed here.")
            } else {
                List(model.log) { e in
                    HStack(alignment: .top, spacing: Tokens.Space.s6) {
                        Image(systemName: e.result == .ok ? "checkmark.circle" : e.result == .failed ? "xmark.octagon" : "minus.circle")
                            .foregroundStyle(e.result == .ok ? Tokens.Colors.success : e.result == .failed ? Tokens.Colors.danger : Tokens.Colors.textMuted)
                            .accessibilityLabel(e.result.rawValue)
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Text(Self.verb(e.operation) + (e.path.map { " " + (($0 as NSString).lastPathComponent.isEmpty ? $0 : ($0 as NSString).lastPathComponent) } ?? ""))
                                .lineLimit(1).truncationMode(.middle)
                            if let m = e.message, !m.isEmpty {
                                Text(m).font(.callout).foregroundStyle(e.result == .failed ? Tokens.Colors.danger : Tokens.Colors.textMuted).lineLimit(3)
                            }
                            Text(e.at, format: .relative(presentation: .named)).font(.caption).foregroundStyle(Tokens.Colors.textMuted)
                        }
                    }
                    .help(e.path ?? "")
                }
                .listStyle(.plain)
            }
            Divider()
            HStack {
                Spacer()
                Button("Clear Log") { ConnectionManager.shared.log.clear(); model.reloadLog() }
                    .controlSize(.small)
                    .disabled(model.log.isEmpty)
            }
            .padding(Tokens.Space.s8)
        }
    }

    static func verb(_ op: LogEntry.Operation) -> String {
        switch op {
        case .connect: "Connected to"
        case .disconnect: "Disconnected from"
        case .upload: "Uploaded"
        case .download: "Downloaded"
        case .copy: "Copied"
        case .move: "Moved"
        case .rename: "Renamed"
        case .mkdir: "Created folder"
        case .delete: "Deleted"
        case .chmod: "Changed permissions of"
        case .sync: "Synced"
        case .editUpload: "Saved edit to"
        }
    }
}

/// S13: the few settings that matter. Stored in UserDefaults, applied immediately.
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    @Published var downloadKBps: Int { didSet { save() } }
    @Published var uploadKBps: Int { didSet { save() } }
    @Published var terminal: String { didSet { if let app = TerminalLauncher.known.first(where: { $0.bundleID == terminal }) { TerminalLauncher.setPreferred(app) } } }

    private init() {
        downloadKBps = UserDefaults.standard.integer(forKey: "ShellpaneDownloadKBps")
        uploadKBps = UserDefaults.standard.integer(forKey: "ShellpaneUploadKBps")
        terminal = TerminalLauncher.preferred.bundleID
        apply()
    }

    private func save() {
        UserDefaults.standard.set(downloadKBps, forKey: "ShellpaneDownloadKBps")
        UserDefaults.standard.set(uploadKBps, forKey: "ShellpaneUploadKBps")
        apply()
    }

    func apply() {
        let down = max(0, downloadKBps) * 1024, up = max(0, uploadKBps) * 1024
        Task {
            await BandwidthLimiter.downloads.setLimit(down)
            await BandwidthLimiter.uploads.setLimit(up)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Bandwidth") {
                LabeledContent("Downloads") {
                    HStack {
                        TextField("Downloads", value: $model.downloadKBps, format: .number).labelsHidden().frame(width: 90)
                        Text("KB/s").foregroundStyle(Tokens.Colors.textMuted)
                    }
                }
                LabeledContent("Uploads") {
                    HStack {
                        TextField("Uploads", value: $model.uploadKBps, format: .number).labelsHidden().frame(width: 90)
                        Text("KB/s").foregroundStyle(Tokens.Colors.textMuted)
                    }
                }
                Text("0 means no limit. The limit is shared by all transfers in each direction.")
                    .font(.callout).foregroundStyle(Tokens.Colors.textMuted)
            }
            Section("Keyboard") {
                Toggle("Commander keys", isOn: Binding(get: { PaneTableView.commanderKeys }, set: { PaneTableView.commanderKeys = $0; model.objectWillChange.send() }))
                Text("Space or Insert marks the file under the cursor and moves down; ↑ ↓ keep your marks; Esc clears them. F3 Quick Look, F4 edit, F5 copy, F6 move, F7 new folder, F8 delete, / filter. Off: Space is Quick Look, as in Finder.")
                    .font(.callout).foregroundStyle(Tokens.Colors.textMuted)
            }
            Section("Terminal") {
                Picker("Open in", selection: $model.terminal) {
                    ForEach(TerminalLauncher.installed, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
