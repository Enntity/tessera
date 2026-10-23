# Five-minute control-plane demo

Use a separate demonstration board with invented work. Keep personal transcripts, endpoint
keys, and real resource assignments out of a public recording. The repository screenshot
generator uses fixtures; its board is illustrative rather than proof of live functionality.

1. **Start with two agents (one minute).** Open two terminal tiles, call `tessera whoami` in each,
   then `tessera board`. Explain that the agents can find other work without sharing a harness.
2. **Exchange a message (one minute).** Send from one tile to the other's exact id, retrieve it
   with `tessera inbox`, and send a reply. Show that inbox delivery is pull-based. If demonstrating
   `--type`, use a disposable terminal and approve the delivery in the lane.
3. **Ask a human (one minute).** Run `tessera ask 'Which demo should run next?' --option 'Tests'
   --option 'Build' --wait 0` as one command. Answer in the lane; retrieve it with `tessera answer
   '<id>' --wait 0`. Other tools continue while the question is pending.
4. **Show resources (one minute).** With a demo LLooM head connected, show `tessera resources`
   beside Fleet. Point out the owner, queue, expiry, and fetch timestamp. Explain that LLooM
   grants reservations; Tessera observes them. If no head is available, show the honest
   unconfigured response and use a clearly labeled screenshot for illustration.
5. **Let Steward brief the board (one minute).** Enable a tested model endpoint before the demo,
   allow time for summaries, and show the brief alongside the underlying tiles. Its name is
   Steward. It suggests; the developer decides. Finish by toggling privacy mode and showing a
   refused board read.

Leave the terminal/window overview until after the coordination workflow. Useful closing line:
“Each agent can see the other work, ask for what it needs, and bring decisions to one queue.”

Before presenting: test the packaged candidate, verify the app and CLI versions match, run the
two-terminal exchange, and confirm the selected endpoint responds. Use the release audit to
separate automated coverage from manual checks. Do not describe a development candidate as a
notarized public download.
