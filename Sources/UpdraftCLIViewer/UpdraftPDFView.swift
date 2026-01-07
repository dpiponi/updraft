import AppKit
import PDFKit

// MARK: - Bookmarks (Vim-style)

private var bookmarks: [Character: BookmarkState] = [:]

private enum PendingCommand {
    case setMark
    case jumpMark
}

private var pendingCommand: PendingCommand?

final class UpdraftPDFView: PDFView {

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
        guard
            let chars = event.charactersIgnoringModifiers,
            let c = chars.first
        else {
            super.keyDown(with: event)
            return
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
        guard
            let doc = document,
            let page = currentPage
        else {
            NSSound.beep()
            return
        }

        let pageIndex = doc.index(for: page)

        // Same policy as StateStore.captureViewState: center-of-view -> page coords
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let pagePoint = convert(viewCenter, to: page)

        bookmarks[mark] = BookmarkState(pageIndex: pageIndex, pointInPage: pagePoint)

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

        go(to: PDFDestination(page: page, at: point))
    }
}

extension UpdraftPDFView {

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
}
