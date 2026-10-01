import AppKit

/// Formatting stays local. Only the text (with explicit code markers) goes to the model.
public struct FormattedText {
    public let attributed: NSAttributedString
    public var string: String { attributed.string }
    public init(_ text: String) { attributed = NSAttributedString(string: text) }
    public init(_ text: NSAttributedString) { attributed = NSAttributedString(attributedString: text) }

    public static func read(_ board: NSPasteboard) -> FormattedText? {
        let plain = board.string(forType: .string)
        if let value = SlackClipboard.read(board), let text = reconcile(value, plain: plain) { return text }
        // HTML carries semantic code and emoji image labels in Electron editors.
        if let data = board.data(forType: .html), let html = String(data: data, encoding: .utf8),
           let value = importHTML(html), let text = reconcile(value, plain: plain) {
            return text
        }
        if let data = board.data(forType: .rtf),
           let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           let text = reconcile(value, plain: plain) {
            return text
        }
        return plain.map(FormattedText.init)
    }

    private static func reconcile(_ value: NSAttributedString, plain: String?) -> FormattedText? {
        guard let plain else { return FormattedText(value) }
        if value.string == plain { return FormattedText(value) }
        if value.string == plain + "\n" {
            return FormattedText(value.attributedSubstring(from: NSRange(location: 0, length: (plain as NSString).length)))
        }
        // Services/RTF and AX can omit emoji images. Keep the richer emoji text,
        // or map styles onto plain text that has the missing emoji, only when all
        // non-emoji wording agrees. Never let a lossy RTF flavor override Unicode.
        func wording(_ text: String) -> String {
            var text = text
            for emoji in Rewrite.emojis(in: text) { text = text.replacingOccurrences(of: emoji, with: "") }
            for shortcode in Rewrite.shortcodes(in: text) { text = text.replacingOccurrences(of: shortcode, with: "") }
            return text.replacingOccurrences(of: "\u{fffc}", with: "")
                .replacingOccurrences(of: "\u{00a0}", with: " ")
                .trimmingCharacters(in: .newlines)
        }
        guard wording(value.string) == wording(plain) else { return nil }
        let richEmojis = Rewrite.emojis(in: value.string) + Rewrite.shortcodes(in: value.string)
        let plainEmojis = Rewrite.emojis(in: plain) + Rewrite.shortcodes(in: plain)
        if richEmojis.count > plainEmojis.count {
            return FormattedText(value)
        }
        if plainEmojis.count >= richEmojis.count {
            return try? FormattedText(value).styled(plain)
        }
        return nil
    }

    static func importHTML(_ html: String) -> NSAttributedString? {
        // Restrict the importer to text formatting; never load clipboard images, CSS or remote resources.
        var clean = html.replacingOccurrences(of: #"(?is)<(head|script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        let tags = try! NSRegularExpression(pattern: #"(?is)<[^>]*>"#)
        let ns = clean as NSString
        for match in tags.matches(in: clean, range: NSRange(location: 0, length: ns.length)).reversed() {
            let tag = ns.substring(with: match.range)
            let nameRE = try! NSRegularExpression(pattern: #"^<\s*(/?)\s*([a-zA-Z0-9]+)"#)
            var replacement = ""
            if let name = nameRE.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
                let slash = (tag as NSString).substring(with: name.range(at: 1))
                let kind = (tag as NSString).substring(with: name.range(at: 2)).lowercased()
                switch kind {
                case "img":
                    // Decode the label locally; never fetch the image URL.
                    for key in ["data-stringify-emoji", "data-stringify-text", "alt"] {
                        guard let label = htmlAttribute(key, in: tag), !label.isEmpty else { continue }
                        if Rewrite.emojis(in: label).joined() == label || Rewrite.shortcodes(in: label).joined() == label {
                            replacement = escape(label)
                            break
                        }
                    }
                case "code", "pre": replacement = slash.isEmpty ? "<\(kind) style=\"font-family: monospace\">" : "</\(kind)>"
                case "b", "strong", "i", "em", "u", "s", "strike", "del", "p", "div", "br", "ul", "ol", "li": replacement = "<\(slash)\(kind)>"
                case "span":
                    if !slash.isEmpty { replacement = "</span>" }
                    else {
                        let lower = tag.lowercased()
                        var style = ""
                        if lower.contains("monospace") || lower.contains("inline-code") || lower.contains("__code") { style += "font-family: monospace;" }
                        if lower.range(of: #"font-weight\s*:\s*(bold|[6-9]00)"#, options: .regularExpression) != nil { style += "font-weight: bold;" }
                        if lower.range(of: #"font-style\s*:\s*italic"#, options: .regularExpression) != nil { style += "font-style: italic;" }
                        if lower.contains("text-decoration") && lower.contains("underline") { style += "text-decoration: underline;" }
                        if lower.contains("text-decoration") && lower.contains("line-through") { style += "text-decoration: line-through;" }
                        replacement = "<span style=\"\(style)\">"
                    }
                case "a":
                    if !slash.isEmpty { replacement = "</a>" }
                    else {
                        let href = try! NSRegularExpression(pattern: #"(?i)href\s*=\s*[\"']([^\"']*)[\"']"#)
                        if let m = href.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
                            let url = (tag as NSString).substring(with: m.range(at: 1))
                            if let scheme = URL(string: url)?.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) {
                                replacement = "<a href=\"\(escape(url))\">"
                            }
                        }
                    }
                default: break
                }
            }
            clean = (clean as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        let result = NSMutableAttributedString(string: "")
        let tagRE = try! NSRegularExpression(pattern: #"(?is)<[^>]*>"#)
        var active: [(String, [NSAttributedString.Key: Any])] = []
        var position = 0
        func append(_ text: String) {
            var attrs: [NSAttributedString.Key: Any] = [:]
            for (_, values) in active { attrs.merge(values) { _, new in new } }
            var font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 15)
            if active.contains(where: { ["b", "strong"].contains($0.0) }) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if active.contains(where: { ["i", "em"].contains($0.0) }) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attrs[.font] = font
            result.append(NSAttributedString(string: decodeEntities(text), attributes: attrs))
        }
        for match in tagRE.matches(in: clean, range: NSRange(location: 0, length: (clean as NSString).length)) {
            append((clean as NSString).substring(with: NSRange(location: position, length: match.range.location - position)))
            let tag = (clean as NSString).substring(with: match.range)
            position = NSMaxRange(match.range)
            let closing = tag.hasPrefix("</")
            let name = tag.dropFirst(closing ? 2 : 1).prefix { $0.isLetter }.lowercased()
            if closing {
                if let index = active.lastIndex(where: { $0.0 == name }) { active.removeSubrange(index...) }
                if ["p", "div", "li", "pre"].contains(name), !result.string.hasSuffix("\n") { append("\n") }
            } else {
                if name == "br" { append("\n"); continue }
                if ["p", "div", "li", "pre"].contains(name), result.length > 0, !result.string.hasSuffix("\n") { append("\n") }
                var attrs: [NSAttributedString.Key: Any] = [:]
                switch name {
                case "code", "pre": attrs[.font] = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
                case "span":
                    var font = tag.contains("monospace") ? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular) : NSFont.systemFont(ofSize: 15)
                    if tag.contains("font-weight: bold") { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    if tag.contains("font-style: italic") { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    if tag.contains("monospace") || tag.contains("font-weight") || tag.contains("font-style") { attrs[.font] = font }
                    if tag.contains("underline") { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if tag.contains("line-through") { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                case "u": attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                case "s", "strike", "del": attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case "a":
                    let re = try! NSRegularExpression(pattern: #"href="([^\"]*)""#)
                    if let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
                       let url = URL(string: decodeEntities((tag as NSString).substring(with: m.range(at: 1)))) { attrs[.link] = url }
                default: break
                }
                active.append((name, attrs))
            }
        }
        append((clean as NSString).substring(from: position))
        return result
    }

    private static func htmlAttribute(_ name: String, in tag: String) -> String? {
        let re = try! NSRegularExpression(pattern: "(?i)\\b" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
        guard let match = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
        return decodeEntities((tag as NSString).substring(with: range))
    }

    private static func decodeEntities(_ text: String) -> String {
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}",
                     "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "ndash": "–", "mdash": "—", "hellip": "…"]
        let re = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)
        var value = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
            let entity = (text as NSString).substring(with: match.range(at: 1))
            var replacement = names[entity]
            if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x")
                if let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            }
            if let replacement { value = (value as NSString).replacingCharacters(in: match.range, with: replacement) }
        }
        return value
    }

    public var codeRanges: [NSRange] {
        var ranges: [NSRange] = []
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                if let last = ranges.last, NSMaxRange(last) == range.location {
                    ranges[ranges.count - 1] = NSUnionRange(last, range)
                } else { ranges.append(range) }
            }
        }
        return ranges
    }

    public var modelText: String {
        var value = string as NSString
        for range in codeRanges.reversed() {
            let code = value.substring(with: range)
            // Use a delimiter longer than any backtick run in the selected code.
            let longest = code.split(separator: "`", omittingEmptySubsequences: false).count - 1
            let marker = String(repeating: "`", count: max(1, longest + 1))
            value = value.replacingCharacters(in: range, with: marker + code + marker) as NSString
        }
        return value as String
    }

    /// Remove only the code delimiters introduced by us, and restore styles using unchanged token anchors.
    public func rewritten(_ response: String) throws -> FormattedText {
        var plain = response
        var searchStart = plain.startIndex
        for range in codeRanges {
            let code = (string as NSString).substring(with: range)
            let longest = code.split(separator: "`", omittingEmptySubsequences: false).count - 1
            let marker = String(repeating: "`", count: max(1, longest + 1))
            guard let found = plain.range(of: marker + code + marker, range: searchStart..<plain.endIndex) else {
                throw GrammyError("The suggestion changed formatted code. Regenerate to keep it intact.")
            }
            let offset = plain.distance(from: plain.startIndex, to: found.lowerBound)
            plain.replaceSubrange(found, with: code)
            searchStart = plain.index(plain.startIndex, offsetBy: offset + code.count)
        }
        return try styled(plain)
    }

    public func styled(_ plain: String) throws -> FormattedText {
        let result = NSMutableAttributedString(string: plain)
        let old = TextDiff.tokens(string), new = TextDiff.tokens(plain)
        let matches = TextDiff.matches(old.map(\.text), new.map(\.text))
        for (a, b) in matches {
            let source = attributed.attributedSubstring(from: old[a].range)
            result.replaceCharacters(in: new[b].range, with: source)
        }
        // A replacement inside a uniformly styled phrase inherits that phrase's style.
        let anchors = [(-1, -1)] + matches + [(old.count, new.count)]
        for i in 1..<anchors.count {
            let left = anchors[i - 1], right = anchors[i]
            guard right.0 > left.0 + 1, right.1 > left.1 + 1 else { continue }
            let range = NSUnionRange(old[left.0 + 1].range, old[right.0 - 1].range)
            var attributes: [NSAttributedString.Key: Any]?
            var uniform = true
            attributed.enumerateAttributes(in: range) { attrs, _, _ in
                if let attributes { if !NSDictionary(dictionary: attributes).isEqual(to: attrs) { uniform = false } }
                else { attributes = attrs }
            }
            if uniform, var attributes {
                attributes.removeValue(forKey: .link) // Never extend a link to newly generated words.
                attributes.removeValue(forKey: .slackEmoji)
                if let font = attributes[.font] as? NSFont, font.fontDescriptor.symbolicTraits.contains(.monoSpace) { continue }
                result.addAttributes(attributes, range: NSUnionRange(new[left.1 + 1].range, new[right.1 - 1].range))
            }
        }
        // Restore complete protected spans, even when diff anchors picked another identical word.
        var start = 0
        for range in codeRanges {
            let code = (string as NSString).substring(with: range)
            let sourceIndex = old.firstIndex { NSLocationInRange(range.location, $0.range) }
            let targetIndex = matches.first { $0.0 == sourceIndex }?.1
            var found = NSRange(location: NSNotFound, length: 0)
            if let sourceIndex, let targetIndex {
                let location = new[targetIndex].range.location + range.location - old[sourceIndex].range.location
                if location >= start, location + range.length <= result.length,
                   (plain as NSString).substring(with: NSRange(location: location, length: range.length)) == code {
                    found = NSRange(location: location, length: range.length)
                }
            }
            if found.location == NSNotFound {
                found = (plain as NSString).range(of: code, options: [], range: NSRange(location: start, length: result.length - start))
            }
            guard found.location != NSNotFound else { throw GrammyError("Formatted code could not be restored.") }
            result.replaceCharacters(in: found, with: attributed.attributedSubstring(from: range))
            start = NSMaxRange(found)
        }
        return FormattedText(result)
    }

    public func write(to board: NSPasteboard) {
        board.clearContents()
        board.setString(string, forType: .string)
        if let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            board.setData(data, forType: .rtf)
        }
        board.setString(html, forType: .html)
        SlackClipboard.write(attributed, to: board)
    }

    public var html: String {
        var body = ""
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            var text = Self.escape((string as NSString).substring(with: range)).replacingOccurrences(of: "\n", with: "<br>")
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.monoSpace) { text = "<code>\(text)</code>" }
                if traits.contains(.bold) { text = "<strong>\(text)</strong>" }
                if traits.contains(.italic) { text = "<em>\(text)</em>" }
            }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { text = "<u>\(text)</u>" }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { text = "<s>\(text)</s>" }
            if let link = attrs[.link] { text = "<a href=\"\(Self.escape(String(describing: link)))\">\(text)</a>" }
            body += text
        }
        return "<html><body><!--StartFragment-->\(body)<!--EndFragment--></body></html>"
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum TextDiff {
    public struct Token { public let text: String; public let range: NSRange }
    public static func tokens(_ text: String) -> [Token] {
        let re = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]+(?:[’'][\p{L}\p{M}\p{N}_]+)*|\s+|[^\p{L}\p{M}\p{N}_\s]"#)
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map {
            Token(text: (text as NSString).substring(with: $0.range), range: $0.range)
        }
    }
    static func matches(_ old: [String], _ new: [String]) -> [(Int, Int)] {
        let diff = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change { case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset) }
        }
        let a = old.indices.filter { !removed.contains($0) }, b = new.indices.filter { !inserted.contains($0) }
        return Array(zip(a, b))
    }
    public static func changedRanges(original: String, suggestion: String) -> [NSRange] {
        let old = tokens(original), new = tokens(suggestion)
        let unchanged = Set(matches(old.map(\.text), new.map(\.text)).map { $0.1 })
        return new.indices.filter { !unchanged.contains($0) && !new[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { new[$0].range }
    }
}
