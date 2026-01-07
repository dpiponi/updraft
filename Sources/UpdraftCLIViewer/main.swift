import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windows: [NSWindow] = []
    private var document: PDFDocument?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

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
            title: url.lastPathComponent,
            initialScaleFactor: nil
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
        title: String,
        initialScaleFactor: CGFloat?
    ) {
        let pdfView = UpdraftPDFView(frame: .zero)
        pdfView.document = document
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.updraftDelegate = self

        let scaleToUse: CGFloat
        if let s = initialScaleFactor {
            pdfView.autoScales = false
            pdfView.scaleFactor = s
            scaleToUse = s
        } else {
            // Keep your prior behavior: window matches the page size in PDF points,
            // and PDFKit fits content via autoScales.
            pdfView.autoScales = true
            scaleToUse = 1.0
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = pdfView

        // Size window content to the (target) page size, scaled by zoom if provided.
        let pageToMeasure: PDFPage? = destination?.page ?? document.page(at: 0)
        if let page = pageToMeasure {
            let pageBounds = page.bounds(for: .cropBox)
            let padding: CGFloat = 24.0

            var desired = NSSize(
                width: pageBounds.width * scaleToUse + padding,
                height: pageBounds.height * scaleToUse + padding
            )

            if let screen = NSScreen.main {
                let vf = screen.visibleFrame
                let maxW = max(400.0, vf.width - 40.0)
                let maxH = max(300.0, vf.height - 40.0)
                desired.width = min(desired.width, maxW)
                desired.height = min(desired.height, maxH)
            }

            window.setContentSize(desired)
        }

        window.center()
        window.makeKeyAndOrderFront(nil)

        if let destination {
            pdfView.go(to: destination)
        }

        windows.append(window)
    }

    @objc private func bringAllWindowsToFront(_ sender: Any?) {
        // Make Updraft the active (frontmost) app.
        NSApp.activate(ignoringOtherApps: true)

        // Bring every Updraft window to the front.
        for w in windows where w.isVisible {
            w.makeKeyAndOrderFront(nil)
        }

        // Optional: ask AppKit to arrange them in front (helps if some are behind others).
        NSApp.arrangeInFront(nil)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Updraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu (optional but conventional)
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Navigate menu
        let navMenuItem = NSMenuItem()
        mainMenu.addItem(navMenuItem)
        let navMenu = NSMenu(title: "Navigate")
        navMenuItem.submenu = navMenu

        let goToPageItem = NSMenuItem(title: "Go to Page…", action: #selector(goToPage(_:)), keyEquivalent: "g")
        goToPageItem.keyEquivalentModifierMask = [.command]
        goToPageItem.target = self
        navMenu.addItem(goToPageItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        let bringAllItem = NSMenuItem(
            title: "Bring All to Front",
            action: #selector(bringAllWindowsToFront(_:)),
            keyEquivalent: "`"    // pick a shortcut you like
        )
        bringAllItem.keyEquivalentModifierMask = [.command, .shift]
        bringAllItem.target = self
        windowMenu.addItem(bringAllItem)

        // Keep the standard item too, if you want it:
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        NSApp.mainMenu = mainMenu
    }

    @objc private func goToPage(_ sender: Any?) {
        guard
            let pdfView = NSApp.keyWindow?.contentView as? PDFView,
            let doc = pdfView.document
        else {
            NSSound.beep()
            return
        }

        let pageCount = doc.pageCount
        let currentIndex: Int = {
            if let p = pdfView.currentPage { return doc.index(for: p) }
            return 0
        }()

        let alert = NSAlert()
        alert.messageText = "Go to Page"
        alert.informativeText = "Enter a page number (1–\(pageCount)). Currently on \(currentIndex + 1)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: "\(currentIndex + 1)")
        field.alignment = .left
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(trimmed), (1...pageCount).contains(n) else {
            NSSound.beep()
            return
        }

        let targetIndex = n - 1
        guard let page = doc.page(at: targetIndex) else { return }
        pdfView.go(to: page)
    }
}

// MARK: - App bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
