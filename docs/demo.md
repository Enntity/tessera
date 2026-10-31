# Five-minute collaboration demo

Use a disposable host and invented work. Keep personal transcripts, credentials and real
resource assignments out of recordings.

1. Start two different agent clients with the Accord skill. Have both call `accord_bootstrap`
   and announce their work. Use `accord_find` to show the other participant.
2. Send a message through `accord_send`, read it through `accord_inbox`, and acknowledge with
   `accord_read`. Show that opening Tessera does not mark the recipient's message read.
3. Ask a question with `accord_ask`. Answer in Tessera's Needs-you lane and retrieve the same
   answer with `accord_question`. Repeat with Accord's web UI while Tessera is closed.
4. Show a disposable resource through `accord_resources` beside the native Fleet band. Reserve
   it, wait for `running`, then release and wait for confirmation. A snapshot alone grants nothing.
   Demonstrate crash recovery only with a fixture process, never an active serving workload.
5. Search shared session history from the command palette. Show Accord's summaries beside the
   native board brief and an overseer check-in. Open the underlying evidence before acting.

Use native `tessera board`, `read`, and `whoami` only when demonstrating Mac-specific inspection.
Tessera no longer publishes coordination commands or an agent skill. Verify the package before
presenting; a development candidate is not a notarized public download.
