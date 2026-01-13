import AppKit
import PDFKit

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSSearchFieldDelegate {

    // MARK: Dependencies

    private let saveDebouncer = Debouncer(delay: 0.5)

    // MARK: State

    private var windows: [NSWindow] = []
    private var isTerminating = false

    // Finder may send open requests before didFinishLaunching.
    private var pendingOpenURLs: [URL] = []
    private var didFinishLaunching = false

    // Find panel
    private var findPanel: NSPanel?
    private var findField: NSSearchField?
    private var lastFindTerm: String = ""

    // MARK: - NSApplicationDelegate lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        didFinishLaunching = true

        // Launch modes:
        // 1) CLI: open only the passed file, restoring all saved windows for it (per-document).
        // 2) Finder/Open With: open requested files (no full session restore).
        // 3) Normal GUI launch: restore full previous session.
        if openFromCommandLineIfPresent() { return }
        if openPendingURLsIfPresent() { return }
        restorePreviousSessionIfAvailable()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        saveNow() // save while windows still exist
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Open documents (Finder / CLI)

    func application(_ application: NSApplication, open urls: [URL]) {
        let normalized = urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }

        if didFinishLaunching {
            normalized.forEach(openFromSystem)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            pendingOpenURLs.append(contentsOf: normalized)
        }
    }

    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        // Legacy path still used by Finder in some cases.
        self.application(application, open: [URL(fileURLWithPath: filename)])
        return true
    }

    private func openFromCommandLineIfPresent() -> Bool {
        let args = CommandLine.arguments.dropFirst()
        guard let path = args.first else { return false }

        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        openFromSystem(url)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func openPendingURLsIfPresent() -> Bool {
        guard !pendingOpenURLs.isEmpty else { return false }

        let urls = pendingOpenURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        pendingOpenURLs.removeAll()

        urls.forEach(openFromSystem)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func restorePreviousSessionIfAvailable() {
        guard let session = StateStore.shared.loadSession() else { return }

        for ws in session.windows {
            guard let url = StateStore.shared.resolveDocumentURL(ws.document) else { continue }
            openViewerWindow(url: url, restoredState: ws)
        }
    }

    private func openFromSystem(_ url: URL) {
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL

        // Per-document restore: load saved windows for THIS PDF, even if it wasn't
        // part of the most recent session.
        let matches = StateStore.shared.loadWindowStates(for: normalized)

        if matches.isEmpty {
            openViewerWindow(url: normalized, restoredState: nil)
        } else {
            for ws in matches {
                openViewerWindow(url: normalized, restoredState: ws)
            }
        }
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Updraft")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Updraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")

        editMenu.addItem(.separator())

        let findItem = NSMenuItem(title: "Find…", action: #selector(find(_:)), keyEquivalent: "f")
        findItem.keyEquivalentModifierMask = [.command]
        findItem.target = self
        editMenu.addItem(findItem)

        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(findNext(_:)), keyEquivalent: "g")
        findNextItem.keyEquivalentModifierMask = [.command]
        findNextItem.target = self
        editMenu.addItem(findNextItem)

        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(findPrevious(_:)), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.target = self
        editMenu.addItem(findPrevItem)

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

    // MARK: - Find panel

    func controlTextDidEndEditing(_ obj: Notification) {
        guard
            let field = obj.object as? NSSearchField,
            field === findField
        else { return }

        // Only trigger on Return/Enter.
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSReturnTextMovement {
            performFindFromPanel(nil)
        }
    }

    private func ensureFindPanel() -> NSPanel {
        if let p = findPanel { return p }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Find"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let field = NSSearchField(frame: NSRect(x: 12, y: 14, width: 336, height: 28))
        field.delegate = self
        field.isContinuous = false
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true

        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView?.addSubview(field)

        findPanel = panel
        findField = field
        return panel
    }

    @objc private func performFindFromPanel(_ sender: Any?) {
        guard let pdfView = currentUpdraftPDFView() else { NSSound.beep(); return }
        guard let field = findField else { return }

        let term = field.stringValue
        lastFindTerm = term
        pdfView.performFind(term)

        // Optional: close panel after successful find.
        findPanel?.orderOut(nil)
    }

    @objc func find(_ sender: Any?) {
        guard NSApp.keyWindow != nil else { NSSound.beep(); return }

        let panel = ensureFindPanel()
        findField?.stringValue = lastFindTerm

        center(panel: panel, over: NSApp.keyWindow)
        panel.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(findField)
        findField?.selectText(nil)
    }

    @objc func findNext(_ sender: Any?) {
        guard let pdfView = currentUpdraftPDFView() else { NSSound.beep(); return }
        pdfView.findNext()
    }

    @objc func findPrevious(_ sender: Any?) {
        guard let pdfView = currentUpdraftPDFView() else { NSSound.beep(); return }
        pdfView.findPrevious()
    }

    // MARK: - Window actions

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

        alert.window.animationBehavior = .none
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(trimmed), (1...pageCount).contains(n) else { NSSound.beep(); return }
        guard let page = doc.page(at: n - 1) else { return }

        pdfView.go(to: page)
    }

    // MARK: - Window creation (URL-based, open/restore)


    func openViewerWindow(url: URL, restoredState: WindowState?) {
        // Security-scoped best-effort.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let doc = PDFDocument(url: url) else { return }

        let pdfView = UpdraftPDFView(frame: .zero)
        pdfView.document = doc
        pdfView.updraftDelegate = self

        let viewState = restoredState?.view
        let isRestoringZoom = (viewState != nil)

        // Restore / set layout mode.
        let (displayMode, displayDirection, displaysAsBook) = resolveLayout(restoredState: restoredState)
        pdfView.displayMode = displayMode
        pdfView.displayDirection = displayDirection
        pdfView.displaysAsBook = displaysAsBook

        // Apply zoom/state (restored windows keep their saved zoom policy).
        applyZoom(viewState: viewState, to: pdfView)

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
            // New window default: use a screen-relative size so "fit page" doesn't look tiny.
            if let screen = NSScreen.main {
                let vf = screen.visibleFrame
                let w = vf.width * 0.80
                let h = vf.height * 0.85
                window.setFrame(NSRect(x: 0, y: 0, width: w, height: h), display: false)
            }
            window.center()
        }

        window.makeKeyAndOrderFront(nil)

        // For brand-new windows (no saved zoom), force a post-layout "fit page" computation.
        if !isRestoringZoom {
            DispatchQueue.main.async { [weak pdfView] in
                guard let pdfView else { return }
                pdfView.layoutSubtreeIfNeeded()
                pdfView.autoScales = true
                pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
            }
        }

        // Restore bookmarks.
        if let restoredState, let bm = restoredState.view.bookmarks {
            let fingerprintOK = StateStore.shared.isFingerprintMatching(restoredState.document, url: url)
            pdfView.importBookmarks(bm, fingerprintOK: fingerprintOK)
        }

        // Navigate to restored position.
        if let vs = viewState {
            restorePosition(viewState: vs, restoredState: restoredState, url: url, document: doc, pdfView: pdfView)
        }

        windows.append(window)
        attachObservers(pdfView: pdfView, window: window)
        scheduleSave()
    }

    // MARK: - Window creation (existing document, link opens)

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

    func noteViewStateChanged() {
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

    // MARK: - Window sizing

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

    // MARK: - Small helpers (UI)

    private func currentUpdraftPDFView() -> UpdraftPDFView? {
        // Prefer keyWindow; fall back to mainWindow.
        if let v = NSApp.keyWindow?.contentView as? UpdraftPDFView { return v }
        if let v = NSApp.mainWindow?.contentView as? UpdraftPDFView { return v }
        return nil
    }

    private func center(panel: NSPanel, over window: NSWindow?) {
        guard let w = window else { return }
        let wf = w.frame
        let pf = panel.frame
        let x = wf.midX - pf.width / 2
        let y = wf.midY - pf.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Restore helpers (layout/zoom/position)

    private func resolveLayout(restoredState: WindowState?) -> (PDFDisplayMode, PDFDisplayDirection, Bool) {
        // Defaults
        var mode: PDFDisplayMode = .singlePageContinuous
        var direction: PDFDisplayDirection = .vertical
        var book: Bool? = nil

        if let rs = restoredState {
            if let raw = rs.pdfDisplayModeRaw, let m = PDFDisplayMode(rawValue: raw) {
                mode = m
            }
            if let raw = rs.pdfDisplayDirectionRaw, let d = PDFDisplayDirection(rawValue: raw) {
                direction = d
            }
            book = rs.pdfDisplaysAsBook
        }

        // Book pairing policy:
        // - If saved value exists, respect it.
        // - Otherwise, enforce "book" pairing for two-up modes (cover alone), off otherwise.
        let resolvedBook: Bool = {
            if let book { return book }
            switch mode {
            case .twoUp, .twoUpContinuous:
                return true
            default:
                return false
            }
        }()

        return (mode, direction, resolvedBook)
    }

    private func applyZoom(viewState: DocumentViewState?, to pdfView: PDFView) {
        guard let viewState else {
            pdfView.autoScales = true
            return
        }

        if viewState.usesAutoScale {
            pdfView.autoScales = true
            return
        }

        if let s = viewState.scaleFactor {
            pdfView.autoScales = false
            pdfView.scaleFactor = s
        } else {
            pdfView.autoScales = true
        }
    }

    private func preferredSizingPage(document: PDFDocument, viewState: DocumentViewState?) -> PDFPage? {
        if let vs = viewState {
            let idx = clamp(vs.pageIndex, 0, max(0, document.pageCount - 1))
            if let p = document.page(at: idx) { return p }
        }
        return document.page(at: 0)
    }

    private func preferredSizingScale(viewState: DocumentViewState?) -> CGFloat {
        if let vs = viewState, !vs.usesAutoScale, let s = vs.scaleFactor {
            return s
        }
        return 1.0
    }

    private func restorePosition(
        viewState vs: DocumentViewState,
        restoredState: WindowState?,
        url: URL,
        document doc: PDFDocument,
        pdfView: PDFView
    ) {
        let idx = clamp(vs.pageIndex, 0, max(0, doc.pageCount - 1))
        guard let page = doc.page(at: idx) else { return }

        // If fingerprint changed, ignore pointInPage (best-effort policy).
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
