# Tessera: agents need a way to coordinate

Running several coding agents gives you several conversations to follow. One is waiting for a
decision, another is editing the same files, and a third needs hardware someone else is using.
Tessera puts that coordination in one place on your Mac.

An agent can use Tessera's CLI or MCP server to discover other sessions, read their current
state, exchange messages, and ask you a question with answer choices. The question joins one
Needs-you queue, wherever the agent is running. Messages have a recipient inbox, and typing a
message into another terminal requires your approval by default.

With a LLooM head connected, agents can inspect shared resource holders, queues, and lease
expiry. Every response includes freshness information. LLooM still handles reservations, so an
agent must acquire a resource before using it.

The Steward adds a short model-generated brief: what changed, what needs you, and what might be
put away. It is advisory. You can open the underlying work to check its summary, and nothing
closes unless you act. Point it at a local model or an endpoint you trust with the board's content.

The native workspace provides live terminal tiles, desktop agent conversations, session resume,
a watch dock, and a connected iPhone view. Those controls give you a way to inspect and act on
the work the coordination layer exposes.

Tessera is MIT-licensed and currently targets macOS 15 and newer. Linux is future work.
Start with the [agent setup guide](install.md) and the [five-minute demo](demo.md).

Publication note: attach the verified public release link only after Developer ID signing and
notarization pass. The release candidate alone does not establish that installation experience.
