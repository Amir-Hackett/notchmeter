import Foundation
import Testing
@testable import Notchmeter

/// The crash report Settings › Advanced › Diagnostics offers (CrashReports): the newest of this app's own reports
/// in a listing of every app's, by modification date, in either the `.ips` or the older `.crash` naming, and never
/// another app's whose name only starts with this one's.
@Suite struct CrashReportPicking {
    static func report(_ name: String, _ secondsAgo: TimeInterval) -> CrashReports.Report {
        CrashReports.Report(url: URL(fileURLWithPath: "/reports/\(name)"), modified: Date(timeIntervalSince1970: 1_000_000 - secondsAgo))
    }

    @Test func theNewestOfThisAppsReportsWins() throws {
        let listing = [
            Self.report("Notchmeter-2026-09-20-101010.ips", 400),
            Self.report("Notchmeter_2026-09-23-090000_Mac.crash", 100),
            Self.report("Notchmeter-2026-09-22-101010.ips", 200),
            // Newer, but not this app's.
            Self.report("Safari-2026-09-24-080000.ips", 10),
            Self.report("NotchmeterHelper-2026-09-24-080000.ips", 5),
            Self.report("Notchmeter-2026-09-24-080000.diag", 1),
        ]
        let newest = try #require(CrashReports.newest(listing, app: "Notchmeter"))
        #expect(newest.url.lastPathComponent == "Notchmeter_2026-09-23-090000_Mac.crash")
    }

    @Test func noneWhenTheListingHoldsNothingOfThisApps() {
        #expect(CrashReports.newest([], app: "Notchmeter") == nil)
        #expect(CrashReports.newest([Self.report("Xcode-2026-09-24-080000.ips", 1)], app: "Notchmeter") == nil)
    }

    @Test func theNameNeedsASeparatorAndAReportExtension() {
        #expect(CrashReports.isReport("Notchmeter-2026-09-24-080000.ips", app: "Notchmeter"))
        #expect(CrashReports.isReport("Notchmeter.crash", app: "Notchmeter"))
        #expect(CrashReports.isReport("Notchmeter-2026-09-24-080000.IPS", app: "Notchmeter"))
        #expect(!CrashReports.isReport("Notchmeters-2026-09-24-080000.ips", app: "Notchmeter"))
        #expect(!CrashReports.isReport("Notchmeter-2026-09-24-080000.spin", app: "Notchmeter"))
        #expect(!CrashReports.isReport("Notchmeter", app: "Notchmeter"))
    }

    @Test func aLongReportIsCutAtTheLimitAndScrubbedOfHome() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchmeterTests.crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Notchmeter-2026-09-24-080000.ips")
        let body = "{\"procPath\" : \"\\/Users\\/someone\\/Applications\\/Notchmeter.app\"}\n/Users/someone/x\n" + String(repeating: "a", count: 4096)
        try Data(body.utf8).write(to: file)
        let text = try #require(CrashReports.text(of: file, limit: 1024, home: "/Users/someone"))
        #expect(!text.contains("someone"))
        #expect(text.contains("~\\/Applications"))
        #expect(text.hasSuffix("[cut at 1 KB]"))
        let found = try #require(CrashReports.newest(in: folder))
        #expect(found.url.lastPathComponent == file.lastPathComponent)
    }

    /// A home path straddling the cut is scrubbed whole: the scrub runs before the cut, so no piece of the user's
    /// name survives at the end of the copy.
    @Test func aHomePathAcrossTheCutLeavesNothingOfTheName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchmeterTests.crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Notchmeter-2026-09-24-080000.ips")
        let body = String(repeating: "a", count: 1020) + "\\/Users\\/someone\\/Applications" + String(repeating: "b", count: 4096)
        try Data(body.utf8).write(to: file)
        let text = try #require(CrashReports.text(of: file, limit: 1024, home: "/Users/someone"))
        #expect(!text.contains("some"))
        #expect(!text.contains("\\/Users"))
        #expect(text.hasSuffix("[cut at 1 KB]"))
    }

    /// macOS moves reports into `Retired` within a day or so; the newest there is still the newest crash.
    @Test func aReportMacOSHasRetiredIsStillFound() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchmeterTests.crash-\(UUID().uuidString)")
        let retired = folder.appendingPathComponent("Retired")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let older = folder.appendingPathComponent("Notchmeter-2026-09-20-080000.ips")
        let newer = retired.appendingPathComponent("Notchmeter-2026-09-23-080000.ips")
        try Data("{}".utf8).write(to: older)
        try Data("{}".utf8).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 4)], ofItemAtPath: older.path)
        #expect(CrashReports.newest(in: folder)?.url.lastPathComponent == newer.lastPathComponent)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: newer)
        #expect(CrashReports.newest(in: folder)?.url.lastPathComponent == newer.lastPathComponent, "only Retired holds one")
    }
}
