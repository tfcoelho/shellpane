import AppKit
import Combine
import ShellpaneCore
import ShellpaneUI
import SFTPKit
import SwiftUI
import TransferKit

/// S10: compare two folders, review what would change, then sync. Saves as a Synclet.
@MainActor
final class SyncModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case comparing(Int)
        case ready
        case syncing(done: Int, total: Int)
        case finished(SyncResult)
        case failed(String)
    }

    enum Filter: String, CaseIterable { case changes = "Changes", conflicts = "Conflicts", same = "Unchanged", all = "All" }

    let left: Location
    let right: Location
    @Published var options: SyncOptions
    @Published var excludesText: String
    @Published var phase: Phase = .idle
    @Published var plan: SyncPlan?
    @Published var filter: Filter = .changes
    var syncletID: String?
    var syncletName: String?
    var onClose: () -> Void = {}
    var onSynced: () -> Void = {}
    private var task: Task<Void, Never>?

    init(left: Location, right: Location, options: SyncOptions = SyncOptions(), synclet: Synclet? = nil) {
        self.left = left
        self.right = right
        self.options = synclet?.options ?? options
        self.excludesText = (synclet?.options ?? options).excludes.joined(separator: ", ")
        self.syncletID = synclet?.id
        self.syncletName = synclet?.name
    }

    var visibleItems: [SyncItem] {
        guard let plan else { return [] }
        return plan.items.filter { item in
            switch filter {
            case .changes: item.isChange
            case .conflicts: if case .conflict = item.action { true } else { false }
            case .same: item.action == .same
            case .all: true
            }
        }
    }

    func optionsChanged() {
        options.excludes = excludesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if options.direction == .both { options.deleteOrphans = false }
        plan = nil
        phase = .idle
    }

    func compare() {
        optionsChanged()
        task?.cancel()
        phase = .comparing(0)
        let opts = options
        task = Task { @MainActor in
            do {
                let l = try await left.live(), r = try await right.live()
                let p = try await SyncEngine.compare(left: l.ops, leftRoot: l.path, right: r.ops, rightRoot: r.path,
                                                     options: opts) { n in Task { @MainActor in self.phase = .comparing(n) } }
                guard !Task.isCancelled else { return }
                plan = p
                phase = .ready
                filter = p.hasChanges ? .changes : (p.conflicts > 0 ? .conflicts : .all)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func toggle(_ item: SyncItem) {
        guard let i = plan?.items.firstIndex(where: { $0.id == item.id }) else { return }
        plan?.items[i].included.toggle()
    }

    /// Deletions need a yes first. Returns false if the person backed out.
    func confirmDeletes(window: NSWindow?) -> Bool {
        guard let plan, plan.deletes > 0 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(plan.deletes) item\(plan.deletes == 1 ? "" : "s") that aren't in the source?"
        alert.informativeText = "Items on a server don't go to a Trash. This can't be undone. Untick them in the list to keep them."
        alert.addButton(withTitle: "Sync and Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    func sync() {
        guard let plan, plan.hasChanges else { return }
        let total = plan.items.filter { $0.included && $0.isChange }.count
        phase = .syncing(done: 0, total: total)
        task = Task { @MainActor in
            do {
                let l = try await left.live(), r = try await right.live()
                let result = await SyncEngine.execute(plan, left: l.ops, leftRoot: l.path, right: r.ops, rightRoot: r.path) { done, total, _ in
                    Task { @MainActor in self.phase = .syncing(done: done, total: total) }
                }
                phase = .finished(result)
                ConnectionManager.shared.log.record(.sync, path: "\(left.displayName) ↔ \(right.displayName)",
                                                    result: result.failures.isEmpty ? .ok : .failed,
                                                    message: "\(result.done) item\(result.done == 1 ? "" : "s")" + (result.failures.isEmpty ? "" : ", \(result.failures.count) problem\(result.failures.count == 1 ? "" : "s")"),
                                                    favoriteID: right.session?.key ?? left.session?.key)
                onSynced()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Both sides must be on this Mac or on a saved server, so the synclet can reconnect later.
    var saveProblem: String? {
        for loc in [left, right] {
            if let s = loc.session, (try? ConnectionManager.shared.favorites.favorite(id: s.key)) ?? nil == nil {
                return "\(s.label) isn't a saved server. Save it as a favorite first, then save this sync."
            }
        }
        return nil
    }

    func saveSynclet(name: String) throws {
        optionsChanged()
        let s = Synclet(id: syncletID ?? UUID().uuidString, name: name,
                        leftFavoriteID: left.session?.key, leftPath: left.path,
                        rightFavoriteID: right.session?.key, rightPath: right.path, options: options)
        try ConnectionManager.shared.synclets.save(s)
        syncletID = s.id
        syncletName = name
    }
}

struct SyncView: View {
    @ObservedObject var model: SyncModel
    var onSave: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            optionsBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private func place(_ loc: Location) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Label(loc.session?.label ?? "This Mac", systemImage: loc.session == nil ? "laptopcomputer" : "server.rack")
                .font(.headline)
            Text(loc.path)
                .font(.callout.monospaced())
                .foregroundStyle(Tokens.Colors.textMuted)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s16) {
            place(model.left)
            Picker("Direction", selection: Binding(get: { model.options.direction }, set: { model.options.direction = $0; model.optionsChanged() })) {
                Image(systemName: "arrow.right").tag(SyncOptions.Direction.leftToRight).accessibilityLabel("Left to right")
                Image(systemName: "arrow.left").tag(SyncOptions.Direction.rightToLeft).accessibilityLabel("Right to left")
                Image(systemName: "arrow.left.arrow.right").tag(SyncOptions.Direction.both).accessibilityLabel("Both ways")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            place(model.right)
        }
        .padding(Tokens.Space.s16)
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<SyncOptions, Bool>, disabled: Bool = false) -> some View {
        Toggle(title, isOn: Binding(get: { model.options[keyPath: keyPath] }, set: { model.options[keyPath: keyPath] = $0; model.optionsChanged() }))
            .disabled(disabled)
    }

    private var optionsBar: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            HStack(spacing: Tokens.Space.s16) {
                toggle("Subfolders", \.subfolders)
                toggle("Hidden files", \.includeHidden)
                toggle("Add missing", \.addMissing)
                toggle("Skip empty folders", \.skipEmptyFolders)
                toggle("Delete items not in the source", \.deleteOrphans, disabled: model.options.direction == .both)
                    .help(model.options.direction == .both ? "Two-way sync can't tell a deletion from a new file, so it never deletes." : "")
            }
            HStack(spacing: Tokens.Space.s16) {
                Picker("Update when", selection: Binding(get: { model.options.updateBy }, set: { model.options.updateBy = $0; model.optionsChanged() })) {
                    Text("Newer").tag(SyncOptions.UpdateBy.date)
                    Text("Size differs").tag(SyncOptions.UpdateBy.size)
                    Text("Newer or size differs").tag(SyncOptions.UpdateBy.dateOrSize)
                    Text("Never").tag(SyncOptions.UpdateBy.never)
                }
                .fixedSize()
                Stepper(value: Binding(get: { model.options.timeOffset / 60 }, set: { model.options.timeOffset = $0 * 60; model.optionsChanged() }), in: -1440...1440, step: 60) {
                    Text("Server clock offset: \(model.options.timeOffset / 60) min")
                }
                .fixedSize()
                TextField("Exclude", text: $model.excludesText, prompt: Text("Exclude: *.log, node_modules"))
                    .onSubmit { model.optionsChanged() }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Tokens.Space.s16)
        .padding(.vertical, Tokens.Space.s8)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            EmptyState(symbol: "arrow.triangle.2.circlepath", title: "Compare the two folders",
                       message: "Nothing changes until you've seen the list and pressed Sync.",
                       actionTitle: "Compare") { model.compare() }
        case let .comparing(n):
            VStack(spacing: Tokens.Space.s8) {
                ProgressView().controlSize(.small)
                Text(n == 0 ? "Comparing…" : "Compared \(n.formatted()) items…").foregroundStyle(Tokens.Colors.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't compare", message: message, tone: .danger,
                       actionTitle: "Try Again") { model.compare() }
        case .ready, .syncing, .finished:
            if let plan = model.plan, plan.items.isEmpty || (!plan.hasChanges && plan.conflicts == 0 && model.filter == .changes) {
                EmptyState(symbol: "checkmark.circle", title: "Already in sync",
                           message: "Nothing to copy or delete with these options.")
            } else {
                VStack(spacing: 0) {
                    Picker("Show", selection: $model.filter) {
                        ForEach(SyncModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(Tokens.Space.s8)
                    List(model.visibleItems) { item in
                        SyncRow(item: item) { model.toggle(item) }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
        }
    }

    private var summary: String {
        switch model.phase {
        case let .syncing(done, total): return "Syncing \(done) of \(total)…"
        case let .finished(result):
            return result.failures.isEmpty ? "Done: \(result.done) item\(result.done == 1 ? "" : "s") synced."
                : "Done, with \(result.failures.count) problem\(result.failures.count == 1 ? "" : "s"): " + result.failures.prefix(2).map { "\($0.path): \($0.message)" }.joined(separator: "; ")
        default:
            guard let p = model.plan else { return "" }
            var parts = ["\(p.adds) to add", "\(p.updates) to update"]
            if p.deletes > 0 { parts.append("\(p.deletes) to delete") }
            if p.conflicts > 0 { parts.append("\(p.conflicts) conflict\(p.conflicts == 1 ? "" : "s") (skipped)") }
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(p.bytes), countStyle: .file))
            return parts.joined(separator: " · ")
        }
    }

    private var footer: some View {
        HStack {
            Button(model.syncletName == nil ? "Save as Synclet…" : "Update Synclet") { onSave() }
                .help(model.saveProblem ?? "Save these folders and options in the sidebar")
            Text(summary)
                .font(.callout)
                .foregroundStyle({ if case let .finished(r) = model.phase, !r.failures.isEmpty { return Tokens.Colors.danger }; return Tokens.Colors.textMuted }())
                .lineLimit(2)
            Spacer()
            Button("Close") { model.cancel(); model.onClose() }
                .keyboardShortcut(.cancelAction)
            switch model.phase {
            case .ready:
                let deletes = model.plan?.deletes ?? 0
                Button(deletes > 0 ? "Sync and Delete \(deletes)" : "Sync") {
                    if model.confirmDeletes(window: NSApp.keyWindow) { model.sync() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(model.plan?.hasChanges ?? false))
            case .syncing:
                Button("Stop") { model.cancel() }
            default:
                Button("Compare") { model.compare() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Space.s12)
    }
}

struct SyncRow: View {
    let item: SyncItem
    let onToggle: () -> Void

    private var symbol: (String, Color, String) {
        switch item.action {
        case .copyToRight: (item.reason == "new" ? "plus.circle" : "arrow.right.circle", Tokens.Colors.accentText, item.reason == "new" ? "Add on the right" : "Update the right (\(item.reason))")
        case .copyToLeft: (item.reason == "new" ? "plus.circle" : "arrow.left.circle", Tokens.Colors.accentText, item.reason == "new" ? "Add on the left" : "Update the left (\(item.reason))")
        case .createFolderRight: ("folder.badge.plus", Tokens.Colors.accentText, "Create folder on the right")
        case .createFolderLeft: ("folder.badge.plus", Tokens.Colors.accentText, "Create folder on the left")
        case .deleteRight: ("minus.circle", Tokens.Colors.danger, "Delete from the right")
        case .deleteLeft: ("minus.circle", Tokens.Colors.danger, "Delete from the left")
        case let .conflict(why): ("exclamationmark.triangle", Tokens.Colors.warning, why)
        case .same: ("equal.circle", Tokens.Colors.textMuted, "Unchanged")
        }
    }

    private func describe(_ a: FileAttributes?) -> String {
        guard let a else { return "–" }
        if a.fileType == .directory { return "folder" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(a.size ?? 0), countStyle: .file)
        let date = a.modificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? ""
        return "\(size), \(date)"
    }

    var body: some View {
        HStack(spacing: Tokens.Space.s8) {
            if item.isChange {
                Toggle("", isOn: Binding(get: { item.included }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .accessibilityLabel("Include \(item.relativePath)")
            } else {
                Spacer().frame(width: 18)
            }
            Image(systemName: symbol.0)
                .foregroundStyle(symbol.1)
                .help(symbol.2)
                .accessibilityLabel(symbol.2)
            Text(item.relativePath)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(item.isDelete && item.included)
            Spacer()
            Text(describe(item.left)).font(.callout).foregroundStyle(Tokens.Colors.textMuted).frame(width: 170, alignment: .trailing)
            Text(describe(item.right)).font(.callout).foregroundStyle(Tokens.Colors.textMuted).frame(width: 170, alignment: .trailing)
        }
        .opacity(item.isChange && !item.included ? 0.55 : 1)
    }
}
