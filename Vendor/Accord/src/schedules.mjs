// SPDX-License-Identifier: MIT
// Durable one-shot, interval and event-triggered scheduled messages. Schedules
// live in the store (migration 21), fire on the leader's reconcile tick and
// deliver through the ordinary message outbox as the accord-scheduler system
// principal, so a schedule never impersonates its owner and retries cannot
// double-send: the outbox id is hash(scheduleId:firedCount).
import { hash, integer, requireThat, text } from './common.mjs';

const MAX_ACTIVE_PER_OWNER = 50;
const MAX_TEXT = 2000;
const DEFAULT_EXPIRY_MS = 7 * 86400000;
const MAX_EXPIRY_MS = 30 * 86400000;
const MIN_EVERY_MS = 60000;
const MIN_IDLE_MS = 60000;
const FIRE_COALESCE_MS = 60000;
const MAX_FIRES_PER_OWNER_HOUR = 60;
const MAX_PUBLISH_PER_ACTOR_HOUR = 60;
const MAX_PENDING_DETAIL = 5;
const FIRE_BATCH = 64;
const EVENT_BATCH = 500;
const TOPIC_RE = /^[a-z0-9][a-z0-9:._#/-]{0,119}$/i;
const RESERVATION_STATES = ['active', 'released'];
const JOB_STATES = ['working', 'waiting', 'done', 'failed', 'cancelled'];
const RELEASED_KINDS = new Set(['claim.released', 'claim.expired', 'claim.orphan_expired', 'reservation.reclaimed']);
const OWNER_ENDED_KINDS = new Set(['session.retired', 'session.closed', 'session.expired']);

function triggerSummary(trigger) {
  if (trigger.at !== undefined) return `at ${new Date(trigger.at).toISOString()}`;
  if (trigger.everyMs !== undefined) return `every ${Math.round(trigger.everyMs / 60000)}m`;
  if (trigger.event === 'reservation') return `reservation:${trigger.resource}${trigger.states ? `:${trigger.states.join(',')}` : ''}`;
  if (trigger.event === 'job') return `job:${trigger.job}${trigger.states ? `:${trigger.states.join(',')}` : ''}`;
  if (trigger.event === 'idle') return `idle:${trigger.session}:${Math.round(trigger.idleMs / 60000)}m`;
  if (trigger.event === 'topic') return `topic:${trigger.topic}`;
  return 'event';
}

export class Schedules {
  constructor(store, collaboration, { resourceExists } = {}) {
    this.store = store;
    this.collaboration = collaboration;
    this.db = store.db;
    this.resourceExists = resourceExists ?? ((localId) => !!this.db.prepare('SELECT 1 FROM resources WHERE id=? UNION SELECT 1 FROM resource_bindings WHERE id=? LIMIT 1').get(localId, localId));
    this.db.prepare('INSERT OR IGNORE INTO schedule_cursor VALUES(1,0)').run();
  }

  view(row) {
    const trigger = JSON.parse(row.trigger);
    return {
      id: row.id, state: row.state, owner: row.owner, ownerLabel: row.owner_label ?? undefined,
      to: row.target, kind: row.kind, delivery: row.delivery, trigger: triggerSummary(trigger),
      nextAt: row.next_at ?? undefined, firedCount: row.fired_count,
      pendingEvents: row.pending_events || undefined,
      expiresAt: row.expires_at, lastFiredAt: row.last_fired_at ?? undefined,
      endedReason: row.ended_reason ?? undefined, lastError: row.last_error ?? undefined,
      createdAt: row.created_at,
    };
  }

  parseTrigger(body, now) {
    const on = body.on;
    requireThat(on === undefined || (typeof on === 'object' && on !== null && !Array.isArray(on)), 'INVALID_INPUT', 'Trigger on must be an object', 400);
    const chosen = [body.at, body.inMs, body.everyMs, on].filter((v) => v !== undefined);
    requireThat(chosen.length === 1, 'INVALID_INPUT', 'Name exactly one trigger: at, inMs, everyMs or on', 400);
    if (body.at !== undefined) {
      integer(body.at, 'at', 1, now + MAX_EXPIRY_MS);
      return { trigger: { at: body.at }, nextAt: body.at };
    }
    if (body.inMs !== undefined) {
      integer(body.inMs, 'inMs', 1, MAX_EXPIRY_MS);
      return { trigger: { at: now + body.inMs }, nextAt: now + body.inMs };
    }
    if (body.everyMs !== undefined) {
      integer(body.everyMs, 'everyMs', MIN_EVERY_MS, MAX_EXPIRY_MS);
      if (body.startAt !== undefined) integer(body.startAt, 'startAt', 1, now + MAX_EXPIRY_MS);
      const startAt = body.startAt ?? now;
      return { trigger: { everyMs: body.everyMs, ...(body.startAt !== undefined ? { startAt } : {}) }, nextAt: startAt + body.everyMs };
    }
    const event = on.event;
    if (event === 'reservation') {
      text(on.resource, 'on.resource', 160);
      const [authority, localId] = on.resource.includes('/') ? on.resource.split('/') : [null, on.resource];
      requireThat(authority === null || authority === this.store.authority, 'INVALID_INPUT', 'Reservation triggers watch resources on this host; create the schedule on that host', 400);
      requireThat(this.resourceExists(localId), 'NOT_FOUND', `Unknown resource ${localId}`, 404);
      const states = on.states === undefined ? undefined : on.states;
      requireThat(states === undefined || (Array.isArray(states) && states.length >= 1 && states.every((s) => RESERVATION_STATES.includes(s))), 'INVALID_INPUT', `Reservation states are ${RESERVATION_STATES.join('|')}`, 400);
      return { trigger: { event: 'reservation', resource: localId, ...(states ? { states } : {}) }, nextAt: null };
    }
    if (event === 'job') {
      text(on.job, 'on.job', 128);
      const states = on.states === undefined ? undefined : on.states;
      requireThat(states === undefined || (Array.isArray(states) && states.length >= 1 && states.every((s) => JOB_STATES.includes(s))), 'INVALID_INPUT', `Job states are ${JOB_STATES.join('|')}`, 400);
      return { trigger: { event: 'job', job: on.job, ...(states ? { states } : {}) }, nextAt: null };
    }
    if (event === 'idle') {
      text(on.session, 'on.session', 220);
      const [authority, session] = on.session.includes('/') ? on.session.split('/') : [null, on.session];
      requireThat(authority === null || authority === this.store.authority, 'INVALID_INPUT', 'Idle triggers watch local sessions only', 400);
      requireThat(this.db.prepare('SELECT 1 FROM sessions WHERE id=? UNION SELECT 1 FROM session_views WHERE id=? LIMIT 1').get(session, session), 'NOT_FOUND', `Unknown local session ${session}`, 404);
      integer(on.idleMs, 'on.idleMs', MIN_IDLE_MS, MAX_EXPIRY_MS);
      return { trigger: { event: 'idle', session, idleMs: on.idleMs }, nextAt: null };
    }
    if (event === 'topic') {
      text(on.topic, 'on.topic', 120);
      requireThat(TOPIC_RE.test(on.topic), 'INVALID_INPUT', 'Invalid topic name', 400);
      return { trigger: { event: 'topic', topic: on.topic }, nextAt: null };
    }
    requireThat(false, 'INVALID_INPUT', 'Trigger event is reservation, job, idle or topic', 400);
  }

  validateTarget(to, owner) {
    requireThat(typeof to === 'string' && to.split('/').length === 2, 'INVALID_INPUT', 'Use a recipient address from find, or omit to for yourself', 400);
    const [authority, recipient] = to.split('/');
    text(to, 'to', 220);
    if (authority === this.store.authority) {
      if (recipient === owner) return; // An actor can always reach itself.
      
      requireThat(this.collaboration.recipientExists(recipient), 'RECIPIENT_UNKNOWN', 'Recipient is not registered; use an address from find or a received message', 404);
      const retired = this.collaboration.retiredRecipient(recipient);
      if (retired) throw this.collaboration.retiredError(retired);
      return;
    }
    requireThat(this.db.prepare('SELECT 1 FROM links WHERE authority=?').get(authority), 'HOST_UNKNOWN', 'Recipient host is not linked', 404);
  }

  create(actor, body) {
    return this.store.command(actor, body, 'schedule.create', () => {
      const now = this.store.now();
      text(body.text, 'text', MAX_TEXT);
      const to = body.to ?? this.collaboration.address(actor);
      this.validateTarget(to, actor.id);
      const { trigger, nextAt } = this.parseTrigger(body, now);
      const kind = body.kind === undefined || body.kind === 'message' ? 'message' : body.kind;
      requireThat(['message', 'notification'].includes(kind), 'INVALID_INPUT', 'Unknown schedule kind', 400);
      const delivery = body.delivery !== undefined ? body.delivery : body.wake === true ? 'native-prompt' : 'inbox';
      requireThat(['inbox', 'native-prompt'].includes(delivery), 'INVALID_INPUT', 'Unknown delivery preference', 400);
      const expiresAt = body.expiresInMs !== undefined ? now + integer(body.expiresInMs, 'expiresInMs', 60000, MAX_EXPIRY_MS) : now + DEFAULT_EXPIRY_MS;
      requireThat(nextAt === null || nextAt <= expiresAt, 'INVALID_INPUT', 'The trigger never fires before expiry', 400);
      const maxFires = body.maxFires === undefined ? null : integer(body.maxFires, 'maxFires', 1, 10000);
      if (actor.role !== 'admin')
        requireThat(this.db.prepare("SELECT count(*) n FROM schedules WHERE owner=? AND state='active'").get(actor.id).n < MAX_ACTIVE_PER_OWNER, 'SCHEDULE_LIMIT', `At most ${MAX_ACTIVE_PER_OWNER} active schedules`, 429);
      const scheduleId = `sched-${hash(`${actor.id}:${body.key}:${now}`).slice(0, 24)}`;
      const ownerLabel = this.db.prepare('SELECT label FROM sessions WHERE id=?').get(actor.id)?.label
        ?? this.db.prepare('SELECT label FROM participants WHERE actor=?').get(actor.id)?.label ?? null;
      this.db.prepare('INSERT INTO schedules VALUES(?,?,?,?,?,?,?,?,?,1,0,NULL,NULL,0,?,?,?,NULL,NULL,0,?)').run(
        scheduleId, actor.id, ownerLabel, to, body.text, kind, delivery, JSON.stringify(trigger), nextAt,
        maxFires, expiresAt, 'active', now,
      );
      this.store.emit('schedule.created', { schedule: scheduleId, owner: actor.id, trigger: triggerSummary(trigger) });
      return this.view(this.db.prepare('SELECT * FROM schedules WHERE id=?').get(scheduleId));
    });
  }

  list(actor, { all = false } = {}) {
    if (all) requireThat(actor.role === 'admin', 'FORBIDDEN', 'Administrator required', 403);
    return {
      schedules: this.db.prepare(`SELECT * FROM schedules ${all ? '' : 'WHERE owner=?'} ORDER BY created_at DESC LIMIT 200`).all(...(all ? [] : [actor.id])).map((row) => this.view(row)),
    };
  }

  cancel(actor, body) {
    text(body.id, 'id', 128);
    const row = this.db.prepare('SELECT * FROM schedules WHERE id=?').get(body.id);
    requireThat(row, 'NOT_FOUND', 'Unknown schedule', 404);
    requireThat(row.owner === actor.id || actor.role === 'admin', 'NOT_OWNER', 'Schedule belongs to another actor', 403);
    if (row.state === 'active')
      this.store.mutate(() => this.db.prepare("UPDATE schedules SET state='cancelled',ended_reason='cancelled' WHERE id=? AND state='active'").run(body.id));
    return this.view(this.db.prepare('SELECT * FROM schedules WHERE id=?').get(body.id));
  }

  publish(actor, body) {
    return this.store.command(actor, body, 'topic.publish', () => {
      text(body.topic, 'topic', 120);
      requireThat(TOPIC_RE.test(body.topic), 'INVALID_INPUT', 'Invalid topic name', 400);
      if (body.text !== undefined) text(body.text, 'text', 500);
      const recent = this.db.prepare("SELECT count(*) n FROM events WHERE kind='topic.published' AND at>? AND json_extract(data,'$.actor')=?").get(this.store.now() - 3600000, actor.id).n;
      requireThat(recent < MAX_PUBLISH_PER_ACTOR_HOUR, 'RATE_LIMIT', `At most ${MAX_PUBLISH_PER_ACTOR_HOUR} topic publishes per hour`, 429);
      this.store.emit('topic.published', { topic: body.topic, text: body.text ?? '', actor: actor.id });
      return { published: true, topic: body.topic };
    });
  }

  eventResource(data) {
    if (data.resource) return data.resource;
    return this.db.prepare('SELECT resource FROM claims WHERE id=?').get(data.claim)?.resource;
  }

  eventSummary(kind, data) {
    if (kind === 'job.updated') return `job ${data.job}: ${data.previous ?? 'new'} -> ${data.state}`;
    if (kind === 'topic.published') return `topic ${data.topic}${data.text ? `: ${String(data.text).slice(0, 80)}` : ''}`;
    if (kind === 'idle') return `idle ${Math.floor((this.store.now() - (data.since ?? 0)) / 60000)}m`;
    return `${kind} ${data.claim ?? data.reservation ?? ''}${data.outcome ? ` (${data.outcome})` : ''}`.trim();
  }

  matchEvent(row, trigger, kind, data) {
    if (trigger.event === 'reservation') {
      const state = kind === 'claim.active' ? 'active' : RELEASED_KINDS.has(kind) ? 'released' : null;
      if (!state || (trigger.states && !trigger.states.includes(state))) return false;
      return this.eventResource(data) === trigger.resource;
    }
    if (trigger.event === 'job')
      return kind === 'job.updated' && data.job === trigger.job && (!trigger.states || trigger.states.includes(data.state));
    if (trigger.event === 'topic') return kind === 'topic.published' && data.topic === trigger.topic;
    return false;
  }

  notePending(row, summary, now) {
    const detail = [...(row.pending_detail ? JSON.parse(row.pending_detail) : []), summary].slice(-MAX_PENDING_DETAIL);
    // A pending event sets the fire time once: now, or after the 60 s
    // coalescing window from the previous firing.
    const nextAt = row.pending_events === 0 ? Math.max(now, (row.last_fired_at ?? 0) + FIRE_COALESCE_MS) : row.next_at;
    this.db.prepare('UPDATE schedules SET pending_events=pending_events+1,pending_detail=?,next_at=? WHERE id=?').run(JSON.stringify(detail), nextAt, row.id);
  }

  applyEvent(ev) {
    let data;
    try { data = JSON.parse(ev.data); } catch { return; }
    if (OWNER_ENDED_KINDS.has(ev.kind) && typeof data.session === 'string') {
      const raw = data.successor
        ?? this.db.prepare('SELECT successor FROM sessions WHERE id=?').get(data.session)?.successor
        ?? this.db.prepare('SELECT successor FROM session_views WHERE id=?').get(data.session)?.successor;
      const successor = typeof raw === 'string' && raw ? raw.split('/').pop() : null;
      if (successor) {
        const label = this.db.prepare('SELECT label FROM participants WHERE actor=?').get(successor)?.label
          ?? this.db.prepare('SELECT label FROM sessions WHERE id=?').get(successor)?.label;
        // A rebound session inherits the retired owner's schedules; the owner
        // label stays unless the successor has one of its own.
        // Self-targeted check-ins follow the rebound owner; explicit targets stay.
        this.db.prepare("UPDATE schedules SET owner=?,owner_label=coalesce(?,owner_label),target=CASE WHEN target=? THEN ? ELSE target END WHERE owner=? AND state='active'")
          .run(successor, label ?? null, `${this.store.authority}/${data.session}`, `${this.store.authority}/${successor}`, data.session);
      } else {
        this.db.prepare("UPDATE schedules SET state='cancelled',ended_reason='owner-retired' WHERE owner=? AND state='active'").run(data.session);
      }
    }
    const summary = this.eventSummary(ev.kind, data);
    for (const row of this.db.prepare("SELECT * FROM schedules WHERE state='active' AND json_extract(trigger,'$.event') IS NOT NULL").all())
      try {
        if (this.matchEvent(row, JSON.parse(row.trigger), ev.kind, data)) this.notePending(row, summary, ev.at);
      } catch { /* One malformed trigger row cannot stall the scan. */ }
  }

  idlePass(now) {
    for (const row of this.db.prepare("SELECT * FROM schedules WHERE state='active' AND json_extract(trigger,'$.event')='idle'").all()) {
      const trigger = JSON.parse(row.trigger);
      const ended = this.db.prepare('SELECT 1 FROM sessions WHERE id=? AND (closed_at IS NOT NULL OR retired_at IS NOT NULL OR expires_at<=?)').get(trigger.session, now)
        || this.db.prepare('SELECT 1 FROM session_views WHERE id=? AND retired_at IS NOT NULL').get(trigger.session);
      if (ended) continue;
      const lastActivity = this.db.prepare('SELECT progress_at FROM session_views WHERE id=?').get(trigger.session)?.progress_at
        ?? this.db.prepare('SELECT created_at FROM sessions WHERE id=?').get(trigger.session)?.created_at;
      if (lastActivity == null) continue;
      let armed = row.armed;
      if (!armed && row.last_fired_at !== null && lastActivity > row.last_fired_at) {
        this.db.prepare('UPDATE schedules SET armed=1 WHERE id=?').run(row.id);
        armed = 1;
      }
      if (armed && row.pending_events === 0 && now - lastActivity >= trigger.idleMs)
        this.notePending(row, `idle since ${new Date(lastActivity).toISOString()}`, now);
    }
  }

  firedThisHour(owner, now) {
    return this.db.prepare("SELECT count(*) n FROM events WHERE kind='schedule.fired' AND at>? AND json_extract(data,'$.owner')=?").get(now - 3600000, owner).n;
  }

  fireDue(now) {
    const due = this.db.prepare("SELECT * FROM schedules WHERE state='active' AND next_at IS NOT NULL AND next_at<=? ORDER BY next_at LIMIT ?").all(now, FIRE_BATCH);
    let flushed = false;
    for (const row of due) {
      const trigger = JSON.parse(row.trigger);
      if (this.firedThisHour(row.owner, now) >= MAX_FIRES_PER_OWNER_HOUR) {
        this.db.prepare('UPDATE schedules SET next_at=?,deferred=1 WHERE id=?').run(Math.ceil(now / 60000) * 60000, row.id);
        continue;
      }
      const error = this.targetError(row.target, row.owner);
      const fired = row.fired_count + 1;
      if (error) {
        this.db.prepare("UPDATE schedules SET state='failed',last_error=? WHERE id=?").run(error, row.id);
        this.store.emit('schedule.failed', { schedule: row.id, owner: row.owner, error });
        continue;
      }
      const detail = row.pending_events > 0
        ? ` (${row.pending_events} event${row.pending_events > 1 ? 's' : ''}: ${(row.pending_detail ? JSON.parse(row.pending_detail) : []).join('; ')})`
        : '';
      const late = trigger.event === undefined && now - row.next_at >= 60000 ? ` (late by ${Math.round((now - row.next_at) / 60000)}m)` : '';
      const deferred = row.deferred ? ' (rate-limited; deferred)' : '';
      const ownerLabel = row.owner_label ?? row.owner;
      const envelope = {
        id: hash(`${row.id}:${fired}`),
        from: `${this.store.authority}/accord-scheduler`,
        to: row.target,
        text: `Scheduled by ${ownerLabel} (${row.id}): ${row.text}${detail}${late}${deferred}`,
        kind: row.kind,
        delivery: row.delivery,
        scheduledBy: `${this.store.authority}/${row.owner}`,
        scheduleId: row.id,
      };
      this.db.prepare("INSERT OR IGNORE INTO message_outbox(id,actor,envelope,state,error,created_at) VALUES(?,?,?,'queued',NULL,?)").run(envelope.id, 'accord-scheduler', JSON.stringify(envelope), now);
      flushed = true;
      const done = trigger.at !== undefined || (row.max_fires !== null && fired >= row.max_fires);
      const nextAt = done || trigger.event !== undefined ? null : now + trigger.everyMs;
      const armed = trigger.event === 'idle' ? 0 : 1;
      this.db.prepare("UPDATE schedules SET last_fired_at=?,fired_count=?,pending_events=0,pending_detail=NULL,deferred=0,armed=?,next_at=?,state=? WHERE id=?")
        .run(now, fired, armed, nextAt, done ? 'done' : 'active', row.id);
      this.store.emit('schedule.fired', { schedule: row.id, owner: row.owner, count: fired });
    }
    return flushed;
  }

  targetError(target, owner) {
    const [authority, recipient] = String(target).split('/');
    try {
      if (authority === this.store.authority) {
        if (recipient === owner) return null;
        requireThat(this.collaboration.recipientExists(recipient), 'RECIPIENT_UNKNOWN', 'Recipient is not registered', 404);
        const retired = this.collaboration.retiredRecipient(recipient);
        if (retired) return 'RECIPIENT_RETIRED';
        return null;
      }
      requireThat(this.db.prepare('SELECT 1 FROM links WHERE authority=?').get(authority), 'HOST_UNKNOWN', 'Recipient host is not linked', 404);
      return null;
    } catch (e) {
      return e.code ?? 'RECIPIENT_UNKNOWN';
    }
  }

  // One mutate covers expiry, the durable event-cursor scan, idle arming and
  // firing: the whole batch commits or none of it does, so a lease handover
  // cannot fire twice. Returns whether the outbox needs a flush.
  tick() {
    // Read-only fast path: an idle tick writes nothing, not even the cursor.
    const now = this.store.now();
    const cursor = this.db.prepare('SELECT event_seq FROM schedule_cursor WHERE id=1').get()?.event_seq ?? 0;
    const hasDue = this.db.prepare("SELECT 1 FROM schedules WHERE state='active' AND next_at IS NOT NULL AND next_at<=? LIMIT 1").get(now);
    const hasExpiry = this.db.prepare("SELECT 1 FROM schedules WHERE state='active' AND expires_at<=? LIMIT 1").get(now);
    const hasEvents = this.db.prepare('SELECT 1 FROM events WHERE seq>? LIMIT 1').get(cursor);
    const hasIdle = this.db.prepare("SELECT 1 FROM schedules WHERE state='active' AND json_extract(trigger,'$.event')='idle' LIMIT 1").get();
    if (!hasDue && !hasExpiry && !hasEvents && !hasIdle) return false;
    let flushed = false;
    this.store.mutate(() => {
      const now = this.store.now();
      if (hasExpiry)
        this.db.prepare("UPDATE schedules SET state='expired',ended_reason='expired' WHERE state='active' AND expires_at<=?").run(now);
      const cursor = this.db.prepare('SELECT event_seq FROM schedule_cursor WHERE id=1').get()?.event_seq ?? 0;
      let last = cursor;
      for (const ev of this.db.prepare('SELECT seq,kind,at,data FROM events WHERE seq>? ORDER BY seq LIMIT ?').all(cursor, EVENT_BATCH)) {
        this.applyEvent(ev);
        last = ev.seq;
      }
      if (last !== cursor)
        this.db.prepare('INSERT INTO schedule_cursor VALUES(1,?) ON CONFLICT(id) DO UPDATE SET event_seq=excluded.event_seq').run(last);
      this.idlePass(now);
      flushed = this.fireDue(now);
    });
    return flushed;
  }

  nextWake() {
    return this.db.prepare("SELECT min(next_at) at FROM schedules WHERE state='active' AND next_at IS NOT NULL").get().at;
  }
}
