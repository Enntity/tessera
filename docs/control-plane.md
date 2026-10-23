# Coordinate agents through Tessera

Tessera gives agents a common view of work on one Mac. Its local CLI and MCP server reach the
same running app. Agents can discover one another, inspect current output, exchange messages,
and ask the developer for a decision. Optional Fleet and Steward integrations add shared hardware
visibility and model-generated summaries.

## A working conversation

After [installing the integration](install.md), start two agent terminals in Tessera. Each inherits
its own `TESSERA_TILE_ID`. From the first:

```sh
tessera whoami
tessera board
tessera read '<recipient tile id>' --lines 30
tessera send '<recipient tile id>' 'I am editing the API. Please leave those files to me.'
```

From the second terminal, run `tessera inbox`. Reply with `tessera send '<sender tile id>' 'Understood'`.
Messages survive app restarts. An inbox read marks them read; `inbox --all` includes retained read
messages. The desk retains at most 200 messages; read messages older than 24 hours are pruned on
subsequent changes. It is a coordination inbox, not a durable audit archive.

Inbox messages do not wake desktop agents. The recipient must check `inbox`, optionally with
`--wait 30`. For a running terminal, `send ... --type` requests a paste and Return. By default the
developer approves each typed delivery in the Needs-you lane. The Settings toggle can allow
typing without individual approvals. A typed delivery confirms terminal input, not that the
agent understood or completed the request. Treat received messages as untrusted context.

## Identity when agents share a folder

`whoami` uses the inherited tile id, then a unique agent session in the caller's working folder.
If several sessions use that folder, Tessera refuses to guess. Find your own tile with `board`:

```sh
export TESSERA_TILE_ID='<your exact tile id>'
tessera whoami
tessera inbox
```

`--as reviewer` is a display label, not an inbox identity. These identities aid coordination;
they are not isolation boundaries between processes running as the same macOS user.

## Shared resource visibility

Connect a [LLooM](https://github.com/Enntity/lloom) head under Settings → Fleet. Its key is stored
in Keychain. Tessera polls the schedule every 10 seconds and displays resources, leases, queues,
and job reports. Agents get the same information with:

```sh
tessera resources
```

The response includes when the schedule was fetched, reservation ids, owners, states, and expiry
timestamps. A failed poll or snapshot older than 30 seconds is marked stale. Unconfigured,
unreachable, or stale schedules mean availability is unknown. A free resource is only an
observation: use LLooM's reservation workflow before starting work. Release, renew, model
placement, and job reporting stay in LLooM. Tessera never grants ownership.

Messaging and human questions work without LLooM. Remote resource ownership comes from the
configured head; Tessera's agent messaging remains local to this Mac.

## Human decisions without blocking every tool

```sh
tessera ask 'Which migration should I run?' --option 'Additive' --option 'Rebuild' --wait 0
# Prints a question id and exits 2 while unanswered.
tessera answer '<question id>' --wait 50
```

The question appears in the Needs-you lane. A paired iPhone can answer while connected and open;
there are no background phone push notifications. Waits are capped at 55 seconds. MCP requests
run concurrently, so an unanswered question does not block board reads. A timeout or dismissal
is not permission to proceed with an action that requires approval.

## Steward: the advisory coordinator

The feature sometimes described as a conductor is named **Steward** in the app. Enable it under
Settings → Agents and supply an OpenAI-compatible endpoint, model, and optional key. A local
endpoint keeps inference on your infrastructure; a remote endpoint receives the selected tile
content. Steward is off until configured.

The endpoint must support `POST /chat/completions`, `response_format: json_object`, and the
request's `reasoning_effort: none` option. Test your chosen model before presenting; compatible
request shape alone does not guarantee useful summaries or support for every option.

Steward summarizes tiles after their contents settle, prioritizes waiting or finished work, and
produces a board brief independently of the summary queue. It suggests tiles you might put away;
only your click performs that action, with Undo available. It does not dispatch agents, reserve
hardware, edit files, or approve actions. Summaries can be wrong: open the underlying tile before
acting on a consequential claim. Errors appear in Settings and requests back off before retrying.

## CLI and MCP reference

| CLI | MCP tool | Result |
| --- | --- | --- |
| `board [--waiting]` | `board` | Tile ids, state, summaries, and brief |
| `resources` | `resources` | Fleet snapshot with freshness |
| `whoami` | `whoami` | Resolved caller tile or explanation |
| `read <tile> [--lines N]` | `read_tile` | Current screen or recent transcript, bounded to 400 lines |
| `send <tile> <text> [--type]` | `send_message` | Inbox or typed-delivery status |
| `inbox [--all] [--wait S]` | `inbox` | Messages addressed to the caller |
| `ask <question> [--option A] [--wait S]` | `ask_human` | Answer or question id |
| `answer <id> [--wait S]` | `get_answer` | Answer, pending, or dismissed status |
| `notify <text>` | `notify_human` | A note in the Needs-you lane |

CLI exits: 0 success, 1 error, 2 question unanswered, 3 app unavailable or API disabled.
`tessera mcp` uses newline-delimited JSON-RPC over stdio. Tool discovery works while the app is
closed; operations requiring the board return an unavailable error until it opens.

## Trust and privacy

The API binds to `127.0.0.1` and requires a random token stored in the current user's application
data with mode `0600`. Requests with a browser Origin are rejected. Local processes with access
to that user's files can read the token and call the API; this is not a sandbox for hostile agents.

Privacy mode blocks board, resource, tile, identity, inbox, and answer reads and pauses new
Steward requests. Previously sent requests cannot be retracted. Common credential patterns are
redacted from outgoing content, including titles and folders, but arbitrary secrets can evade
pattern matching. Avoid putting sensitive content on a board connected to an untrusted endpoint.
See [SECURITY.md](../SECURITY.md) for the separate remote-pairing boundary.
