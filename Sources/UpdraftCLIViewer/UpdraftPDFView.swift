import AppKit
import PDFKit

// MARK: - Bookmarks (Vim-style)

private var bookmarks: [Character: PDFDestination] = [:]

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
        guard let page = currentPage else {
            NSSound.beep()
            return
        }

        let point: CGPoint
        if let dest = currentDestination {
            point = dest.point
        } else {
            // Fallback: top-left of page
            let bounds = page.bounds(for: .cropBox)
            point = CGPoint(x: 0, y: bounds.height)
        }

        let destination = PDFDestination(page: page, at: point)
        bookmarks[mark] = destination
        updraftDelegate?.noteViewStateChanged()

        Swift.print("Updraft: set bookmark '\(mark)'")
    }

    private func jumpToBookmark(_ mark: Character) {
        Swift.print("Updraft: attempt to go to '\(mark)'")
        guard let dest = bookmarks[mark] else {
            NSSound.beep()
            return
        }

        Swift.print("Updraft: go to '\(mark)'")
        go(to: dest)
    }
}

extension UpdraftPDFView {

    func exportBookmarks() -> [String: BookmarkState] {
        guard let doc = document else { return [:] }

        var out: [String: BookmarkState] = [:]
        for (ch, dest) in bookmarks {
            guard let page = dest.page else { continue; }
            let idx = doc.index(for: page)
            out[String(ch)] = BookmarkState(pageIndex: idx, pointInPage: dest.point)
        }
        return out
    }

    func importBookmarks(_ state: [String: BookmarkState], fingerprintOK: Bool) {
        guard let doc = document else { return }

        var rebuilt: [Character: PDFDestination] = [:]

        for (k, s) in state {
            guard let ch = k.first, ch.isLetter else { continue }
            let idx = max(0, min(s.pageIndex, doc.pageCount - 1))
            guard let page = doc.page(at: idx) else { continue }

            // Apply your existing policy: if fingerprint mismatch, ignore pointInPage
            let point: CGPoint
            if fingerprintOK, let p = s.pointInPage {
                point = p
            } else {
                let bounds = page.bounds(for: .cropBox)
                point = CGPoint(x: 0, y: bounds.height)
            }

            rebuilt[ch] = PDFDestination(page: page, at: point)
        }

        bookmarks = rebuilt
    }
}
