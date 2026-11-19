# V4 Update Watch Ownership Audit

Status: source-level audit and migration design only. No schema, runtime, startup, notification, or V3 data changes are made in this document.

## Current V3 shape

V3 `DBUpdateWatch` is globally unique by `gameID` and stores:

- `isEnabled`: user preference controlling whether the game is monitored.
- `entityTag`, `lastModified`, `contentHash`, `lastCheckedAt`, `hasBaseline`: HTTP response validators and local comparison state.

The current repository loads every row without an account context, and writes/removes rows using only `gameID`. `GameUpdateMonitorStore.shared` is process-wide. This is not safe for two itch accounts that independently choose which games to monitor.

## Ownership findings

### Confirmed account-specific

- `isEnabled` is an explicit user choice. It must belong to the itch account whose library game is being monitored.
- The enabled watch set must be filtered by the active, verified itch account.
- A watch removal must delete only that account's preference, never another account's watch.
- Update notifications must be namespaced by account and invalidated on account transition. The V3 identifier currently uses only `gameID`, so two accounts can overwrite or remove each other's notification.

### Validators are not yet proven globally shareable

The ETag, Last-Modified, content hash, baseline flag and last-check timestamp look like reusable polling metadata for a public game page. However, current update checks call `URLSession.shared.data(for:)`. That session can use shared cookie storage and other shared session state. The request path does not explicitly prove that responses are independent of the currently signed-in itch website identity.

Therefore these fields must **not** be migrated into a shared V4 poll-state table yet. A response may vary by authentication, age-gate/session cookie, localization, or other request context. Sharing its validators could make one account's check suppress or mis-detect another account's changes.

Historical Devlog sync explicitly reads itch website cookies and is a separate authenticated flow. Its cookies must never be copied into the update-watch database or migration manifest.

## Safe V4 target for the first implementation

Use one account-scoped watch row, keyed by (accountID, gameID), and keep all current watch fields together:

- canonical `accountID` in the form `itch:<positive-user-id>`;
- `gameID`;
- `isEnabled`;
- `entityTag`, `lastModified`, `contentHash`, `lastCheckedAt`, `hasBaseline`.

This deliberately duplicates validators between accounts at first. It is safer than assuming HTTP response equivalence. A future optimization may extract shared poll metadata only after a dedicated request client proves cookie-free, account-independent behavior and tests demonstrate identical responses across sessions.

The repository API must require an explicit verified account ID for list, enable, disable, update, and delete operations. No API may load or mutate all accounts' watches implicitly.

## Network and asynchronous safety

- Introduce an explicit update-check client with a documented cookie policy. Do not silently inherit `HTTPCookieStorage.shared` or shared URL cache state.
- Until public unauthenticated behavior is demonstrated, use account-scoped request/session state and account-scoped validators.
- Capture the authenticated itch session generation before each check; after every await and before persistence, verify that the same account/session is still active.
- Stage response results only for the initiating account. A stale request must not update another account's watch, library, calendar, or notifications.
- Historical Devlog RSS requests remain a separate authenticated pathway; do not reuse its cookie injection for page polling.
- Notification identifiers must include the canonical account ID and game ID. On account switch, remove only the previous account's notification namespace, and rebuild the active account's projection.

## V3 migration policy

V3 rows have no account owner. The fact that a game currently appears in one account's library does not prove that the old watch preference or its validators belonged to that account.

- Preserve every V3 row losslessly in an unassigned legacy-watch quarantine.
- Do not copy a row into the currently authenticated account.
- Do not infer ownership from the game's current library membership, title, URL, or current login.
- A later explicit user claim/import flow may copy a selected legacy watch into a verified account, recording provenance and making the action idempotent and restartable.
- If the migration has not implemented the quarantine converter and verifier, a non-empty V3 watch table must remain an uncovered domain and block promotion.

## Required tests before production use

1. Account A and B can independently enable/disable monitoring for the same game.
2. Listing watches for A never returns B's rows; removing A's row preserves B's row.
3. Validators and baselines never cross account boundaries.
4. A stale A request completing after switch to B cannot persist or notify.
5. Notification identifiers and cleanup are account-scoped.
6. Session/cookie tests prove the configured HTTP client does not accidentally share authentication state.
7. Legacy V3 watch rows are quarantined without owner assignment and survive restart/recovery.
8. An explicit claim/import operation is idempotent and cannot overwrite an existing account watch.

## Validation boundary

This audit is based on source inspection of `DBUpdateWatch`, `GameUpdateMonitorRepository`, and `GameUpdateMonitorStore`. It does not inspect live user rows, establish historical ownership, or change production behavior. Existing V4 startup is not wired to these proposed models.