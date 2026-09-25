import SwiftUI

/// Lightweight block renderer for card bodies: headings, bullets, tasks,
/// quotes and inline markdown. Lines starting with `[m:ss]` become seek buttons.
struct MarkdownText: View {
    let text: String
    let size: CGFloat
    let color: Color
    let accent: Color
    var onSeek: ((Double) -> Void)? = nil

    enum Block {
        case heading(Int, String)
        case bullet(String, checked: Bool?)
        case quote(String)
        case paragraph(String)
        case gap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.35) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                row(block)
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            Text(Self.inline(s))
                .font(.system(size: size * [1.4, 1.2, 1.08, 1, 1, 1][min(level, 6) - 1], weight: .semibold))
        case .bullet(let s, let checked):
            HStack(alignment: .firstTextBaseline, spacing: size * 0.45) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: size * 0.9))
                } else {
                    Text("•").font(.system(size: size))
                }
                line(s)
            }
        case .quote(let s):
            HStack(spacing: size * 0.55) {
                Rectangle().fill(accent.opacity(0.6)).frame(width: max(2, size * 0.18))
                line(s).italic()
            }
            .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let s):
            line(s)
        case .gap:
            Color.clear.frame(height: size * 0.15)
        }
    }

    /// A timestamp is an inline, clickable chip so the note wraps beneath it
    /// rather than hanging in a column beside it.
    @ViewBuilder private func line(_ s: String) -> some View {
        if let ts = Self.timestamp(s) {
            Text(chip(ts) + AttributedString(" ") + Self.inline(ts.rest))
                .font(.system(size: size))
                .tint(accent)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == Self.seekScheme,
                          let seconds = Double(url.absoluteString.dropFirst(Self.seekScheme.count + 1)) else {
                        return .systemAction
                    }
                    onSeek?(seconds)
                    return .handled
                })
        } else {
            Text(Self.inline(s)).font(.system(size: size))
        }
    }

    private static let seekScheme = "commonplace-seek"

    private func chip(_ ts: Stamp) -> AttributedString {
        var chip = AttributedString("\u{2009}\(ts.label)\u{2009}")
        chip.font = .system(size: size * 0.82, weight: .semibold, design: .monospaced)
        chip.foregroundColor = accent
        chip.backgroundColor = accent.opacity(0.18)
        if onSeek != nil { chip.link = URL(string: "\(Self.seekScheme):\(ts.seconds)") }
        return chip
    }

    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if case .gap? = out.last {} else if !out.isEmpty { out.append(.gap) }
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    out.append(.heading(level, String(line.dropFirst(level + 1))))
                    continue
                }
            }
            let lower = line.lowercased()
            if lower.hasPrefix("- [ ] ") || lower.hasPrefix("* [ ] ") {
                out.append(.bullet(String(line.dropFirst(6)), checked: false))
            } else if lower.hasPrefix("- [x] ") || lower.hasPrefix("* [x] ") {
                out.append(.bullet(String(line.dropFirst(6)), checked: true))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet(String(line.dropFirst(2)), checked: nil))
            } else if line.hasPrefix(">") {
                out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    struct Stamp {
        let seconds: Double
        let label: String
        let rest: String
    }

    private static let stampPattern = try! NSRegularExpression(pattern: #"^\[((?:\d{1,2}:)?\d{1,2}:\d{2})\]\s*"#)

    static func timestamp(_ s: String) -> Stamp? {
        guard let m = stampPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let whole = Range(m.range, in: s), let group = Range(m.range(at: 1), in: s),
              let seconds = Timestamp.parse(String(s[group])) else { return nil }
        return Stamp(seconds: seconds, label: String(s[group]), rest: String(s[whole.upperBound...]))
    }
}
