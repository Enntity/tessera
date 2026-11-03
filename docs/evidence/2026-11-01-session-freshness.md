# Session freshness correction

The music agent reported “No Spark resources reserved” at 18:39 UTC, announced working at 18:42, and requested the 03/04 reservation at 18:43. The screenshot showed its older waiting report beside the current lease strip. By inspection at 18:53, the source session had reported done and the running Tessera board no longer contained that card. No reservation was changed during this investigation.

Two presentation defects were found in source: external sources were merged in dictionary iteration order, allowing a cached search copy to win over newer live state, and reading shared history refreshed events without refreshing the session title/state. Opened historical sessions also needed completion updates after dropping out of the active-only projection. These paths now use the newest observation with live Accord winning timestamp ties, read current metadata, and retain live updates for opened history.

The screenshot alone does not establish which stale-display path was involved. Independently, projecting every `waiting` report as `needsInput` incorrectly presented ordinary waiting as ASKING. Waiting now projects as idle; blocked reports and actual human questions retain their existing attention behavior. Agent-authored statements are dated and labelled as reports rather than presented as current resource observations.

Validation: 14 focused Accord bridge tests passed, including newer live state versus cached search, tie-breaking, opened history receiving completion, waiting without human attention, privacy, and source failure retention. The signed build is staged for normal app exit; the active Tessera process was not restarted.
