# Accord board cleanup — installed verification

A failed Accord poll previously removed every imported Tessera tile, and a later
successful poll recreated them. Background overseer incidents were also rendered
as full-size tiles whose system-only content was hidden by the thumbnail view.

The installed build retains the last good snapshot through transport failures,
including individual unreachable peers. Background check-ins stay in Accord;
human questions still use Tessera's attention UI. Completed, idle and old shared
sessions remain searchable without filling the default board. Host-authenticated
bindings suppress duplicate native tiles. Active shared sessions render summaries.
The unused artifact resource no longer appears in the fleet strip.

Accord announcements preserve lifecycle state unless explicitly changed. Bound
native sessions resolve obsolete duplicate incidents, and unchanged observations
do not continually reorder incidents. Remote holders resolve through their exact
origin identity, including older hosts. Four notification-only hardware rules
require 15 minutes of fresh idle telemetry and allow one ping per incident.

Validation and installed binary identity are in [installed.json](installed.json).
The full LLooM suite passes after correcting a macOS TCP accept-backlog artifact
in the rate-limit stress test; all 300 requests still overlap, with 256 waiters
and 43 queue-full responses. Both products pin the same qualified Accord package.

The Spark gateway was not restarted. Its configuration and routes were unchanged.
The observed training container completed with exit code 0 during verification.
Its lease was not altered. External container recovery registration remains a
separate coordinated handoff; these checks do not prove arbitrary workloads are
stopped before a new grant. Do not upgrade a host driver with an active grant.
