import AppKit
import PDFKit

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
        guard
            let doc = self.document,
            let target = sender.representedObject as? LinkTarget
        else { return }

        switch target {
        case .destination(let dest):
            updraftDelegate?.openViewerWindow(
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

        // Direct destination
        if let dest = annotation.destination {
            return .destination(dest)
        }

        // Action-based links
        if let action = annotation.action {

            if let goTo = action as? PDFActionGoTo {
                return .destination(goTo.destination)
            }

            if let urlAction = action as? PDFActionURL,
               let url = urlAction.url {
                return .url(url)
            }
        }

        return nil
    }
}
