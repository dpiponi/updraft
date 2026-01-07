import AppKit
import PDFKit

final class UpdraftPDFView: PDFView {

    // MARK: - Bookmarks (Vim-style)
    private enum PendingCommand {
        case setMark
        case jumpMark
    }

    private var pendingCommand: PendingCommand?

    private var bookmarks: [Character: BookmarkState] = [:]
    // MARK: - Link navigation history (Vim-like jump list)

    private var backStack: [BookmarkState] = []
    private var forwardStack: [BookmarkState] = []

    
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
        guard let doc = document else { NSSound.beep(); return }
        guard state.pageIndex >= 0, state.pageIndex < doc.pageCount,
              let page = doc.page(at: state.pageIndex)
        else { NSSound.beep(); return }

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
        guard let cur = captureCurrentLocation(), let prev = backStack.popLast() else {
            NSSound.beep()
            return
        }
        forwardStack.append(cur)
        jump(to: prev)
    }

    private func goForward() {
        guard let cur = captureCurrentLocation(), let next = forwardStack.popLast() else {
            NSSound.beep()
            return
        }
        backStack.append(cur)
        jump(to: next)
    }

    weak var updraftDelegate: AppDelegate?

    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event) ?? NSMenu()

        guard let target = linkTarget(at: event) else {
            return baseMenu
        }

        let item = NSMenuItem(
            title: "Open Link in New Window",
            action: #selector(openLinkInNewWindow(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = target

        baseMenu.insertItem(NSMenuItem.separator(), at: 0)
        baseMenu.insertItem(item, at: 0)

        return baseMenu
    }

    @objc private func openLinkInNewWindow(_ sender: NSMenuItem) {
        guard let doc = self.document else { return }
        guard let target = sender.representedObject as? LinkTarget else { return }

        switch target {
        case .destination(let dest):
            updraftDelegate?.openViewerWindowFromExistingDocument(
                document: doc,
                destination: dest,
                title: (NSApp.keyWindow?.title ?? "Updraft") + " (Link)",
                initialScaleFactor: self.scaleFactor
            )
            NSApp.activate(ignoringOtherApps: true)

        case .url(let url):
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Link detection

    private enum LinkTarget {
        case destination(PDFDestination)
        case url(URL)
    }

    private func linkTarget(at event: NSEvent) -> LinkTarget? {
        let windowPoint = event.locationInWindow
        let viewPoint = convert(windowPoint, from: nil)

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

    override func keyDown(with event: NSEvent) {
  
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
            if chars == "o" {
                goBack()
                return
            }
            if chars == "i" || chars == "\t" {
                goForward()
                return
            }
        }

        // If we are waiting for a bookmark letter
        if let pending = pendingCommand {
            pendingCommand = nil
            handleBookmarkKey(c, mode: pending)
            return
        }

        switch c {
        case "m":
            pendingCommand = .setMark
        case "'":
            pendingCommand = .jumpMark
        default:
            super.keyDown(with: event)
        }
    }

    private func handleBookmarkKey(_ c: Character, mode: PendingCommand) {
        guard c.isLetter else {
            NSSound.beep()
            return
        }

        switch mode {
        case .setMark:
            setBookmark(c)
        case .jumpMark:
            jumpToBookmark(c)
        }
    }

    private func setBookmark(_ mark: Character) {
        guard let loc = captureCurrentLocation() else {
            NSSound.beep()
            return
        }

        bookmarks[mark] = loc
        updraftDelegate?.noteViewStateChanged()
    }

    private func jumpToBookmark(_ mark: Character) {
        guard
            let doc = document,
            let bm = bookmarks[mark]
        else {
            NSSound.beep()
            return
        }

        guard bm.pageIndex >= 0, bm.pageIndex < doc.pageCount,
              let page = doc.page(at: bm.pageIndex)
        else {
            NSSound.beep()
            return
        }

        let point: CGPoint
        if let p = bm.pointInPage {
            point = p
        } else {
            let bounds = page.bounds(for: .cropBox)
            point = CGPoint(x: 0, y: bounds.height)
        }

        super.go(to: PDFDestination(page: page, at: point))
    }
}

extension UpdraftPDFView {

    override var acceptsFirstResponder: Bool { true }

    func exportBookmarks() -> [String: BookmarkState] {
        var out: [String: BookmarkState] = [:]
        for (ch, bm) in bookmarks {
            out[String(ch)] = bm
        }
        return out
    }

    func importBookmarks(_ state: [String: BookmarkState], fingerprintOK: Bool) {
        var rebuilt: [Character: BookmarkState] = [:]
        for (k, bm) in state {
            guard let ch = k.first, ch.isLetter else { continue }

            if fingerprintOK {
                rebuilt[ch] = bm
            } else {
                // If fingerprint mismatch, keep page only (drop point)
                rebuilt[ch] = BookmarkState(pageIndex: bm.pageIndex, pointInPage: nil)
            }
        }
        bookmarks = rebuilt
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        // Only treat plain left-click on *internal* PDF links as a jump.
        // Right-click is handled by the context menu; we don't want to push history then.
        if event.type == .leftMouseDown {
            if case .destination = linkTarget(at: event) {
                if let cur = captureCurrentLocation() {
                    backStack.append(cur)
                    forwardStack.removeAll()
                }
            }
        }

        super.mouseDown(with: event)
    }

    override func copy(_ sender: Any?) {
        // PDFView already knows how to copy its current selection.
        // Calling super is typically sufficient.
        super.copy(sender)
    }
}
