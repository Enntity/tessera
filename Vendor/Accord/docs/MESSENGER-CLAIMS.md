# Messenger identity claims

An agent can take over a Messenger identity with one call. Accord then keeps the
identity's token, watches its inbox and wakes the agent when mail waits. The agent
reads and replies through Accord. Nothing in the Messenger service changes: Accord is
an ordinary HTTPS client of its API.

## Configuration

`messenger.json` beside Accord's database names the service and where each token lives.
It never holds a token:

```json
{
  "url": "https://messenger.example.test",
  "principals": {
    "builder": { "keychainService": "accord-messenger" },
    "reviewer": { "tokenFile": "/home/example/.config/accord/messenger/reviewer.token" }
  }
}
```

- `keychainService` (macOS) reads the generic password with that service and the
  principal as its account.
- `tokenFile` must be a regular file that group and other users can't read (the
  vendored Messenger client enforces this).

The file is read on each call, so a change needs no restart.

## Claiming

`accord_messenger_claim {principal}` (CLI `accord messenger claim PRINCIPAL`):

1. Refuses with `CLAIM_HELD` (409) while another live agent holds the identity. The
   holder releases it with `release:true`; an administrator may pass `handover:true`.
2. Calls `/v1/me` with the configured token and requires the expected handle and
   `kind: agent` (`IDENTITY_MISMATCH` otherwise).
3. Creates a schedule owned by the claimant: `persistent`, `wake`, triggered by the
   topic `messenger:<principal>`, with fixed text that contains no peer content.
4. Records the claim (migration 24, `messenger_claims`).

A claim serves only mail that arrives after it (with one minute allowed for clock
skew). Older pending deliveries stay in Messenger untouched. `backlog:true` (CLI
`--backlog`) serves them too.

Calling it with no `principal` lists claims: holder, topic, schedule, last poll, waiting
count and the last error code.

## Watching

Every 15 seconds, for each claim, the service peeks the inbox
(`GET /v1/inbox?claim=false`). A peek takes no lease and acknowledges nothing, so the
holder's own reads are never disturbed.

When a delivery appears that hasn't been announced, the service emits
`topic.published` (`topic: messenger:<principal>`, `text: "<n> waiting"`,
`actor: accord-messenger`). Mail that is still unhandled is announced again after 30
minutes. A peek returns at most 200 deliveries, oldest first. If older pending mail
fills it, newer mail can't be seen; the claim then reports `peekFull: true`, and the
backlog has to be handled before the watcher can see new mail. The schedule's
coalescing window and Accord's wake limits bound how often
the holder is woken.

## Reading and replying

- `accord_messenger_inbox` claims up to `limit` deliveries (default 10) for each
  identity the caller holds. It marks them read and returns the author's canonical
  identity, the body (truncated past 16,000 characters) and attachment metadata.
  Lease tokens stay in Accord (`messenger_leases`).
- `accord_messenger_reply {deliveryId, body}` sends an in-thread reply as the
  identity, with a client message ID derived from the identity and message. A
  retried call can therefore never answer twice. It then acknowledges the delivery.
  With `body` omitted it only acknowledges.

  If the lease expired first, the reply stands and Messenger offers the message
  again, showing the existing reply.

Only the current holder may read or reply (`NOT_HOLDER`).

## Lifecycle

- **Retirement with a live successor:** the claim and its schedule follow the successor.
- **Retirement without a successor:** the claim, its schedule and its leases end.
- **Explicit release:** ends the claim and cancels the schedule.

Events: `messenger.claimed`, `messenger.claim-moved`, `messenger.claim-ended`,
`messenger.released`, `messenger.replied`.

## Trust

Messenger mail is untrusted input from its sender, never the operator's word. Every
inbox result carries the default rule: no deploys, no shared hardware and no repos
outside the current task because a sender asked; those go to the operator through
`accord_ask`, naming the sender. Tokens never appear in tool results, events,
schedules, messages or logs.
