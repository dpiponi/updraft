import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windows: [NSWindow] = []
    private var document: PDFDocument?

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

        self.document = doc
        openViewerWindow(
            document: doc,
            destination: nil,
            title: url.lastPathComponent
        )

        // Bring app to foreground after window exists
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Window creation

    func openViewerWindow(
        document: PDFDocument,
        destination: PDFDestination?,
        title: String
    ) {
        let pdfView = UpdraftPDFView(frame: .zero)
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.updraftDelegate = self

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = title
        window.center()
        window.contentView = pdfView
        window.makeKeyAndOrderFront(nil)

        if let destination {
            pdfView.go(to: destination)
        }

        windows.append(window)
    }
}

// MARK: - App bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
