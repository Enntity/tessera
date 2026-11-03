import XCTest
@testable import TesseraKit
@testable import TesseraHost

final class ClaudeQuotaWindowTests: XCTestCase {
    func testWeeklyOnlyAndModelLimitsWithoutAttributingContributionPercentages() throws {
        let screen = ["Current week (all models)", "████ 16% used", "Resets Nov 4 at 5am (America/Phoenix)",
                      "Current week (Fable)", "0%used", "Resets Nov 4 at 5am (America/Phoenix)",
                      "Skills % of usage", "/accord 2%", "Subagents % of usage", "general-purpose 10%"]
        guard case .windows(let windows) = ClaudeUsageScreen.parse(screen) else { return XCTFail("missing weekly quotas") }
        XCTAssertEqual(windows.map(\.label), ["Week", "Week (Fable)"])
        XCTAssertEqual(windows.map(\.usedPercent), [16, 0])
        let reading = UsageAPI.claudeUsageReading(windows, readAt: Date(), config: .init(id: "c", kind: .claudePlan))
        XCTAssertEqual(reading.headline, "84% left")
        XCTAssertFalse(reading.lines.contains { $0.hasPrefix("5h") })
        XCTAssertNil(ClaudeUsageScreen.parse(Array(screen.suffix(4))))
    }

    func testMissingWindowDoesNotStealTheNextWindowsValueAndRedrawUsesLatest() {
        let screen = ["Current session", "Current week (all models)", "20% used",
                      "Current day", "30% used", "Current week (all models)", "21% used"]
        guard case .windows(let windows) = ClaudeUsageScreen.parse(screen) else { return XCTFail("missing quotas") }
        XCTAssertEqual(windows.map(\.label), ["Week", "Day"])
        XCTAssertEqual(windows.map(\.usedPercent), [21, 30])
        XCTAssertNil(ClaudeUsageScreen.parse(["Current session", "999% used"]))
        XCTAssertNil(ClaudeUsageScreen.parse(["Current session", "-1% used"]))
    }
}

@MainActor final class ClaudePlanPersistenceTests: XCTestCase {
    func testLastGoodReadingPublishesImmediatelySurvivesRestartAndRetainsAgeAfterFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-plan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = Preferences.store.object(forKey: "tessera.claudeUsageChecks")
        Preferences.store.set(true, forKey: "tessera.claudeUsageChecks")
        defer { if let previous { Preferences.store.set(previous, forKey: "tessera.claudeUsageChecks") } else { Preferences.store.removeObject(forKey: "tessera.claudeUsageChecks") } }
        let config = UsageProviderConfig(id: "claude", kind: .claudePlan)
        StateFile.save([config], to: directory.appendingPathComponent("providers.json"))
        let now = Date(), readAt = now.addingTimeInterval(-3600)
        let service = UsageService(directory: directory)
        let windows = [ClaudeUsageScreen.Window(label: "Week", usedPercent: 16, resets: "Nov 4 at 5am")]
        service.acceptClaudePlan(.read(windows), for: config, at: readAt)
        XCTAssertEqual(service.readings[config.id]?.headline, "84% left")
        let file = directory.appendingPathComponent("claude-plan.json")
        let bytes = try Data(contentsOf: file)
        let restarted = UsageService(directory: directory)
        XCTAssertEqual(restarted.readings[config.id]?.headline, "84% left")
        XCTAssertEqual(restarted.readings[config.id]?.updatedAt.timeIntervalSince1970 ?? 0, readAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(restarted.readings[config.id]?.message, "As of 1h ago")
        restarted.acceptClaudePlan(.failed("Panel unavailable"), for: config, at: now)
        XCTAssertEqual(restarted.readings[config.id]?.headline, "84% left")
        XCTAssertEqual(restarted.readings[config.id]?.message, "Last read 1h ago · Panel unavailable")
        restarted.acceptClaudePlan(.refused("rate limited"), for: config, at: now)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        restarted.acceptClaudePlan(.read([]), for: config, at: now)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        // A fresh response replaces the window set; an absent 5h window is never invented.
        restarted.acceptClaudePlan(.read([.init(label: "Week (Fable)", usedPercent: 3)]), for: config, at: now)
        XCTAssertEqual(UsageService(directory: directory).readings[config.id]?.lines, ["Week (Fable) 3% used"])
    }

    func testInvalidCacheCannotDisplayInventedQuota() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-plan-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("claude-plan.json")
        let config = UsageProviderConfig(id: "claude", kind: .claudePlan)
        StateFile.save([config], to: directory.appendingPathComponent("providers.json"))
        StateFile.save(UsageService.ClaudePlan(windows: [], at: Date()), to: file)
        XCTAssertNil(UsageService(directory: directory).readings[config.id])
        XCTAssertFalse(UsageService.ClaudePlan(windows: [.init(label: "Week", usedPercent: -1)], at: Date()).valid())
    }
}
