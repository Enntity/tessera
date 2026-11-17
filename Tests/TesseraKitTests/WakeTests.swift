// SPDX-License-Identifier: MIT
import XCTest
@testable import TesseraHost
@testable import TesseraKit

@MainActor
final class WakePolicyTests: XCTestCase {
    /// Who types without asking: the overseer always under its own policy, peers only when the
    /// policy includes them, an unplaced sender and an opted-out tile never.
    func testWhoMayTypeWithoutAsking() {
        XCTAssertTrue(WakePolicy.overseer.allows(.overseer, tileOptedOut: false))
        XCTAssertFalse(WakePolicy.overseer.allows(.peer, tileOptedOut: false))
        XCTAssertFalse(WakePolicy.overseer.allows(.other, tileOptedOut: false))
        XCTAssertTrue(WakePolicy.overseerAndPeers.allows(.overseer, tileOptedOut: false))
        XCTAssertTrue(WakePolicy.overseerAndPeers.allows(.peer, tileOptedOut: false))
        XCTAssertFalse(WakePolicy.overseerAndPeers.allows(.other, tileOptedOut: false))
        XCTAssertFalse(WakePolicy.askAlways.allows(.overseer, tileOptedOut: false))
        XCTAssertFalse(WakePolicy.askAlways.allows(.peer, tileOptedOut: false))
        for policy in [WakePolicy.overseer, .overseerAndPeers, .askAlways] {
            XCTAssertFalse(policy.allows(.overseer, tileOptedOut: true))
        }
    }

    /// The switch it replaces migrates: on meant overseer and peers; never set, it is overseer only.
    func testTheLegacySwitchMigrates() {
        let key = "tessera.wakePolicy", legacy = "tessera.agentsMayType"
        let before = Preferences.store.object(forKey: key)
        defer {
            Preferences.store.removeObject(forKey: legacy)
            if let before { Preferences.store.set(before, forKey: key) } else { Preferences.store.removeObject(forKey: key) }
        }
        Preferences.store.removeObject(forKey: key)
        Preferences.store.set(true, forKey: legacy)
        XCTAssertEqual(WakePolicy.stored, .overseerAndPeers)
        XCTAssertNil(Preferences.store.object(forKey: legacy))
        Preferences.store.removeObject(forKey: key)
        Preferences.store.set(false, forKey: legacy)
        XCTAssertEqual(WakePolicy.stored, .overseer)
        Preferences.store.removeObject(forKey: key)
        Preferences.store.removeObject(forKey: legacy)
        XCTAssertEqual(WakePolicy.stored, .overseer)
    }
}

@MainActor
final class CanWakeTests: XCTestCase {
    private let now = Date()

    /// A queued message types only into a running, unsuspended agent at an idle or finished
    /// prompt the user hasn't just typed into.
    func testATileIsWokenOnlyWhenItCanTakeThePrompt() {
        XCTAssertTrue(Workspace.canWake(activity: .idle, isAgent: true, running: true, suspended: false, lastUserInputAt: nil, now: now))
        XCTAssertTrue(Workspace.canWake(activity: .done, isAgent: true, running: true, suspended: false, lastUserInputAt: nil, now: now))
        // A bare shell is never typed into, whatever its state.
        XCTAssertFalse(Workspace.canWake(activity: .idle, isAgent: false, running: true, suspended: false, lastUserInputAt: nil, now: now))
        // Busy, asking, starting, or ended: wait or never.
        for activity in [TileActivity.working, .needsInput, .starting, .exited, .failed] {
            XCTAssertFalse(Workspace.canWake(activity: activity, isAgent: true, running: true, suspended: false, lastUserInputAt: nil, now: now), "\(activity)")
        }
        XCTAssertFalse(Workspace.canWake(activity: .idle, isAgent: true, running: false, suspended: false, lastUserInputAt: nil, now: now))
        XCTAssertFalse(Workspace.canWake(activity: .idle, isAgent: true, running: true, suspended: true, lastUserInputAt: nil, now: now))
        // The user's own typing is waited out.
        XCTAssertFalse(Workspace.canWake(activity: .idle, isAgent: true, running: true, suspended: false,
                                       lastUserInputAt: now.addingTimeInterval(-10), now: now))
        XCTAssertTrue(Workspace.canWake(activity: .idle, isAgent: true, running: true, suspended: false,
                                        lastUserInputAt: now.addingTimeInterval(-30), now: now))
        // A tile just woken is left alone until it has had time to take the message: the paste's
        // Return hasn't landed when the pump looks again, so the cooldown stands in for it.
        XCTAssertFalse(Workspace.canWake(activity: .idle, isAgent: true, running: true, suspended: false,
                                         lastUserInputAt: nil, lastWokeAt: now.addingTimeInterval(-5), now: now))
        XCTAssertTrue(Workspace.canWake(activity: .idle, isAgent: true, running: true, suspended: false,
                                        lastUserInputAt: nil, lastWokeAt: now.addingTimeInterval(-15), now: now))
        XCTAssertTrue(Workspace.canWake(activity: .idle, isAgent: true, running: true, suspended: false,
                                        lastUserInputAt: nil, lastWokeAt: nil, now: now))
    }
}
