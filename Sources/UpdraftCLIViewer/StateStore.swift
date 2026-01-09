import Foundation
import AppKit
import PDFKit

final class StateStore {

    static let shared = StateStore()
    private let defaultsKey = "updraft.session.state"

    private init() {}

    // MARK: - Public

    func saveSession(windows: [NSWindow]) {
        let winStates = windows.compactMap { windowState(for: $0) }
        let session = SessionState(windows: winStates)
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func loadSession() -> SessionState? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func resolveDocumentURL(_ key: DocumentKey) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: key.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            // Fall back to non-security-scoped resolution if needed
            var stale2 = false
            return try? URL(
                resolvingBookmarkData: key.bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale2
            )
        }
        return url
    }

    func isFingerprintMatching(_ key: DocumentKey, url: URL) -> Bool {
        guard let current = FileFingerprint.from(url: url) else { return true }
        return current == key.fingerprint
    }

    // MARK: - Internals

    private func windowState(for window: NSWindow) -> WindowState? {
        guard
            let pdfView = window.contentView as? PDFView,
            let doc = pdfView.document,
            let url = doc.documentURL
        else { return nil }

        guard
            let bookmark = makeBookmarkData(url: url),
            let fingerprint = FileFingerprint.from(url: url)
        else { return nil }

        let key = DocumentKey(bookmark: bookmark, fingerprint: fingerprint)

        guard let view = captureViewState(pdfView: pdfView) else { return nil }

        var ws = WindowState(
            document: key,
            view: view,
            frame: window.frame
        )

        // Persist PDF layout mode
        ws.pdfDisplayModeRaw = pdfView.displayMode.rawValue
        ws.pdfDisplayDirectionRaw = pdfView.displayDirection.rawValue
        ws.pdfDisplaysAsBook = pdfView.displaysAsBook

        return ws    }

    private func makeBookmarkData(url: URL) -> Data? {
        // Prefer security-scoped bookmark; fall back if not allowed (non-sandboxed contexts vary).
        if let b = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return b
        }
        return try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func captureViewState(pdfView: PDFView) -> DocumentViewState? {
        guard
            let doc = pdfView.document,
            let page = pdfView.currentPage
        else { return nil }

        let pageIndex = doc.index(for: page)

        // Best-effort "where I am" capture: center of view -> page coords.
        let viewCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        let pagePoint = pdfView.convert(viewCenter, to: page)

        let bookmarks: [String: BookmarkState]?
        if let up = pdfView as? UpdraftPDFView {
            let exported = up.exportBookmarks()
            bookmarks = exported.isEmpty ? nil : exported
        } else {
            bookmarks = nil
        }

        return DocumentViewState(
            pageIndex: pageIndex,
            pointInPage: pagePoint,
            scaleFactor: pdfView.autoScales ? nil : pdfView.scaleFactor,
            usesAutoScale: pdfView.autoScales,
            bookmarks: bookmarks
        )
    }
}
