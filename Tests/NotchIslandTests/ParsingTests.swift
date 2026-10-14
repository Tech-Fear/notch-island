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
