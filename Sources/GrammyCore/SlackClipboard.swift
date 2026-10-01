import AppKit

extension NSAttributedString.Key {
    static let slackEmoji = NSAttributedString.Key("grammy.slackEmoji")
}

/// Chromium stores custom MIME clipboard data as a Pickle of UTF-16 pairs.
/// Format: chromium/src/ui/base/clipboard/custom_data_helper.cc and base/pickle.cc.
enum ChromiumClipboard {
    static let type = NSPasteboard.PasteboardType("org.chromium.web-custom-data")

    static func decode(_ data: Data) -> [String: String]? {
        guard data.count >= 8, data.count <= 1_000_000 else { return nil }
        let bytes = [UInt8](data)
        var position = 0
        func integer() -> Int? {
            guard position + 4 <= bytes.count else { return nil }
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[position + $1]) << ($1 * 8) }
            position += 4
            return Int(value)
        }
        guard let payload = integer(), payload <= bytes.count - 4 else { return nil }
        position = bytes.count - payload
        guard position >= 4, position % 4 == 0, let count = integer(), count <= 64 else { return nil }
        func string() -> String? {
            guard let length = integer(), length <= 500_000, length * 2 <= bytes.count - position else { return nil }
            let end = position + length * 2
            guard let value = String(data: Data(bytes[position..<end]), encoding: .utf16LittleEndian) else { return nil }
            position = end + (4 - length * 2 % 4) % 4
            guard position <= bytes.count else { return nil }
            return value
        }
        var result: [String: String] = [:]
        for _ in 0..<count {
            guard let key = string(), let value = string(), result[key] == nil else { return nil }
            result[key] = value
        }
        guard position == bytes.count else { return nil }
        return result
    }

    static func encode(_ values: [String: String]) -> Data {
        var payload = Data()
        func integer(_ value: Int, into data: inout Data) {
            var value = UInt32(value).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func string(_ value: String) {
            let data = value.data(using: .utf16LittleEndian)!
            integer(data.count / 2, into: &payload)
            payload.append(data)
            payload.append(Data(repeating: 0, count: (4 - data.count % 4) % 4))
        }
        integer(values.count, into: &payload)
        for key in values.keys.sorted() { string(key); string(values[key]!) }
        var result = Data()
        integer(payload.count, into: &result)
        result.append(payload)
        return result
    }
}

enum SlackClipboard {
    static func read(_ board: NSPasteboard) -> NSAttributedString? {
        guard let data = board.data(forType: ChromiumClipboard.type),
              let value = ChromiumClipboard.decode(data)?["slack/texty"],
              let json = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let ops = object["ops"] as? [[String: Any]], ops.count <= 10_000 else { return nil }
        let result = NSMutableAttributedString(string: "")
        for op in ops {
            var attrs: [NSAttributedString.Key: Any] = [:]
            let text: String
            if let inserted = op["insert"] as? String { text = inserted }
            else if let inserted = op["insert"] as? [String: Any],
                    let emoji = inserted["slackemoji"] as? [String: Any],
                    let label = emoji["text"] as? String, !label.isEmpty,
                    Rewrite.shortcodes(in: label).joined() == label || Rewrite.emojis(in: label).joined() == label {
                text = label
                attrs[.slackEmoji] = label
            } else { return nil } // Never silently drop an unsupported embed.
            guard result.length + (text as NSString).length <= 128_000 else { return nil }
            if let style = op["attributes"] as? [String: Any] {
                var font = style["code"] as? Bool == true || style["code-block"] as? Bool == true
                    ? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular) : NSFont.systemFont(ofSize: 15)
                if style["bold"] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if style["italic"] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                attrs[.font] = font
                if style["underline"] as? Bool == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if style["strike"] as? Bool == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = style["link"] as? String, let url = URL(string: link),
                   ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { attrs[.link] = url }
            }
            result.append(NSAttributedString(string: text, attributes: attrs))
        }
        return result
    }

    static func write(_ text: NSAttributedString, to board: NSPasteboard) {
        var ops: [[String: Any]] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let value = (text.string as NSString).substring(with: range)
            var styles: [String: Any] = [:]
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.monoSpace) { styles["code"] = true }
                if traits.contains(.bold) { styles["bold"] = true }
                if traits.contains(.italic) { styles["italic"] = true }
            }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { styles["underline"] = true }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { styles["strike"] = true }
            if let link = attrs[.link] { styles["link"] = String(describing: link) }
            func append(_ insert: Any) {
                var op: [String: Any] = ["insert": insert]
                if !styles.isEmpty { op["attributes"] = styles }
                ops.append(op)
            }
            if let emoji = attrs[.slackEmoji] as? String, !emoji.isEmpty,
               value.replacingOccurrences(of: emoji, with: "").isEmpty {
                for _ in 0..<(value.utf16.count / emoji.utf16.count) { append(["slackemoji": ["text": emoji]]) }
            } else { append(value) }
        }
        guard let json = try? JSONSerialization.data(withJSONObject: ["ops": ops]),
              let value = String(data: json, encoding: .utf8) else { return }
        board.setData(ChromiumClipboard.encode(["slack/texty": value, "public.utf8-plain-text": text.string]), forType: ChromiumClipboard.type)
    }
}
