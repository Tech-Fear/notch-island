import AppKit
import CoreAudio
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
