# V4 Calendar Ownership Implementation

Status: first V4-only schema and repository slice; not wired to app startup and not a V3 migration.

## Data model split

- `DBCalendarSourceEvent`: shared source-derived timeline fields only (fingerprint, game, title/date/kind, optional update link and title snapshot).
- `DBAccountCalendarEvent`: user-created events owned by one canonical `itch:<positive-user-id>` account. Reminder preferences and notes stay private.
- `DBAccountCalendarOverlay`: per-account reminder and notes overlay for a shared source event.
- `DBLegacyCalendarEvent`: lossless copy of a V3 calendar row in an unassigned quarantine namespace, including original event identity and all V3 fields plus an optional integrity issue.

Stable IDs use length-prefixed components to avoid delimiter collisions. Patreon identity is not accepted as calendar ownership.

## Repository boundary

`AccountScopedCalendarRepository` requires an explicit V4 `ModelContext` and canonical itch account ID. It supports:
- shared source timeline upsert/read with game and cross-game update-link validation;
- account-filtered personal event CRUD;
- account-filtered overlay CRUD, requiring an existing shared source event;
- resolved active-account event projection (shared events plus only the selected account's overlay and personal events);
- idempotent copying of legacy V3 rows into quarantine without assigning an owner or deleting/changing source rows.

The repository is not used by V3 `GameCalendarStore.shared`, `CalendarRepository`, `AppDatabase`, or app startup. This PR does not switch production reads/writes.

## Migration and runtime intentionally deferred

This slice does not automatically classify or migrate source events. A valid source marker/link still requires a separate integrity-checked migration plan; all personal reminder fields remain unassigned until ownership is proven or explicitly claimed. Markerless and broken-link rows remain recoverable in quarantine.

Account-switch cancellation of in-flight asynchronous work and rebuilding/cancelling notification requests require a later account-aware store/session integration. The resolved projection here is a pure repository snapshot and does not schedule notifications.

## Tests

- same shared source event visible to two accounts with independent reminder/note overlays;
- personal event isolation and cross-account delete protection;
- canonical identity validation and missing-game rejection;
- cross-game source-update link rejection;
- overlay source existence validation;
- lossless, idempotent legacy quarantine without owner assignment or source deletion;
- broken legacy references preserved with an integrity issue.

## Safety boundary

No production startup wiring, V3 row mutation/deletion, owner inference, automatic migration, notification scheduling, or PR merge is performed in this change.
