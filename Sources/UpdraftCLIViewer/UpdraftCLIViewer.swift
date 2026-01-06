import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments.dropFirst()
        guard let path = args.first else {
            fputs("Usage: updraft /path/to/file.pdf\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let url = URL(fileURLWithPath: path)
        guard let doc = PDFDocument(url: url) else {
            fputs("Failed to open PDF: \(url.path)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let pdfView = PDFView(frame: .zero)
        pdfView.document = doc
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.center()
        window.contentView = pdfView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
// app.activate(ignoringOtherApps: true)
app.run()
