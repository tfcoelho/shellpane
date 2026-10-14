// Renders an SVG to transparent PNGs with WebKit (which handles filters and gradients).
// usage: render_png <file.svg> <outdir> <name> <px> [<px> ...]   → <outdir>/<name>-<px>.png
import AppKit
import WebKit

let a = CommandLine.arguments
let svg = URL(fileURLWithPath: a[1]), outDir = URL(fileURLWithPath: a[2]), name = a[3]
let sizes = a[4...].compactMap { Int($0) }
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

final class Job: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    override init() {
        super.init()
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        // Inline the SVG: a string-loaded page isn't allowed to read local files.
        let markup = (try? String(contentsOf: svg, encoding: .utf8)) ?? ""
        let html = "<html><body style='margin:0;background:transparent'><div style='width:1024px;height:1024px'>\(markup)</div></body></html>"
        web.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let cfg = WKSnapshotConfiguration()
            cfg.snapshotWidth = 1024
            w.takeSnapshot(with: cfg) { img, err in
                guard let img else { print("snapshot failed: \(String(describing: err))"); exit(1) }
                for px in sizes {
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = NSSize(width: px, height: px)
                    NSGraphicsContext.saveGraphicsState()
                    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
                    ctx.imageInterpolation = .high
                    NSGraphicsContext.current = ctx
                    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                    NSGraphicsContext.restoreGraphicsState()
                    let out = outDir.appendingPathComponent("\(name)-\(px).png")
                    try! rep.representation(using: .png, properties: [:])!.write(to: out)
                }
                print("rendered \(name) at \(sizes.map(String.init).joined(separator: ", "))")
                exit(0)
            }
        }
    }
}
let job = Job()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout"); exit(1) }
NSApp.run()
