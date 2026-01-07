import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windows: [NSWindow] = []
    private let saveDebouncer = Debouncer(delay: 0.5)
    private var isTerminating = false

    // MARK: - App lifecycle

    
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let args = CommandLine.arguments.dropFirst()
        let session = StateStore.shared.loadSession()

        if let path = args.first {
            // CLI launch: open ONLY this file, but restore ALL saved windows for it.
            let cliURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL

            var matches: [WindowState] = []

            if let session {
                for ws in session.windows {
                    guard let restoredURL = StateStore.shared.resolveDocumentURL(ws.document) else { continue }
                    let r = restoredURL.resolvingSymlinksInPath().standardizedFileURL
                    if r == cliURL {
                        matches.append(ws)
                    }
                }
            }

            if matches.isEmpty {
                // No saved state for this doc: open it "fresh"
                openViewerWindow(url: cliURL, restoredState: nil)
            } else {
                // Restore every saved window for this doc
                for ws in matches {
                    openViewerWindow(url: cliURL, restoredState: ws)
                }
            }

            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // No CLI file: restore the full previous session (all windows)
        if let session {
            for ws in session.windows {
                guard let url = StateStore.shared.resolveDocumentURL(ws.document) else { continue }
                openViewerWindow(url: url, restoredState: ws)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true

        // Save session while windows are still present
        saveNow()

        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Updraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
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
            keyEquivalent: "`"
        )
        bringAllItem.keyEquivalentModifierMask = [.command, .shift]
        bringAllItem.target = self
        windowMenu.addItem(bringAllItem)

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func bringAllWindowsToFront(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        for w in windows where w.isVisible {
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.arrangeInFront(nil)
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
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(trimmed), (1...pageCount).contains(n) else {
            NSSound.beep()
            return
        }

        guard let page = doc.page(at: n - 1) else { return }
        pdfView.go(to: page)
    }

    // MARK: - Window creation (URL-based, used for open/restore)

    func openViewerWindow(url: URL, restoredState: WindowState?) {
        // Security-scoped best-effort
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let doc = PDFDocument(url: url) else { return }

        let pdfView = UpdraftPDFView(frame: .zero)
        pdfView.document = doc
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.updraftDelegate = self

        // Apply zoom/state
        let viewState = restoredState?.view
        if let viewState {
            if viewState.usesAutoScale {
                pdfView.autoScales = true
            } else if let s = viewState.scaleFactor {
                pdfView.autoScales = false
                pdfView.scaleFactor = s
            } else {
                pdfView.autoScales = true
            }
        } else {
            pdfView.autoScales = true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.contentView = pdfView

        if let savedFrame = restoredState?.frame {
            // savedFrame is a WINDOW frame (screen coords), not a content rect.
            window.setFrame(savedFrame, display: false)
        } else {
            // No saved frame: size to page and center (your prior behavior)
            let pageToMeasure: PDFPage? = {
                if let vs = viewState, let page = doc.page(at: clamp(vs.pageIndex, 0, doc.pageCount - 1)) {
                    return page
                }
                return doc.page(at: 0)
            }()

            let scaleForSizing: CGFloat = {
                if let vs = viewState, !vs.usesAutoScale, let s = vs.scaleFactor { return s }
                return 1.0
            }()

            if let pageToMeasure {
                sizeWindowToPage(window: window, page: pageToMeasure, scale: scaleForSizing)
            }
            window.center()
        }

        window.makeKeyAndOrderFront(nil)

        if let restoredState, let bm = restoredState.view.bookmarks {
            let fingerprintOK = StateStore.shared.isFingerprintMatching(restoredState.document, url: url)
            pdfView.importBookmarks(bm, fingerprintOK: fingerprintOK)
        }

        // Navigate to restored position
        if let vs = viewState {
            let idx = clamp(vs.pageIndex, 0, max(0, doc.pageCount - 1))
            if let page = doc.page(at: idx) {
                // If fingerprint changed, ignore pointInPage (best-effort policy)
                let fingerprintOK: Bool = {
                    guard let restoredState else { return true }
                    return StateStore.shared.isFingerprintMatching(restoredState.document, url: url)
                }()

                if fingerprintOK, let p = vs.pointInPage {
                    pdfView.go(to: PDFDestination(page: page, at: p))
                } else {
                    pdfView.go(to: page)
                }
            }
        }

        windows.append(window)
        attachObservers(pdfView: pdfView, window: window)
        scheduleSave()
    }

    func noteViewStateChanged() {
        scheduleSave()
    }

    // MARK: - Window creation (existing document, used for "open link in new window")

    func openViewerWindowFromExistingDocument(
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

        let scaleForSizing: CGFloat
        if let s = initialScaleFactor {
            pdfView.autoScales = false
            pdfView.scaleFactor = s
            scaleForSizing = s
        } else {
            pdfView.autoScales = true
            scaleForSizing = 1.0
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = pdfView

        // Size to the target page at the same zoom
        if let page = destination?.page ?? document.page(at: 0) {
            sizeWindowToPage(window: window, page: page, scale: scaleForSizing)
        }

        window.center()
        window.makeKeyAndOrderFront(nil)

        if let destination {
            pdfView.go(to: destination)
        }

        windows.append(window)
        attachObservers(pdfView: pdfView, window: window)
        scheduleSave()
    }

    // MARK: - Observers / Saving

    private func attachObservers(pdfView: PDFView, window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSave()
        }

        NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSave()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.windows.removeAll { $0 === window }

            // If the app is quitting, don't overwrite the session as windows drain to zero.
            if !self.isTerminating {
                self.saveNow()
            }
        }
    }

    private func scheduleSave() {
        saveDebouncer.schedule { [weak self] in
            self?.saveNow()
        }
    }

    private func saveNow() {
        StateStore.shared.saveSession(windows: windows)
        print("Updraft: saved session with \(windows.count) window(s)")
    }

    // MARK: - Window sizing to page

    private func sizeWindowToPage(window: NSWindow, page: PDFPage, scale: CGFloat) {
        let bounds = page.bounds(for: .cropBox)
        let padding: CGFloat = 24.0

        var desired = NSSize(
            width: bounds.width * scale + padding,
            height: bounds.height * scale + padding
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
}

// MARK: - Helpers

private func clamp(_ x: Int, _ lo: Int, _ hi: Int) -> Int {
    if x < lo { return lo }
    if x > hi { return hi }
    return x
}

// MARK: - App bootstrap (must be top-level in main.swift)

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
