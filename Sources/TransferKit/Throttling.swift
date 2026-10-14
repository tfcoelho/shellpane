import Foundation
import SFTPKit

/// A token bucket: on average no more than `bytesPerSecond`, with up to one second's worth as a burst.
/// 0 means no limit. One for downloads and one for uploads, shared by every transfer.
public actor BandwidthLimiter {
    public static let downloads = BandwidthLimiter()
    public static let uploads = BandwidthLimiter()

    public private(set) var bytesPerSecond = 0
    private var available = 0.0
    private var last = ContinuousClock.now

    public init() {}

    public func setLimit(_ bytesPerSecond: Int) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        available = Double(self.bytesPerSecond)
        last = .now
    }

    public func take(_ bytes: Int) async {
        guard bytesPerSecond > 0 else { return }
        let now = ContinuousClock.now
        let elapsed = Double((now - last).components.attoseconds) / 1e18 + Double((now - last).components.seconds)
        last = now
        available = min(Double(bytesPerSecond), available + elapsed * Double(bytesPerSecond))
        available -= Double(bytes)
        if available < 0 {
            let wait = -available / Double(bytesPerSecond)
            try? await Task.sleep(for: .seconds(wait))
        }
    }
}

/// Pause between chunks and between files. Cancelling still works while paused.
public actor PauseGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isPaused: Bool { paused }

    public func pause() { paused = true }

    public func resume() {
        paused = false
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume() }
    }

    public func wait() async {
        guard paused, !Task.isCancelled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
