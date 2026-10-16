import AppKit
import Combine
import CryptoKit
import SwiftUI

// MARK: - Formatters

enum FormatResult: Equatable {
    case ok(String)
    /// `line` / `column` (1-based) point at the problem when the parser says where it is.
    case error(String, line: Int? = nil, column: Int? = nil)
}

/// "… around line 3, column 13." -> (3, 13)
func lineColumn(in message: String) -> (Int, Int)? {
    guard let r = message.range(of: #"line (\d+), column (\d+)"#, options: .regularExpression) else { return nil }
    let nums = message[r].split { !$0.isNumber }.compactMap { Int($0) }
    return nums.count == 2 ? (nums[0], nums[1]) : nil
}

/// Re-indents JSON keeping your key order (JSONSerialization would sort or shuffle keys),
/// after checking it's valid.
func formatJSON(_ text: String, minify: Bool = false) -> FormatResult {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = t.data(using: .utf8) else { return .error("Not text") }
    do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
        let detail = (error as NSError).userInfo["NSDebugDescription"] as? String ?? error.localizedDescription
        let at = lineColumn(in: detail)
        return .error("Invalid JSON: \(detail)", line: at?.0, column: at?.1)
    }
    var out = "", indent = 0, inString = false, escaped = false
    func newline() { out += "\n" + String(repeating: "  ", count: indent) }
    for ch in t {
        if inString {
            out.append(ch)
            if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            continue
        }
        switch ch {
        case "\"": inString = true; out.append(ch)
        case "{", "[":
            out.append(ch)
            indent += 1
            if !minify { newline() }
        case "}", "]":
            indent -= 1
            if !minify {
                // Empty {} / []: no blank line inside.
                if let last = out.last(where: { !$0.isWhitespace }), last == "{" || last == "[" {
                    while out.last?.isWhitespace == true { out.removeLast() }
                } else { newline() }
            }
            out.append(ch)
        case ",": out.append(ch); if !minify { newline() }
        case ":": out += minify ? ":" : ": "
        case " ", "\n", "\r", "\t": break
        default: out.append(ch)
        }
    }
    return .ok(out)
}

func formatXML(_ text: String) -> FormatResult {
    do {
        let doc = try XMLDocument(xmlString: text, options: [.nodePreserveWhitespace])
        return .ok(doc.xmlString(options: [.nodePrettyPrint]))
    } catch {
        // XMLDocument says what's wrong; XMLParser says where it stopped.
        let p = XMLParser(data: Data(text.utf8))
        _ = p.parse()
        return .error("Invalid XML: \(error.localizedDescription)", line: p.lineNumber > 0 ? p.lineNumber : nil,
                      column: p.columnNumber > 0 ? p.columnNumber : nil)
    }
}

func encodeBase64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

func decodeBase64Text(_ text: String) -> FormatResult {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        .components(separatedBy: .whitespacesAndNewlines).joined()
    while s.count % 4 != 0 { s += "=" }
    guard let data = Data(base64Encoded: s) else { return .error("Not valid Base64") }
    guard let str = String(data: data, encoding: .utf8) else { return .error("Decoded \(data.count) bytes of binary data (not text)") }
    return .ok(str)
}

/// A JWT's header and claims, with exp / iat / nbf in words. The signature isn't checked (that needs the key).
func decodeJWT(_ text: String, now: Date = Date()) -> FormatResult {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return .error("Not a JWT: expected three parts separated by dots, found \(parts.count)") }
    guard case .ok(let header) = decodeBase64Text(String(parts[0])), case .ok(let h) = formatJSON(header) else {
        return .error("The header (first part) isn't Base64URL JSON")
    }
    guard case .ok(let payload) = decodeBase64Text(String(parts[1])), case .ok(let p) = formatJSON(payload) else {
        return .error("The payload (second part) isn't Base64URL JSON")
    }
    var out = "HEADER\n\(h)\n\nPAYLOAD\n\(p)"
    let claims = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
    let rel = RelativeDateTimeFormatter()
    let dates = [("exp", "Expires"), ("iat", "Issued"), ("nbf", "Not before")].compactMap { key, title -> String? in
        guard let t = (claims[key] as? NSNumber)?.doubleValue else { return nil }
        let d = Date(timeIntervalSince1970: t)
        let note = key == "exp" && d < now ? "EXPIRED  " : key == "nbf" && d > now ? "NOT YET VALID  " : ""
        return "\(title.padding(toLength: 11, withPad: " ", startingAt: 0)) \(note)\(d.formatted(date: .abbreviated, time: .standard)) (\(rel.localizedString(for: d, relativeTo: now)))"
    }
    if !dates.isEmpty { out += "\n\nDATES\n" + dates.joined(separator: "\n") }
    return .ok(out + "\n\nSignature not checked: that needs the signing key.")
}

/// Percent-decoding (+ counts as a space, as in forms); a full URL also gets its parts and query listed.
func decodeURL(_ text: String) -> FormatResult {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let decoded = t.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
        return .error("Invalid percent-encoding: a % must be followed by two hex digits")
    }
    guard let c = URLComponents(string: t), c.host != nil || !(c.queryItems ?? []).isEmpty else { return .ok(decoded) }
    var lines = [decoded, "", "PARTS"]
    if let v = c.scheme { lines.append("scheme    \(v)") }
    if let v = c.host { lines.append("host      \(v)") }
    if let v = c.port { lines.append("port      \(v)") }
    if !c.path.isEmpty { lines.append("path      \(c.path)") }
    if let v = c.fragment { lines.append("fragment  \(v)") }
    if let q = c.queryItems, !q.isEmpty {
        lines += ["", "QUERY (\(q.count))"] + q.map { "\($0.name) = \($0.value?.replacingOccurrences(of: "+", with: " ") ?? "")" }
    }
    return .ok(lines.joined(separator: "\n"))
}

/// Encodes everything except letters, digits and - . _ ~ (like JavaScript's encodeURIComponent).
func encodeURL(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
}

/// HTTP Basic auth, either way round: a client ID and secret (`id:secret`, or one per line) become the
/// Authorization header; a header (`Authorization: Basic …`, `Basic …` or the bare Base64) is taken apart.
func basicAuth(_ text: String) -> FormatResult {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var encoded = t
    for prefix in ["authorization:", "basic "] where encoded.lowercased().hasPrefix(prefix) {
        encoded = String(encoded.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
    let lines = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    // Decode: a header, or a single Base64 word that hides "id:secret".
    if encoded != t || (lines.count == 1 && !t.contains(":")) {
        guard let data = Data(base64Encoded: encoded.padding(toLength: (encoded.count + 3) / 4 * 4, withPad: "=", startingAt: 0)),
              let pair = String(data: data, encoding: .utf8), let colon = pair.firstIndex(of: ":") else {
            return .error("Not a Basic auth value: expected Base64 of \"client_id:secret\"")
        }
        return .ok("Client ID   \(pair[..<colon])\nSecret      \(pair[pair.index(after: colon)...])")
    }
    // Encode: "id:secret" (the secret may contain colons) or the two values on two lines.
    let id: String, secret: String
    if lines.count == 2 {
        (id, secret) = (lines[0], lines[1])
    } else if lines.count == 1, let colon = t.firstIndex(of: ":") {
        (id, secret) = (String(t[..<colon]), String(t[t.index(after: colon)...]))
    } else {
        return .error("Paste client_id:secret, or the client ID and the secret on two lines")
    }
    guard !id.contains(":") else { return .error("A client ID can't contain \":\" in Basic auth") }
    let b64 = Data("\(id):\(secret)".utf8).base64EncodedString()
    return .ok("""
    Authorization: Basic \(b64)

    Header value   Basic \(b64)
    Base64         \(b64)
    curl           -H "Authorization: Basic \(b64)"
    """)
}

/// One line each: a Unix time (seconds, ms, µs or ns, told apart by size) or a date, shown every common way.
func convertTimes(_ text: String, now: Date = Date(), zone: TimeZone = .current) -> FormatResult {
    let iso = ISO8601DateFormatter(), isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map { f -> DateFormatter in
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = zone; d.dateFormat = f
        return d
    }
    let local = DateFormatter()
    local.timeZone = zone; local.dateFormat = "EEE d MMM yyyy, HH:mm:ss zzz"
    let rel = RelativeDateTimeFormatter()
    var out: [String] = []
    for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { continue }
        let date: Date
        if let n = Double(s) {
            let a = abs(n)
            date = Date(timeIntervalSince1970: a >= 1e17 ? n / 1e9 : a >= 1e14 ? n / 1e6 : a >= 1e11 ? n / 1e3 : n)
        } else if let d = isoFrac.date(from: s) ?? iso.date(from: s) ?? plain.lazy.compactMap({ $0.date(from: s) }).first {
            date = d
        } else {
            return .error("Line \(i + 1): not a Unix time or a date like 2026-10-16 14:30 / 2026-10-16T09:00:00Z", line: i + 1)
        }
        let unix = date.timeIntervalSince1970
        out.append("""
        \(s)
          UTC     \(iso.string(from: date))
          Local   \(local.string(from: date))
          Unix    \(Int64(unix.rounded(.down))) s   \(Int64((unix * 1000).rounded())) ms
          \(rel.localizedString(for: date, relativeTo: now))
        """)
    }
    return .ok(out.joined(separator: "\n\n"))
}

/// CSV with quotes, escaped quotes ("") and line breaks inside quotes. Delimiter: , ; or tab (whichever the
/// first line uses most).
func parseCSV(_ text: String) -> [[String]] {
    let firstLine = text.prefix { $0 != "\n" }
    let delimiter: Character = [",", ";", "\t"].max { a, b in
        firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
    } ?? ","
    var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
    var chars = Array(text)
    if chars.last != "\n" { chars.append("\n") }
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if quoted {
            if c == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
            } else { field.append(c) }
        } else if c == "\"" {
            quoted = true
        } else if c == delimiter {
            row.append(field); field = ""
        } else if c == "\n" || c == "\r\n" {
            row.append(field); field = ""
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        } else if c != "\r" {
            field.append(c)
        }
        i += 1
    }
    return rows
}

// MARK: - JSON tree (keeps key order, for the collapsible view)

indirect enum JNode: Equatable {
    case object([JMember]), array([JNode]), string(String), number(String), bool(Bool), null
    var isContainer: Bool { if case .object = self { true } else if case .array = self { true } else { false } }
}

struct JMember: Equatable { let name: String; let value: JNode }

/// Small recursive-descent parser; call only on JSON that JSONSerialization already accepted.
func parseJSONTree(_ text: String) -> JNode? {
    let b = Array(text.utf8)
    var i = 0
    func ws() { while i < b.count, [0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 } }
    func str() -> String? {
        let start = i
        i += 1
        while i < b.count, b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
        i += 1
        // Let JSONSerialization decode the escapes (\n, \u00e9 ...) of this one string.
        let raw = Data(b[start..<min(i, b.count)])
        return (try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)) as? String
    }
    func value() -> JNode? {
        ws()
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [JMember] = []
            ws(); if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object([]) }
            while i < b.count {
                ws(); guard let n = str() else { return nil }
                ws(); i += 1 // the colon
                guard let v = value() else { return nil }
                members.append(JMember(name: n, value: v))
                ws(); if i < b.count, b[i] == UInt8(ascii: ",") { i += 1; continue }
                i += 1; break // the closing brace
            }
            return .object(members)
        case UInt8(ascii: "["):
            i += 1
            var items: [JNode] = []
            ws(); if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array([]) }
            while i < b.count {
                guard let v = value() else { return nil }
                items.append(v)
                ws(); if i < b.count, b[i] == UInt8(ascii: ",") { i += 1; continue }
                i += 1; break // the closing bracket
            }
            return .array(items)
        case UInt8(ascii: "\""): return str().map(JNode.string)
        case UInt8(ascii: "t"): i += 4; return .bool(true)
        case UInt8(ascii: "f"): i += 5; return .bool(false)
        case UInt8(ascii: "n"): i += 4; return .null
        default:
            let start = i
            while i < b.count, "+-0123456789.eE".utf8.contains(b[i]) { i += 1 }
            return .number(String(decoding: b[start..<i], as: UTF8.self))
        }
    }
    return value()
}

/// The tree as JSON text again, in its own key order (2-space indent, like formatJSON).
func jsonText(_ n: JNode, minify: Bool = false, depth: Int = 0) -> String {
    let pad = minify ? "" : "\n" + String(repeating: "  ", count: depth + 1)
    let end = minify ? "" : "\n" + String(repeating: "  ", count: depth)
    func quoted(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
    switch n {
    case .object(let m) where !m.isEmpty:
        return "{" + m.map { pad + quoted($0.name) + (minify ? ":" : ": ") + jsonText($0.value, minify: minify, depth: depth + 1) }
            .joined(separator: ",") + end + "}"
    case .array(let a) where !a.isEmpty:
        return "[" + a.map { pad + jsonText($0, minify: minify, depth: depth + 1) }.joined(separator: ",") + end + "]"
    case .object: return "{}"
    case .array: return "[]"
    case .string(let v): return quoted(v)
    case .number(let v): return v
    case .bool(let v): return v ? "true" : "false"
    case .null: return "null"
    }
}

/// JSON.parse for stringified JSON: `"{\"a\":1}"`, or the same without its outer quotes as logs print it
/// (`{\"a\":1}`), becomes `{"a":1}`; double-stringified text is unwrapped again. nil if it isn't stringified JSON.
func unwrapStringified(_ text: String) -> String? {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines), changed = false
    for _ in 0..<5 {
        let quoted = t.hasPrefix("\"") ? t : t.contains("\\\"") ? "\"" + t + "\"" : nil
        guard let q = quoted, let s = (try? JSONSerialization.jsonObject(with: Data(q.utf8), options: .fragmentsAllowed)) as? String else { break }
        let inner = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = inner.first, "{[\"".contains(first),
              (try? JSONSerialization.jsonObject(with: Data(inner.utf8), options: .fragmentsAllowed)) != nil else { break }
        t = inner
        changed = true
    }
    return changed ? t : nil
}

/// String values that hold a JSON object or array (stringified or not), parsed into the tree.
func parsingNested(_ n: JNode) -> JNode {
    switch n {
    case .object(let m): return .object(m.map { JMember(name: $0.name, value: parsingNested($0.value)) })
    case .array(let a): return .array(a.map(parsingNested))
    case .string(let v):
        let t = unwrapStringified(v) ?? v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("["), (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil,
              let inner = parseJSONTree(t) else { return n }
        return parsingNested(inner)
    default: return n
    }
}

/// Every object's keys A to Z, all the way down.
func sortingKeys(_ n: JNode) -> JNode {
    switch n {
    case .object(let m): .object(m.sorted { $0.name < $1.name }.map { JMember(name: $0.name, value: sortingKeys($0.value)) })
    case .array(let a): .array(a.map(sortingKeys))
    default: n
    }
}

/// What changed between two JSON documents by path (key order and layout don't count):
/// removed and added keys, and changed values as a removed / added pair.
func diffJSON(_ a: JNode, _ b: JNode, path: String = "$") -> [DiffLine] {
    func line(_ kind: DiffLine.Kind, _ p: String, _ n: JNode) -> DiffLine {
        let t = jsonText(n, minify: true)
        return DiffLine(kind: kind, text: "\(p): \(t.count > 160 ? t.prefix(157) + "..." : t)", left: nil, right: nil)
    }
    switch (a, b) {
    case (.object(let x), .object(let y)):
        let ys = Dictionary(y.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 }), xs = Set(x.map(\.name))
        return x.flatMap { m in ys[m.name].map { diffJSON(m.value, $0, path: path + jsonKey(m.name)) } ?? [line(.removed, path + jsonKey(m.name), m.value)] }
            + y.filter { !xs.contains($0.name) }.map { line(.added, path + jsonKey($0.name), $0.value) }
    case (.array(let x), .array(let y)):
        return (0..<max(x.count, y.count)).flatMap { i -> [DiffLine] in
            let p = path + "[\(i)]"
            return i >= y.count ? [line(.removed, p, x[i])] : i >= x.count ? [line(.added, p, y[i])] : diffJSON(x[i], y[i], path: p)
        }
    default:
        return a == b ? [] : [line(.removed, path, a), line(.added, path, b)]
    }
}

/// One visible line of the JSON or XML tree.
struct TreeRow: Identifiable {
    enum Kind {
        case open(Character, summary: String, collapsed: Bool), close(Character), leaf(JNode)
        case tagOpen(String, attrs: String, summary: String, collapsed: Bool), tagClose(String)
        case tagLeaf(String, attrs: String, text: String?), text(String)
    }
    let id: String      // path: $.items[2].name or /root/item[2] (plus "/" for closing rows)
    let depth: Int
    let label: String?
    let kind: Kind
    let comma: Bool
    /// What the line shows, for Copy Value.
    enum Source { case json(JNode), xml(XMLNode) }
    var source: Source? = nil

    var closes: Bool {
        switch kind {
        case .close, .tagClose: true
        default: false
        }
    }
    /// The words Find looks in: key and value, tag, attributes and text.
    var searchText: String {
        switch kind {
        case .open, .close, .tagClose: label ?? ""
        case .leaf(let n): (label ?? "") + " " + jsonText(n)
        case .tagOpen(let n, let a, _, _): n + a
        case .tagLeaf(let n, let a, let t): n + a + " " + (t ?? "")
        case .text(let t): t
        }
    }
    /// The line's whole value: a string as plain text, an object / array as JSON, an element as XML.
    var value: String? {
        switch source {
        case .json(.string(let v)): v
        case .json(let n): jsonText(n)
        case .xml(let x): x.xmlString(options: .nodePrettyPrint)
        case nil: nil
        }
    }

    /// Collapsed state for rows that can fold; nil for the rest.
    var folded: Bool? {
        switch kind {
        case .open(_, _, let c), .tagOpen(_, _, _, let c): c
        default: nil
        }
    }
    /// The JSONPath / XPath worth copying (not for closing brackets or loose text).
    var path: String? {
        switch kind {
        case .close, .tagClose, .text: nil
        default: id
        }
    }
}

/// `.name`, or `["odd.key"]` when the key isn't a plain identifier (also keeps row ids unique).
private func jsonKey(_ k: String) -> String {
    k.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
        ? "." + k : "[\"" + k.replacingOccurrences(of: "\"", with: "\\\"") + "\"]"
}

func treeRows(_ node: JNode, collapsed: Set<String>, label: String? = nil, path: String = "$", depth: Int = 0, comma: Bool = false) -> [TreeRow] {
    guard node.isContainer else { return [TreeRow(id: path, depth: depth, label: label, kind: .leaf(node), comma: comma, source: .json(node))] }
    var kids: [(String?, String, JNode)] = []
    var isObject = false
    if case .object(let m) = node { isObject = true; kids = m.map { ($0.name, path + jsonKey($0.name), $0.value) } }
    if case .array(let a) = node { kids = a.enumerated().map { (nil, path + "[\($0.offset)]", $0.element) } }
    let noun = isObject ? "key" : "item"
    let summary = "\(kids.count) \(noun)\(kids.count == 1 ? "" : "s")"
    let shut = collapsed.contains(path)
    var rows = [TreeRow(id: path, depth: depth, label: label, kind: .open(isObject ? "{" : "[", summary: summary, collapsed: shut), comma: shut && comma, source: .json(node))]
    guard !shut else { return rows }
    for (n, kid) in kids.enumerated() {
        rows += treeRows(kid.2, collapsed: collapsed, label: kid.0, path: kid.1, depth: depth + 1, comma: n < kids.count - 1)
    }
    rows.append(TreeRow(id: path + "/", depth: depth, label: nil, kind: .close(isObject ? "}" : "]"), comma: comma))
    return rows
}

/// XML as rows: elements fold, an element holding only text is one line, comments and mixed text get their own line.
func xmlRows(_ e: XMLElement, collapsed: Set<String>, path: String? = nil, depth: Int = 0) -> [TreeRow] {
    func squash(_ t: String) -> String {
        t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    let name = e.name ?? ""
    let path = path ?? "/" + name
    let attrs = (e.attributes ?? []).map { " \($0.name ?? "")=\"\($0.stringValue ?? "")\"" }.joined()
    let kids = (e.children ?? []).filter { $0.kind != .text || !squash($0.stringValue ?? "").isEmpty }
    if kids.count <= 1, kids.allSatisfy({ $0.kind == .text }) {
        return [TreeRow(id: path, depth: depth, label: nil, kind: .tagLeaf(name, attrs: attrs, text: kids.first.map { squash($0.stringValue ?? "") }), comma: false, source: .xml(e))]
    }
    let shut = collapsed.contains(path)
    let summary = "\(kids.count) child\(kids.count == 1 ? "" : "ren")"
    var rows = [TreeRow(id: path, depth: depth, label: nil, kind: .tagOpen(name, attrs: attrs, summary: summary, collapsed: shut), comma: false, source: .xml(e))]
    guard !shut else { return rows }
    var seen: [String: Int] = [:]
    for (i, kid) in kids.enumerated() {
        if let child = kid as? XMLElement {
            let n = child.name ?? ""
            seen[n, default: 0] += 1
            rows += xmlRows(child, collapsed: collapsed, path: path + "/" + n + "[\(seen[n]!)]", depth: depth + 1)
        } else {
            let t = kid.kind == .comment ? "<!-- \(squash(kid.stringValue ?? "")) -->" : squash(kid.stringValue ?? "")
            rows.append(TreeRow(id: path + "#\(i)", depth: depth + 1, label: nil, kind: .text(t), comma: false, source: .xml(kid)))
        }
    }
    rows.append(TreeRow(id: path + "/", depth: depth, label: nil, kind: .tagClose(name), comma: false))
    return rows
}

// MARK: - Compare (line diff)

struct DiffLine: Equatable {
    enum Kind { case same, removed, added }
    let kind: Kind
    let text: String
    let left: Int?   // line number in the first text
    let right: Int?  // line number in the second text
}

/// Line-by-line differences, in reading order (Swift's Myers diff).
func diffLines(_ a: String, _ b: String, ignoreWhitespace: Bool = false) -> [DiffLine] {
    let la = a.components(separatedBy: "\n"), lb = b.components(separatedBy: "\n")
    func key(_ s: String) -> String { ignoreWhitespace ? s.filter { !$0.isWhitespace } : s }
    let diff = lb.map(key).difference(from: la.map(key))
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in diff {
        switch change {
        case .remove(let o, _, _): removed.insert(o)
        case .insert(let o, _, _): inserted.insert(o)
        }
    }
    var out: [DiffLine] = [], i = 0, j = 0
    while i < la.count || j < lb.count {
        if i < la.count, removed.contains(i) {
            out.append(DiffLine(kind: .removed, text: la[i], left: i + 1, right: nil)); i += 1
        } else if j < lb.count, inserted.contains(j) {
            out.append(DiffLine(kind: .added, text: lb[j], left: nil, right: j + 1)); j += 1
        } else if i < la.count, j < lb.count {
            out.append(DiffLine(kind: .same, text: lb[j], left: i + 1, right: j + 1)); i += 1; j += 1
        } else { break }
    }
    return out
}

/// Highlights for one side of the side-by-side compare: changed lines (1-based) and, inside a line that
/// was edited rather than added or removed, the part that differs (UTF-16 range within the line).
struct DiffMarks: Equatable {
    var lines: Set<Int> = []
    var spans: [Int: NSRange] = [:]
}

/// Removed lines go left, added lines right. A run of removed lines followed by added ones counts as
/// edited line by line, so the differing middle of each pair (after the shared start and end) is marked.
func diffMarks(_ d: [DiffLine]) -> (left: DiffMarks, right: DiffMarks) {
    var left = DiffMarks(), right = DiffMarks()
    var i = 0
    while i < d.count {
        var removed: [DiffLine] = [], added: [DiffLine] = []
        while i < d.count, d[i].kind == .removed { removed.append(d[i]); i += 1 }
        while i < d.count, d[i].kind == .added { added.append(d[i]); i += 1 }
        if removed.isEmpty && added.isEmpty { i += 1; continue }
        removed.forEach { left.lines.insert($0.left!) }
        added.forEach { right.lines.insert($0.right!) }
        for (r, a) in zip(removed, added) {
            let x = Array(r.text.utf16), y = Array(a.text.utf16)
            var pre = 0
            while pre < min(x.count, y.count), x[pre] == y[pre] { pre += 1 }
            var suf = 0
            while suf < min(x.count, y.count) - pre, x[x.count - 1 - suf] == y[y.count - 1 - suf] { suf += 1 }
            left.spans[r.left!] = NSRange(location: pre, length: x.count - pre - suf)
            right.spans[a.right!] = NSRange(location: pre, length: y.count - pre - suf)
        }
    }
    return (left, right)
}

// MARK: - Markdown (blocks: headings, lists, quotes, code, rules; inline via Foundation)

struct MarkdownView: View {
    let text: String
    @Environment(\.theme) var theme

    private enum Block { case heading(Int, String), bullet(String, String), quote(String), code(String), rule, paragraph(String) }

    private var blocks: [Block] {
        var out: [Block] = [], para: [String] = [], code: [String]? = nil
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[h] == " ", line.distance(from: line.startIndex, to: h) <= 6 {
                flush(); out.append(.heading(line.distance(from: line.startIndex, to: h), String(line[h...]).trimmingCharacters(in: .whitespaces)))
            } else if ["---", "***", "___"].contains(line) {
                flush(); out.append(.rule)
            } else if line.hasPrefix("> ") {
                flush(); out.append(.quote(String(line.dropFirst(2))))
            } else if let m = line.range(of: #"^([-*+]|\d+\.)\s+"#, options: .regularExpression) {
                flush()
                let marker = line[m].trimmingCharacters(in: .whitespaces)
                out.append(.bullet(marker.first?.isNumber == true ? marker : "•", String(line[m.upperBound...])))
            } else {
                para.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let level, let s):
                    inline(s).font(.system(size: [0, 22, 18, 15, 13, 12, 12][level], weight: .bold)).foregroundStyle(theme.text)
                case .bullet(let marker, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(theme.secondary)
                        inline(s).foregroundStyle(theme.text)
                    }
                case .quote(let s):
                    inline(s).italic().foregroundStyle(theme.secondary)
                        .padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(theme.accent).frame(width: 3) }
                case .code(let s):
                    Text(s).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.background, in: RoundedRectangle(cornerRadius: 6)) // stands out on the tile
                case .rule:
                    Divider()
                case .paragraph(let s):
                    inline(s).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Generators and hashes (the system's secure random source; nothing is stored)

func randomBytes(_ count: Int) -> Data {
    var d = Data(count: max(count, 1))
    let status = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
    precondition(status == errSecSuccess, "secure random source unavailable") // never hand out weak "random" keys
    return d
}

struct GeneratorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The character kinds a password draws from, after exclusions, each with its minimum count.
func passwordSets(_ o: PasswordOptions) -> [(chars: [Character], min: Int)] {
    let drop = Set(o.exclude + (o.avoidSimilar ? "0O1lIo" : ""))
    let kinds: [(Bool, String, Int)] = [(o.upper, "ABCDEFGHIJKLMNOPQRSTUVWXYZ", o.minUpper), (o.lower, "abcdefghijklmnopqrstuvwxyz", o.minLower),
                                        (o.digits, "0123456789", o.minDigits), (o.symbols, o.symbolSet, o.minSymbols)]
    return kinds.filter(\.0).map { (Array(Set($0.1)).filter { !drop.contains($0) }.sorted(), max($0.2, 0)) }
}

/// The required characters of each kind first, the rest from all allowed characters, then a secure shuffle,
/// so the minimums never make positions predictable. Picks are uniform (no modulo bias).
func generatePassword(length: Int, options o: PasswordOptions = PasswordOptions()) throws -> String {
    let sets = passwordSets(o)
    guard !sets.isEmpty else { throw GeneratorError(message: "Pick at least one kind of character") }
    guard sets.allSatisfy({ !$0.chars.isEmpty }) else {
        throw GeneratorError(message: "Your exclusions leave a chosen kind with no characters")
    }
    let required = sets.reduce(0) { $0 + $1.min }
    guard required <= length else {
        throw GeneratorError(message: "The minimums add up to \(required) characters, more than the length \(length)")
    }
    var rng = SystemRandomNumberGenerator() // the system's cryptographic generator
    var chars = sets.flatMap { set in (0..<set.min).map { _ in set.chars.randomElement(using: &rng)! } }
    let all = sets.flatMap(\.chars)
    while chars.count < length { chars.append(all.randomElement(using: &rng)!) }
    chars.shuffle(using: &rng)
    return String(chars)
}

/// Bits of strength of a random password over `alphabet` characters.
func passwordBits(length: Int, alphabet: Int) -> Int { Int((Double(length) * log2(Double(max(alphabet, 2)))).rounded(.down)) }

func pem(_ der: Data, _ label: String) -> String {
    "-----BEGIN \(label)-----\n" + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        + "\n-----END \(label)-----"
}

enum SecretKind: String, CaseIterable, Identifiable {
    case password = "Password", aes = "AES key", hmac = "HMAC key", chacha = "ChaCha20-Poly1305 key"
    case bytes = "Random bytes", uuid = "UUID", ed25519 = "Ed25519 key pair", p256 = "P-256 (ECDSA) key pair", rsa = "RSA key pair"
    var id: String { rawValue }

    /// Sizes to pick from: characters (password), bytes (random bytes) or bits (keys). Empty: fixed size.
    var sizes: [Int] {
        switch self {
        case .password: [12, 16, 20, 24, 32, 48, 64]
        case .aes: [128, 192, 256]
        case .hmac: [256, 384, 512]
        case .bytes: [16, 24, 32, 48, 64]
        case .rsa: [2048, 3072, 4096]
        case .chacha, .uuid, .ed25519, .p256: []
        }
    }
    var defaultSize: Int {
        switch self {
        case .password: 20
        case .aes, .hmac: 256
        case .bytes: 32
        case .rsa: 3072
        default: 0
        }
    }
    var unit: String {
        switch self {
        case .password: "characters"
        case .bytes: "bytes"
        default: "bits"
        }
    }
}

struct Generated: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let value: String
}

struct PasswordOptions: Equatable {
    var upper = true, lower = true, digits = true, symbols = true, avoidSimilar = false
    /// At least this many of each kind (only for kinds that are on).
    var minUpper = 1, minLower = 1, minDigits = 1, minSymbols = 1
    /// Characters never used, e.g. ones a website rejects.
    var exclude = ""
    var symbolSet = "!@#$%^&*()-_=+[]{};:,.?/~"
}

func generateSecrets(_ kind: SecretKind, size: Int, count: Int = 1, options: PasswordOptions = PasswordOptions()) throws -> [Generated] {
    func hexKey(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    func key(_ name: String, bytes: Int) -> [Generated] {
        let d = randomBytes(bytes)
        return [Generated(title: "\(name) · hex", value: hexKey(d)), Generated(title: "\(name) · Base64", value: d.base64EncodedString())]
    }
    switch kind {
    case .password:
        let alphabet = Set(passwordSets(options).flatMap(\.chars)).count
        return try (0..<count).map { _ in
            let p = try generatePassword(length: size, options: options)
            return Generated(title: "Password · \(size) characters · ~\(passwordBits(length: size, alphabet: alphabet)) bits", value: p)
        }
    case .aes: return key("AES-\(size)", bytes: size / 8)
    case .hmac: return key("HMAC-SHA\(size) (\(size / 8) bytes)", bytes: size / 8)
    case .chacha: return key("ChaCha20-Poly1305 (256 bits)", bytes: 32)
    case .bytes:
        let d = randomBytes(size)
        let b64url = d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return [Generated(title: "\(size) bytes · hex", value: hexKey(d)), Generated(title: "\(size) bytes · Base64", value: d.base64EncodedString()),
                Generated(title: "\(size) bytes · Base64URL", value: b64url)]
    case .uuid:
        return (0..<count).map { _ in Generated(title: "UUID v4", value: UUID().uuidString.lowercased()) }
    case .ed25519:
        let k = Curve25519.Signing.PrivateKey()
        // PKCS#8 / SubjectPublicKeyInfo wrappers for Ed25519 (RFC 8410), so tools like openssl read them.
        let priv = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]) + k.rawRepresentation
        let pub = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]) + k.publicKey.rawRepresentation
        return [Generated(title: "Ed25519 private key (PKCS#8)", value: pem(priv, "PRIVATE KEY")),
                Generated(title: "Ed25519 public key", value: pem(pub, "PUBLIC KEY"))]
    case .p256:
        let k = P256.Signing.PrivateKey()
        return [Generated(title: "P-256 private key (PKCS#8)", value: k.pemRepresentation),
                Generated(title: "P-256 public key", value: k.publicKey.pemRepresentation)]
    case .rsa:
        var error: Unmanaged<CFError>?
        let attrs = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: size] as CFDictionary // not kept in the Keychain
        guard let k = SecKeyCreateRandomKey(attrs, &error), let pubKey = SecKeyCopyPublicKey(k),
              let priv = SecKeyCopyExternalRepresentation(k, &error) as Data?,
              let pub = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
            throw error.map { $0.takeRetainedValue() as Error } ?? NSError(domain: "Generator", code: 2)
        }
        return [Generated(title: "RSA-\(size) private key (PKCS#1)", value: pem(priv, "RSA PRIVATE KEY")),
                Generated(title: "RSA-\(size) public key (PKCS#1)", value: pem(pub, "RSA PUBLIC KEY"))]
    }
}

/// Common digests of the text exactly as typed (a trailing newline changes every hash).
func hashes(_ text: String) -> FormatResult {
    let d = Data(text.utf8)
    func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
    return .ok("""
    MD5       \(hex(Insecure.MD5.hash(data: d)))
    SHA-1     \(hex(Insecure.SHA1.hash(data: d)))
    SHA-256   \(hex(SHA256.hash(data: d)))
    SHA-384   \(hex(SHA384.hash(data: d)))
    SHA-512   \(hex(SHA512.hash(data: d)))

    \(d.count) bytes of UTF-8. MD5 and SHA-1 are fine for checksums, not for passwords or signatures.
    """)
}

@MainActor
final class GeneratorModel: ObservableObject {
    static let shared = GeneratorModel()
    @Published var kind = SecretKind.password { didSet { size = kind.defaultSize; generate() } }
    @Published var size = 20 { didSet { generate() } }
    @Published var count = 3 { didSet { generate() } }
    @Published var options = PasswordOptions() { didSet { generate() } }
    @Published private(set) var results: [Generated] = []
    @Published private(set) var working = false
    @Published private(set) var problem: String?
    @Published private(set) var copiedID: UUID?

    /// RSA keys take a moment (4096 bits: a second or two), so everything is made off the main thread.
    func generate() {
        let (kind, size, count, options) = (kind, size, count, options)
        working = true
        Task.detached {
            let result = Result { try generateSecrets(kind, size: size, count: count, options: options) }
            await MainActor.run {
                guard kind == self.kind, size == self.size else { return } // settings changed meanwhile: a newer run follows
                self.working = false
                switch result {
                case .success(let r): self.results = r; self.problem = nil
                case .failure(let e): self.results = []; self.problem = e.localizedDescription
                }
            }
        }
    }

    /// Hidden from clipboard histories; the row says "Copied" for a moment.
    func copy(_ r: Generated) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        pb.setString(r.value, forType: .string)
        pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        copiedID = r.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.copiedID == r.id { self?.copiedID = nil }
        }
    }
}

struct GeneratorView: View {
    @ObservedObject var g = GeneratorModel.shared
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("Type", selection: $g.kind) { ForEach(SecretKind.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                if g.kind == .password {
                    Stepper("Length \(g.size)", value: $g.size, in: 4...128).fixedSize()
                } else if !g.kind.sizes.isEmpty {
                    Picker("Size", selection: $g.size) {
                        ForEach(g.kind.sizes, id: \.self) { Text("\($0) \(g.kind.unit)").tag($0) }
                    }
                    .fixedSize()
                }
                if g.kind == .password || g.kind == .uuid {
                    Stepper("\(g.count) at once", value: $g.count, in: 1...10).fixedSize()
                }
                Spacer()
                if g.working { ProgressView().controlSize(.small) }
                Button { g.generate() } label: { Label("Generate Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).keyboardShortcut("r")
            }
            if g.kind == .password {
                // One row per kind: use it at all, and at least how many.
                HStack(spacing: 18) {
                    kind("A–Z", $g.options.upper, $g.options.minUpper)
                    kind("a–z", $g.options.lower, $g.options.minLower)
                    kind("0–9", $g.options.digits, $g.options.minDigits)
                    kind("Symbols", $g.options.symbols, $g.options.minSymbols)
                    Toggle("Avoid look-alikes (0 O 1 l I)", isOn: $g.options.avoidSimilar).toggleStyle(.checkbox).fixedSize()
                }
                HStack(spacing: 10) {
                    Text("Symbols").foregroundStyle(theme.secondary)
                    TextField("Symbols to use", text: $g.options.symbolSet)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 230)
                        .disabled(!g.options.symbols)
                    Text("Exclude").foregroundStyle(theme.secondary)
                    TextField("Characters never to use, e.g. \"'`\\", text: $g.options.exclude)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 230)
                    Button("Reset") { g.options = PasswordOptions() }.buttonStyle(.borderless)
                }
            }
            if let p = g.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(g.results) { r in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.title).font(.caption).foregroundStyle(theme.secondary)
                                Text(r.value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button { g.copy(r) } label: {
                                Label(g.copiedID == r.id ? "Copied" : "Copy", systemImage: g.copiedID == r.id ? "checkmark" : "doc.on.doc")
                                    .frame(minWidth: 64)
                            }
                            .buttonStyle(.bordered).tint(g.copiedID == r.id ? .green : nil)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.tile, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Text("Made on this Mac from the system's secure random generator. Nothing is saved or sent; copies are hidden from clipboard histories.")
                .font(.caption).foregroundStyle(theme.secondary)
        }
        .onAppear { if g.results.isEmpty { g.generate() } }
    }

    /// A kind of character: on/off, and the minimum count while it's on.
    private func kind(_ title: String, _ on: Binding<Bool>, _ minimum: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Toggle(title, isOn: on).toggleStyle(.checkbox)
            if on.wrappedValue {
                Stepper("min \(minimum.wrappedValue)", value: minimum, in: 0...32)
                    .font(.caption).foregroundStyle(theme.secondary)
            }
        }
        .fixedSize()
    }
}

// MARK: - Viewer model

enum ViewerMode: String, CaseIterable, Identifiable {
    case json = "JSON", xml = "XML", base64 = "Base64", jwt = "JWT", url = "URL", time = "Time", auth = "Basic Auth", hash = "Hash", generate = "Generate"
    case csv = "CSV", markdown = "Markdown", compare = "Compare"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .json: "curlybraces"
        case .xml: "chevron.left.forwardslash.chevron.right"
        case .base64: "number"
        case .jwt: "key.horizontal"
        case .url: "link"
        case .time: "clock"
        case .auth: "person.badge.key"
        case .hash: "checkmark.seal"
        case .generate: "dice"
        case .csv: "tablecells"
        case .markdown: "text.document"
        case .compare: "arrow.left.arrow.right"
        }
    }

    static let tabs: [ViewerMode] = [.json, .xml, .csv, .markdown, .compare]
    static let converters: [ViewerMode] = [.generate, .hash, .base64, .jwt, .auth, .url, .time]

    /// Menu titles for the converters.
    var title: String {
        switch self {
        case .base64: "Base64 encode / decode"
        case .jwt: "JWT decode"
        case .url: "URL encode / decode"
        case .time: "Unix time ↔ date"
        case .auth: "Basic Auth ↔ client ID + secret"
        case .hash: "Hash (MD5, SHA-1, SHA-256, SHA-512)"
        case .generate: "Password & Key Generator"
        default: rawValue
        }
    }

    /// What to paste, shown in the empty editor.
    var placeholder: String {
        switch self {
        case .json: "Paste JSON (also stringified JSON), or open a file with the folder button"
        case .xml: "Paste XML, or open a file"
        case .base64: "Paste Base64 to decode, or text to encode"
        case .jwt: "Paste a JWT (eyJ…)"
        case .url: "Paste a URL or percent-encoded text"
        case .time: "Paste Unix times or dates, one per line (or press Now)"
        case .auth: "client_id:secret (or ID and secret on two lines) to make a header, or a Basic header to decode"
        case .hash: "Text to hash, exactly as typed (a trailing newline changes the hash)"
        case .generate: ""
        case .csv: "Paste CSV or TSV, or open a file"
        case .markdown: "Paste Markdown, or open a file"
        case .compare: "Paste text"
        }
    }

    static func forFile(_ url: URL) -> ViewerMode? {
        switch url.pathExtension.lowercased() {
        case "json", "geojson": .json
        case "xml", "plist", "svg", "xsd", "pom": .xml
        case "csv", "tsv": .csv
        case "md", "markdown": .markdown
        case "b64", "base64": .base64
        case "jwt": .jwt
        default: nil
        }
    }
}

/// Text being viewed (no @State without Xcode's macro plugin).
@MainActor
final class ViewerModel: ObservableObject {
    static let shared = ViewerModel()
    @Published var mode: ViewerMode = .json { didSet { run() } }
    @Published var input = "" { didSet { run() } }
    @Published private(set) var output = ""
    @Published private(set) var error: String?
    @Published private(set) var errorLine: Int?
    @Published private(set) var errorColumn: Int?
    /// Compare: the second text, options and result.
    @Published var inputB = "" { didSet { run() } }
    @Published var ignoreWhitespace = false { didSet { run() } }
    @Published private(set) var marks = (left: DiffMarks(), right: DiffMarks())

    /// Compare: lays both sides out as JSON, in place, so layout differences don't count.
    func formatBothAsJSON() {
        if case .ok(let a) = formatJSON(input) { input = a }
        if case .ok(let b) = formatJSON(inputB) { inputB = b }
    }
    @Published private(set) var diff: [DiffLine] = []
    /// JSON and XML: collapsible tree (default) or plain formatted text.
    @Published var showTree = true
    private var tree: JNode?
    private var xmlRoot: XMLElement?
    /// The visible tree lines, rebuilt only when the document or the folding changes.
    @Published private(set) var rows: [TreeRow] = []
    @Published var collapsed: Set<String> = [] { didSet { buildRows() } }
    /// Find in the tree: only matching lines and the lines leading to them.
    @Published var search = "" { didSet { buildRows() } }
    @Published private(set) var hits: Set<String> = []
    /// JSON: keys A to Z (tree and text).
    @Published var sortKeys = false { didSet { run() } }
    /// JSON: string values holding JSON become real objects / arrays.
    @Published var parseNested = true { didSet { run() } }
    /// JSON: the input was stringified JSON and has been unwrapped.
    @Published private(set) var wasStringified = false
    /// Compare: by JSON path instead of by line.
    @Published var structural = false { didSet { run() } }

    private func allRows(collapsed: Set<String>) -> [TreeRow] {
        if let tree { return treeRows(tree, collapsed: collapsed) }
        if let xmlRoot { return xmlRows(xmlRoot, collapsed: collapsed) }
        return []
    }
    var hasTree: Bool { tree != nil || xmlRoot != nil }

    private func buildRows() {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { rows = allRows(collapsed: collapsed); hits = []; return }
        // Everything unfolded, then keep the matches, the lines that open around them and their closing lines.
        let all = allRows(collapsed: [])
        var keep = Set<Int>(), found = Set<String>(), open: [Int] = []
        for (i, r) in all.enumerated() {
            if r.folded != nil { open.append(i) }
            if r.searchText.localizedCaseInsensitiveContains(q) { found.insert(r.id); keep.insert(i); keep.formUnion(open) }
            if r.closes, let o = open.popLast(), keep.contains(o) { keep.insert(i) }
        }
        rows = all.indices.filter(keep.contains).map { all[$0] }
        hits = found
    }

    func expandAll() { collapsed = [] }
    /// Folds everything at `level` and deeper (1 = all but the top).
    func fold(from level: Int) { collapsed = Set(allRows(collapsed: []).filter { $0.folded != nil && $0.depth >= level }.map(\.id)) }

    /// Lines the current result needs, so the panel can size itself to the document.
    var contentLines: Int {
        func lines(_ t: String) -> Int { t.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
        let out: Int
        switch mode {
        case .compare: out = max(lines(input), lines(inputB)) + (structural ? diff.count + 4 : 0)
        case .generate: return GeneratorModel.shared.results.reduce(14) { $0 + lines($1.value) + 3 } // 14: the option rows
        case .csv: out = parseCSV(input).count + 2
        case .markdown: out = Int(Double(lines(input)) * 1.4)
        default: out = lines(output) // the same for Tree and Text, so switching never resizes the window
        }
        return max(lines(input), out)
    }
    /// Base64 and URL: decode (default) or encode.
    @Published var decode = true { didSet { run() } }
    @Published var minify = false { didSet { run() } }
    @Published var title: String?

    func run() {
        error = nil; errorLine = nil; errorColumn = nil
        defer { buildRows() }
        tree = nil; xmlRoot = nil
        if mode == .compare {
            marks = (DiffMarks(), DiffMarks())
            // Wait for both sides: one empty side would just be "everything removed".
            if input.isEmpty || inputB.isEmpty { diff = []; return }
            if structural {
                guard case .ok = formatJSON(input), case .ok = formatJSON(inputB), let a = parseJSONTree(input), let b = parseJSONTree(inputB) else {
                    diff = []; error = "Compare by structure needs valid JSON on both sides"; return
                }
                diff = diffJSON(a, b)
                if diff.isEmpty { diff = [DiffLine(kind: .same, text: "Same data (key order and layout aside)", left: nil, right: nil)] }
                return
            }
            diff = diffLines(input, inputB, ignoreWhitespace: ignoreWhitespace)
            marks = diffMarks(diff)
            return
        }
        guard !input.isEmpty else { output = ""; return }
        var result: FormatResult
        switch mode {
        case .json:
            let unwrapped = unwrapStringified(input)
            wasStringified = unwrapped != nil
            result = formatJSON(unwrapped ?? input, minify: minify)
        case .xml: result = formatXML(input)
        case .base64: result = decode ? decodeBase64Text(input) : .ok(encodeBase64(input))
        case .jwt: result = decodeJWT(input)
        case .url: result = decode ? decodeURL(input) : .ok(encodeURL(input))
        case .time: result = convertTimes(input)
        case .auth: result = basicAuth(input)
        case .hash: result = hashes(input)
        case .generate: result = .ok("") // has its own panel
        case .csv, .markdown, .compare: result = .ok(input) // shown rendered
        }
        if case .ok = result {
            // Past ~2 MB a tree has hundreds of thousands of rows and would freeze the viewer: plain text then.
            if mode == .json, input.utf8.count < 2_000_000, let t = parseJSONTree(unwrapStringified(input) ?? input) {
                var shown = parseNested ? parsingNested(t) : t
                if sortKeys { shown = sortingKeys(shown) }
                tree = shown
                if shown != t { result = .ok(jsonText(shown, minify: minify)) }
            }
            if mode == .xml, input.utf8.count < 2_000_000 { xmlRoot = (try? XMLDocument(xmlString: input))?.rootElement() }
        }
        switch result {
        case .ok(let s): output = s
        case .error(let e, let line, let column): output = ""; error = e; errorLine = line; errorColumn = column
        }
    }

    /// JSON.stringify of the result: one quoted, escaped line to paste into code or a request body.
    func copyStringified() {
        copy(jsonText(.string(tree.map { jsonText($0, minify: true) } ?? output)), note: "Copied as string")
    }

    func copyOutput() { copy(output, note: "Copied") }

    /// Shown in the bottom bar for a moment, right where you clicked, so you know the copy worked.
    @Published private(set) var copied: String?
    private var copiedClear: DispatchWorkItem?

    func copy(_ text: String, note: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if mode == .auth { // holds a secret: clipboard histories (ours too) skip concealed items
            pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
            pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        }
        pb.setString(text, forType: .string)
        copied = note
        copiedClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in self?.copied = nil }
        copiedClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: clear)
    }
}

struct ViewerView: View {
    @ObservedObject var m = ViewerModel.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        let theme = settings.themeColors
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Formats as tabs; the one-shot converters in one menu, so the bar stays short.
                Picker("", selection: Binding<ViewerMode?>(get: { ViewerMode.tabs.contains(m.mode) ? m.mode : nil },
                                                           set: { if let v = $0 { m.mode = v } })) {
                    ForEach(ViewerMode.tabs) { Text($0.rawValue).tag(Optional($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Menu {
                    ForEach(ViewerMode.converters) { c in
                        Button { m.mode = c } label: { Label(c.title, systemImage: c.symbol) }
                    }
                } label: {
                    Label(ViewerMode.converters.contains(m.mode) ? m.mode.rawValue : "Convert", systemImage: "arrow.triangle.2.circlepath")
                }
                .menuStyle(.button).fixedSize()
                .tint(ViewerMode.converters.contains(m.mode) ? .accentColor : nil)
                .help("Base64, JWT, URL and time conversions")
                Spacer()
                if let t = m.title { Text(t).font(.caption).foregroundStyle(theme.secondary).lineLimit(1) }
                Button { if let s = NSPasteboard.general.string(forType: .string) { m.title = nil; m.collapsed = []; m.input = s } } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .help("Paste from clipboard")
                Button { open() } label: { Image(systemName: "folder") }.help("Open a file…")
                Button { NSApp.keyWindow?.close() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction).help("Close (Esc)")
            }
            .buttonStyle(.borderless)
            if m.mode == .generate {
                GeneratorView()
            } else if m.mode == .compare {
                // Original and Changed side by side, differences highlighted where they are.
                VSplitView {
                    HStack(spacing: 8) {
                        diffEditor($m.input, m.marks.left, removed: true, theme, label: "Original").frame(maxWidth: .infinity)
                        diffEditor($m.inputB, m.marks.right, removed: false, theme, label: "Changed").frame(maxWidth: .infinity)
                    }
                    if m.structural { output(theme).frame(minHeight: 100) }
                }
            } else {
                // Two equal halves that never shift as the content changes.
                HStack(spacing: 8) {
                    editor($m.input, theme, label: nil).frame(maxWidth: .infinity, maxHeight: .infinity)
                    output(theme).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack(spacing: 10) {
                options // per-mode options live down here, so the top bar never overflows
                if let e = m.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
                } else if m.mode == .compare, m.input.isEmpty || m.inputB.isEmpty {
                    Text("Paste the original on the left and the changed text on the right.").foregroundStyle(theme.secondary)
                } else if m.mode == .compare, !m.diff.isEmpty {
                    let removed = m.diff.filter { $0.kind == .removed }.count, added = m.diff.filter { $0.kind == .added }.count
                    if removed + added == 0 {
                        Label("Identical", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("\(removed) removed · \(added) added", systemImage: "arrow.left.arrow.right").foregroundStyle(theme.secondary)
                    }
                } else if !m.output.isEmpty, ![.csv, .markdown, .compare, .generate].contains(m.mode) {
                    Label(m.mode == .json && m.wasStringified ? "Valid · unwrapped" : "Valid", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).fixedSize()
                        .help(m.wasStringified ? "The input was stringified JSON (JSON.stringify); shown parsed" : "")
                }
                Spacer()
                if let note = m.copied {
                    Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize().transition(.opacity)
                }
                if ![.csv, .markdown, .compare, .generate].contains(m.mode) {
                    Button { m.copyOutput() } label: {
                        Label(m.copied == "Copied" ? "Copied" : "Copy Result", systemImage: m.copied == "Copied" ? "checkmark" : "doc.on.doc")
                            .frame(minWidth: 96) // same width either way: nothing next to it moves
                    }
                    .disabled(m.output.isEmpty).keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
            .font(.caption)
            .frame(height: 30) // the same in every mode, whatever controls it holds
        }
        .padding(14)
        .frame(minWidth: 640, minHeight: 360)
        .foregroundStyle(theme.text)
        .background(theme.background)
        .environment(\.theme, theme)
    }

    @ViewBuilder private var options: some View {
        switch m.mode {
        case .json, .xml:
            Picker("", selection: $m.showTree) { Text("Tree").tag(true); Text("Text").tag(false) }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            if m.showTree, m.hasTree {
                TextField("Find", text: $m.search).textFieldStyle(.roundedBorder).frame(width: 130)
                if !m.search.isEmpty { Text("\(m.hits.count) found").foregroundStyle(.secondary).fixedSize() }
                Button("Expand All") { m.expandAll() }.buttonStyle(.borderless).fixedSize()
                Menu("Collapse") {
                    Button("All") { m.fold(from: 1) }
                    ForEach(2...4, id: \.self) { n in Button("Below level \(n - 1)") { m.fold(from: n) } }
                } primaryAction: { m.fold(from: 1) }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Click: fold everything. Arrow: keep the first levels open")
            }
            if m.mode == .json {
                Menu {
                    Toggle("Sort Keys A–Z", isOn: $m.sortKeys)
                    Toggle("Parse JSON Inside Strings", isOn: $m.parseNested)
                    Toggle("Minify (Text view)", isOn: $m.minify)
                    Divider()
                    Button("Copy as String (JSON.stringify)") { m.copyStringified() }.disabled(m.output.isEmpty)
                } label: { Label("Options", systemImage: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Sort keys, parse nested JSON, minify, copy as a string")
            }
        case .compare:
            Picker("", selection: $m.structural) { Text("Lines").tag(false); Text("JSON structure").tag(true) }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("JSON structure: compares by path, so key order and layout don't count")
            if !m.structural {
                Toggle("Ignore spaces", isOn: $m.ignoreWhitespace).toggleStyle(.checkbox).fixedSize()
                    .help("Lines that differ only in spaces count as the same")
                Button("Format JSON") { m.formatBothAsJSON() }.buttonStyle(.bordered).fixedSize()
                    .help("Lay out both sides as JSON, so layout differences don't count")
            }
        case .base64, .url:
            Picker("", selection: $m.decode) { Text("Decode").tag(true); Text("Encode").tag(false) }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        case .time:
            Button { m.input = String(Int(Date().timeIntervalSince1970)) } label: { Label("Now", systemImage: "clock") }
                .buttonStyle(.bordered)
                .help("Put the current Unix time in")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func output(_ theme: Theme) -> some View {
        Group {
            switch m.mode {
            case .csv:
                let rows = parseCSV(m.input)
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(Array(rows.prefix(2000).enumerated()), id: \.offset) { i, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell).font(.system(size: 12, weight: i == 0 ? .semibold : .regular)).lineLimit(1).textSelection(.enabled)
                                }
                            }
                            if i == 0 { Divider() }
                        }
                    }
                    .padding(8)
                }
            case .markdown:
                ScrollView { MarkdownView(text: m.input).padding(10) }
            case .compare:
                DiffView(lines: m.diff)
            default:
                if m.showTree, m.hasTree { // only valid JSON / XML has a tree
                    TreeView(rows: m.rows, hits: m.hits, collapsed: $m.collapsed)
                } else if m.error != nil {
                    // Your text with line numbers, the broken line highlighted and a ^ under the spot.
                    NumberedText(text: m.input, highlight: m.errorLine, column: m.errorColumn)
                } else {
                    SelectableText(text: m.output, color: NSColor(theme.text))
                }
            }
        }
        .background(theme.tile, in: RoundedRectangle(cornerRadius: 8))
    }

    private func editor(_ text: Binding<String>, _ theme: Theme, label: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label { Text(label).font(.caption).foregroundStyle(theme.secondary) }
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(m.mode.placeholder).font(.system(size: 12)).foregroundStyle(theme.secondary.opacity(0.7))
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .padding(6)
                .background(theme.tile, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func diffEditor(_ text: Binding<String>, _ marks: DiffMarks, removed: Bool, _ theme: Theme, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(theme.secondary)
            DiffEditor(text: text, marks: marks, tint: removed ? .systemRed : .systemGreen, color: NSColor(theme.text))
                .padding(6)
                .background(theme.tile, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func open() {
        let panel = NSOpenPanel()
        if panel.runModal() == .OK, let url = panel.url { ViewerWindow.shared.open(file: url) }
    }
}

// MARK: - The pop-up under the notch

/// Drops down from the notch. Unlike the island it can take keyboard focus, because you type in it;
/// it only appears when you open it.
final class ViewerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ViewerWindow: NSObject, NSWindowDelegate {
    static let shared = ViewerWindow()
    private var panel: ViewerPanel?
    private var sizeWatch: AnyCancellable?
    static let defaultWidth: CGFloat = 860

    /// Height that fits the document (about 18 pt a line plus the bars), from 320 pt to nearly the screen.
    private func fittedHeight() -> CGFloat {
        let notch = IslandModel.shared.notch
        let maxH = notch.screenFrame.height - notch.height - 60
        return min(max(CGFloat(ViewerModel.shared.contentLines) * 18 + 150, 320), maxH)
    }

    /// Grows or shrinks with the document (expanding the tree, pasting, switching mode); top edge stays put.
    private func fitHeight(animated: Bool) {
        guard let p = panel, p.isVisible else { return }
        let h = fittedHeight()
        guard abs(p.frame.height - h) > 4 else { return }
        var f = p.frame
        f.origin.y = f.maxY - h
        f.size.height = h
        p.setFrame(f, display: true) // in one step: animating a window resize re-lays-out SwiftUI each frame (jitter)
    }

    /// `focus: false` shows it without taking the keyboard (dev snapshots, so your typing never lands in it).
    func open(mode: ViewerMode, text: String?, title: String? = nil, focus: Bool = true) {
        let m = ViewerModel.shared
        m.title = title
        m.mode = mode
        if let text { m.collapsed = []; m.input = text }
        show(focus: focus)
    }

    func open(file url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            IslandModel.shared.show(Peek(icon: .symbol("exclamationmark.triangle"), title: "Can't open as text", subtitle: url.lastPathComponent))
            return
        }
        open(mode: ViewerMode.forFile(url) ?? .json, text: text, title: url.lastPathComponent)
    }

    private func show(focus: Bool = true) {
        if panel == nil {
            let p = ViewerPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 480),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentViewController = NSHostingController(rootView: ViewerView())
            p.delegate = self
            panel = p
        }
        guard let p = panel else { return }
        if sizeWatch == nil {
            // Only new text (or new generated values) resizes the window; switching tabs or Tree/Text doesn't.
            let m = ViewerModel.shared
            sizeWatch = m.$input.map { _ in () }.merge(with: m.$inputB.map { _ in () }, GeneratorModel.shared.$results.map { _ in () })
                .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.fitHeight(animated: true) } }
        }
        // Just under the notch, centred, sliding down from it: default width, height to fit the document.
        let notch = IslandModel.shared.notch
        let size = NSSize(width: p.isVisible ? p.frame.width : Self.defaultWidth, height: fittedHeight())
        let top = notch.screenFrame.maxY - notch.height - 8
        let target = NSRect(x: notch.screenFrame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        if !p.isVisible {
            p.setFrame(target.offsetBy(dx: 0, dy: 24), display: false)
            p.alphaValue = 0
        }
        if focus {
            IslandModel.shared.dismiss() // close the island you clicked in, or it would hover open on top of the viewer
            NSApp.activate(ignoringOtherApps: true)
        }
        p.orderFrontRegardless()
        if focus { p.makeKey() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
    }
}

// MARK: - Tools widget

struct ToolsTile: View {
    @Environment(\.theme) var theme
    @Environment(\.tileSize) var size

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileHeader(symbol: "wrench.and.screwdriver", title: "DEV TOOLBOX")
            ScrollView(showsIndicators: false) { // more tools than a short tile holds
            LazyVGrid(columns: [GridItem(.adaptive(minimum: size.width < 160 ? 28 : 56), spacing: 6)], spacing: 6) {
                ForEach(ViewerMode.allCases) { mode in
                    Button {
                        // Opens with what was there before; the paste button brings in the clipboard when you want it
                        // (a huge copied JSON would otherwise load on its own).
                        ViewerWindow.shared.open(mode: mode, text: nil)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: mode.symbol).font(.system(size: 13))
                            if size.width >= 160, size.height >= 120 { Text(mode.rawValue).font(.system(size: 9)).lineLimit(1) }
                        }
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .padding(.vertical, 3)
                        .background(theme.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("\(mode.rawValue): opens with the clipboard's text")
                }
            }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}


// MARK: - Error and diff views

private struct LineNumber: View {
    let n: Int?
    @Environment(\.theme) var theme
    var body: some View {
        Text(n.map(String.init) ?? "").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(theme.secondary.opacity(0.7)).frame(width: 34, alignment: .trailing)
    }
}

/// The text with line numbers; the problem line is red, with a ^ under the column. Scrolls to it.
struct NumberedText: View {
    let text: String
    let highlight: Int?
    let column: Int?
    @Environment(\.theme) var theme

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        GeometryReader { g in
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let bad = highlight == i + 1
                        HStack(alignment: .top, spacing: 8) {
                            LineNumber(n: i + 1)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced)).fixedSize()
                                if bad, let column {
                                    Text(String(repeating: " ", count: max(column - 1, 0)) + "^")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Color.red).fixedSize()
                                }
                            }
                        }
                        .padding(.vertical, 1).padding(.trailing, 8)
                        .frame(minWidth: g.size.width, alignment: .leading)
                        .background(bad ? Color.red.opacity(0.22) : Color.clear)
                        .id(i + 1)
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .topLeading) // short content starts at the top, not mid-pane
                .textSelection(.enabled)
            }
            .onAppear { if let highlight { proxy.scrollTo(highlight, anchor: .center) } }
            .onChange(of: highlight) { _, h in if let h { withAnimation { proxy.scrollTo(h, anchor: .center) } } }
        }
        }
    }
}

/// Unified diff: − red for removed, + green for added, line numbers of both texts.
struct DiffView: View {
    let lines: [DiffLine]
    @Environment(\.theme) var theme

    var body: some View {
        if lines.isEmpty {
            Text("Paste JSON on both sides.")
                .font(.system(size: 12)).foregroundStyle(theme.secondary).padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            GeometryReader { g in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            HStack(spacing: 6) {
                                LineNumber(n: l.left)
                                LineNumber(n: l.right)
                                Text(l.kind == .removed ? "−" : l.kind == .added ? "+" : " ")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(l.kind == .removed ? Color.red : l.kind == .added ? Color.green : theme.secondary)
                                Text(l.text.isEmpty ? " " : l.text).font(.system(size: 12, design: .monospaced)).fixedSize()
                            }
                            .padding(.vertical, 1).padding(.trailing, 8)
                            .frame(minWidth: g.size.width, alignment: .leading)
                            .background(l.kind == .removed ? Color.red.opacity(0.18) : l.kind == .added ? Color.green.opacity(0.18) : Color.clear)
                            .id(i)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .topLeading) // short content starts at the top, not mid-pane
                    .textSelection(.enabled)
                }
                // Jump to the first difference.
                .onAppear { if let first = lines.firstIndex(where: { $0.kind != .same }) { proxy.scrollTo(first, anchor: .top) } }
            }
            }
        }
    }
}


/// Collapsible JSON / XML: a chevron on everything that folds; folded ones show how much they hold.
/// Right-click a line to copy its JSONPath / XPath.
struct TreeView: View {
    let rows: [TreeRow]
    var hits: Set<String> = []
    @Binding var collapsed: Set<String>
    @Environment(\.theme) var theme

    var body: some View {
        GeometryReader { g in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 0) {
                            Color.clear.frame(width: CGFloat(row.depth) * 16 + 4, height: 1)
                            if let shut = row.folded {
                                Image(systemName: shut ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.secondary).frame(width: 14)
                            } else {
                                Color.clear.frame(width: 14, height: 1)
                            }
                            if let label = row.label {
                                Text("\"\(label)\"").foregroundStyle(theme.accent)
                                Text(": ").foregroundStyle(theme.secondary)
                            }
                            content(row)
                            if row.comma { Text(",").foregroundStyle(theme.secondary) }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize()
                        .padding(.vertical, 1)
                        .frame(minWidth: g.size.width, alignment: .leading)
                        .background(hits.contains(row.id) ? theme.accent.opacity(0.2) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(row) }
                        .contextMenu {
                            if let path = row.path { Button("Copy Path") { copy(path, note: "Copied path") } }
                            if row.source != nil, !row.closes { Button("Copy Value") { copy(row.value, note: "Copied value") } }
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .topLeading) // short content starts at the top, not mid-pane
            }
        }
    }

    private func copy(_ s: String?, note: String) {
        guard let s else { return }
        ViewerModel.shared.copy(s, note: note)
    }

    private func toggle(_ row: TreeRow) {
        guard row.folded != nil else { return }
        if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
    }

    @ViewBuilder private func content(_ row: TreeRow) -> some View {
        switch row.kind {
        case .open(let bracket, let summary, let shut):
            if shut {
                Text(bracket == "{" ? "{...}" : "[...]").foregroundStyle(theme.text)
                Text("  \(summary)").foregroundStyle(theme.secondary).italic()
            } else {
                Text(String(bracket)).foregroundStyle(theme.text)
            }
        case .close(let bracket):
            Text(String(bracket)).foregroundStyle(theme.text)
        case .leaf(let node):
            switch node {
            case .string(let v): Text("\"\(v.replacingOccurrences(of: "\n", with: "\\n"))\"").foregroundStyle(Color(hex: 0x98C379))
            case .number(let v): Text(v).foregroundStyle(Color(hex: 0xD19A66))
            case .bool(let v): Text(v ? "true" : "false").foregroundStyle(Color(hex: 0xC678DD))
            case .null: Text("null").foregroundStyle(Color(hex: 0xC678DD))
            default: EmptyView()
            }
        case .tagOpen(let name, let attrs, let summary, let shut):
            tag("<", name, attrs, ">")
            if shut {
                Text("...").foregroundStyle(theme.secondary)
                tag("</", name, "", ">")
                Text("  \(summary)").foregroundStyle(theme.secondary).italic()
            }
        case .tagClose(let name):
            tag("</", name, "", ">")
        case .tagLeaf(let name, let attrs, let text):
            if let text {
                tag("<", name, attrs, ">")
                Text(text).foregroundStyle(theme.text)
                tag("</", name, "", ">")
            } else {
                tag("<", name, attrs, "/>")
            }
        case .text(let t):
            Text(t).foregroundStyle(t.hasPrefix("<!--") ? theme.secondary : theme.text)
        }
    }

    private func tag(_ open: String, _ name: String, _ attrs: String, _ close: String) -> some View {
        HStack(spacing: 0) {
            Text(open).foregroundStyle(theme.secondary)
            Text(name).foregroundStyle(theme.accent)
            Text(attrs).foregroundStyle(Color(hex: 0xD19A66))
            Text(close).foregroundStyle(theme.secondary)
        }
    }
}


/// Read-only output you can select; dragging past the edge scrolls, which SwiftUI's selectable Text doesn't do.
struct SelectableText: NSViewRepresentable {
    let text: String
    let color: NSColor

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 8)
        // Long lines wrap to the pane, so nothing is ever cut off at either edge.
        scroll.hasHorizontalScroller = false
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            // After layout, show the first character: setting text can leave the view scrolled sideways.
            DispatchQueue.main.async {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        tv.textColor = color
    }

    // Take the space offered: otherwise the pane asks for its longest line's width and SwiftUI centres the
    // oversized view, cutting off both edges.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: proposal.height ?? 200)
    }
}


/// An editable text pane whose changed lines are tinted (and the changed part of an edited line tinted
/// more). The tint is drawn by the layout manager, so it never becomes part of the text.
struct DiffEditor: NSViewRepresentable {
    @Binding var text: String
    let marks: DiffMarks
    let tint: NSColor
    let color: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isHorizontallyResizable = true // long lines scroll sideways, so lines stay lines
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, let lm = tv.layoutManager else { return }
        if tv.string != text { tv.string = text }
        tv.textColor = color
        tv.insertionPointColor = color
        let ns = tv.string as NSString
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: ns.length))
        guard !marks.lines.isEmpty else { return }
        var line = 1, at = 0
        while at <= ns.length {
            let r = ns.lineRange(for: NSRange(location: at, length: 0))
            if marks.lines.contains(line) {
                lm.addTemporaryAttribute(.backgroundColor, value: tint.withAlphaComponent(0.22), forCharacterRange: r)
                if let span = marks.spans[line], span.length > 0, NSMaxRange(span) <= r.length {
                    lm.addTemporaryAttribute(.backgroundColor, value: tint.withAlphaComponent(0.55),
                                             forCharacterRange: NSRange(location: r.location + span.location, length: span.length))
                }
            }
            if NSMaxRange(r) >= ns.length { break }
            at = NSMaxRange(r); line += 1
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: proposal.height ?? 200) // see SelectableText
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DiffEditor
        init(_ parent: DiffEditor) { self.parent = parent }
        func textDidChange(_ n: Notification) {
            if let tv = n.object as? NSTextView { parent.text = tv.string }
        }
    }
}
