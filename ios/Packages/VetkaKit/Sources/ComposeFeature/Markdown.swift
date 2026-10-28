import Foundation

/// What the selection menu can do to the post's text.
enum MarkdownFormat: CaseIterable, Hashable, Sendable {
    case bold, italic, strikethrough, code, link, heading, quote, list, plain

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .heading: "textformat.size"
        case .quote: "text.quote"
        case .list: "list.bullet"
        case .plain: "textformat"
        }
    }

    var title: String {
        switch self {
        case .bold: "Жирный"
        case .italic: "Курсив"
        case .strikethrough: "Зачёркнутый"
        case .code: "Моноширинный"
        case .link: "Ссылка"
        case .heading: "Подзаголовок"
        case .quote: "Цитата"
        case .list: "Список"
        case .plain: "Обычный текст"
        }
    }

    /// The inline formats, kept as attributes on the characters.
    var key: NSAttributedString.Key? {
        switch self {
        case .bold: .mdBold
        case .italic: .mdItalic
        case .strikethrough: .mdStrike
        case .code: .mdCode
        default: nil
        }
    }
}

/// Paragraph formats, kept as an attribute on every character of the line.
enum MarkdownBlock: String, Sendable {
    case heading, quote
}

extension NSAttributedString.Key {
    /// What the text means; how it looks is derived from these.
    static let mdBold = NSAttributedString.Key("vetka.md.bold")
    static let mdItalic = NSAttributedString.Key("vetka.md.italic")
    static let mdStrike = NSAttributedString.Key("vetka.md.strike")
    static let mdCode = NSAttributedString.Key("vetka.md.code")
    /// The address of a link, a String.
    static let mdLink = NSAttributedString.Key("vetka.md.link")
    /// A MarkdownBlock raw value.
    static let mdBlock = NSAttributedString.Key("vetka.md.block")

    static let markdownKeys: [NSAttributedString.Key] = [.mdBold, .mdItalic, .mdStrike, .mdCode, .mdLink, .mdBlock]
}

/// The editor shows formatted text, the server and the draft keep markdown.
/// This converts between the two: the meaning lives in `.md*` attributes,
/// a list item is a line starting with "• ".
///
/// Characters that markdown would read as markup are escaped with a
/// backslash, so text typed as "2*3*4" comes back as typed.
enum MarkdownCodec {
    static let bullet = "• "
    private static let escapable: Set<Character> = ["\\", "*", "~", "`", "[", "]", "#", ">", "-"]
    private static let inlineEscaped: Set<Character> = ["\\", "*", "~", "`", "[", "]"]

    // MARK: Rich text → markdown

    static func markdown(from text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var out = ""
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            let hasNewline = content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 0x0A
            if hasNewline { content.length -= 1 }

            var line = ""
            let block = content.length > 0
                ? (text.attribute(.mdBlock, at: content.location, effectiveRange: nil) as? String).flatMap(MarkdownBlock.init)
                : nil
            var inner = content
            if ns.substring(with: content).hasPrefix(bullet) {
                line += "- "
                inner = NSRange(location: content.location + 2, length: content.length - 2)
            } else if block == .heading {
                line += "## "
            } else if block == .quote {
                line += "> "
            }
            var body = inline(text, inner)
            // A plain line that would read as a heading, quote or list.
            if line.isEmpty, let first = body.first, "#>-".contains(first) {
                body = "\\" + body
            }
            out += line + body + (hasNewline ? "\n" : "")
            location = NSMaxRange(paragraph)
        }
        return out
    }

    private static func inline(_ text: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        text.enumerateAttributes(in: range) { attrs, run, _ in
            let raw = (text.string as NSString).substring(with: run)
            let isCode = attrs[.mdCode] != nil
            // Markers hug the words: spaces at the edges go outside them.
            let core = raw.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else {
                out += raw
                return
            }
            let leading = String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
            let trailing = String(raw.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            var s = isCode ? core : escape(core)
            if isCode {
                s = "`" + s + "`"
            } else {
                if attrs[.mdItalic] != nil { s = "*" + s + "*" }
                if attrs[.mdBold] != nil { s = "**" + s + "**" }
                if attrs[.mdStrike] != nil { s = "~~" + s + "~~" }
            }
            if let url = attrs[.mdLink] as? String {
                s = "[" + s + "](" + url + ")"
            }
            out += leading + s + trailing
        }
        return out
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if inlineEscaped.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    // MARK: Markdown → rich text

    static func attributed(from markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            var rest = Substring(raw)
            var block: MarkdownBlock?
            var isBullet = false
            if let prefix = ["### ", "## ", "# "].first(where: { rest.hasPrefix($0) }) {
                block = .heading
                rest = rest.dropFirst(prefix.count)
            } else if rest.hasPrefix("> ") || rest == ">" {
                block = .quote
                rest = rest.dropFirst(min(2, rest.count))
            } else if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
                isBullet = true
                rest = rest.dropFirst(2)
            }

            let line = NSMutableAttributedString()
            if isBullet { line.append(NSAttributedString(string: bullet)) }
            line.append(parseInline(Array(rest), attributes: [:]))
            if index < lines.count - 1 { line.append(NSAttributedString(string: "\n")) }
            if let block, line.length > 0 {
                line.addAttribute(.mdBlock, value: block.rawValue, range: NSRange(location: 0, length: line.length))
            }
            out.append(line)
        }
        return out
    }

    private static func parseInline(_ chars: [Character], attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var plain = ""
        func flush() {
            if !plain.isEmpty {
                out.append(NSAttributedString(string: plain, attributes: attributes))
                plain = ""
            }
        }
        func adding(_ key: NSAttributedString.Key, _ value: Any = true) -> [NSAttributedString.Key: Any] {
            var a = attributes
            a[key] = value
            return a
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if c == "\\", let next, escapable.contains(next) {
                plain.append(next)
                i += 2
                continue
            }
            if c == "`", let close = find("`", in: chars, from: i + 1, escapes: false), close > i + 1 {
                flush()
                out.append(NSAttributedString(string: String(chars[(i + 1)..<close]), attributes: adding(.mdCode)))
                i = close + 1
                continue
            }
            if c == "*", next == "*", let close = findPair("**", in: chars, from: i + 2), close > i + 2,
               chars[i + 2] != " ", chars[close - 1] != " " {
                flush()
                out.append(parseInline(Array(chars[(i + 2)..<close]), attributes: adding(.mdBold)))
                i = close + 2
                continue
            }
            if c == "~", next == "~", let close = findPair("~~", in: chars, from: i + 2), close > i + 2 {
                flush()
                out.append(parseInline(Array(chars[(i + 2)..<close]), attributes: adding(.mdStrike)))
                i = close + 2
                continue
            }
            if c == "*", next != "*", next != " ", let close = findSingleStar(in: chars, from: i + 1), close > i + 1,
               chars[close - 1] != " " {
                flush()
                out.append(parseInline(Array(chars[(i + 1)..<close]), attributes: adding(.mdItalic)))
                i = close + 1
                continue
            }
            if c == "[", let closeBracket = find("]", in: chars, from: i + 1, escapes: true),
               closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
               let closeParen = find(")", in: chars, from: closeBracket + 2, escapes: false) {
                let url = String(chars[(closeBracket + 2)..<closeParen])
                if !url.isEmpty, !url.contains(" ") {
                    flush()
                    out.append(parseInline(Array(chars[(i + 1)..<closeBracket]), attributes: adding(.mdLink, url)))
                    i = closeParen + 1
                    continue
                }
            }
            plain.append(c)
            i += 1
        }
        flush()
        return out
    }

    private static func find(_ target: Character, in chars: [Character], from start: Int, escapes: Bool) -> Int? {
        var j = start
        while j < chars.count {
            if escapes && chars[j] == "\\" { j += 2; continue }
            if chars[j] == target { return j }
            j += 1
        }
        return nil
    }

    private static func findPair(_ pair: String, in chars: [Character], from start: Int) -> Int? {
        let p = Array(pair)
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == p[0] && chars[j + 1] == p[1] {
                // "***" closes italic, then bold: the pair is the last two.
                while j + 2 < chars.count && chars[j + 2] == p[1] { j += 1 }
                return j
            }
            j += 1
        }
        return nil
    }

    /// The closing `*` of italic: a single star, not half of a `**`.
    private static func findSingleStar(in chars: [Character], from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "*" {
                if j + 1 < chars.count && chars[j + 1] == "*" { j += 2; continue }
                return j
            }
            j += 1
        }
        return nil
    }
}
