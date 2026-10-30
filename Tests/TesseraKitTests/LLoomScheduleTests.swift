import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// A LLooM head's `GET /gateway/schedule` reply, as LLooM's own schedule module produced it:
/// a pair lease running out with a job reporting on it and an agent waiting, a stuck restore,
/// a build slot in use, a resource with a bad configuration, and jobs in every state.
private let board = #"""
{
 "schemaVersion": 1,
 "now": 1800001920000,
 "seq": 21,
 "resources": [
  {
   "id": "pair",
   "description": "two-node pair",
   "hosts": [
    "gpu-box-1",
    "gpu-box-2"
   ],
   "capacity": 1,
   "ttlMs": 1800000,
   "maxTtlMs": 28800000,
   "allowIndefinite": false,
   "onExpiry": "release",
   "actions": [
    {
     "kind": "route",
     "alias": "chat",
     "profile": "cloud",
     "node": null
    },
    {
     "kind": "suspend",
     "model": "pair-model",
     "node": null
    }
   ],
   "holders": [
    "r-8642106d"
   ],
   "queue": [
    "r-a65af390"
   ]
  },
  {
   "id": "bench",
   "description": "bench box",
   "hosts": [
    "gpu-box-3"
   ],
   "capacity": 1,
   "ttlMs": 1800000,
   "maxTtlMs": 28800000,
   "allowIndefinite": false,
   "onExpiry": "release",
   "actions": [
    {
     "kind": "suspend",
     "model": "bench-model",
     "node": null
    }
   ],
   "holders": [
    "r-c60ba4d9"
   ],
   "queue": []
  },
  {
   "id": "builds",
   "description": null,
   "hosts": [],
   "capacity": 2,
   "ttlMs": 1800000,
   "maxTtlMs": 28800000,
   "allowIndefinite": false,
   "onExpiry": "release",
   "actions": [],
   "holders": [
    "r-2d5806cb"
   ],
   "queue": []
  },
  {
   "id": "broken",
   "error": "reservation resource broken: suspend/routes require capacity 1",
   "holders": [],
   "queue": []
  }
 ],
 "reservations": [
  {
   "id": "r-8642106d",
   "resource": "pair",
   "owner": "main",
   "purpose": "decode A/B",
   "session": "claude:cli-1234",
   "state": "active",
   "ttlMs": 1200000,
   "createdAt": 1800000000000,
   "updatedAt": 1800000960000,
   "startedAt": 1800000000000,
   "expiresAt": 1800002160000,
   "endedAt": null,
   "endReason": null,
   "warnedAt": 1800001920000,
   "error": null,
   "steps": [
    {
     "kind": "route",
     "alias": "chat",
     "profile": "cloud",
     "node": null,
     "previous": "local",
     "status": "done"
    },
    {
     "kind": "suspend",
     "model": "pair-model",
     "node": null,
     "status": "done"
    }
   ],
   "remainingMs": 240000
  },
  {
   "id": "r-a65af390",
   "resource": "pair",
   "owner": "buildopt",
   "purpose": null,
   "session": null,
   "state": "queued",
   "ttlMs": 1800000,
   "createdAt": 1800000000000,
   "updatedAt": 1800000960000,
   "startedAt": null,
   "expiresAt": null,
   "endedAt": null,
   "endReason": null,
   "warnedAt": null,
   "error": null,
   "steps": [],
   "queuedUntil": 1800002760000,
   "position": 1
  },
  {
   "id": "r-c60ba4d9",
   "resource": "bench",
   "owner": "drafter",
   "purpose": null,
   "session": null,
   "state": "stuck",
   "ttlMs": 7200000,
   "createdAt": 1800000000000,
   "updatedAt": 1800001920000,
   "startedAt": 1800000000000,
   "expiresAt": 1800007200000,
   "endedAt": null,
   "endReason": "released",
   "warnedAt": null,
   "error": "restore failed: suspend bench-model: runtime pair-model failed health check after resume",
   "steps": [
    {
     "kind": "suspend",
     "model": "bench-model",
     "node": null,
     "status": "done",
     "error": "runtime pair-model failed health check after resume"
    }
   ]
  },
  {
   "id": "r-2d5806cb",
   "resource": "builds",
   "owner": "ci",
   "purpose": null,
   "session": null,
   "state": "active",
   "ttlMs": 7200000,
   "createdAt": 1800000000000,
   "updatedAt": 1800000000000,
   "startedAt": 1800000000000,
   "expiresAt": 1800007200000,
   "endedAt": null,
   "endReason": null,
   "warnedAt": null,
   "error": null,
   "steps": [],
   "remainingMs": 5280000
  }
 ],
 "jobs": [
  {
   "id": "j-d9c3ff54",
   "title": "decode A/B",
   "owner": "main",
   "session": "claude:cli-1234",
   "reservationId": "r-8642106d",
   "resource": "pair",
   "state": "running",
   "startedAt": 1800000000000,
   "heartbeatAt": 1800000960000,
   "endedAt": null,
   "staleAfterMs": 1800000,
   "stalledAt": null,
   "note": "arm 3",
   "notes": [
    {
     "at": 1800000000000,
     "text": "building"
    },
    {
     "at": 1800000000000,
     "text": "arm 2"
    },
    {
     "at": 1800000960000,
     "text": "arm 3"
    }
   ],
   "progress": {
    "done": 2,
    "total": 5,
    "unit": "arms"
   },
   "metrics": {
    "tok_s": 58.2,
    "image": "f399caa"
   },
   "receipt": null,
   "heartbeatAgeMs": 960000,
   "health": "ok"
  },
  {
   "id": "j-a5cc8f2e",
   "title": "NLL receipts",
   "owner": "drafter",
   "session": null,
   "reservationId": null,
   "resource": null,
   "state": "running",
   "startedAt": 1800000000000,
   "heartbeatAt": 1800000000000,
   "endedAt": null,
   "staleAfterMs": 600000,
   "stalledAt": 1800001920000,
   "note": null,
   "notes": [],
   "progress": null,
   "metrics": {},
   "receipt": null,
   "heartbeatAgeMs": 1920000,
   "health": "stalled"
  },
  {
   "id": "j-48a46346",
   "title": "kernel sweep",
   "owner": "ci",
   "session": null,
   "reservationId": null,
   "resource": null,
   "state": "done",
   "startedAt": 1800000000000,
   "heartbeatAt": 1800000000000,
   "endedAt": 1800000000000,
   "staleAfterMs": 900000,
   "stalledAt": null,
   "note": "flat vs baseline",
   "notes": [
    {
     "at": 1800000000000,
     "text": "flat vs baseline"
    }
   ],
   "progress": null,
   "metrics": {},
   "receipt": "receipts/sweep.json",
   "heartbeatAgeMs": 1920000,
   "health": "done"
  },
  {
   "id": "j-1e0e9ca1",
   "title": "image build",
   "owner": "ci",
   "session": null,
   "reservationId": null,
   "resource": null,
   "state": "failed",
   "startedAt": 1800000000000,
   "heartbeatAt": 1800000000000,
   "endedAt": 1800000000000,
   "staleAfterMs": 900000,
   "stalledAt": null,
   "note": "out of disk",
   "notes": [
    {
     "at": 1800000000000,
     "text": "out of disk"
    }
   ],
   "progress": null,
   "metrics": {},
   "receipt": null,
   "heartbeatAgeMs": 1920000,
   "health": "failed"
  }
 ]
}
"""#

final class LLoomScheduleTests: XCTestCase {
    private func parsed() throws -> LLoomSchedule.Board { try LLoomSchedule.parse(Data(board.utf8)) }
    private func item(_ title: String, in items: [LLoomSchedule.Item]) -> LLoomSchedule.Item? { items.first { $0.title == title } }

    func testRequestAsksTheHeadWithItsKey() throws {
        let base = try XCTUnwrap(LLoomSchedule.baseURL(" http://lloom.example:8100 "))
        let request = LLoomSchedule.request(base: base, token: "admin-key")
        XCTAssertEqual(request.url?.absoluteString, "http://lloom.example:8100/gateway/schedule")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer admin-key")
        XCTAssertNil(LLoomSchedule.request(base: base, token: nil).value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(LLoomSchedule.baseURL("ftp://lloom.example"))
        XCTAssertNil(LLoomSchedule.baseURL("lloom.example:8100"))
    }

    func testJobsBecomeTilesThatSayHowTheyAreGoing() throws {
        let items = LLoomSchedule.items(try parsed(), lookback: 36 * 3600)
        let running = try XCTUnwrap(item("decode A/B", in: items))
        XCTAssertTrue(running.id.hasPrefix(LLoomSchedule.idPrefix))
        XCTAssertEqual(running.activity, .working)
        XCTAssertEqual(running.subtitle, "main · pair")
        XCTAssertEqual(running.detail, "arm 3 · 2/5 arms · image f399caa tok_s 58.2")
        XCTAssertEqual(try XCTUnwrap(running.progress), 0.4, accuracy: 0.001)
        XCTAssertEqual(running.notes.map(\.text), ["building", "arm 2", "arm 3"])
        XCTAssertEqual(running.session, "claude:cli-1234")

        let quiet = try XCTUnwrap(item("NLL receipts", in: items))
        XCTAssertEqual(quiet.activity, .failed)
        XCTAssertEqual(quiet.detail, "No report for 32m")
        // It needs the user from the moment it went quiet, not from its last report.
        XCTAssertEqual(quiet.changedAt.timeIntervalSince1970, 1_800_001_920, accuracy: 0.5)

        XCTAssertEqual(item("kernel sweep", in: items)?.activity, .done)
        XCTAssertEqual(item("kernel sweep", in: items)?.detail, "flat vs baseline")
        XCTAssertEqual(item("image build", in: items)?.activity, .failed)
        // Ended work leaves once it is older than the board's lookback.
        XCTAssertNil(item("kernel sweep", in: LLoomSchedule.items(try parsed(), lookback: 60)))
        XCTAssertNotNil(item("decode A/B", in: LLoomSchedule.items(try parsed(), lookback: 60)))
    }

    func testLeasesThatNeedSomeoneJoinTheQueue() throws {
        let items = LLoomSchedule.items(try parsed(), lookback: 36 * 3600)
        let expiring = try XCTUnwrap(item("pair lease expiring", in: items))
        XCTAssertEqual(expiring.activity, .needsInput)
        XCTAssertEqual(expiring.detail, "4m left · lloom renew pair")
        XCTAssertEqual(expiring.session, "claude:cli-1234")
        let stuck = try XCTUnwrap(item("bench restore failed", in: items))
        XCTAssertEqual(stuck.activity, .failed)
        XCTAssertTrue(stuck.detail?.contains("failed health check") == true)
        // A lease that is simply held, or waiting, is the band's business, not a tile.
        XCTAssertEqual(items.filter { $0.subtitle.hasSuffix("· lease") }.count, 2)
    }

    /// Job tiles are opt-in; off, only what wants the user is published as a tile.
    func testWantsUserKeepsOnlyWhatNeedsSomeone() throws {
        let items = LLoomSchedule.items(try parsed(), lookback: 36 * 3600)
        XCTAssertEqual(item("decode A/B", in: items)?.wantsUser, false)        // running
        XCTAssertEqual(item("kernel sweep", in: items)?.wantsUser, false)      // done
        XCTAssertEqual(item("NLL receipts", in: items)?.wantsUser, true)       // stalled
        XCTAssertEqual(item("image build", in: items)?.wantsUser, true)        // failed
        XCTAssertEqual(item("pair lease expiring", in: items)?.wantsUser, true)   // warned lease
        XCTAssertEqual(item("bench restore failed", in: items)?.wantsUser, true)  // stuck lease
    }

    func testLanesSayWhoHoldsWhat() throws {
        let lanes = LLoomSchedule.lanes(try parsed())
        XCTAssertEqual(lanes.map(\.id), ["pair", "bench", "builds", "broken"])
        let pair = lanes[0]
        XCTAssertEqual(pair.state, .attention)
        XCTAssertEqual(pair.holders, ["main"])
        XCTAssertEqual(pair.queued, 1)
        XCTAssertEqual(try XCTUnwrap(pair.remaining), 240, accuracy: 1)
        XCTAssertTrue(pair.help.contains("gpu-box-1, gpu-box-2"))
        XCTAssertTrue(pair.help.contains("Waiting: buildopt"))
        XCTAssertEqual(lanes[1].state, .attention)
        XCTAssertEqual(lanes[2].state, .held)
        XCTAssertEqual(lanes[2].capacity, 2)
        XCTAssertEqual(lanes[3].state, .unusable)
    }

    func testAJobTileOpensItsAgentsConversation() throws {
        let job = try XCTUnwrap(item("decode A/B", in: LLoomSchedule.items(try parsed(), lookback: 3600)))
        let session = FleetService.session(job)
        XCTAssertEqual(session.flavor, .lloom)
        XCTAssertEqual(session.link, "claude:cli-1234")
        XCTAssertEqual(session.progress, job.progress)
        XCTAssertEqual(session.snapshot.items.count, 3)
        XCTAssertEqual(session.snapshot.lastEventAt, job.changedAt)
        XCTAssertNil(session.openURL)
    }
}
