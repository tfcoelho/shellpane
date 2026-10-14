import SwiftUI

public enum TransferKind: Sendable { case upload, download, copy, delete

    var symbol: String {
        switch self {
        case .upload: "arrow.up"
        case .download: "arrow.down"
        case .copy: "arrow.left.arrow.right"
        case .delete: "trash"
        }
    }

    var verb: String {
        switch self {
        case .upload: "upload"
        case .download: "download"
        case .copy: "copy"
        case .delete: "delete"
        }
    }
}

public enum TransferStatus: Sendable, Equatable {
    case queued
    case running(bytesPerSecond: Double, secondsLeft: Double?)
    case paused
    case waitingConflict
    case failed(String)
    case done
    case cancelled
}

/// One row in the Activity view (S07).
public struct ProgressRow: View {
    let kind: TransferKind
    let name: String
    let destination: String
    let bytesDone: Int64
    let bytesTotal: Int64
    let status: TransferStatus
    var onPauseResume: () -> Void = {}
    var onCancel: () -> Void = {}
    var onResolve: () -> Void = {}
    var onRetry: () -> Void = {}

    public init(kind: TransferKind, name: String, destination: String,
                bytesDone: Int64, bytesTotal: Int64, status: TransferStatus,
                onPauseResume: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {},
                onResolve: @escaping () -> Void = {}, onRetry: @escaping () -> Void = {}) {
        self.kind = kind
        self.name = name
        self.destination = destination
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.status = status
        self.onPauseResume = onPauseResume
        self.onCancel = onCancel
        self.onResolve = onResolve
        self.onRetry = onRetry
    }

    private var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }

    private var detail: String {
        let done = ByteCountFormatter.string(fromByteCount: bytesDone, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file)
        switch status {
        case .queued: return "Waiting · → \(destination)"
        case let .running(bps, left):
            let speed = ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
            var s = "\(done) of \(total) · \(speed)"
            if let left { s += " · " + Self.formatDuration(left) + " left" }
            return s
        case .paused: return "Paused · \(done) of \(total)"
        case .waitingConflict: return "Needs a decision: a file with this name already exists"
        case let .failed(message): return message
        case .done: return "Done · \(total) → \(destination)"
        case .cancelled: return "Cancelled"
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? ""
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s12) {
            statusIcon
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text(name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Tokens.Colors.text)
                Text(detail)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(detailColour)
                if showsBar {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(status == .paused ? Tokens.Colors.progressTrack : Tokens.Colors.accent)
                }
                actions
            }
            Spacer(minLength: 0)
            trailingButtons
        }
        .padding(Tokens.Space.s8)
        .background(status == .waitingConflict ? Tokens.Colors.warningBg : .clear)
        .accessibilityElement(children: .combine)
    }

    private var showsBar: Bool {
        switch status {
        case .running, .paused: true
        default: false
        }
    }

    private var detailColour: Color {
        switch status {
        case .failed: Tokens.Colors.danger
        case .waitingConflict: Tokens.Colors.warning
        default: Tokens.Colors.textMuted
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.Colors.success)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Tokens.Colors.danger)
        case .waitingConflict:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Colors.warning)
        default:
            Image(systemName: kind.symbol).foregroundStyle(Tokens.Colors.textMuted)
        }
    }

    @ViewBuilder private var actions: some View {
        switch status {
        case .waitingConflict:
            Button("Resolve…", action: onResolve).controlSize(.small)
        case .failed:
            Button("Retry", action: onRetry).controlSize(.small)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailingButtons: some View {
        switch status {
        case .running, .paused, .queued:
            HStack(spacing: Tokens.Space.s4) {
                if status != .queued {
                    Button(action: onPauseResume) {
                        Image(systemName: status == .paused ? "play.fill" : "pause.fill")
                    }
                    .accessibilityLabel("\(status == .paused ? "Resume" : "Pause") \(kind.verb) of \(name)")
                }
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Cancel \(kind.verb) of \(name)")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Tokens.Colors.textMuted)
        default:
            EmptyView()
        }
    }
}
