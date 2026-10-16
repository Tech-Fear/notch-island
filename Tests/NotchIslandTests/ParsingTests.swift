import AppKit
import CoreAudio
import CryptoKit
import EventKit
import Foundation
import Testing
@testable import NotchIsland

@Suite struct LyricsParsing {
    @Test func parsesTimestampsAndSorts() {
        let lines = Lyrics.parse("[00:12.50] second\n[00:01.00] first\nno timestamp\n[01:00.00]")
        #expect(lines.map(\.time) == [1, 12.5, 60])
        #expect(lines.map(\.text) == ["first", "second", ""])
    }

    @Test func repeatsLinesWithSeveralTimestamps() {
        let lines = Lyrics.parse("[00:05.00][00:30.00] chorus")
        #expect(lines.map(\.time) == [5, 30])
        #expect(lines.allSatisfy { $0.text == "chorus" })
    }
}

@Suite @MainActor struct NowPlayingParsing {
    @Test func nothingPlaying() {
        #expect(SystemNowPlaying.parse(["pid": 0]) == nil)
        #expect(SystemNowPlaying.parse([:]) == nil)
    }

    @Test func readsHelperLine() throws {
        let np = try #require(SystemNowPlaying.parse([
            "pid": Int(getpid()), "playing": 1, "title": "Song", "artist": "Artist", "album": "",
            "duration": 200.5, "elapsed": 10, "at": 1_000_000,
        ]))
        #expect(np.title == "Song")
        #expect(np.artist == "Artist")
        #expect(np.playing)
        #expect(np.duration == 200.5)
        #expect(np.player == nil) // came from the system helper, not AppleScript
        // Paused tracks don't advance; playing ones do (capped at the duration).
        #expect(np.position(at: Date(timeIntervalSince1970: 1_000_005)) == 15)
        #expect(np.position(at: Date(timeIntervalSince1970: 2_000_000)) == 200.5)
    }
}

@Suite struct MeetingLinks {
    private func event(location: String? = nil, notes: String? = nil) -> EKEvent {
        let e = EKEvent(eventStore: EKEventStore())
        e.location = location
        e.notes = notes
        return e
    }

    @Test func findsZoomMeetTeams() {
        #expect(CalendarTile.meetingURL(event(notes: "Join: https://us02web.zoom.us/j/123456?pwd=abc thanks"))?
            .absoluteString == "https://us02web.zoom.us/j/123456?pwd=abc")
        #expect(CalendarTile.meetingURL(event(location: "https://meet.google.com/abc-defg-hij"))?
            .host == "meet.google.com")
        #expect(CalendarTile.meetingURL(event(notes: "<https://teams.microsoft.com/l/meetup-join/19%3a>"))?
            .host == "teams.microsoft.com")
    }

    @Test func ignoresOtherLinks() {
        #expect(CalendarTile.meetingURL(event(location: "Room 4", notes: "https://example.com/agenda")) == nil)
        #expect(CalendarTile.meetingURL(event(notes: "http://zoom.us/j/1")) == nil) // https only
    }
}

@Suite struct AlwaysRule {
    @Test func describesSuggestedRules() {
        let text = ClaudeBridge.describeAlways([[
            "type": "addRules", "behavior": "allow", "destination": "localSettings",
            "rules": [["toolName": "Bash", "ruleContent": "npm run lint:*"]],
        ]])
        #expect(text == "Bash(npm run lint:*) in this project")
        #expect(ClaudeBridge.describeAlways([["type": "setMode", "mode": "acceptEdits", "destination": "session"]])
            == "switch to acceptEdits mode")
    }

    @Test func noSuggestionMeansNoAlwaysButton() {
        #expect(ClaudeBridge.describeAlways([]) == nil)
        #expect(ClaudeBridge.describeAlways([["type": "addRules", "rules": []]]) == nil)
    }
}

@Suite @MainActor struct LayoutModel {
    @Test func movesWidgetsAcrossPages() {
        let settings = AppSettings.shared
        let saved = settings.layout
        defer { settings.layout = saved }

        let a = Placement(kind: .weather, width: 1), b = Placement(kind: .timer, width: 1), c = Placement(kind: .volume, width: 2)
        settings.layout = IslandLayout(pages: [[a, b], [c]])
        settings.move(b.id, toPage: 1, before: c.id)
        #expect(settings.layout.pages.map { $0.map(\.kind) } == [[.weather], [.timer, .volume]])
        settings.move(a.id, toPage: 1, before: nil)
        #expect(settings.layout.pages.map { $0.map(\.kind) } == [[], [.timer, .volume, .weather]])
        #expect(settings.layout.page(of: .weather) == 1)
    }

    @Test func widgetPartsDefaults() {
        let settings = AppSettings.shared
        #expect(settings.shows(.timer, "p25"))
        #expect(!settings.shows(.timer, "p90") || settings.parts["timer.p90"] == true)
    }
}

@Suite struct PerAppVolume {
    /// Builds an AudioBufferList with one buffer per entry (channels, samples) and runs `body` on it.
    private func withBuffers(_ spec: [(Int, [Float])], _ body: (UnsafeMutablePointer<AudioBufferList>) -> Void) -> [[Float]] {
        let list = AudioBufferList.allocate(maximumBuffers: spec.count)
        var storage = spec.map { $0.1 }
        for i in spec.indices {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: storage[i].count)
            p.initialize(from: storage[i], count: storage[i].count)
            list[i] = AudioBuffer(mNumberChannels: UInt32(spec[i].0), mDataByteSize: UInt32(storage[i].count * 4), mData: p)
        }
        body(list.unsafeMutablePointer)
        for i in spec.indices {
            let p = list[i].mData!.assumingMemoryBound(to: Float.self)
            storage[i] = Array(UnsafeBufferPointer(start: p, count: storage[i].count))
            p.deallocate()
        }
        free(list.unsafeMutablePointer)
        return storage
    }

    @Test func interleavedStereoAtHalfGain() {
        let input: [Float] = [1, -1, 0.5, -0.5] // 2 frames, L/R interleaved
        var out: [[Float]] = []
        _ = withBuffers([(2, input)]) { inList in
            out = withBuffers([(2, [9, 9, 9, 9])]) { outList in mixTapped(input: inList, output: outList, gain: 0.5) }
        }
        #expect(out[0] == [0.5, -0.5, 0.25, -0.25])
    }

    @Test func headsetMicChannelsAreSkipped() {
        // Aggregate input: 1 mic channel buffer, then the stereo tap; output is two mono buffers.
        var out: [[Float]] = []
        _ = withBuffers([(1, [7, 7]), (2, [1, 2, 3, 4])]) { inList in
            out = withBuffers([(1, [0, 0]), (1, [0, 0])]) { outList in mixTapped(input: inList, output: outList, gain: 1) }
        }
        #expect(out == [[1, 3], [2, 4]])
    }

    @Test func mutedIsSilent() {
        var out: [[Float]] = []
        _ = withBuffers([(2, [1, 1])]) { inList in
            out = withBuffers([(2, [5, 5])]) { outList in mixTapped(input: inList, output: outList, gain: 0) }
        }
        #expect(out[0] == [0, 0])
    }

    @Test func helpersBelongToTheirApp() {
        let apps = ["com.google.Chrome", "com.spotify.client", "com.google.Chrome.canary"]
        #expect(owningAppBundleID(of: "com.google.Chrome.helper.Renderer", among: apps) == "com.google.Chrome")
        #expect(owningAppBundleID(of: "com.google.Chrome.canary.helper", among: apps) == "com.google.Chrome.canary")
        #expect(owningAppBundleID(of: "com.spotify.client", among: apps) == "com.spotify.client")
        #expect(owningAppBundleID(of: "com.apple.coreaudiod", among: apps) == nil)
    }
}

@Suite struct SmallWidgets {
    @Test func countdownWording() {
        let now = Date(timeIntervalSince1970: 0)
        let c = Countdown(title: "Launch", date: now.addingTimeInterval(2 * 86_400 + 3 * 3600 + 4 * 60))
        #expect(countdownText(to: c, from: now) == ("2 days", "3 h 4 m to Launch"))
        #expect(countdownText(to: Countdown(title: "Launch", date: now.addingTimeInterval(90 * 60)), from: now) == ("1 h 30 m", "to Launch"))
        #expect(countdownText(to: Countdown(title: "Trip", date: now.addingTimeInterval(-86_400)), from: now).small == "Trip was 1 day ago")
    }

    @Test func colorHex() {
        #expect(hexString(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#FF8000")
        #expect(hexString(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)) == "#000000")
    }
}

@Suite struct DevToolParsing {
    @Test func listeningPorts() {
        let out = "p501\ncnode\nn*:3000\nn[::1]:3000\np777\ncjava\nn127.0.0.1:8080\n"
        #expect(parseListeningPorts(out) == [ListeningPort(port: 3000, pid: 501, command: "node"),
                                             ListeningPort(port: 8080, pid: 777, command: "java")])
    }

    @Test func gitStatus() {
        let out = """
        # branch.oid abc
        # branch.head feature/notch
        # branch.upstream origin/feature/notch
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 a b README.md
        2 R. N... 100644 100644 100644 a b R100 new.swift\told.swift
        ? scratch.txt
        """
        #expect(parseGitStatus(out) == GitStatus(branch: "feature/notch", ahead: 2, behind: 1, changed: 2, untracked: 1, hasUpstream: true))
        #expect(parseGitStatus("# branch.head main\n").hasUpstream == false)
    }

    @Test func dockerContainers() {
        let out = "a1\tdb\texited\tExited (0) 2 hours ago\nb2\tapi\trunning\tUp 5 minutes\n"
        let c = parseContainers(out)
        #expect(c.map(\.name) == ["api", "db"]) // running first
        #expect(c.first?.running == true)
    }
}

@Suite struct ClipboardTools {
    @Test func json() {
        #expect(prettyJSON(#"{"b":1,"a":[1,2]}"#) == "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1\n}")
        #expect(prettyJSON("hello") == nil)
    }

    @Test func base64() {
        #expect(decodeBase64("aGVsbG8gd29ybGQ=") == "hello world")
        #expect(decodeBase64("password") == nil)     // decodes to binary, not text
        #expect(decodeBase64("hi there") == nil)     // spaces: not Base64
    }

    @Test func jwt() {
        // {"alg":"HS256"} . {"sub":"42"} . signature
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI0MiJ9.c2ln"
        #expect(decodeJWT(token) == "{\n  \"alg\" : \"HS256\"\n}\n{\n  \"sub\" : \"42\"\n}")
        #expect(decodeJWT("a.b") == nil)
    }

    @Test func timestamps() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(timestampDate("1700000000", timeZone: utc) == "2023-11-14 22:13:20 GMT")
        #expect(timestampDate("1700000000000", timeZone: utc) == "2023-11-14 22:13:20 GMT")
        #expect(timestampDate("1234", timeZone: utc) == nil)
        #expect(timestampDate("9999999999", timeZone: utc) == nil) // year 2286: out of range
    }
}

@Suite struct AuthenticatorCodes {
    // RFC 6238 appendix B test vectors (8 digits).
    let k1 = Data("12345678901234567890".utf8)
    let k256 = Data("12345678901234567890123456789012".utf8)
    let k512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    @Test func rfc6238() {
        func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
        #expect(totp(secret: k1, at: at(59), digits: 8) == "94287082")
        #expect(totp(secret: k1, at: at(1_111_111_109), digits: 8) == "07081804")
        #expect(totp(secret: k1, at: at(1_234_567_890), digits: 8) == "89005924")
        #expect(totp(secret: k1, at: at(2_000_000_000), digits: 8) == "69279037")
        #expect(totp(secret: k256, at: at(59), digits: 8, algorithm: .sha256) == "46119246")
        #expect(totp(secret: k512, at: at(59), digits: 8, algorithm: .sha512) == "90693936")
        #expect(totp(secret: k1, at: at(59)) == "287082") // 6 digits = last 6
    }

    @Test func base32() {
        #expect(base32Decode("GEZDGNBVGY3TQOJQ") == Data("1234567890".utf8))
        #expect(base32Decode("gezd gnbv-gy3t qojq") == Data("1234567890".utf8)) // spaces, dashes, lowercase
        #expect(base32Decode("not base32!") == nil)
    }

    @Test func otpauthLink() throws {
        let (a, key) = try #require(parseOTPAuth("otpauth://totp/GitHub:me%40example.com?secret=GEZDGNBVGY3TQOJQ&issuer=GitHub&digits=8&period=60&algorithm=SHA256"))
        #expect(a.issuer == "GitHub")
        #expect(a.account == "me@example.com")
        #expect((a.digits, a.period, a.algorithm) == (8, 60, .sha256))
        #expect(key == Data("1234567890".utf8))
        #expect(parseOTPAuth("otpauth://hotp/x?secret=GEZDGNBV") == nil) // counter-based: not supported
        #expect(parseOTPAuth("https://example.com") == nil)
    }
}

@Suite struct TextToolsFormatting {
    @Test func jsonKeepsKeyOrder() {
        #expect(formatJSON(#"{"z":1,"a":[1,{"b":"x,y"}],"e":{}}"#) == .ok("{\n  \"z\": 1,\n  \"a\": [\n    1,\n    {\n      \"b\": \"x,y\"\n    }\n  ],\n  \"e\": {}\n}"))
        #expect(formatJSON("{ \"a\" : [ 1 , 2 ] }", minify: true) == .ok(#"{"a":[1,2]}"#))
        if case .error = formatJSON("{\"a\": }") {} else { Issue.record("invalid JSON must be reported") }
    }

    @Test func csvQuotes() {
        let rows = parseCSV("name,note\n\"Smith, J\",\"said \"\"hi\"\"\"\n\"multi\nline\",x\n")
        #expect(rows == [["name", "note"], ["Smith, J", "said \"hi\""], ["multi\nline", "x"]])
        #expect(parseCSV("a;b\n1;2") == [["a", "b"], ["1", "2"]]) // ; delimiter
    }

    @Test func xmlAndBase64() {
        if case .ok(let s) = formatXML("<a><b>1</b></a>") { #expect(s.contains("\n")) } else { Issue.record("valid XML") }
        if case .error = formatXML("<a><b></a>") {} else { Issue.record("invalid XML must be reported") }
        #expect(decodeBase64Text("aGVsbG8=") == .ok("hello"))
        #expect(encodeBase64("hello") == "aGVsbG8=")
    }

    @Test func errorsPointAtTheLine() {
        if case .error(_, let line, let column) = formatJSON("{\n  \"a\": 1,\n  \"b\": [1, 2,,\n}") {
            #expect(line == 3)
            #expect(column != nil)
        } else { Issue.record("invalid JSON must be reported") }
        if case .error(_, let line, _) = formatXML("<a>\n  <b>1</b>\n  <c>\n</a>") {
            #expect(line == 4)
        } else { Issue.record("invalid XML must be reported") }
        #expect(lineColumn(in: "Invalid value around line 3, column 13.")! == (3, 13))
    }
}

@Suite struct Compare {
    @Test func changedLines() {
        let d = diffLines("a\nb\nc", "a\nB\nc\nd")
        #expect(d.map(\.kind) == [.same, .removed, .added, .same, .added])
        #expect(d[1] == DiffLine(kind: .removed, text: "b", left: 2, right: nil))
        #expect(d[2] == DiffLine(kind: .added, text: "B", left: nil, right: 2))
        #expect(d.last == DiffLine(kind: .added, text: "d", left: nil, right: 4))
    }

    @Test func identicalAndWhitespace() {
        #expect(diffLines("x\ny", "x\ny").allSatisfy { $0.kind == .same })
        #expect(diffLines("a = 1", "a=1", ignoreWhitespace: true).allSatisfy { $0.kind == .same })
        #expect(diffLines("a = 1", "a=1").contains { $0.kind != .same })
    }

    @Test func jsonTreeKeepsOrderAndCollapses() {
        let tree = parseJSONTree(#"{"z": 1, "a": {"b": [true, null, "x\n"]}, "m": 2.5}"#)!
        guard case .object(let m) = tree else { Issue.record("not an object"); return }
        #expect(m.map(\.name) == ["z", "a", "m"])
        #expect(m[1].value == .object([JMember(name: "b", value: .array([.bool(true), .null, .string("x\n")]))]))
        #expect(treeRows(tree, collapsed: []).compactMap { $0.folded == nil ? nil : $0.id } == ["$", "$.a", "$.a.b"])
        // Keys with dots get bracket paths, so they never clash with nested keys.
        let odd = treeRows(parseJSONTree(#"{"a.b": 1, "a": {"b": 2}}"#)!, collapsed: []).map(\.id)
        #expect(odd.contains(#"$["a.b"]"#) && odd.contains("$.a.b") && Set(odd).count == odd.count)
        #expect(treeRows(tree, collapsed: []).count == 11)
        let shut = treeRows(tree, collapsed: ["$.a"])
        #expect(shut.count == 5)
        if case .open(_, let summary, true) = shut[2].kind { #expect(summary == "1 key") } else { Issue.record("$.a not collapsed") }
        #expect(shut.last?.comma == false && shut[2].comma)
    }

    @Test func xmlTreeRows() throws {
        let root = try #require(try XMLDocument(xmlString: "<r a=\"1\"><i>x</i><i/><!-- note --><g><k>1</k></g></r>").rootElement())
        let rows = xmlRows(root, collapsed: [])
        #expect(rows.map(\.id) == ["/r", "/r/i[1]", "/r/i[2]", "/r#2", "/r/g[1]", "/r/g[1]/k[1]", "/r/g[1]/", "/r/"])
        if case .tagOpen(_, let attrs, let summary, false) = rows[0].kind { #expect(attrs == #" a="1""# && summary == "4 children") } else { Issue.record("root") }
        if case .tagLeaf(_, _, let text) = rows[1].kind { #expect(text == "x") } else { Issue.record("leaf") }
        if case .tagLeaf(_, _, let text) = rows[2].kind { #expect(text == nil) } else { Issue.record("empty") }
        #expect(xmlRows(root, collapsed: ["/r/g[1]"]).count == 6)
    }

    @Test func pageGridStacksShortWidgetsBesideTallOnes() {
        let big = Placement(kind: .music, width: 2, height: 2)
        let small = (0..<4).map { _ in Placement(kind: .weather, width: 1) }
        let g = PageGrid([big] + small)
        #expect(g.columns == 4 && g.rows == 2)
        #expect(g.cells[big.id]! == (0, 0))
        #expect(small.map { [g.cells[$0.id]!.col, g.cells[$0.id]!.row] } == [[2, 0], [3, 0], [2, 1], [3, 1]])
        // One-row pages are laid out as before: side by side.
        let row = [Placement(kind: .git, width: 2), Placement(kind: .ports, width: 1)]
        let r = PageGrid(row)
        #expect(r.columns == 3 && r.rows == 1 && r.cells[row[1].id]! == (2, 0))
        // Same widget several times is fine.
        #expect(PageGrid(small).columns == 4)
    }

    @Test func oldLayoutsLoadWithHeightOne() throws {
        let old = #"{"id":"6F1C3A3E-8D7B-4B7E-9C1F-2D3E4F5A6B7C","kind":"music","width":2}"#
        let p = try JSONDecoder().decode(Placement.self, from: Data(old.utf8))
        #expect(p.width == 2 && p.height == 1)
    }

    @Test func jsonTextSortAndStructureDiff() {
        let t = parseJSONTree(#"{"b": [1, {"x": "a/b"}], "a": {}, "c": null}"#)!
        #expect(jsonText(t, minify: true) == #"{"b":[1,{"x":"a/b"}],"a":{},"c":null}"#)
        #expect(jsonText(sortingKeys(t), minify: true) == #"{"a":{},"b":[1,{"x":"a/b"}],"c":null}"#)
        if case .ok(let f) = formatJSON(#"{"b": [1, {"x": "a/b"}], "a": {}, "c": null}"#) { #expect(jsonText(t) == f) }
        let d = diffJSON(t, parseJSONTree(#"{"a": {}, "b": [1, {"x": "z"}, 3], "d": true}"#)!)
        #expect(d.map(\.text) == [#"$.b[1].x: "a/b""#, #"$.b[1].x: "z""#, "$.b[2]: 3", "$.c: null", "$.d: true"])
        #expect(d.map(\.kind) == [.removed, .added, .added, .removed, .added])
    }

    @Test func jwtUrlAndTime() {
        // {"alg":"HS256"} . {"sub":"1","exp":0}
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIiwiZXhwIjowfQ.sig"
        guard case .ok(let j) = decodeJWT(jwt) else { Issue.record("jwt"); return }
        #expect(j.contains(#""alg": "HS256""#) && j.contains(#""sub": "1""#) && j.contains("EXPIRED"))
        if case .error = decodeJWT("a.b") {} else { Issue.record("two parts accepted") }

        #expect(decodeURL("a%20b+c") == .ok("a b c"))
        if case .error = decodeURL("100%") {} else { Issue.record("bad % accepted") }
        if case .ok(let u) = decodeURL("https://x.dev:8080/p%20q?a=1&b=two+words#top") {
            #expect(u.contains("host      x.dev") && u.contains("port      8080") && u.contains("b = two words") && u.contains("fragment  top"))
        } else { Issue.record("url") }
        #expect(encodeURL("a b&c/é") == "a%20b%26c%2F%C3%A9")

        let utc = TimeZone(identifier: "UTC")!
        for input in ["1700000000", "1700000000000", "2023-11-14T22:13:20Z", "2023-11-14 22:13:20"] {
            guard case .ok(let t) = convertTimes(input, zone: utc) else { Issue.record("time \(input)"); continue }
            #expect(t.contains("2023-11-14T22:13:20Z") && t.contains("1700000000 s"))
        }
        if case .error(_, let line, _) = convertTimes("1700000000\nsoon") { #expect(line == 2) } else { Issue.record("bad time accepted") }
    }

    @MainActor @Test func treeFindAndFold() {
        let m = ViewerModel.shared
        m.mode = .json
        m.input = #"{"user": {"name": "Ada", "tags": ["x"]}, "other": 1}"#
        m.search = "ada"
        #expect(m.rows.map(\.id) == ["$", "$.user", "$.user.name", "$.user/", "$/"] && m.hits == ["$.user.name"])
        m.search = ""
        m.fold(from: 2)
        #expect(m.collapsed == ["$.user.tags"])
        m.fold(from: 1)
        #expect(m.collapsed == ["$.user", "$.user.tags"])
        m.input = ""; m.collapsed = []
    }

    @Test func sideBySideMarks() {
        let m = diffMarks(diffLines("keep\nid: 123\nold", "keep\nid: 1X3\nnew line\nextra"))
        #expect(m.left.lines == [2, 3] && m.right.lines == [2, 3, 4])
        #expect(m.left.spans[2] == NSRange(location: 5, length: 1) && m.right.spans[2] == NSRange(location: 5, length: 1))
        #expect(m.right.spans[4] == nil) // a purely added line has no pair
        #expect(diffMarks(diffLines("a", "a")).left.lines.isEmpty)
    }

    @Test func stringifiedJSON() {
        #expect(unwrapStringified(#""{\"a\":1,\"b\":[true]}""#) == #"{"a":1,"b":[true]}"#)
        #expect(unwrapStringified(#"{\"a\":\"x\"}"#) == #"{"a":"x"}"#)            // logged without outer quotes
        #expect(unwrapStringified(#""\"{\\\"a\\\":1}\"""#) == #"{"a":1}"#)       // stringified twice
        #expect(unwrapStringified(#""hello""#) == nil && unwrapStringified(#"{"a":1}"#) == nil)
        let nested = parsingNested(parseJSONTree(#"{"payload": "{\"id\": 7, \"tags\": \"[1,2]\"}", "note": "{not json"}"#)!)
        #expect(jsonText(nested, minify: true) == #"{"payload":{"id":7,"tags":[1,2]},"note":"{not json"}"#)
    }

    @MainActor @Test func viewerUnwrapsStringified() {
        let m = ViewerModel.shared
        m.mode = .json
        m.input = #""{\"user\":\"{\\\"id\\\":1}\"}""#
        #expect(m.error == nil && m.wasStringified && m.output == "{\n  \"user\": {\n    \"id\": 1\n  }\n}")
        m.input = ""
    }

    @Test func bulkOTPLinks() {
        let text = """
        otpauth://totp/OpenVPN:me%40x.com?secret=JBSWY3DPEHPK3PXP&issuer=OpenVPN
        otpauth://totp/GitHub:dev?secret=GEZDGNBVGY3TQOJQ&digits=8,  otpauth://totp/Bad?secret=B
        not a link
        """
        let links = otpLinks(in: text)
        #expect(links.count == 3)
        let parsed = links.compactMap(parseOTPAuth)
        #expect(parsed.map { "\($0.0.issuer)|\($0.0.account)|\($0.0.digits)" } == ["OpenVPN|me@x.com|6", "GitHub|dev|8"])
        #expect(parseOTPAuth(links[2]) == nil) // "B" isn't a usable secret
    }

    @Test func dragHandoffClonesProtectedFiles() throws {
        let home = "/Users/x"
        #expect(DragHandoff.isProtected(URL(fileURLWithPath: "/Users/x/Documents/a b/n.md"), home: home))
        #expect(DragHandoff.isProtected(URL(fileURLWithPath: "/Users/x/Library/CloudStorage/Dropbox/f.pdf"), home: home))
        #expect(!DragHandoff.isProtected(URL(fileURLWithPath: "/Users/x/Projects/n.md"), home: home))
        #expect(!DragHandoff.isProtected(URL(fileURLWithPath: "/Users/x/Documents"), home: home))

        let src = FileManager.default.temporaryDirectory.appendingPathComponent("handoff test.md")
        try "# hi".write(to: src, atomically: true, encoding: .utf8)
        let clone = try #require(DragHandoff.stage(src))
        #expect(clone.lastPathComponent == "handoff test.md" && clone.path.hasPrefix(DragHandoff.folder.path))
        #expect(try String(contentsOf: clone, encoding: .utf8) == "# hi")
        // A hard link, not a copy: one file with two names.
        #expect(try FileManager.default.attributesOfItem(atPath: src.path)[.referenceCount] as? Int == 2)
        try? FileManager.default.removeItem(at: clone.deletingLastPathComponent())
        // Terminals keep the real path, wherever the file is.
        #expect(DragHandoff.url(for: src, destination: "com.googlecode.iterm2") == src)
    }

    @Test func vaultSealsToAPublicKeyAndOpensWithItsPrivateKey() throws {
        // Same sealing as the vault, with a software key standing in for the Secure Enclave one.
        let me = P256.KeyAgreement.PrivateKey()
        let secrets = [UUID(): Data("JBSWY3DPEHPK3PXP".utf8)]
        let (ephemeral, box) = try OTPVault.seal(JSONEncoder().encode(secrets), to: me.publicKey)
        let opened = try OTPVault.open(box, ephemeral: ephemeral) { try me.sharedSecretFromKeyAgreement(with: $0) }
        #expect(try JSONDecoder().decode([UUID: Data].self, from: opened) == secrets)
        let stranger = P256.KeyAgreement.PrivateKey()
        #expect(throws: (any Error).self) { try OTPVault.open(box, ephemeral: ephemeral) { try stranger.sharedSecretFromKeyAgreement(with: $0) } }
    }

    @Test func basicAuthBothWays() {
        // RFC 7617's example: Aladdin / open sesame
        guard case .ok(let h) = basicAuth("Aladdin:open sesame") else { Issue.record("encode"); return }
        #expect(h.hasPrefix("Authorization: Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ=="))
        if case .ok(let two) = basicAuth("Aladdin\nopen sesame") { #expect(two == h) } else { Issue.record("two lines") }
        #expect(basicAuth("Authorization: Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==") == .ok("Client ID   Aladdin\nSecret      open sesame"))
        #expect(basicAuth("QWxhZGRpbjpvcGVuIHNlc2FtZQ") == .ok("Client ID   Aladdin\nSecret      open sesame")) // no padding
        if case .ok(let colon) = basicAuth("id:se:cret") { #expect(colon.contains(Data("id:se:cret".utf8).base64EncodedString())) }
        if case .error = basicAuth("Basic !!!") {} else { Issue.record("bad base64 accepted") }
    }

    @Test func hashesMatchStandardVectors() {
        guard case .ok(let h) = hashes("abc") else { Issue.record("hash"); return }
        #expect(h.contains("900150983cd24fb0d6963f7d28e17f72"))                                    // MD5 (RFC 1321)
        #expect(h.contains("a9993e364706816aba3e25717850c26c9cd0d89d"))                            // SHA-1 (FIPS 180)
        #expect(h.contains("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))    // SHA-256
    }

    @Test func passwordsAndKeys() throws {
        var o = PasswordOptions()
        o.symbols = false; o.avoidSimilar = true
        let p = try generatePassword(length: 24, options: o)
        #expect(p.count == 24 && p.contains(where: \.isUppercase) && p.contains(where: \.isLowercase) && p.contains(where: \.isNumber))
        #expect(!p.contains { "0O1lIo!@#".contains($0) })
        // Minimums, exclusions and a custom symbol set.
        var m = PasswordOptions()
        m.minUpper = 5; m.minDigits = 4; m.minSymbols = 3; m.symbolSet = "#$"; m.exclude = "aeiouAEIOU"
        for _ in 0..<20 {
            let q = try generatePassword(length: 16, options: m)
            #expect(q.filter(\.isUppercase).count >= 5 && q.filter(\.isNumber).count >= 4 && q.filter { "#$".contains($0) }.count >= 3)
            #expect(!q.contains { "aeiouAEIOU!@%".contains($0) })
        }
        var none = PasswordOptions(); none.upper = false; none.lower = false; none.digits = false; none.symbols = false
        #expect(throws: GeneratorError.self) { try generatePassword(length: 8, options: none) }
        var tooMany = PasswordOptions(); tooMany.minUpper = 10
        #expect(throws: GeneratorError.self) { try generatePassword(length: 8, options: tooMany) }
        var emptied = PasswordOptions(); emptied.digits = true; emptied.exclude = "0123456789"
        #expect(throws: GeneratorError.self) { try generatePassword(length: 8, options: emptied) }
        #expect(try generatePassword(length: 20) != generatePassword(length: 20))
        #expect(passwordBits(length: 20, alphabet: 87) == 128)

        let aes = try generateSecrets(.aes, size: 256)
        #expect(aes[0].value.count == 64 && Data(base64Encoded: aes[1].value)?.count == 32)
        #expect(try generateSecrets(.uuid, size: 0, count: 4).count == 4)
        #expect(try generateSecrets(.password, size: 16, count: 3).allSatisfy { $0.value.count == 16 })
        // Key pairs come out as PEM that CryptoKit reads back.
        let p256 = try generateSecrets(.p256, size: 0)
        #expect((try? P256.Signing.PrivateKey(pemRepresentation: p256[0].value)) != nil)
        let ed = try generateSecrets(.ed25519, size: 0)
        let der = try #require(Data(base64Encoded: ed[0].value.split(separator: "\n").dropFirst().dropLast().joined()))
        #expect(der.count == 48 && (try? Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32))) != nil)
        let rsa = try generateSecrets(.rsa, size: 2048)
        #expect(rsa[0].value.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") && rsa[1].value.hasSuffix("-----END RSA PUBLIC KEY-----"))
    }
}
