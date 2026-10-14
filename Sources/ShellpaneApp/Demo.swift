import AppKit
import AVFoundation
import SSHProcess

/// `--demo out.mp4` (or .mov): plays the core flow against a demo server and records the window to a video,
/// with each key shown in a caption. For the landing page and launch posts (see scripts/demo-video.sh).
/// Captures the app's own window, so it needs no Screen Recording permission.
///
///   --left PATH          the local project (left pane)
///   --right HOST         the ssh_config host to connect (right pane)
///   --mark a,b,c         the local files to mark with Space and copy with F5
///   --filter TEXT        typed after `/` in the server pane
///   --no-captions        no key captions (the video project adds its own titles)
///   --timeline PATH      write when each step happened, in seconds from the first frame (JSON)
@MainActor
enum Demo {
    static func run(_ controller: MainWindowController, to path: String, arguments args: [String]) {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let window = controller.window, let frameView = window.contentView?.superview,
              let localPath = value("--left"), let host = value("--right") else {
            print("usage: --demo out.mov --left PATH --right HOST [--mark a,b,c] [--filter TEXT]"); exit(2)
        }
        if args.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
        let names = value("--mark")?.split(separator: ",").map(String.init) ?? []
        let filter = value("--filter")

        controller.left.navigate(to: .local(localPath))
        controller.right.navigate(to: .local(localPath))
        let caption = KeyCaption()
        caption.attach(to: frameView)
        caption.silent = args.contains("--no-captions")
        // Keep the window frontmost so marks and selection draw in their active colours.
        caption.onShow = {
            if !window.isKeyWindow { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let recorder: FrameRecorder
            do { recorder = try FrameRecorder(view: frameView, to: URL(fileURLWithPath: path)) } catch {
                print("can't record: \(error)"); exit(1)
            }
            recorder.start()
            func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            var events: [[String: Any]] = []
            @MainActor func mark(_ name: String) { events.append(["event": name, "t": (recorder.elapsed * 1000).rounded() / 1000]) }
            mark("start")

            caption.show(nil, "Your ~/.ssh/config hosts are already in the sidebar")
            await pause(2.4)

            // 1. Connect the right pane, the way a click on the sidebar host does.
            caption.show("Click", host)
            controller.paneDidBecomeActive(controller.right)
            mark("connect")
            controller.connect(to: SSHTarget(host: host), key: "alias:" + host)
            for _ in 0..<100 where controller.right.location.session == nil || controller.right.entries.isEmpty {
                await pause(0.1)
            }
            mark("connected")
            await pause(1.4)

            // 2. Mark files in the local pane: arrows to move, Space to mark.
            let left = controller.left
            controller.paneDidBecomeActive(left)
            window.makeFirstResponder(left.tableView)
            left.tableView.setCursor(0)
            caption.show(nil, "On your Mac's side")
            await pause(1.2)
            for row in names.compactMap({ n in left.entries.firstIndex { $0.name == n } }).sorted() {
                while left.tableView.cursor < row {
                    caption.show("↓", "Move")
                    left.tableView.setCursor(left.tableView.cursor + 1)
                    await pause(0.22)
                }
                caption.show("Space", "Mark")
                mark("space")
                left.tableView.toggleMarkAndAdvance()
                await pause(0.7)
            }
            await pause(0.5)

            // 3. F5: copy to the server, and wait until the server pane shows them.
            caption.show("F5", "Copy to the server")
            mark("f5")
            controller.transferToOtherPane(.copy)
            controller.hideActivity()
            for _ in 0..<100 where !Set(names).isSubset(of: Set(controller.right.entries.map(\.name))) {
                await pause(0.1)
            }
            controller.paneDidBecomeActive(controller.right)
            window.makeFirstResponder(controller.right.tableView)
            if let first = names.compactMap({ n in controller.right.entries.firstIndex { $0.name == n } }).min() {
                controller.right.tableView.setCursor(first)
            }
            mark("copied")
            caption.show("✓", "\(names.count) files copied to \(host)")
            await pause(2.2)

            // 4. `/` filters as you type.
            if let filter {
                caption.show("/", "Filter")
                mark("filter")
                controller.right.showFilter()
                await pause(0.6)
                var typed = ""
                for ch in filter {
                    typed.append(ch)
                    controller.right.filterField.stringValue = typed
                    controller.right.setFilter(typed)
                    caption.show(typed, "Filter")
                    await pause(0.35)
                }
                await pause(1.8)
                mark("filtered")
                caption.show("esc", "Clear the filter")
                controller.right.clearFilter()
                window.makeFirstResponder(controller.right.tableView)
                await pause(1.2)
            }

            caption.show(nil, "If ssh works, Shellpane works.")
            await pause(2.8)
            caption.hide()
            await pause(0.4)

            mark("end")
            let ok = await recorder.finish()
            if let timeline = value("--timeline"),
               let json = try? JSONSerialization.data(withJSONObject: ["fps": 30, "events": events], options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: URL(fileURLWithPath: timeline))
            }
            print(ok ? "wrote \(path) (\(recorder.frames) frames)" : "recording failed")
            ConnectionManager.shared.closeAll()
            exit(ok ? 0 : 1)
        }
    }
}

/// The caption at the bottom of the window: a key cap and what it does.
@MainActor
final class KeyCaption {
    private let box = NSView()
    private let key = NSTextField(labelWithString: "")
    private let text = NSTextField(labelWithString: "")
    private let keyBox = NSView()
    var onShow: () -> Void = {}
    /// Recording for the video project: steps still happen, nothing is drawn.
    var silent = false

    func attach(to view: NSView) {
        // Solid, not translucent: the caption has to read the same over light and dark windows.
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.9).cgColor
        box.alphaValue = 0
        keyBox.wantsLayer = true
        keyBox.layer?.cornerRadius = 7
        keyBox.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        keyBox.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        keyBox.layer?.borderWidth = 1
        key.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        key.textColor = .white
        text.font = .systemFont(ofSize: 22, weight: .medium)
        text.textColor = .white
        let stack = NSStackView(views: [keyBox, text])
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 20)
        for v in [key, keyBox, stack, box] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        keyBox.addSubview(key)
        box.addSubview(stack)
        view.addSubview(box, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: keyBox.leadingAnchor, constant: 12),
            key.trailingAnchor.constraint(equalTo: keyBox.trailingAnchor, constant: -12),
            key.topAnchor.constraint(equalTo: keyBox.topAnchor, constant: 4),
            key.bottomAnchor.constraint(equalTo: keyBox.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            box.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -56),
        ])
    }

    func show(_ keyLabel: String?, _ description: String) {
        key.stringValue = keyLabel ?? ""
        keyBox.isHidden = keyLabel == nil
        text.stringValue = description
        box.alphaValue = silent ? 0 : 1
        onShow()
    }

    func hide() { box.alphaValue = 0 }
}

/// Records a view to H.264 by drawing it into frames, timed by the wall clock.
@MainActor
final class FrameRecorder {
    private let view: NSView
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private(set) var frames = 0
    var elapsed: Double { CACurrentMediaTime() - startTime }

    init(view: NSView, to url: URL, fps: Double = 30) throws {
        self.view = view
        let scale = view.window?.backingScaleFactor ?? 2
        width = Int(view.bounds.width * scale) & ~1
        height = Int(view.bounds.height * scale) & ~1
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        self.fps = fps
    }
    private let fps: Double

    func start() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        startTime = CACurrentMediaTime()
        capture()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
    }

    private func capture() {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let t = CMTime(seconds: CACurrentMediaTime() - startTime, preferredTimescale: 600)
        if adaptor.append(buffer, withPresentationTime: t) { frames += 1 }
    }

    func finish() async -> Bool {
        timer?.invalidate()
        capture()
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
