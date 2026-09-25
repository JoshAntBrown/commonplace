import Foundation
import CoreGraphics

enum CardKind: String, Codable, CaseIterable {
    case sticky, note, link, video, image, place

    var label: String {
        switch self {
        case .sticky: "Sticky"
        case .note: "Note"
        case .link: "Link"
        case .video: "Video"
        case .image: "Image"
        case .place: "Place"
        }
    }

    var symbol: String {
        switch self {
        case .sticky: "note"
        case .note: "doc.text"
        case .link: "link"
        case .video: "play.rectangle"
        case .image: "photo"
        case .place: "list.bullet.rectangle"
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .sticky: CGSize(width: 220, height: 200)
        case .note: CGSize(width: 320, height: 240)
        case .link: CGSize(width: 320, height: 300)
        case .video: CGSize(width: 480, height: Card.videoHeight(width: 480))
        case .image: CGSize(width: 320, height: 240)
        case .place: CGSize(width: 220, height: Place.height(for: ""))
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
    /// The page this card was clipped from.
    var source: String?
    /// For a moment sticky: the video card it marks a point in.
    var momentOf: UUID?
    /// Playback speed for a video card.
    var speed: Double = 1
    /// Where playback was last, in seconds, so the video resumes there.
    var position: Double = 0
    var created = Date()
    /// The markdown file this card was loaded from, if any.
    var file: String?

    var fileName: String { file ?? id.uuidString.lowercased() + ".md" }

    static let headerHeight: CGFloat = 30
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// A video card is its header plus a 16:9 player; moments live in stickies.
    static func videoHeight(width: CGFloat) -> CGFloat { headerHeight + width * 9 / 16 }
}

struct Connection: Identifiable, Codable, Equatable {
    var id = UUID()
    var from: UUID
    var to: UUID
    var label = ""
    /// The affordance on a place card the connection starts from, if any.
    var fromItem: String?
}

/// Breadboard places (Shape Up): an underlined name with one affordance per
/// line. Rows have fixed heights so connection lines can start from a
/// specific affordance.
enum Place {
    static let padX: CGFloat = 14
    static let padTop: CGFloat = 8
    static let titleHeight: CGFloat = 34
    static let rowHeight: CGFloat = 24
    static let padBottom: CGFloat = 10

    static func affordances(_ body: String) -> [String] {
        body.components(separatedBy: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "* ", "• "] where line.hasPrefix(bullet) { line.removeFirst(bullet.count) }
            return line.isEmpty ? nil : line
        }
    }

    /// Vertical centre of affordance `i`, from the top of the card.
    static func rowCenter(_ i: Int) -> CGFloat {
        padTop + titleHeight + CGFloat(i) * rowHeight + rowHeight / 2
    }

    static func height(for body: String, editing: Bool = false) -> CGFloat {
        let rows = editing ? body.components(separatedBy: "\n").count + 1 : affordances(body).count
        return padTop + titleHeight + CGFloat(max(rows, 1)) * rowHeight + padBottom
    }
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
