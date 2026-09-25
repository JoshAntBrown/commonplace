import Foundation
import CoreGraphics

enum CardKind: String, Codable, CaseIterable {
    case sticky, note, link, video, image

    var label: String {
        switch self {
        case .sticky: "Sticky"
        case .note: "Note"
        case .link: "Link"
        case .video: "Video"
        case .image: "Image"
        }
    }

    var symbol: String {
        switch self {
        case .sticky: "note"
        case .note: "doc.text"
        case .link: "link"
        case .video: "play.rectangle"
        case .image: "photo"
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .sticky: CGSize(width: 220, height: 200)
        case .note: CGSize(width: 320, height: 240)
        case .link: CGSize(width: 320, height: 300)
        case .video: CGSize(width: 480, height: 470)
        case .image: CGSize(width: 320, height: 240)
        }
    }
}

/// Order matters: keys 1–6 map onto these in sequence.
enum CardColor: String, Codable, CaseIterable {
    case none, yellow, orange, pink, purple, blue, green
}

struct Card: Identifiable, Equatable {
    var id = UUID()
    var kind: CardKind
    var frame: CGRect = .zero
    var color: CardColor = .none
    var title = ""
    var body = ""
    var url: String?
    /// Relative path inside the board folder (`assets/…`) or a remote URL.
    var image: String?
    var summary: String?
    /// Direct video file behind a post (e.g. the MP4 in an X post).
    var media: String?
    var created = Date()
    /// The markdown file this card was loaded from, if any.
    var file: String?

    var fileName: String { file ?? id.uuidString.lowercased() + ".md" }
}

struct Connection: Identifiable, Codable, Equatable {
    var id = UUID()
    var from: UUID
    var to: UUID
    var label = ""
}

struct Viewport: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1
}

struct Board {
    var name: String
    var folder: URL
    var cards: [Card] = []
    var connections: [Connection] = []
    var viewport = Viewport()
}

/// On-disk layout for a board. Card content lives in `cards/*.md`.
struct BoardFile: Codable {
    struct Placement: Codable {
        var id: UUID
        var x, y, w, h: Double
    }

    var version = 1
    var cards: [Placement]
    var connections: [Connection]
    var viewport: Viewport
}

enum Timestamp {
    static func format(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func parse(_ s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        return Double(parts.reduce(0) { $0 * 60 + $1 })
    }
}
