# Calendar Data Ownership Audit (V3 → V4)

Status: source-level design audit; no schema, startup, or runtime changes.

## Why the current row is mixed-scope

V3 `DBCalendarEvent` is one globally keyed record containing both source/timeline fields and user-controlled reminder fields:

- Identity and relationship: `id`, `gameID`
- Event/timeline fields: `title`, `date`, `kind`, `sourceFingerprint`, `sourceUpdateID`, `gameTitleSnapshot`
- Reminder/personal fields: `reminderEnabled`, `reminderMinutes`, `notes`

The application also enriches linked events from shared `DBGameUpdate` rows. `GameCalendarRepository.events()` prefers the linked update's title, date, summary, and URL when the link is valid. The stored calendar row therefore acts partly as a source/timeline index and partly as a user-facing event/reminder record.

A direct copy of every V3 calendar row into a shared V4 table would leak personal reminders and notes across accounts. A direct copy into the active account would incorrectly claim historical ownership.

## Source-derived versus user-created event signals

### Strong source-derived markers

The current code creates system-generated timeline rows with one or both of:

- `sourceFingerprint` (detected updates and historical Devlog entries)
- `sourceUpdateID` (link to a canonical `DBGameUpdate` row)

When present, these are strong evidence that the event has a shared source/timeline component. The referenced update must still pass game-ID and source-integrity checks before migration.

### User-created event path

The calendar editor creates events for the selected personal-library game and permits the user to set:

- title
- date and time
- kind (planned play, release, update, or custom)
- reminder enabled / lead time
- notes

Those fields are user-authored and must be account-scoped after ownership is established. A missing source marker is not enough to prove that a row is user-created; it could also be an older or partially migrated source row.

### Ambiguous legacy rows

Rows without a valid source marker/link, rows with dangling or cross-game update links, and rows whose provenance cannot be proven remain legacy/unclassified. Do not infer ownership from the current session, event kind, game ownership today, or a matching game title.

## Proposed V4 decomposition

The following is a target design, not a migration already implemented.

1. **Shared source timeline** — a shared record for source-derived events, keyed by stable source identity and linked to shared `DBGame` / `DBGameUpdate`. Store only source-derived title/date/kind/fingerprint/link and a non-authoritative game-title snapshot if still needed.
2. **Account-owned personal calendar events** — a separate account-scoped record for user-created plans and custom events. Its owner must be a verified `itch:<numeric-user-id>` or an explicit unassigned/claim state.
3. **Account-owned source-event preferences** — an optional overlay keyed by (accountID, sourceEventID), containing reminder enablement, reminder lead time, and user-authored notes/preferences for a shared source event.
4. **Device notification projection** — local notifications are derived from the currently visible account's personal events and preference overlays. They are not the canonical source of ownership and must be rebuilt after account switch.

Do not force every field into the shared source table. In particular, `reminderEnabled`, `reminderMinutes`, and `notes` are not safe to expose globally merely because a row has a source fingerprint.

## Legacy migration policy

- **Valid source marker/link:** the source component may be copied to the shared timeline only after referential validation. Its reminder fields and notes remain unassigned until ownership is proven or the user claims them.
- **No source marker:** preserve the complete row in a legacy/unassigned staging bucket. Do not assume it belongs to the active account.
- **Broken or cross-game link:** preserve the raw row and report an integrity issue; do not silently repair or discard it.
- **User claim/import:** if a user explicitly claims legacy personal events, copy the full personal event and reminder state to that verified itch account, recording provenance and making the operation restartable/idempotent.
- **Unknown fields / future schema:** preserve without normalization until a reviewed mapping exists.

## Runtime changes required later

- Replace the process-wide `GameCalendarStore.shared` data view with an account-aware store/repository boundary.
- On account switch, invalidate in-flight calendar work and rebuild the visible calendar from shared source events plus the selected account's personal events and preference overlays.
- Schedule/cancel local notifications only from the active account's resolved view; prevent one account's reminders from surviving as another account's visible notifications.
- Ensure editing a shared source event changes only that account's overlay, not the shared source event.
- Keep Patreon identity separate. Calendar ownership follows the itch account unless a future feature explicitly defines a distinct Patreon-owned calendar.

## Required tests before production migration

- Two itch accounts can hold different reminders/notes for the same shared source event.
- Shared source events remain visible to both accounts without leaking personal overlays.
- User-created events from account A never appear in account B.
- Unknown and ambiguous V3 rows are preserved without owner assignment.
- Broken source links are diagnosed and remain recoverable.
- Account switching cancels stale writes and refreshes notification projections.
- Interrupted staging can resume without duplicate events or loss of notes/reminder settings.
- Rollback leaves the original V3 store unchanged.

## Validation boundary

This is a source-level ownership audit. It does not inspect the user's actual calendar rows, prove any V3 row's owner, or perform a migration. PR #66's preflight correctly marks every V3 calendar row for ownership review. No production data or startup behavior is changed here.
