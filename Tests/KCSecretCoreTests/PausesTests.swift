import Foundation
import Testing
@testable import KCSecretCore

@Suite("Pauses")
struct PausesTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func projectPauseWinsOverGlobal() {
        var p = Pauses()
        p.pause("/a", until: nil)
        p.pause(Pauses.everywhere, until: now.addingTimeInterval(60))
        #expect(p.covering("/a", now: now)?.scope == "/a")
        #expect(p.covering("/b", now: now)?.isGlobal == true)
        #expect(p.covering("/b", now: now.addingTimeInterval(61)) == nil)
    }

    @Test func roundTripsAndPrunes() {
        var p = Pauses()
        p.pause("/a", until: now.addingTimeInterval(10))
        p.pause(Pauses.everywhere, until: nil)
        var q = Pauses(text: p.render() + "garbage\nrelative\t0\n")
        #expect(q == p)
        let pruned = q.prune(now: now.addingTimeInterval(11))
        #expect(pruned)
        #expect(q.entries.map(\.scope) == [Pauses.everywhere])
        let first = q.resume(Pauses.everywhere), second = q.resume(Pauses.everywhere)
        #expect(first && !second)
        #expect(q.render() == "")
    }

    @Test(arguments: [("90s", 90.0), ("30m", 1800), ("2h", 7200), ("1d", 86400), ("1h30m", 5400), ("2H", 7200)])
    func durations(_ text: String, _ seconds: Double) {
        #expect(Pauses.duration(text) == seconds)
    }

    @Test(arguments: ["", "5", "h", "1x", "0m", "1h30", "-1h"])
    func badDurations(_ text: String) {
        #expect(Pauses.duration(text) == nil)
    }

    @Test func ssh() {
        #expect(Session.isSSH(["SSH_CONNECTION": "1.2.3.4 5 6.7.8.9 22"]))
        #expect(!Session.isSSH(["SSH_TTY": ""]))
        #expect(!Session.isSSH([:]))
    }

    @Test func configKey() throws {
        #expect(Config().skipOverSSH)
        #expect(try Config.parse("skip_over_ssh = false").config.skipOverSSH == false)
    }
}
