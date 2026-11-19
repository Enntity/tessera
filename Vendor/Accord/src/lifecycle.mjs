// SPDX-License-Identifier: MIT
// Session retirement shared by the store, awareness and collaboration paths.
// Retirement is durable bookkeeping only: rows stay readable by id, and only
// fresh authenticated activity clears it.
import { requireThat, integer } from "./common.mjs";
export const lifecycleDefaults = { observedRetireMs: 86400000, joinedRetireMs: 259200000, notify: [] };
// An orphaned hold releases after this grace; a resource may shorten or
// lengthen it through its manifest. Cooperative age-out defaults to 30 days.
export const orphanGraceDefaultMs = 900000, cooperativeAgeOutDefaultMs = 30 * 86400000;
// A retiring holder orphans its reservations only for an affirmative end; a
// silent holder is the stale-holder path, and a closed one is fenced at once.
export const orphaningReasons = new Set(["tile-closed", "process-exited", "superseded", "operator"]);

// An actor (local session id or remote route actor) marks its active claims
// orphaned; a later notice within the same mark never overwrites the first.
export function orphanClaims(db, emit, now, actor, reason) {
  for (const r of db
    .prepare(`SELECT r.id reservation, c.id claim, c.resource, c.generation FROM reservations r JOIN claims c ON c.task_id=r.task_id
      WHERE c.actor=? AND c.state IN ('preparing','running') AND r.orphaned_at IS NULL`)
    .all(actor)) {
    db.prepare("UPDATE reservations SET orphaned_at=?,orphan_reason=? WHERE id=?").run(now, reason, r.reservation);
    emit("reservation.orphaned", { reservation: r.reservation, claim: r.claim, resource: r.resource, actor, reason });
  }
}

// A retired or revived local session tells each linked host once, so remote
// actors that speak for it release or reclaim their holds. The dedupe index
// collapses a repeated enqueue inside the same millisecond; the receiver
// applies idempotently either way.
export function enqueueLifecycle(db, now, session, event, { reason = "", successor = "" } = {}) {
  const payload = JSON.stringify({ session, event, ...(reason ? { reason } : {}), ...(successor ? { successor } : {}), at: now });
  for (const link of db.prepare("SELECT authority FROM links").all())
    db.prepare("INSERT OR IGNORE INTO lifecycle_outbox(authority,session_id,event,reason,successor,at,payload,state,created_at) VALUES(?,?,?,?,?,?,?,'queued',?)")
      .run(link.authority, session, event, reason, successor, now, payload, now);
}

export function parseLifecycle(raw) {
  const c = raw ?? {};
  const ms = (value, fallback) =>
    value === undefined ? fallback : Math.min(Math.max(Number(value) || fallback, 60000), 30 * 86400000);
  return {
    observedRetireMs: ms(c.observedRetireMs, lifecycleDefaults.observedRetireMs),
    joinedRetireMs: ms(c.joinedRetireMs, lifecycleDefaults.joinedRetireMs),
    notify: Array.isArray(c.notify) ? c.notify.filter((a) => typeof a === "string" && a.length <= 220).slice(0, 16) : [],
    // Sources the transcript scanner refreshes from file activity; the server
    // fills this from awareness.json roots, so it is absent in tests unless set.
    scannedSources: Array.isArray(c.scannedSources) ? c.scannedSources.filter((s) => typeof s === "string").slice(0, 16) : [],
  };
}

// Manifest lifecycle fields, declared per resource: how long an orphaned hold
// survives before release (0 releases at once, up to a day), and for
// cooperative resources how long an idle registration lasts (0 means never).
export function lifecycleFields(value, { ageOut = false } = {}) {
  const out = {};
  if (value.orphanGraceMs !== undefined) { integer(value.orphanGraceMs, "orphanGraceMs", 0, 86400000); out.orphanGraceMs = value.orphanGraceMs; }
  requireThat(ageOut || value.ageOutMs === undefined, "RESOURCE_MANIFEST", "ageOutMs is only available for cooperative resources", 400);
  if (ageOut && value.ageOutMs !== undefined) { integer(value.ageOutMs, "ageOutMs", 0, 365 * 86400000); out.ageOutMs = value.ageOutMs; }
  return out;
}

// Resolving an incident merges into its recorded evidence: the observations
// and attempts already there explain why it was opened.
export function resolveSubjectIncidents(db, now, id) {
  db.prepare("UPDATE overseer_incidents SET state='resolved',updated_at=?,evidence=json_set(COALESCE(NULLIF(evidence,''),'{}'),'$.resolution','subject-retired') WHERE session_id=? AND state!='resolved'")
    .run(now, id);
}

// Caller supplies the transaction; every branch is a no-op when the row is
// already retired, so a replayed retirement emits once — except positive end
// evidence, which upgrades a silent retirement because the retired session may
// hold claims on linked hosts this one knows nothing about.
export function applyRetirement(db, emit, now, id, { reason, successor } = {}) {
  const cond = orphaningReasons.has(reason)
    ? "(retired_at IS NULL OR retired_reason='silent')"
    : "retired_at IS NULL";
  const sessionChanged = db
    .prepare(`UPDATE sessions SET retired_at=COALESCE(retired_at,?),retired_reason=?,successor=COALESCE(?,successor) WHERE id=? AND ${cond}`)
    .run(now, reason, successor ?? null, id).changes;
  const changed = sessionChanged + db
    .prepare(`UPDATE session_views SET retired_at=COALESCE(retired_at,?),retired_reason=?,successor=COALESCE(?,successor) WHERE id=? AND ${cond}`)
    .run(now, reason, successor ?? null, id).changes;
  if (!changed) return false;
  resolveSubjectIncidents(db, now, id);
  if (orphaningReasons.has(reason)) orphanClaims(db, emit, now, id, reason);
  // Only an enrolled session speaks on other hosts; observations stay local.
  if (sessionChanged) enqueueLifecycle(db, now, id, "retired", { reason, successor: successor ?? "" });
  emit("session.retired", { session: id, reason, ...(successor ? { successor } : {}) });
  return true;
}

export function lifecycleFor(row, now, { observedMs = lifecycleDefaults.observedRetireMs, joinedMs = lifecycleDefaults.joinedRetireMs, scanned = [] } = {}) {
  if (row.retired_at !== null && row.retired_at !== undefined) return "retired";
  if (["exited", "cancelled"].includes(row.state)) return "exited";
  const last = Math.max(row.heartbeat_at ?? 0, row.progress_at ?? 0, row.observed_at ?? 0);
  if (now - last <= 120000) return "live";
  // Enrolled sessions and adapter-reported observations get the joined
  // threshold; only transcript-scanned observations use the shorter one.
  const threshold = row.source !== "agent" && scanned.includes(row.source) ? observedMs : joinedMs;
  if (now - last < threshold) return "idle";
  return "stale";
}
