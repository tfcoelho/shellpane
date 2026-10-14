import AppKit
import Combine
import ShellpaneUI
import SFTPKit
import SwiftUI
import ShellpaneCore
import TransferKit

/// One copy or move (of any number of files and folders), observed by the Activity popover.
@MainActor
final class TransferItem: ObservableObject, Identifiable {
    let id = UUID()
    let kind: TransferKind
    let name: String
    let destination: String
    @Published var bytesDone: Int64 = 0
    @Published var bytesTotal: Int64 = 0
    @Published var status: TransferStatus = .queued
    @Published var failures: [BatchProgress.Failure] = []
    @Published var detail = ""
    @Published private(set) var isPaused = false
    var task: Task<Void, Never>?
    var retry: (() -> Void)?
    var batch: TransferBatch?
    fileprivate var work: (@MainActor () async -> Void)?
    private var samples: [(Date, Int64)] = []
    private var startedAt = Date()

    init(kind: TransferKind, name: String, destination: String) {
        self.kind = kind
        self.name = name
        self.destination = destination
    }

    var isWaiting: Bool { task == nil && status == .queued }

    /// Pauses at the next chunk; files already written stay. Resume picks up where it stopped.
    func togglePause() {
        guard let batch else { return }
        isPaused.toggle()
        let paused = isPaused
        Task { paused ? await batch.pause() : await batch.resume() }
        if paused { status = .paused } else { samples.removeAll() }
    }

    func apply(_ p: BatchProgress) {
        bytesDone = Int64(p.bytesDone)
        bytesTotal = Int64(max(p.bytesTotal, p.bytesDone))
        failures = p.failures
        detail = p.filesTotal > 1 ? "\(p.filesDone) of \(p.filesTotal) files" + (p.currentName.isEmpty ? "" : " · \(p.currentName)") : ""
        switch p.state {
        case .planning: status = .queued
        case .waitingForDecision: status = .waitingConflict
        case .running:
            if isPaused { status = .paused; return }
            let now = Date()
            samples.append((now, bytesDone))
            samples.removeAll { now.timeIntervalSince($0.0) > 3 }  // speed smoothed over 3 s
            let speed: Double
            if let first = samples.first, now.timeIntervalSince(first.0) > 0.2 {
                speed = Double(bytesDone - first.1) / now.timeIntervalSince(first.0)
            } else {
                speed = 0
            }
            let left = speed > 0 && now.timeIntervalSince(startedAt) > 2 ? Double(bytesTotal - bytesDone) / speed : nil
            status = .running(bytesPerSecond: speed, secondsLeft: left)
        case .done:
            status = .done
            if p.skipped > 0 { detail = "\(p.skipped) skipped" }
        case .cancelled: status = .cancelled
        case let .failed(message): status = .failed(message)
        }
    }

    fileprivate func markStarted() { startedAt = Date() }
}

@MainActor
final class TransferCenter: ObservableObject {
    static let shared = TransferCenter()
    /// In the order they were started; waiting ones run top to bottom.
    @Published private(set) var items: [TransferItem] = []
    weak var window: NSWindow?
    /// Self-test only: answers conflicts without showing the dialog.
    var testResolver: ((Conflict) -> ConflictDecision)?
    /// Transfers running at once; the rest wait their turn (each one runs several files in parallel itself).
    var maxRunning = 2
    private var running = 0

    /// Copies or moves entries into `dest`. Reconnects either side if its connection dropped.
    /// `completion` runs on the main actor when the batch ends, however it ends.
    func start(_ mode: TransferBatch.Mode, _ entries: [FileEntry], from source: Location, to dest: Location,
               retrying: Bool = false, completion: @escaping @MainActor () -> Void) {
        guard !entries.isEmpty else { return }
        let kind: TransferKind = switch (source, dest) {
        case (.local, .remote): .upload
        case (.remote, .local): .download
        default: .copy
        }
        let label = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        let verb = mode == .move ? "Moving" : "Copying"
        let item = TransferItem(kind: kind, name: label, destination: dest.displayName)
        item.detail = "\(verb)…"
        items.append(item)
        item.retry = { [weak self, weak item] in
            if let item { self?.items.removeAll { $0 === item } }
            self?.start(mode, entries, from: source, to: dest, retrying: true, completion: completion)
        }

        item.work = { @MainActor in
            defer { completion() }
            item.markStarted()
            let src: Location, dst: Location
            do {
                src = try await source.live()
                dst = try await dest.live()
            } catch {
                item.status = .failed(error.localizedDescription)
                return
            }
            let batch = TransferBatch(
                mode: mode, sources: entries, from: src.ops, to: dst.ops, destinationFolder: dst.path,
                parallel: 3, skipIdentical: retrying,
                resolver: { conflict in await ConflictPrompt.ask(conflict) },
                onProgress: { p in Task { @MainActor in item.apply(p) } })
            item.batch = batch
            await batch.run()
            item.batch = nil
            let snap = batch.snapshot
            item.apply(snap)
            let op: LogEntry.Operation = mode == .move ? .move : (kind == .upload ? .upload : kind == .download ? .download : .copy)
            let failed: Bool = { if case .failed = snap.state { return true }; return false }()
            let message: String = switch snap.state {
            case .cancelled: "Cancelled after \(snap.filesDone) of \(snap.filesTotal) files"
            case let .failed(m): m + (snap.failures.isEmpty ? "" : ": " + snap.failures.prefix(3).map { "\(($0.path as NSString).lastPathComponent): \($0.message)" }.joined(separator: "; "))
            default: "\(snap.filesDone) file\(snap.filesDone == 1 ? "" : "s"), " + ByteCountFormatter.string(fromByteCount: Int64(snap.bytesTotal), countStyle: .file) + (snap.skipped > 0 ? ", \(snap.skipped) skipped" : "")
            }
            // One item: its path where it landed ("Uploaded index.html"). Several: the destination folder.
            let logPath = entries.count == 1 ? RemotePath.join(dst.path, entries[0].name) : dst.path
            let folder = (dst.path as NSString).lastPathComponent.isEmpty ? "/" : (dst.path as NSString).lastPathComponent
            let into = "to " + (dst.session.map { "\($0.label): " } ?? "") + folder
            // What happened first (the reason, when it failed), then where.
            ConnectionManager.shared.log.record(op, path: logPath, result: failed ? .failed : snap.state == .cancelled ? .skipped : .ok,
                                                message: message + " · " + (entries.count == 1 ? "" : "\(entries.count) items ") + into,
                                                favoriteID: dst.session?.key ?? src.session?.key)
        }
        pump()
    }

    /// Starts waiting transfers, in list order, while there's room.
    private func pump() {
        while running < maxRunning, let next = items.first(where: \.isWaiting), let work = next.work {
            running += 1
            next.work = nil
            next.task = Task { @MainActor in
                await work()
                self.running -= 1
                self.pump()
            }
        }
    }

    /// A waiting transfer starts sooner.
    func moveUp(_ item: TransferItem) {
        guard item.isWaiting, let i = items.firstIndex(where: { $0 === item }),
              let j = items[..<i].lastIndex(where: \.isWaiting) else { return }
        items.swapAt(i, j)
    }

    func cancel(_ item: TransferItem) {
        if item.isWaiting {
            item.work = nil
            item.status = .cancelled
            return
        }
        if item.isPaused { item.togglePause() }  // a paused batch must wake up to see the cancel
        item.task?.cancel()
    }

    func clearFinished() {
        items.removeAll {
            switch $0.status {
            case .done, .cancelled, .failed: true
            default: false
            }
        }
    }

    var activeCount: Int {
        items.filter {
            switch $0.status {
            case .running, .queued, .waitingConflict, .paused: true
            default: false
            }
        }.count
    }
}

/// S08: what to do when a file with the same name is already there. Skip is the default (Return).
@MainActor
enum ConflictPrompt {
    static func ask(_ c: Conflict) async -> ConflictDecision {
        if let answer = TransferCenter.shared.testResolver { return answer(c) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let folder = (c.destinationFolder as NSString).lastPathComponent
        alert.messageText = "“\(c.name)” is already in “\(folder.isEmpty ? "/" : folder)”"
        alert.informativeText = compare(c)
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace if Newer")
        alert.addButton(withTitle: "Stop")
        alert.buttons[4].keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = c.remaining > 0
        alert.suppressionButton?.title = "Do the same for the rest of this transfer"
        NSApp.activate(ignoringOtherApps: true)
        let response: NSApplication.ModalResponse
        if let window = TransferCenter.shared.window, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        let all = alert.suppressionButton?.state == .on
        switch response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
        case 0: return .init(.skip, applyToAll: all)
        case 1: return .init(.replace, applyToAll: all)
        case 2: return .init(.keepBoth, applyToAll: all)
        case 3: return .init(.replaceIfNewer, applyToAll: all)
        default: return .init(.stop)
        }
    }

    /// Which one is newer, in words, so it isn't carried by colour alone.
    static func compare(_ c: Conflict) -> String {
        func describe(_ a: FileAttributes) -> String {
            let size = a.fileType == .directory ? "folder" : ByteCountFormatter.string(fromByteCount: Int64(a.size ?? 0), countStyle: .file)
            let date = a.modificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "unknown date"
            return "\(size), modified \(date)"
        }
        let e = c.existing.modificationTime ?? 0, i = c.incoming.modificationTime ?? 0
        return "Already there: \(describe(c.existing))\(e > i ? " (newer)" : "")\nCopying in: \(describe(c.incoming))\(i > e ? " (newer)" : "")"
    }
}

struct TransferRowView: View {
    @ObservedObject var item: TransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressRow(kind: item.kind, name: item.name, destination: item.destination,
                        bytesDone: item.bytesDone, bytesTotal: item.bytesTotal, status: item.status,
                        onPauseResume: { item.togglePause() },
                        onCancel: { TransferCenter.shared.cancel(item) },
                        onResolve: { NSApp.mainWindow?.attachedSheet?.makeKeyAndOrderFront(nil) },
                        onRetry: { item.retry?() })
            if item.isWaiting {
                Button("Start Sooner") { TransferCenter.shared.moveUp(item) }
                    .controlSize(.small)
                    .padding(.leading, 36)
                    .padding(.bottom, Tokens.Space.s8)
                    .help("Move up the queue")
            }
            if !item.detail.isEmpty || !item.failures.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    if !item.detail.isEmpty {
                        Text(item.detail).lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(item.failures.prefix(5), id: \.path) { f in
                        Text("\((f.path as NSString).lastPathComponent): \(f.message)")
                            .foregroundStyle(Tokens.Colors.danger)
                            .lineLimit(2)
                    }
                    if item.failures.count > 5 {
                        Text("and \(item.failures.count - 5) more").foregroundStyle(Tokens.Colors.danger)
                    }
                }
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textMuted)
                .padding(.leading, 36)
                .padding(.trailing, Tokens.Space.s8)
                .padding(.bottom, Tokens.Space.s8)
            }
        }
    }
}

struct ActivityView: View {
    @ObservedObject var center: TransferCenter

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Clear Finished") { center.clearFinished() }
                    .controlSize(.small)
                    .disabled(center.items.isEmpty)
            }
            .padding(Tokens.Space.s12)
            Divider()
            if center.items.isEmpty {
                EmptyState(symbol: "arrow.up.arrow.down", title: "Nothing transferring",
                           message: "Copies and moves show up here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(center.items) { item in
                            TransferRowView(item: item)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 380)
    }
}
