import Foundation
import CoreGraphics

struct BookmarkState: Codable {
    let pageIndex: Int
    let pointInPage: CGPoint?
}

struct FileFingerprint: Codable, Hashable {
    let fileSize: Int64
    let modTime: TimeInterval

    static func from(url: URL) -> FileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              let mod = attrs[.modificationDate] as? Date
        else { return nil }

        return FileFingerprint(
            fileSize: size.int64Value,
            modTime: mod.timeIntervalSince1970
        )
    }
}

struct DocumentKey: Codable, Hashable {
    let bookmark: Data
    let fingerprint: FileFingerprint

    static func == (lhs: DocumentKey, rhs: DocumentKey) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fingerprint)
    }
}

struct DocumentViewState: Codable {
    let pageIndex: Int
    let pointInPage: CGPoint?
    let scaleFactor: CGFloat?
    let usesAutoScale: Bool
    let bookmarks: [String: BookmarkState]?
}

struct WindowState: Codable {
    let document: DocumentKey
    let view: DocumentViewState
    let frame: CGRect?

    var pdfDisplayModeRaw: Int?
    var pdfDisplayDirectionRaw: Int?
    var pdfDisplaysAsBook: Bool?
}

struct SessionState: Codable {
    let windows: [WindowState]
}
