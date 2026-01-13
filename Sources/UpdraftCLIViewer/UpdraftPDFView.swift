import AppKit
import PDFKit

final class UpdraftPDFView: PDFView {

    // MARK: - Types

    /// Vim-style "m{letter}" set mark and "'{letter}" jump mark.
    private enum PendingCommand {
        case setMark
        case jumpMark
    }

    // MARK: - Dependencies

    weak var updraftDelegate: AppDelegate?

    // MARK: - State

    // Bookmarks / marks
    private var pendingCommand: PendingCommand?
    private var bookmarks: [Character: BookmarkState] = [:]

    // Link navigation history (Vim-like jump list)
    private var backStack: [BookmarkState] = []
    private var forwardStack: [BookmarkState] = []

    // Find
    private var findTerm: String = ""
    private var findMatches: [PDFSelection] = []
    private var findIndex: Int = -1

    // Two-page book mode (cover page alone, then spreads)
    private var displayModeObserver: NSObjectProtocol?

    // MARK: - NSResponder

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingDisplayModeChanges()
    }

    deinit {
        stopObservingDisplayModeChanges()
    }

    // MARK: - Find API

    func performFind(_ term: String) {
        guard let doc = document else { beep(); return }

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { beep(); return }

        findTerm = trimmed
        findMatches = doc.findString(trimmed, withOptions: .caseInsensitive)
        findIndex = -1

        guard !findMatches.isEmpty else { beep(); return }
        findNext()
    }

    func findNext() {
        guard !findMatches.isEmpty else { beep(); return }
        findIndex = (findIndex + 1) % findMatches.count
        showFindMatch(at: findIndex)
    }

    func findPrevious() {
        guard !findMatches.isEmpty else { beep(); return }
        findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
        showFindMatch(at: findIndex)
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event) ?? NSMenu()

        guard let target = linkTarget(for: event) else {
            return baseMenu
        }

        let item = NSMenuItem(
            title: "Open Link in New Window",
            action: #selector(openLinkInNewWindow(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = target

        baseMenu.insertItem(.separator(), at: 0)
        baseMenu.insertItem(item, at: 0)
        return baseMenu
    }

    @objc private func openLinkInNewWindow(_ sender: NSMenuItem) {
        guard let doc = document,
              let target = sender.representedObject as? LinkTarget
        else { return }

        switch target {
        case .destination(let dest):
            updraftDelegate?.openViewerWindowFromExistingDocument(
                document: doc,
                destination: dest,
                title: (NSApp.keyWindow?.title ?? "Updraft") + " (Link)",
                initialScaleFactor: scaleFactor
            )
            NSApp.activate(ignoringOtherApps: true)

        case .url(let url):
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Keyboard handling

    override func keyDown(with event: NSEvent) {
        // Don’t interfere with standard ⌘ shortcuts.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        guard
            let chars = event.charactersIgnoringModifiers,
            let c = chars.first
        else {
            super.keyDown(with: event)
            return
        }

        // Vim-like navigation: Ctrl-O back, Ctrl-I forward.
        // Ctrl-I is frequently delivered as TAB ("\t"), so handle both.
        if event.modifierFlags.contains(.control) {
            switch chars {
            case "o":
                goBack()
                return
            case "i", "\t":
                goForward()
                return
            default:
                super.keyDown(with: event)
                return
            }
        }

        // Pending bookmark command consumes next key.
        if let pending = pendingCommand {
            pendingCommand = nil
            handleBookmarkKey(c, mode: pending)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isBare = flags.isEmpty
        let isShiftOnly = flags == [.shift]

        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            super.keyDown(with: event)
            return
        }

        // Vim-ish find keys
        if isBare {
            switch c {
            case "/":
                NSApp.sendAction(#selector(AppDelegate.find(_:)), to: appDelegate, from: self)
                return
            case "n":
                NSApp.sendAction(#selector(AppDelegate.findNext(_:)), to: appDelegate, from: self)
                return
            default:
                break
            }
        } else if isShiftOnly, c == "?" {
            NSApp.sendAction(#selector(AppDelegate.findPrevious(_:)), to: appDelegate, from: self)
            return
        }

        // Vim-ish marks
        switch c {
        case "m":
            pendingCommand = .setMark
        case "'":
            pendingCommand = .jumpMark
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        // ⌘-click: open link in a new window instead of following it here.
        if event.type == .leftMouseDown,
           event.modifierFlags.contains(.command),
           let target = linkTarget(for: event)
        {
            let item = NSMenuItem()
            item.representedObject = target
            openLinkInNewWindow(item)
            return // IMPORTANT: do not call super, or PDFView will follow the link in-place
        }

        // History bookkeeping for normal in-place navigation.
        if event.type == .leftMouseDown,
           case .destination = linkTarget(for: event),
           let cur = captureCurrentLocation()
        {
            backStack.append(cur)
            forwardStack.removeAll()
        }

        super.mouseDown(with: event)
    }

    override func copy(_ sender: Any?) {
        super.copy(sender)
    }

    // MARK: - Bookmark import/export

    func exportBookmarks() -> [String: BookmarkState] {
        var out: [String: BookmarkState] = [:]
        out.reserveCapacity(bookmarks.count)
        for (ch, bm) in bookmarks {
            out[String(ch)] = bm
        }
        return out
    }

    func importBookmarks(_ state: [String: BookmarkState], fingerprintOK: Bool) {
        var rebuilt: [Character: BookmarkState] = [:]
        rebuilt.reserveCapacity(state.count)

        for (k, bm) in state {
            guard let ch = k.first, ch.isLetter else { continue }
            rebuilt[ch] = fingerprintOK
                ? bm
                : BookmarkState(pageIndex: bm.pageIndex, pointInPage: nil) // drop point if mismatch
        }

        bookmarks = rebuilt
    }

    // MARK: - Two-page "book" layout

    private func startObservingDisplayModeChanges() {
        // Avoid double registration if this view is reused.
        stopObservingDisplayModeChanges()

        displayModeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewDisplayModeChanged,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.enforceBookLayoutForCurrentDisplayMode()
        }

        // Apply once immediately as well.
        enforceBookLayoutForCurrentDisplayMode()
    }

    private func stopObservingDisplayModeChanges() {
        if let obs = displayModeObserver {
            NotificationCenter.default.removeObserver(obs)
            displayModeObserver = nil
        }
    }

    private func enforceBookLayoutForCurrentDisplayMode() {
        switch displayMode {
        case .twoUp, .twoUpContinuous:
            displaysAsBook = true
        default:
            displaysAsBook = false
        }
    }

    // MARK: - Link detection

    private enum LinkTarget {
        case destination(PDFDestination)
        case url(URL)
    }

    private func linkTarget(for event: NSEvent) -> LinkTarget? {
        let windowPoint = event.locationInWindow
        let viewPoint = convert(windowPoint, from: nil)
        return linkTarget(at: viewPoint)
    }

    private func linkTarget(at viewPoint: CGPoint) -> LinkTarget? {
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        let pagePoint = convert(viewPoint, to: page)

        guard let annotation = page.annotation(at: pagePoint) else { return nil }

        if let dest = annotation.destination {
            return .destination(dest)
        }

        if let action = annotation.action {
            if let goTo = action as? PDFActionGoTo {
                return .destination(goTo.destination) // non-optional on your SDK
            }
            if let urlAction = action as? PDFActionURL, let url = urlAction.url {
                return .url(url)
            }
        }

        return nil
    }

    // MARK: - Navigation helpers

    private func captureCurrentLocation() -> BookmarkState? {
        guard let doc = document else { return nil }

        // Choose a point near the top-left of what’s visible.
        // Small inset keeps us inside page content.
        let inset: CGFloat = 12.0
        let viewPoint = CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset)

        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        let pageIndex = doc.index(for: page)
        let pagePoint = convert(viewPoint, to: page)

        return BookmarkState(pageIndex: pageIndex, pointInPage: pagePoint)
    }

    private func jump(to state: BookmarkState) {
        guard let doc = document else { beep(); return }
        guard state.pageIndex >= 0,
              state.pageIndex < doc.pageCount,
              let page = doc.page(at: state.pageIndex)
        else { beep(); return }

        let point: CGPoint
        if let p = state.pointInPage {
            point = p
        } else {
            let bounds = page.bounds(for: .cropBox)
            point = CGPoint(x: 0, y: bounds.height)
        }

        super.go(to: PDFDestination(page: page, at: point))
    }

    private func goBack() {
        guard let cur = captureCurrentLocation(),
              let prev = backStack.popLast()
        else { beep(); return }

        forwardStack.append(cur)
        jump(to: prev)
    }

    private func goForward() {
        guard let cur = captureCurrentLocation(),
              let next = forwardStack.popLast()
        else { beep(); return }

        backStack.append(cur)
        jump(to: next)
    }

    // MARK: - Marks / bookmarks

    private func handleBookmarkKey(_ c: Character, mode: PendingCommand) {
        guard c.isLetter else { beep(); return }

        switch mode {
        case .setMark:
            setBookmark(c)
        case .jumpMark:
            jumpToBookmark(c)
        }
    }

    private func setBookmark(_ mark: Character) {
        guard let loc = captureCurrentLocation() else { beep(); return }
        bookmarks[mark] = loc
        updraftDelegate?.noteViewStateChanged()
    }

    private func jumpToBookmark(_ mark: Character) {
        guard let doc = document,
              let bm = bookmarks[mark]
        else { beep(); return }

        guard bm.pageIndex >= 0,
              bm.pageIndex < doc.pageCount,
              let page = doc.page(at: bm.pageIndex)
        else { beep(); return }

        let point: CGPoint
        if let p = bm.pointInPage {
            point = p
        } else {
            let bounds = page.bounds(for: .cropBox)
            point = CGPoint(x: 0, y: bounds.height)
        }

        super.go(to: PDFDestination(page: page, at: point))
    }

    // MARK: - Utilities

    private func showFindMatch(at index: Int) {
        guard index >= 0, index < findMatches.count else { return }
        let sel = findMatches[index]

        // Highlight + scroll to it.
        setCurrentSelection(sel, animate: true)
        go(to: sel)
    }

    private func beep() {
        NSSound.beep()
    }
}
