// SPDX-License-Identifier: MIT
// State/fingerprint/settle semantics adapted from Tessera Steward and AgentDesk.
import { hash, id, integer, requireThat, text, token } from "./common.mjs";
import { applyRetirement, enqueueLifecycle, lifecycleFor, parseLifecycle, lifecycleDefaults } from "./lifecycle.mjs";

export const awarenessSchema = `
CREATE TABLE remote_routes(actor TEXT PRIMARY KEY REFERENCES actors(id),authority TEXT NOT NULL,session_id TEXT NOT NULL);
CREATE TABLE session_bindings(source TEXT NOT NULL,external_id TEXT NOT NULL,actor TEXT NOT NULL REFERENCES actors(id),PRIMARY KEY(source,external_id));
CREATE TABLE source_privacy(source TEXT PRIMARY KEY,private INTEGER NOT NULL);
CREATE TABLE session_views(id TEXT PRIMARY KEY REFERENCES actors(id),owner TEXT NOT NULL,source TEXT NOT NULL,external_id TEXT,
 title TEXT NOT NULL,state TEXT NOT NULL,location TEXT NOT NULL,detail TEXT NOT NULL,private INTEGER NOT NULL DEFAULT 0,
 observed_at INTEGER NOT NULL,heartbeat_at INTEGER NOT NULL,progress_at INTEGER NOT NULL,revision INTEGER NOT NULL DEFAULT 1,
 fingerprint TEXT NOT NULL,summary TEXT NOT NULL,summary_kind TEXT NOT NULL,summary_revision INTEGER NOT NULL DEFAULT 1,
 expected_at INTEGER,snoozed_until INTEGER NOT NULL DEFAULT 0,UNIQUE(source,external_id));
CREATE TABLE session_activity(seq INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL REFERENCES session_views(id),
 external_key TEXT NOT NULL,at INTEGER NOT NULL,kind TEXT NOT NULL,body TEXT NOT NULL,UNIQUE(session_id,external_key));
CREATE VIRTUAL TABLE session_search USING fts5(session_id UNINDEXED,title,location,detail,summary,body,tokenize='unicode61');
CREATE TABLE overseer_rules(id TEXT PRIMARY KEY,config TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1);
CREATE TABLE overseer_incidents(id TEXT PRIMARY KEY,rule_id TEXT NOT NULL,subject TEXT NOT NULL,session_id TEXT NOT NULL REFERENCES session_views(id),
 state TEXT NOT NULL,evidence TEXT NOT NULL,opened_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,last_sent INTEGER NOT NULL DEFAULT 0,
 attempts INTEGER NOT NULL DEFAULT 0,episode INTEGER NOT NULL DEFAULT 1,UNIQUE(rule_id,subject));
CREATE TABLE overseer_samples(rule_id TEXT NOT NULL,subject TEXT NOT NULL,first_at INTEGER NOT NULL,last_at INTEGER NOT NULL,fingerprint TEXT NOT NULL,PRIMARY KEY(rule_id,subject));
CREATE TABLE agent_jobs(id TEXT PRIMARY KEY,actor TEXT NOT NULL REFERENCES actors(id),title TEXT NOT NULL,state TEXT NOT NULL,
 note TEXT NOT NULL,progress TEXT,metrics TEXT NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,reservation_id TEXT);
CREATE TABLE human_questions(id TEXT PRIMARY KEY,actor TEXT NOT NULL REFERENCES actors(id),question TEXT NOT NULL,options TEXT NOT NULL,
 state TEXT NOT NULL,answer TEXT,created_at INTEGER NOT NULL,answered_at INTEGER);
`;
// Tessera Redactor patterns; redact before persistence, indexing, or model input.
export function redact(value) {
  let s = String(value ?? "");
  for (const re of [
    /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g,
    /\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}/g,
    /\blloom_[a-z]+_[0-9a-f]{16,}/g,
    /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/g,
    /\bxox[abposr]-[A-Za-z0-9-]{10,}/g,
    /\bAKIA[0-9A-Z]{16}\b/g,
    /\bAIza[0-9A-Za-z_-]{35}/g,
    /\b(?:r8|hf|jina|xai)_[A-Za-z0-9]{20,}/g,
    /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g,
    /\baccord_[A-Za-z0-9_-]{20,}/g,
    /\b[sr]k_(?:live|test)_[A-Za-z0-9]{10,}/g,
    /\bnpm_[A-Za-z0-9]{20,}/g,
    /\bglpat-[A-Za-z0-9_-]{16,}/g,
    /\bya29\.[A-Za-z0-9_-]{20,}/g,
  ])
    s = s.replace(re, "[secret]");
  return s
    .replace(/\b((?:set-)?cookie:\s*)[^\r\n]+/gi, "$1[secret]")
    .replace(/\b(authorization:\s*(?:basic|bearer|token)?\s*)\S+/gi, "$1[secret]")
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/[^\s:/@]*:)[^\s@/]+(@)/gi, "$1[secret]$2")
    .replace(/(\s(?:-u|--user)\s+[^\s:]+:)\S+/g, "$1[secret]")
    .replace(/\b((?:password|passphrase)\s+is\s+)\S+/gi, "$1[secret]")
    .replace(
      /\b(bearer\s+|[A-Z0-9_-]*(?:api[_-]?key|access[_-]?key|private[_-]?key|token|secret|password|passwd|pwd)[A-Z0-9_-]*["']?\s*[:=]\s*["']?)([^\s"',;}]{6,})/gi,
      "$1[secret]",
    );
}
const terminal = new Set(["done", "failed", "exited", "cancelled"]);
const DEFAULT_LABELS = new Set(['MCP agent', 'shell agent', 'agent']);
// A live MCP session heartbeats every 30 s and observers stop reading transcripts this
// old, so a session silent this long has nobody left to report for it.
export const staleSessionMs = 36 * 3600000;
export const sessionStates = [
  "starting",
  "working",
  "idle",
  "waiting",
  "blocked",
  "done",
  "failed",
  "exited",
  "cancelled",
  "unknown",
];
export class SessionAwareness {
  constructor(store, { hostName = 'local' } = {}) {
    this.store = store;
    this.db = store.db;
    this.hostName = hostName;
    // The server installs the operator's lifecycle section from awareness.json.
    this.lifecycleConfig = () => lifecycleDefaults;
  }
  thresholds() {
    const c = parseLifecycle(this.lifecycleConfig());
    return { observedMs: c.observedRetireMs, joinedMs: c.joinedRetireMs, scanned: c.scannedSources };
  }
  lifecycleFloor() {
    return Number(
      this.db.prepare("SELECT value FROM meta WHERE key='lifecycle_since'").get()?.value ?? 0,
    );
  }
  // Retirement clears only on fresh authenticated activity; a closed session's
  // credential is gone before this can run, so nothing here reopens it.
  revive(subject) {
    const session = this.db.prepare("SELECT closed_at FROM sessions WHERE id=?").get(subject);
    if (session && session.closed_at !== null) return;
    const sessionChanged = this.db
      .prepare("UPDATE sessions SET retired_at=NULL,retired_reason=NULL WHERE id=? AND retired_at IS NOT NULL")
      .run(subject).changes;
    const changed = sessionChanged + this.db
      .prepare("UPDATE session_views SET retired_at=NULL,retired_reason=NULL WHERE id=? AND retired_at IS NOT NULL")
      .run(subject).changes;
    if (changed) {
      // Revival within grace reclaims the same claims and generations; nothing
      // transfers to a successor, which has to reserve again.
      for (const r of this.db
        .prepare(`SELECT r.id reservation, c.id claim FROM reservations r JOIN claims c ON c.task_id=r.task_id
          WHERE c.actor=? AND c.state IN ('preparing','running') AND r.orphaned_at IS NOT NULL`)
        .all(subject)) {
        this.db.prepare("UPDATE reservations SET orphaned_at=NULL,orphan_reason=NULL WHERE id=?").run(r.reservation);
        this.store.emit("reservation.reclaimed", { reservation: r.reservation, claim: r.claim, actor: subject });
      }
      if (sessionChanged) enqueueLifecycle(this.db, this.store.now(), subject, "revived");
      this.store.emit("session.revived", { session: subject });
    }
  }
  retireRow(id, options) {
    return applyRetirement(this.db, (kind, data) => this.store.emit(kind, data), this.store.now(), id, options);
  }
  bind(actor, body) {
    requireThat(
      actor.role === "admin",
      "FORBIDDEN",
      "Only the host launcher may bind native identity",
      403,
    );
    text(body.source, "source", 64);
    text(body.externalId, "externalId", 200);
    requireThat(
      this.db
        .prepare(
          "SELECT id FROM sessions WHERE id=? AND closed_at IS NULL AND expires_at>?",
        )
        .get(body.actor, this.store.now()),
      "SESSION_EXPIRED",
      "Binding requires a live authenticated session",
    );
    return this.store.command(actor, body, "session.bind", () => {
      // Only a trusted host binding can grant the resumed conversation access
      // to prior mailboxes. Neither labels nor working directories establish this.
      this.db.prepare('INSERT OR IGNORE INTO session_mailbox_aliases VALUES(?,?,?)').run(body.source,body.externalId,body.actor);
      const prior=this.db.prepare('SELECT actor FROM session_bindings WHERE source=? AND external_id=?').get(body.source,body.externalId);
      this.db
        .prepare(
          "INSERT INTO session_bindings VALUES(?,?,?) ON CONFLICT(source,external_id) DO UPDATE SET actor=excluded.actor",
        )
        .run(body.source, body.externalId, body.actor);
      // A rebound conversation belongs to the new actor; the displaced one is
      // retired with a successor pointer so stale addresses still resolve.
      if(prior&&prior.actor!==body.actor)
        this.retireRow(prior.actor,{reason:'superseded',successor:body.actor});
      return { bound: true, ...(prior&&prior.actor!==body.actor?{superseded:prior.actor}:{}) };
    });
  }
  // A non-exclusive link between an actor and the tile it runs in. Unlike a
  // mailbox binding it displaces nothing: one tile can hold many nested
  // sessions, while an actor belongs to one tile at a time.
  linkTile(actor, body) {
    requireThat(actor.role === "admin", "FORBIDDEN", "Only the host launcher may link tiles", 403);
    text(body.actor, "actor", 128); text(body.tile, "tile", 200);
    requireThat(["agent", "nested"].includes(body.role), "INVALID_INPUT", "role is agent or nested", 400);
    requireThat(
      this.db.prepare("SELECT id FROM sessions WHERE id=? AND closed_at IS NULL AND expires_at>?").get(body.actor, this.store.now()),
      "SESSION_EXPIRED", "Linking requires a live authenticated session");
    return this.store.command(actor, body, "session.link-tile", () => {
      this.db
        .prepare("INSERT INTO agent_tiles VALUES(?,?,?,?) ON CONFLICT(actor) DO UPDATE SET tile=excluded.tile,role=excluded.role,linked_at=excluded.linked_at")
        .run(body.actor, body.tile, body.role, this.store.now());
      return { linked: true };
    });
  }
  designate(actor, body) {
    requireThat(actor.role === "admin", "FORBIDDEN", "Administrator required", 403);
    const address = body.address ?? null;
    if (address !== null) {
      text(address, "address", 220);
      const [authority, recipient] = String(address).split("/");
      requireThat(authority === this.store.authority && recipient, "INVALID_INPUT", "Designate a local address, or null to clear", 400);
    }
    return this.store.command(actor, body, "overseer.designate", () => {
      if (address === null) this.db.prepare("DELETE FROM meta WHERE key='overseer_address'").run();
      else this.db.prepare("INSERT INTO meta VALUES('overseer_address',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(address);
      this.store.emit("overseer.designated", { address, by: actor.id });
      return { overseer: address };
    });
  }
  overseerAddress() {
    return this.db.prepare("SELECT value FROM meta WHERE key='overseer_address'").get()?.value ?? null;
  }
  row(session) {
    const row = this.db
      .prepare("SELECT * FROM session_views WHERE id=?")
      .get(session);
    requireThat(row, "NOT_FOUND", "Unknown observed session", 404);
    return row;
  }
  hideInternal(source, externalId) {
    // Host observer classification only: keep the source transcript and durable
    // identity intact, but remove it from collaboration and monitoring views.
    return this.store.mutate(() => {
      const row=this.db.prepare('SELECT id,hidden FROM session_views WHERE source=? AND external_id=?').get(source,externalId);
      if(!row||row.hidden)return;
      this.db.prepare('UPDATE session_views SET hidden=1,revision=revision+1 WHERE id=?').run(row.id);
      this.db.prepare('DELETE FROM session_search WHERE session_id=?').run(row.id);
      this.db.prepare("UPDATE overseer_incidents SET state='resolved',updated_at=? WHERE session_id=?").run(this.store.now(),row.id);
      this.db.prepare('DELETE FROM overseer_samples WHERE subject=?').run(row.id);
      this.store.emit('session.hidden',{session:row.id,reason:'internal-harness-session'});
    });
  }
  public(row) {
    const binding = !row.private && row.source === 'agent'
      ? this.db.prepare('SELECT source,external_id FROM session_bindings WHERE actor=? ORDER BY source,external_id LIMIT 1').get(row.id) : null;
    const origin=this.db.prepare('SELECT authority,session_id FROM remote_routes WHERE actor=?').get(row.id);
    return {
      ...(!row.private && row.parent_session ? {parentSession:JSON.parse(row.parent_session)} : {}),
      ...(!row.private && origin ? {originAddress:origin.authority+'/'+origin.session_id} : {}),
      ...(binding ? {nativeSession:{source:binding.source,externalId:binding.external_id}} : {}),
      ...(() => {
        if (row.private) return {};
        const layers = {};
        for (const t of this.db.prepare("SELECT layer,title,by,at FROM titles WHERE subject=?").all(row.id)) layers[t.layer] = t;
        const top = layers.operator ?? layers.overseer ?? layers.peer;
        const agent = (!row.source || row.source === "agent") ? { agent: this.agentRecord(row.id) } : {};
        return {
          ...(top ? { givenTitle: top.title, titledBy: top.by ? `${this.store.authority}/${top.by}` : undefined, titledAt: top.at } : {}),
          ...agent,
        };
      })(),
      id: row.id,
      address: `${this.store.authority}/${row.id}`,
      source: row.source,
      externalId: row.external_id,
      title: row.private ? "Private session" : row.title,
      state: row.state,
      location: row.private ? "" : row.location,
      private: !!row.private,
      detail: row.private ? "" : row.detail,
      summary: row.private ? "" : row.summary,
      summaryKind: row.summary_kind,
      summaryDetails: row.private ? {} : row.summary_kind === 'model' && row.summary_revision === row.revision
        ? JSON.parse(row.summary_details) : {blocked:['waiting','blocked'].includes(row.state),needs:['waiting','blocked'].includes(row.state)?row.detail:null},
      summaryRevision: row.summary_revision,
      revision: row.revision,
      observedAt: row.observed_at,
      heartbeatAt: row.heartbeat_at,
      progressAt: row.progress_at,
      expectedAt: row.expected_at,
      snoozedUntil: row.snoozed_until,
      presence:
        this.store.now() - row.heartbeat_at < 120000 ? "recent" : "unknown",
      lifecycle: lifecycleFor(row, this.store.now(), this.thresholds()),
      ...(row.retired_at !== null && row.retired_at !== undefined
        ? { retiredAt: row.retired_at, retiredReason: row.retired_reason }
        : {}),
      ...(row.successor ? { successor: `${this.store.authority}/${row.successor}` } : {}),
      terminal: terminal.has(row.state),
    };
  }
  announce(actor, body) {
    const previous = this.db.prepare('SELECT state FROM session_views WHERE id=?').get(actor.id);
    return this.report(actor, {
      key: hash('report:' + body.key), title: body.label, detail: body.activity,
      location: body.location,
      state: body.state ?? previous?.state ?? 'working',
    });
  }
  report(actor, body) {
    const source = body.source ?? "agent";
    text(source, "source", 64);
    if (source !== "agent")
      requireThat(
        actor.role === "admin",
        "FORBIDDEN",
        "Host adapters require administrator authority",
        403,
      );
    const external =
        source === "agent" ? null : text(body.externalId, "externalId", 200),
      session = external
        ? `observed-${hash(source + "/" + external).slice(0, 40)}`
        : actor.id;
    text(body.title ?? actor.session?.label ?? actor.id, "title", 200);
    requireThat(
      sessionStates.includes(body.state ?? "working"),
      "INVALID_INPUT",
      "Invalid session state",
      400,
    );
    requireThat(
      !body.events || (Array.isArray(body.events) && body.events.length <= 50),
      "INVALID_INPUT",
      "At most 50 events per report",
      400,
    );
    if (body.expectedAt !== undefined && body.expectedAt !== null)
      integer(
        body.expectedAt,
        "expectedAt",
        this.store.now(),
        this.store.now() + 7 * 86400000,
      );
    if(body.parentSession !== undefined) {
      requireThat(actor.role === 'admin' && source !== 'agent','FORBIDDEN','Only host observers may report parent relationships',403);
      if(body.parentSession !== null) {
        text(body.parentSession.source,'parent source',64); text(body.parentSession.externalId,'parent externalId',200);
        requireThat(body.parentSession.source !== source || body.parentSession.externalId !== external,'INVALID_INPUT','A session cannot parent itself');
      }
    }
    const events = (body.events ?? []).map((e) => ({
      key: text(e.key, "event key", 200),
      kind: text(e.kind ?? "message", "event kind", 40),
      body: redact(text(e.text, "event text", 16000)),
    }));
    const title = redact(body.title ?? actor.session?.label ?? actor.id),
      location = redact(body.location ?? "").slice(0, 1000),
      detail = redact(body.detail ?? "").slice(0, 4000),
      state = body.state ?? "working",
      privacy =
        body.private === true ||
        this.db
          .prepare("SELECT private FROM source_privacy WHERE source=?")
          .get(source)?.private === 1;
    const persist =
      source === "agent"
        ? (fn) => this.store.command(actor, body, "session.report", fn)
        : (fn) => this.store.mutate(fn);
    return persist(() => {
      const old = this.db
          .prepare("SELECT * FROM session_views WHERE id=?")
          .get(session),
        now = this.store.now();
      requireThat(
        !old || old.owner === actor.id || actor.role === "admin",
        "FORBIDDEN",
        "Session belongs to another adapter",
        403,
      );
      if (!this.db.prepare("SELECT id FROM actors WHERE id=?").get(session))
        this.store.provision(session, token(), "worker");
      const fresh = privacy
        ? []
        : [...new Map(events.map((e) => [e.key, e])).values()].filter(
            (e) =>
              !this.db
                .prepare(
                  "SELECT 1 FROM session_activity WHERE session_id=? AND external_key=?",
                )
                .get(session, e.key),
          );
      const fingerprint = hash(
        JSON.stringify({
          title,
          state,
          location,
          detail: privacy ? "" : detail,
          private: privacy,
          tail: fresh.at(-1)?.body ?? old?.fingerprint,
        }),
      );
      const changed =
        !old ||
        old.title !== title ||
        old.state !== state ||
        old.location !== location ||
        old.detail !== (privacy ? "" : detail) ||
        old.private !== Number(privacy) ||
        fresh.length > 0;
      if (
        body.sourceProgressAt !== undefined &&
        body.sourceProgressAt !== null
      ) {
        requireThat(
          actor.role === "admin",
          "FORBIDDEN",
          "Source timestamps require a host adapter",
          403,
        );
        // A source clock a fraction ahead of ours is clamped, not refused; a day ahead is garbage.
        integer(body.sourceProgressAt, "sourceProgressAt", 0, now + 86400000);
      }
      const revision = (old?.revision ?? 0) + (changed ? 1 : 0),
        progress = changed ? (body.sourceProgressAt == null ? now : Math.min(body.sourceProgressAt, now)) : old.progress_at;
      // A host-observed exit is positive end evidence. Bound actors retire
      // only when the reporter owns the observation: another adapter's exit
      // report must not retire sessions it does not own. This also runs for a
      // report on an already-retired observation, whose bound actor may still
      // be live.
      const endEvidence = () => {
        const reason = source === "tessera" ? "tile-closed" : "process-exited";
        this.retireRow(session, { reason });
        if (old?.owner === actor.id)
          for (const b of this.db
            .prepare("SELECT actor FROM session_bindings WHERE source=? AND external_id=?")
            .all(source, external))
          this.retireRow(b.actor, { reason });
      };
      // A rescan of a dead transcript must not reassert working on a retired
      // observation: only activity newer than the retirement revives it. An
      // authenticated session's own report always revives it. For a source the
      // scanner does not own, an unchanged report from the observation's owner
      // is the adapter confirming it is still live, so it refreshes the
      // heartbeat and revives.
      const endState = source !== "agent" && ["exited", "cancelled"].includes(state);
      const ownerReport = old && old.owner === actor.id;
      // A positive end report never revives; it keeps the observation retired
      // and just settles its bound actors.
      const reviving = old && old.retired_at !== null && !endState &&
        (source === "agent" ||
          (changed && progress > old.retired_at) ||
          (source !== "agent" && ownerReport && !this.thresholds().scanned.includes(source)));
      if (old && old.retired_at !== null && !reviving) {
        if (endState) endEvidence();
        return this.public(old);
      }
      if (reviving || source === "agent") this.revive(session);
      const summary = privacy
        ? ""
        : (detail || fresh.at(-1)?.body || old?.summary || title)
            .replace(/\s+/g, " ")
            .slice(0, 240);
      this.db
        .prepare(
          `INSERT INTO session_views(id,owner,source,external_id,title,state,location,detail,private,observed_at,heartbeat_at,progress_at,revision,fingerprint,summary,summary_kind,summary_revision,expected_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'extractive',?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,state=excluded.state,location=excluded.location,detail=excluded.detail,private=excluded.private,
        observed_at=excluded.observed_at,heartbeat_at=excluded.heartbeat_at,progress_at=excluded.progress_at,revision=excluded.revision,fingerprint=excluded.fingerprint,
        summary=CASE WHEN ? THEN excluded.summary ELSE session_views.summary END,summary_kind=CASE WHEN ? THEN 'extractive' ELSE session_views.summary_kind END,
        summary_revision=CASE WHEN ? THEN excluded.summary_revision ELSE session_views.summary_revision END,expected_at=excluded.expected_at`,
        )
        .run(
          session,
          actor.id,
          source,
          external,
          privacy ? "Private session" : title,
          state,
          privacy ? "" : location,
          privacy ? "" : detail,
          Number(privacy),
          now,
          now,
          progress,
          revision,
          changed ? fingerprint : old.fingerprint,
          summary,
          revision,
          body.expectedAt ?? null,
          Number(changed),
          Number(changed),
          Number(changed),
        );
      if(privacy) {
        this.db.prepare('UPDATE session_views SET given_title=NULL,titled_by=NULL,titled_at=NULL WHERE id=?').run(session);
        this.db.prepare('DELETE FROM titles WHERE subject=?').run(session);
      }
      if(body.parentSession !== undefined || privacy) this.db.prepare('UPDATE session_views SET parent_session=? WHERE id=?').run(privacy||!body.parentSession?null:JSON.stringify({source:body.parentSession.source,externalId:body.parentSession.externalId}),session);
      if (privacy) {
        this.db
          .prepare("DELETE FROM session_activity WHERE session_id=?")
          .run(session);
        this.db
          .prepare(
            "UPDATE overseer_incidents SET state='resolved',evidence='{}' WHERE session_id=?",
          )
          .run(session);
      } else
        for (const e of fresh)
          this.db
            .prepare(
              "INSERT INTO session_activity(session_id,external_key,at,kind,body) VALUES(?,?,?,?,?)",
            )
            .run(session, e.key, now, e.kind, e.body);
      this.db
        .prepare(
          "DELETE FROM session_activity WHERE session_id=? AND seq NOT IN (SELECT seq FROM session_activity WHERE session_id=? ORDER BY seq DESC LIMIT 500)",
        )
        .run(session, session);
      if (changed) {
        this.index(session);
        this.store.emit("session.observed", {
          session,
          revision,
          state,
          source,
        });
      }
      this.db
        .prepare(
          `INSERT INTO participants VALUES(?,?,? ,?,?,?) ON CONFLICT(actor) DO UPDATE SET label=excluded.label,activity=excluded.activity,location=excluded.location,updated_at=excluded.updated_at`,
        )
        .run(
          session,
          privacy ? "Private session" : title,
          JSON.stringify([source]),
          privacy ? "private session" : summary,
          privacy ? "" : location,
          now,
        );
      if (endState) endEvidence();
      return this.public(this.row(session));
    });
  }
  index(session) {
    const r = this.row(session);
    this.db
      .prepare("DELETE FROM session_search WHERE session_id=?")
      .run(session);
    if (!r.private && !r.hidden)
      this.db.prepare("INSERT INTO session_search VALUES(?,?,?,?,?,?)").run(
        session,
        [r.given_title, ...this.db.prepare("SELECT title FROM titles WHERE subject=?").all(session).map(t => t.title), r.title].filter(Boolean).join("\n"),
        r.location,
        r.detail,
        r.summary,
        this.db
          .prepare(
            "SELECT body FROM session_activity WHERE session_id=? ORDER BY seq DESC LIMIT 100",
          )
          .all(session)
          .map((r) => r.body)
          .join("\n"),
      );
  }
  privacy(actor, body) {
    requireThat(
      actor.role === "admin",
      "FORBIDDEN",
      "Only operator may change source privacy",
      403,
    );
    text(body.source, "source", 64);
    return this.store.command(actor, body, "source.privacy", () => {
      this.db
        .prepare(
          "INSERT INTO source_privacy VALUES(?,?) ON CONFLICT(source) DO UPDATE SET private=excluded.private",
        )
        .run(body.source, Number(body.private === true));
      if (body.private === true) {
        for (const row of this.db
          .prepare("SELECT id FROM session_views WHERE source=?")
          .all(body.source)) {
          this.db
            .prepare(
              "UPDATE session_views SET private=1,title='Private session',location='',detail='',summary='',given_title=NULL,titled_by=NULL,titled_at=NULL,revision=revision+1 WHERE id=?",
            )
            .run(row.id);
          this.db
            .prepare("DELETE FROM titles WHERE subject=?")
            .run(row.id);
          this.db
            .prepare("DELETE FROM session_activity WHERE session_id=?")
            .run(row.id);
          this.db
            .prepare(
              "UPDATE participants SET label='Private session',activity='private session',location='' WHERE actor=?",
            )
            .run(row.id);
          this.db
            .prepare(
              "UPDATE overseer_incidents SET state='resolved',evidence='{}' WHERE session_id=?",
            )
            .run(row.id);
          this.index(row.id);
        }
      }
      return { source: body.source, private: body.private === true };
    });
  }
  heartbeat(actor) {
    return this.store.mutate(() => {
      const now = this.store.now();
      // A heartbeat after a stale silence is a resumed session, alive but not yet working.
      this.db
        .prepare("UPDATE session_views SET state=CASE WHEN state='exited' AND heartbeat_at<:stale THEN 'idle' ELSE state END,revision=revision+(state='exited' AND heartbeat_at<:stale),heartbeat_at=:now WHERE id=:id")
        .run({ stale: now - staleSessionMs, now, id: actor.id });
      this.db
        .prepare("UPDATE participants SET updated_at=? WHERE actor=?")
        .run(now, actor.id);
      this.revive(actor.id);
      return { heartbeatAt: now };
    });
  }
  expireStale() {
    return this.store.mutate(() => {
      // A remote session's heartbeats reach its home host, which judges its silence.
      const stale = this.db.prepare(`SELECT id FROM session_views v WHERE hidden=0 AND heartbeat_at<? AND state NOT IN (${[...terminal].map(() => "?").join(",")})
          AND NOT EXISTS (SELECT 1 FROM remote_routes r WHERE r.actor=v.id)`)
          .all(this.store.now() - staleSessionMs, ...terminal),
        exit = this.db.prepare("UPDATE session_views SET state='exited',revision=revision+1 WHERE id=?");
      for (const { id } of stale) {
        exit.run(id);
        this.store.emit("session.stale", { session: id });
      }
      return { expired: stale.length };
    });
  }
  // Administrative retirement: a session id, or every actor bound to a native
  // observation such as ('tessera', tileId). Positive end evidence only.
  retire(actor, body) {
    requireThat(actor.role === "admin", "FORBIDDEN", "Administrator required", 403);
    requireThat(
      ["tile-closed", "process-exited", "operator"].includes(body.reason),
      "INVALID_INPUT",
      "reason must be tile-closed, process-exited or operator",
      400,
    );
    const bySession = body.session !== undefined;
    requireThat(
      bySession !== (body.source !== undefined || body.externalId !== undefined),
      "INVALID_INPUT",
      "Name a session id, or a source and externalId",
      400,
    );
    return this.store.command(actor, body, "lifecycle.retire", () => {
      const retired = [],
        now = this.store.now(),
        drop = (id) => {
          if (applyRetirement(this.db, (k, d) => this.store.emit(k, d), now, id, { reason: body.reason }))
            retired.push(id);
        };
      if (bySession) {
        text(body.session, "session", 200);
        requireThat(
          this.db
            .prepare("SELECT 1 FROM sessions WHERE id=? UNION SELECT 1 FROM session_views WHERE id=? LIMIT 1")
            .get(body.session, body.session),
          "NOT_FOUND",
          "Unknown session",
          404,
        );
        drop(body.session);
      } else {
        text(body.source, "source", 64);
        text(body.externalId, "externalId", 200);
        const view = this.db
            .prepare("SELECT id FROM session_views WHERE source=? AND external_id=?")
            .get(body.source, body.externalId),
          bound = this.db
            .prepare("SELECT actor FROM session_bindings WHERE source=? AND external_id=?")
            .all(body.source, body.externalId);
        requireThat(view || bound.length, "NOT_FOUND", "Nothing observed or bound there", 404);
        if (view) drop(view.id);
        for (const b of bound) drop(b.actor);
      }
      return { retired, reason: body.reason };
    });
  }
  retireCandidates({ observedMs, joinedMs, floor }) {
    const now = this.store.now(),
      held = new Set(
        this.db
          .prepare("SELECT DISTINCT actor FROM claims WHERE state IN ('preparing','running','releasing','revoking')")
          .all()
          .map((r) => r.actor),
      );
    // Silence counts heartbeat, progress, announce and report; floor lifts the
    // pre-upgrade backlog so it ages from the migration instead of its history.
    // Transcript-scanned sources refresh from file activity, so they use the
    // short threshold; adapter-reported sources (tessera and the like) use the
    // joined one, since their reporter re-reports live observations.
    const scanned = this.thresholds().scanned,
      inScanned = scanned.length ? `(${scanned.map(() => "?").join(",")})` : "(NULL)";
    const observations = this.db
        .prepare(
          `SELECT id,source,title,state FROM session_views WHERE retired_at IS NULL AND source!='agent'
           AND ?-MAX(heartbeat_at,progress_at,observed_at,?)>=CASE WHEN source IN ${inScanned} THEN ? ELSE ? END`,
        )
        .all(now, floor, ...scanned, observedMs, joinedMs),
      sessions = this.db
        .prepare(
          `SELECT s.id,s.harness,s.label title FROM sessions s
           LEFT JOIN session_views v ON v.id=s.id LEFT JOIN participants p ON p.actor=s.id
           WHERE s.retired_at IS NULL AND s.closed_at IS NULL AND s.expires_at>?
           AND ?-MAX(COALESCE(v.heartbeat_at,0),COALESCE(v.progress_at,0),COALESCE(v.observed_at,0),COALESCE(p.updated_at,0),s.created_at,?)>=?`,
        )
        .all(now, now, floor, joinedMs)
        .map((s) => ({ ...s, held: held.has(s.id) }));
    return { observations, sessions };
  }
  // The periodic silence pass. A holder of an active claim is never retired: a
  // window reservation is promised to need no heartbeat, so it goes stale and
  // notifies once per claim generation instead.
  retirePass({ observedRetireMs = lifecycleDefaults.observedRetireMs, joinedRetireMs = lifecycleDefaults.joinedRetireMs } = {}) {
    const { observations, sessions } = this.retireCandidates({
      observedMs: observedRetireMs,
      joinedMs: joinedRetireMs,
      floor: this.lifecycleFloor(),
    });
    const stale = [];
    const result = this.store.mutate(() => {
      const now = this.store.now();
      let retired = 0;
      for (const o of observations)
        if (applyRetirement(this.db, (k, d) => this.store.emit(k, d), now, o.id, { reason: "silent" })) retired++;
      for (const s of sessions) {
        if (s.held) {
          const claim = this.db
            .prepare("SELECT id,resource,generation,deadline FROM claims WHERE actor=? AND state IN ('preparing','running','releasing','revoking') ORDER BY created_at DESC LIMIT 1")
            .get(s.id);
          if (!claim) continue;
          const key = `stale:${claim.id}:${claim.generation}`;
          if (this.db.prepare("SELECT 1 FROM commands WHERE actor=? AND key=?").get("accord-lifecycle", key)) continue;
          this.db.prepare("INSERT INTO commands VALUES(?,?,'','{}')").run("accord-lifecycle", key);
          this.store.emit("session.stale_holder", {
            session: s.id, claim: claim.id, resource: claim.resource, generation: claim.generation,
          });
          stale.push({ session: s.id, claim: claim.id, resource: claim.resource, generation: claim.generation, deadline: claim.deadline });
          continue;
        }
        if (applyRetirement(this.db, (k, d) => this.store.emit(k, d), now, s.id, { reason: "silent" })) retired++;
      }
      return { retired };
    });
    return { ...result, stale };
  }
  // The operator's one-time sweep applies the same rules against true activity,
  // ignoring lifecycle_since. A dry run writes nothing.
  sweep(actor, { dryRun = false } = {}) {
    requireThat(actor.role === "admin", "FORBIDDEN", "Administrator required", 403);
    requireThat(typeof dryRun === "boolean", "INVALID_INPUT", "dryRun must be boolean", 400);
    const t = this.thresholds(),
      { observations, sessions } = this.retireCandidates({ observedMs: t.observedMs, joinedMs: t.joinedMs, floor: 0 }),
      retiringSessions = sessions.filter((s) => !s.held),
      staleHolders = sessions.filter((s) => s.held),
      retiring = [...observations.map((o) => o.id), ...retiringSessions.map((s) => s.id)];
    const inList = retiring.length ? `(${retiring.map(() => "?").join(",")})` : "(NULL)",
      incidents = this.db
        .prepare(`SELECT count(*) n FROM overseer_incidents WHERE state!='resolved' AND session_id IN ${inList}`)
        .get(...retiring).n,
      queued = this.db
        .prepare(`SELECT count(*) n FROM tasks t JOIN reservations r ON r.task_id=t.id WHERE t.state='queued' AND r.actor IN ${inList}`)
        .get(...retiring).n,
      sample = (rows) => rows.slice(0, 20).map((r) => ({ id: r.id, title: r.title })),
      by = (rows, key) => {
        const m = {};
        for (const r of rows) m[r[key] ?? "agent"] = (m[r[key] ?? "agent"] ?? 0) + 1;
        return m;
      },
      counts = {
        observations: { count: observations.length, bySource: by(observations, "source"), sample: sample(observations) },
        sessions: { count: retiringSessions.length, byHarness: by(retiringSessions, "harness"), sample: sample(retiringSessions) },
        staleHolders: { count: staleHolders.length, sample: sample(staleHolders) },
        incidentsResolved: incidents,
        queuedReservationsCancelled: queued,
      };
    if (dryRun) return { dryRun: true, ...counts };
    this.store.mutate(() => {
      const now = this.store.now();
      for (const id of retiring)
        applyRetirement(this.db, (k, d) => this.store.emit(k, d), now, id, { reason: "silent" });
      this.db
        .prepare(`UPDATE tasks SET state='cancelled' WHERE state='queued' AND id IN (SELECT task_id FROM reservations WHERE actor IN ${inList})`)
        .run(...retiring);
      this.store.emit("lifecycle.swept", {
        observations: observations.length,
        sessions: retiringSessions.length,
        staleHolders: staleHolders.length,
        incidentsResolved: incidents,
        queuedReservationsCancelled: queued,
      });
    });
    return { dryRun: false, ...counts };
  }
  // `source` narrows to one adapter's sessions, live ones first, so an adapter can read back
  // all it reported: the default list is the most recent progress, and a name is not progress.
  list({ query = "", limit = 50, source, includeRetired = false } = {}) {
    integer(limit, "limit", 1, 200);
    if (source !== undefined) text(source, "source", 64);
    requireThat(
      typeof query === "string" && query.length <= 200,
      "INVALID_INPUT",
      "Query too long",
      400,
    );
    const words = query.match(/[\p{L}\p{N}_-]+/gu) ?? [];
    const retired = includeRetired === true ? "" : " AND v.retired_at IS NULL";
    const rows = words.length
      ? this.db
          .prepare(
            `SELECT v.* FROM session_search f JOIN session_views v ON v.id=f.session_id WHERE v.hidden=0${retired} AND (:source IS NULL OR v.source=:source) AND session_search MATCH :match ORDER BY rank LIMIT :limit`,
          )
          .all({ source: source ?? null, match: words.map((w) => '"' + w + '"').join(" AND "), limit })
      : source !== undefined
      ? this.db
          .prepare(
            `SELECT * FROM session_views v WHERE v.hidden=0${retired} AND v.source=? ORDER BY v.state='exited',v.progress_at DESC LIMIT ?`,
          )
          .all(source, limit)
      : this.db
          .prepare(
            `SELECT * FROM session_views v WHERE v.hidden=0${retired} ORDER BY v.progress_at DESC LIMIT ?`,
          )
          .all(limit);
    return { sessions: rows.map((r) => this.public(r)) };
  }
  read(session, { after = 0, before, limit = 60 } = {}) {
    integer(after, "after", 0, Number.MAX_SAFE_INTEGER);
    if(before!==undefined)integer(before,"before",1,Number.MAX_SAFE_INTEGER);
    integer(limit, "limit", 1, 200);
    const row = this.row(session);
    requireThat(!row.hidden,'NOT_FOUND','Session is internal to its harness',404);
    requireThat(
      !row.private,
      "PRIVATE_SESSION",
      "Session content is private",
      403,
    );
    const events = before!==undefined
      ? this.db.prepare('SELECT seq,at,kind,body FROM session_activity WHERE session_id=? AND seq<? ORDER BY seq DESC LIMIT ?').all(session,before,limit).reverse()
      : after
      ? this.db
          .prepare(
            "SELECT seq,at,kind,body FROM session_activity WHERE session_id=? AND seq>? ORDER BY seq LIMIT ?",
          )
          .all(session, after, limit)
      : this.db
          .prepare(
            "SELECT seq,at,kind,body FROM session_activity WHERE session_id=? ORDER BY seq DESC LIMIT ?",
          )
          .all(session, limit)
          .reverse();
    return {
      session: this.public(row),
      events,
      cursor: events.at(-1)?.seq ?? after,
      ...(events.length&&this.db.prepare('SELECT 1 FROM session_activity WHERE session_id=? AND seq<? LIMIT 1').get(session,events[0].seq)?{previous:events[0].seq}:{}),
    };
  }
  summarize(session, revision, summary, details = {}) {
    return this.store.mutate(() => {
      const r = this.row(session);
      if (r.private || r.hidden || r.revision !== revision) return { accepted: false };
      text(summary, "summary", 1000);
      requireThat(details.blocked===undefined||typeof details.blocked==='boolean','INVALID_INPUT','blocked must be boolean',400);
      requireThat(details.needs==null||typeof details.needs==='string'&&details.needs.length<=1000,'INVALID_INPUT','needs must be a short string',400);
      const needs=details.needs?.trim();
      const extra={blocked:details.blocked===true,needs:needs&&!['none','nothing','n/a','no action','-'].includes(needs.toLowerCase().replace(/\.+$/,''))?redact(needs):null};
      this.db
        .prepare(
          "UPDATE session_views SET summary=?,summary_kind='model',summary_revision=?,summary_details=? WHERE id=?",
        )
        .run(redact(summary), revision, JSON.stringify(extra), session);
      this.index(session);
      return { accepted: true };
    });
  }
  titleLayer(actor) {
    if (actor.role === "admin") return "operator";
    return this.overseerAddress() === `${this.store.authority}/${actor.id}` ? "overseer" : "peer";
  }
  // The effective display name: operator, then the designated overseer, then
  // the agent's own non-default label, then other agents, then the observed title.
  effectiveTitle(subject, { label, observedTitle } = {}) {
    const layers = {};
    for (const r of this.db.prepare("SELECT layer,title,by,at FROM titles WHERE subject=?").all(subject))
      layers[r.layer] = { title: r.title, ...(r.by ? { by: `${this.store.authority}/${r.by}` } : {}), at: r.at };
    if (label && !DEFAULT_LABELS.has(label)) layers.agent = { title: label };
    let title, titleSource;
    for (const layer of ["operator", "overseer", "agent", "peer"])
      if (layers[layer]) { title = layers[layer].title; titleSource = layer; break; }
    if (!title && observedTitle) { title = observedTitle; titleSource = "observed"; }
    return { title, titleSource, titles: Object.keys(layers).length ? layers : undefined };
  }
  // One record per agent: tile link (binding counts as role agent), the
  // effective layered title, the current task, previous addresses and the
  // mailbox binding.
  agentRecord(actorId) {
    const participant = this.db.prepare("SELECT label,activity FROM participants WHERE actor=?").get(actorId);
    const view = this.db.prepare("SELECT title FROM session_views WHERE id=?").get(actorId);
    const tile = this.db.prepare("SELECT tile,role FROM agent_tiles WHERE actor=?").get(actorId)
      ?? (this.db.prepare("SELECT external_id FROM session_bindings WHERE actor=? AND source='tessera'").get(actorId)?.external_id
          ? { tile: this.db.prepare("SELECT external_id FROM session_bindings WHERE actor=? AND source='tessera'").get(actorId).external_id, role: "agent" }
          : null);
    const job = this.db.prepare("SELECT title FROM agent_jobs WHERE actor=? AND state IN('working','waiting') ORDER BY updated_at DESC LIMIT 1").get(actorId);
    const client = this.db.prepare("SELECT client FROM sessions WHERE id=?").get(actorId)?.client ?? undefined;
    const binding = this.db.prepare("SELECT source,external_id FROM session_bindings WHERE actor=? ORDER BY source,external_id LIMIT 1").get(actorId);
    const previous = [];
    for (let id = actorId, depth = 0; depth < 5; depth++) {
      const prior = this.db.prepare("SELECT id FROM sessions WHERE successor=? ORDER BY created_at DESC LIMIT 1").get(id);
      if (!prior) break;
      previous.push(`${this.store.authority}/${prior.id}`);
      id = prior.id;
    }
    const { title, titleSource, titles } = this.effectiveTitle(actorId, { label: participant?.label, observedTitle: view?.title });
    return {
      host: { authority: this.store.authority, name: this.hostName },
      client,
      ...(tile ? { tile: { id: tile.tile, role: tile.role } } : {}),
      title, titleSource,
      ...(titles ? { titles } : {}),
      ...(job?.title ?? participant?.activity ? { task: job?.title ?? participant?.activity } : {}),
      ...(previous.length ? { previous } : {}),
      ...(binding ? { native: { source: binding.source, id: binding.external_id } } : {}),
    };
  }
  // A display name for the operator and other agents, stored per layer: the
  // operator's, the designated overseer's, or another agent's. It is
  // attributed, it is not progress, and it grants nothing.
  title(actor, body) {
    const byId = body.id !== undefined;
    requireThat(byId !== (body.source !== undefined || body.externalId !== undefined), "INVALID_INPUT",
      "Name a session by id, or by source and externalId", 400);
    requireThat(typeof body.title === "string" && body.title.length <= 120, "INVALID_INPUT",
      "title must be a string of at most 120 characters; empty removes the name", 400);
    let subject;
    if (byId) {
      subject = text(body.id, "id", 200);
      const view = this.db.prepare("SELECT * FROM session_views WHERE id=?").get(subject);
      if (view) {
        requireThat(!view.hidden, "NOT_FOUND", "Unknown observed session", 404);
        requireThat(!view.private, "PRIVATE_SESSION", "Session content is private", 403);
      } else {
        requireThat(
          this.db.prepare("SELECT 1 FROM sessions WHERE id=? UNION SELECT 1 FROM participants WHERE actor=? LIMIT 1").get(subject, subject),
          "NOT_FOUND", "Unknown session", 404);
      }
    } else {
      const view = this.db.prepare("SELECT * FROM session_views WHERE source=? AND external_id=?")
        .get(text(body.source, "source", 64), text(body.externalId, "externalId", 200));
      requireThat(view && !view.hidden, "NOT_FOUND", "Unknown observed session", 404);
      requireThat(!view.private, "PRIVATE_SESSION", "Session content is private", 403);
      subject = view.id;
    }
    const given = redact(body.title).replace(/\s+/g, " ").trim() || null;
    const layer = this.titleLayer(actor);
    return this.store.command(actor, body, "session.title", () => {
      if (given === null) this.db.prepare("DELETE FROM titles WHERE subject=? AND layer=?").run(subject, layer);
      else this.db.prepare("INSERT INTO titles VALUES(?,?,?,?,?) ON CONFLICT(subject,layer) DO UPDATE SET title=excluded.title,by=excluded.by,at=excluded.at")
        .run(subject, layer, given, actor.id, this.store.now());
      const hasView = this.db.prepare("SELECT 1 FROM session_views WHERE id=?").get(subject);
      if (hasView) this.index(subject);
      this.store.emit("session.titled", { session: subject, by: actor.id, layer, named: given !== null });
      const view = hasView ? this.db.prepare("SELECT * FROM session_views WHERE id=?").get(subject) : null;
      return view ? this.public(view) : { subject, ...this.effectiveTitle(subject) };
    });
  }
  snooze(actor, body) {
    const row = this.row(body.id);
    requireThat(
      actor.role === "admin" ||
        row.owner === actor.id ||
        this.db
          .prepare(
            "SELECT 1 FROM session_bindings WHERE source=? AND external_id=? AND actor=?",
          )
          .get(row.source, row.external_id, actor.id),
      "FORBIDDEN",
      "Only owner or operator can snooze",
      403,
    );
    integer(
      body.until,
      "until",
      this.store.now(),
      this.store.now() + 7 * 86400000,
    );
    return this.store.command(actor, body, "session.snooze", () => {
      this.db
        .prepare("UPDATE session_views SET snoozed_until=? WHERE id=?")
        .run(body.until, body.id);
      return this.public(this.row(body.id));
    });
  }
  job(actor, body) {
    return this.store.command(actor, body, "job.update", () => {
      const old =
        body.id &&
        this.db.prepare("SELECT * FROM agent_jobs WHERE id=?").get(body.id);
      requireThat(!body.id || old, "NOT_FOUND", "Unknown job", 404);
      requireThat(
        !old || old.actor === actor.id,
        "NOT_OWNER",
        "Job belongs to another session",
        403,
      );
      const state = body.state ?? old?.state ?? "working";
      requireThat(
        ["working", "waiting", "done", "failed", "cancelled"].includes(state),
        "INVALID_INPUT",
        "Invalid job state",
        400,
      );
      text(body.title ?? old?.title, "title", 200);
      for (const field of ["progress", "metrics"])
        if (body[field] != null)
          requireThat(
            typeof body[field] === "object" &&
              !Array.isArray(body[field]) &&
              JSON.stringify(body[field]).length <= 4000,
            "INVALID_INPUT",
            field + " must be a bounded object",
            400,
          );
      if (body.reservationId) {
        const reservation = this.db
          .prepare(
            "SELECT actor FROM reservations WHERE id=? UNION ALL SELECT actor FROM manager_requests WHERE id=?",
          )
          .get(body.reservationId, body.reservationId);
        requireThat(
          reservation?.actor === actor.id,
          "NOT_OWNER",
          "Attach only your own reservation",
          403,
        );
      }
      const jobId = old?.id ?? id(),
        now = this.store.now();
      this.db
        .prepare(
          "INSERT INTO agent_jobs VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,state=excluded.state,note=excluded.note,progress=excluded.progress,metrics=excluded.metrics,updated_at=excluded.updated_at",
        )
        .run(
          jobId,
          actor.id,
          redact(body.title ?? old.title),
          state,
          redact(body.note ?? "").slice(0, 4000),
          JSON.stringify(body.progress ?? null),
          JSON.stringify(body.metrics ?? {}),
          old?.created_at ?? now,
          now,
          body.reservationId ?? old?.reservation_id ?? null,
        );
      if (old?.state !== state)
        this.store.emit("job.updated", { job: jobId, actor: actor.id, state, previous: old?.state ?? null });
      return this.db.prepare("SELECT * FROM agent_jobs WHERE id=?").get(jobId);
    });
  }
  jobs() {
    return {
      jobs: this.db
        .prepare("SELECT * FROM agent_jobs ORDER BY updated_at DESC LIMIT 200")
        .all()
        .map((j) => ({
          ...j,
          progress: JSON.parse(j.progress),
          metrics: JSON.parse(j.metrics),
          stalled:
            j.state === "working" && this.store.now() - j.updated_at > 900000,
        })),
    };
  }
  ask(actor, body) {
    return this.store.command(actor, body, "question.ask", () => {
      text(body.question, "question", 4000);
      requireThat(
        Array.isArray(body.options ?? []) && (body.options ?? []).length <= 6,
        "INVALID_INPUT",
        "At most six options",
        400,
      );
      for (const o of body.options ?? []) text(o, "option", 200);
      const q = id();
      this.db
        .prepare(
          "INSERT INTO human_questions VALUES(?,?,?,?, 'pending',NULL,?,NULL)",
        )
        .run(
          q,
          actor.id,
          redact(body.question),
          JSON.stringify((body.options ?? []).map(redact)),
          this.store.now(),
        );
      return { id: q, state: "pending" };
    });
  }
  answer(actor, body) {
    requireThat(
      actor.role === "admin",
      "FORBIDDEN",
      "Only operator may answer",
      403,
    );
    return this.store.command(actor, body, "question.answer", () => {
      text(body.answer, "answer", 4000);
      const r = this.db
        .prepare(
          "UPDATE human_questions SET answer=?,state='answered',answered_at=? WHERE id=? AND state='pending'",
        )
        .run(redact(body.answer), this.store.now(), body.id);
      requireThat(r.changes === 1, "NOT_PENDING", "Question is not pending");
      return this.question(actor, body.id);
    });
  }
  dismiss(actor, body) {
    requireThat(
      actor.role === "admin",
      "FORBIDDEN",
      "Only operator may dismiss",
      403,
    );
    return this.store.command(actor, body, "question.dismiss", () => {
      this.db
        .prepare(
          "UPDATE human_questions SET state='dismissed' WHERE id=? AND state='pending'",
        )
        .run(body.id);
      return this.question(actor, body.id);
    });
  }
  question(actor, question) {
    const r = this.db
      .prepare("SELECT * FROM human_questions WHERE id=?")
      .get(question);
    requireThat(r, "NOT_FOUND", "Unknown question", 404);
    requireThat(
      actor.role === "admin" || r.actor === actor.id,
      "NOT_OWNER",
      "Question belongs to another session",
      403,
    );
    return { ...r, options: JSON.parse(r.options) };
  }
}
