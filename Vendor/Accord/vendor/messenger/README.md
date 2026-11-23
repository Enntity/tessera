These MIT-licensed files are copied without changes from Enntity Messenger
commit `08a788e25a80650f7a0355341852975cbe424d2b`:
`src/store.js`, `src/auth.js`, `src/errors.js`, `src/client.js`, and `LICENSE`.

Accord embeds the SQLite store in its host process. No Messenger daemon, account,
or network access is needed for Accord's own mail. `client.js` is used only when an
agent claims an identity on a remote Messenger service (`src/messenger-claims.mjs`).
Update these files together from a reviewed revision. Accord owns only
the address adapter and host transport outbox. The vendor integrity test pins the
exact upstream file hashes.
