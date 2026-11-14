# V4 Account Isolation: Migration Architecture Audit

Status: design/audit only. This document does not change the active V3 schema, startup path, repositories, or user data.

Baseline reviewed: PR #61 head 9a4c1fb0dff632bb5970c0618122d8476b9f9e8e.

## 1. Executive decision

Do not switch production startup to V4 yet.

The current V4 model tests establish that the proposed account-keyed records can coexist in an in-memory SwiftData container. They do not establish that the running application is account-isolated. The active app still creates one V3 AppDatabase, and the main feature stores and repositories read/write globally unique V3 records through shared singleton instances.

Deliver the migration in separate, reviewable slices:

1. Freeze and verify the complete V4 schema contract.
2. Introduce account-aware repository APIs and request-generation enforcement while production remains on V3.
3. Define and test ownership-preserving conversion using disposable V3 copies.
4. Add staged V4 bootstrap with backup, validation, promotion, restart recovery, and rollback.
5. Switch startup only after the complete repository/store graph is account-aware and all migration gates pass.

No row may be assigned to an account merely because that account happens to be logged in during migration.

## 2. Current architecture findings

### What exists

- ItchAccountIdentity uses the numeric itch user ID as stable identity.
- ItchAccountSession increments a generation when the active identity changes or signs out.
- ItchAuthService activates/deactivates that session during restore, sign-in, and sign-out.
- DBAccount persists profile metadata; OAuth credentials remain in Keychain.
- V4 defines account-keyed replacements for library entries, collections, collection membership, and status history.
- V4 in-memory tests cover two accounts, same-game separation, shared game-directory uniqueness, and explicit legacy/unassigned rows.
- V3 remains the active schema and startup path.

### What is not connected

- ContentView constructs PersonalLibraryStore.shared, GameCalendarStore.shared, GameUpdateMonitorStore.shared, and SparkSyncStore.shared.
- GameCalendarRepository.shared and GameUpdateMonitorRepository.shared are bound to AppDatabase.shared.
- LibraryRepository, LibraryStatusHistoryRepository, CalendarRepository, UpdateMonitorRepository, and AppStateRepository issue unscoped fetches and writes.
- The account session generation API is not yet checked by every async operation before it publishes state or commits results.
- Spark save scanning uses a device-level Documents/Allsaves folder and should remain device-local unless a future product requirement explicitly introduces account-specific save directories.
- Patreon authentication is a separate identity/session and must not be inferred from an itch account by email or username.

PR #61 is a schema foundation, not completed multi-account isolation.

## 3. V4 record ownership matrix

| Model / domain | Target scope | Migration rule |
|---|---|---|
| DBAccount | Global account registry on device | Create only after successful profile validation using numeric itch user ID. Never store OAuth tokens here. |
| DBDeveloper | Shared catalog | Keep one canonical row per developer ID. |
| DBGame | Shared catalog | Keep one canonical row per game ID. |
| DBGameDetail | Shared, rebuildable detail | Preserve canonical detail snapshot; do not duplicate per account. |
| DBGameUpdate | Shared public update content | Keep public devlog/update content shared. Per-account read, mute, follow, or seen state must be a separate model. |
| DBLibraryEntry | Per itch account | Convert V3 row to legacy/unassigned unless ownership is independently proven. |
| DBLibraryCollection | Per itch account | Preserve key/title/timestamps; do not infer owner from current login. |
| DBLibraryCollectionItem | Per itch account | Rebuild membership using scoped collection key and game ID; validate parent and game references. |
| DBLibraryStatusEvent | Per itch account | Preserve event key, game ID, statuses, and timestamp; keep owner nil when not provable. |
| DBUpdateWatch | Per itch account | V3 watch rows are globally keyed by game ID; copy as unassigned unless durable account association exists. |
| DBCalendarEvent | Split public source data from personal event state | Requires explicit classification and likely model split; do not bulk-assign all rows. |
| DBAppState | Explicitly key-classified | Global/device keys remain global; itch preferences/cursors become account-scoped; unknown keys remain unassigned. |
| DBTranslation | Shared cache | Retain as rebuildable shared cache unless a key embeds private/user-specific input. |
| DBDiscoverySnapshot | Shared cache | Retain as rebuildable shared cache; verify cache key contains no account-private response. |
| DBSparkMetadata | Device-local | Preserve as local save-scan metadata, not an itch account property. |
| Patreon account/session | Separate provider identity | Keep independent of itch identity; no automatic cross-provider account linking. |

### Calendar classification is a blocker

V3 DBCalendarEvent mixes fields that may have different ownership:

- Potentially public/source-derived: game ID, title, date, kind, source fingerprint, source update ID, game-title snapshot.
- Personal: reminder enabled, reminder lead time, notes.
- Some events may be user-created and have no reliable source provenance.

Before V4 cutover, define a normalized representation that separates shared source event identity/content from account-scoped reminder/notes/preferences. Preserve original IDs and provenance. For legacy rows with uncertain ownership, retain the full original payload in a recoverable unassigned record rather than assigning it to the first account.

### App-state key registry is a blocker

Do not decide ownership by broad string-prefix guesses at migration time. Add a source-controlled registry of exact known keys or narrowly-defined namespaces with one of: global, device-local, itch-account, Patreon-account, rebuildable-cache, or unknown. Unknown keys remain preserved in a legacy bucket. Every key added after this audit must declare its scope and have a test.

## 4. V3 to V4 ownership and conversion rules

### Account identity

- Stable key: itch:<numeric user ID>.
- Username, display name, avatar, and profile URL are mutable profile fields only.
- Create/update DBAccount only after a profile has been successfully fetched and validated.
- Never persist OAuth access/refresh credentials in SwiftData.
- Do not use Patreon identity, email, or display name to guess an itch account.

### Legacy personal rows

For each V3 library entry, collection, collection membership, status event, update watch, calendar preference, and account-like app-state key:

1. Read from a read-only V3 source snapshot.
2. Capture into value-only migration DTOs.
3. Assign an account only if an authoritative durable ownership source exists and is validated against the numeric itch user ID.
4. Otherwise use an explicit legacy/unassigned scope.
5. Preserve source IDs and timestamps for traceability.
6. Reject duplicate/conflicting identities before mutating the V4 staging store.
7. Never resolve ambiguous ownership by choosing the currently authenticated account.

The V3 model shape has no accountID field on its personal rows. A single-account V3 install does not by itself prove which remote account owns each row. A local access token at migration time is not sufficient evidence unless the app has a previously persisted, validated mapping between that token's numeric user ID and the exact local data snapshot. If no such mapping exists, keep the data unassigned and provide a deliberate user-facing claim/import flow later.

### Deterministic scoped identifiers

Use an unambiguous length-prefixed encoding or collision-resistant canonical encoding for composite IDs. Define it once and test nil/legacy scope, empty strings, Unicode identifiers, delimiter-containing identifiers, same game/key/event across two accounts, and repeated migration idempotence. Do not rely on delimiter concatenation unless escaping is formally specified.

## 5. Migration architecture

Reuse the safety properties proven by the V2 to V3 bootstrap, not a direct in-place V3 schema open.

### Phase A — preflight, no writes

- Confirm the active V3 store exists and is the expected authoritative store.
- Run SQLite quick_check.
- Open V3 with the frozen V3 schema in read-only mode.
- Validate unique IDs, references, collection memberships, orphan rows, and model counts.
- Capture a deterministic inventory and migration manifest.
- Confirm enough disk space for source, backup, staging, and final stores.
- Close the V3 container before any copy/open operation on another schema.

### Phase B — durable backup and staging

- Create a consistent SQLite snapshot using the existing SQLite backup API, including committed WAL content.
- Keep the original V3 directory untouched.
- Keep a separately named immutable V3 recovery copy.
- Build V4 only in a fresh staging directory.
- Never open V3 and V4 containers simultaneously against the same SQLite files.

### Phase C — transform and validate staging

- Create V4 account registry rows only from validated identity records.
- Copy shared catalog/cache/device-local records according to the ownership matrix.
- Convert personal rows with owner proven or nil/unassigned.
- Split calendar source content from personal settings using the approved policy.
- Apply exact AppState key-scope registry.
- Validate counts, IDs, references, per-account uniqueness, shared-row non-duplication, nil-owner preservation, and payload equivalence.
- Close the V4 staging container, then run SQLite quick_check.
- Write a manifest containing source store identity/version, row counts by model and scope, transform version, and a completion checksum. Do not put credentials or private note contents in logs.

### Phase D — promotion and recovery

- Promote the validated staging directory atomically to the V4 final directory.
- Persist a small versioned promotion marker so restart can distinguish incomplete staging, validated staging, promoted V4, and completed startup.
- If interrupted before promotion, discard/rebuild staging from the untouched V3 source.
- If interrupted after promotion but before completion marker, revalidate V4 and resume idempotently.
- If V4 validation fails, do not delete or mutate V3; quarantine only the invalid V4 candidate and start from V3 recovery.
- Keep the V3 backup until a later app release has demonstrated successful V4 operation and the user has an explicit backup-retention policy.
- Never silently fall back by overwriting or rebuilding from a stale older schema.

### Phase E — runtime cutover

Only after repositories and stores are account-aware:
- Switch database bootstrap to V4.
- Resolve the active account by numeric ID after session restore.
- Load only that account's personal records.
- Keep unassigned records hidden from account views but accessible to a dedicated recovery/claim workflow.
- On sign-out, clear private in-memory presentation state immediately; do not delete persisted data.
- On account switch, cancel or invalidate prior-account work before publishing new-account state.

## 6. Async request isolation contract

Every async operation that can affect account-scoped state must:

1. Capture accountID and generation before its first suspension point.
2. Carry those values through network, parsing, and background work.
3. Re-check both active account ID and generation immediately before every in-memory publication and every persistence commit.
4. Discard stale results without writing or publishing them.
5. Cancel prior-account tasks where practical; generation validation remains mandatory because cancellation is cooperative.
6. Avoid using a global shared context from detached/background work.

Tests must deliberately delay account A's response, switch to B or sign out, then release A's response and assert that neither B's store nor the database is modified.

## 7. Store and repository refactor order

1. Introduce an explicit dependency container (database + account session + repositories) instead of resolving AppDatabase.shared inside account-owned services.
2. Make library entry, collection, membership, and status-history repositories accept explicit account scope. Reads must require an account ID; writes must derive IDs from that same scope.
3. Make the library store an account-scoped instance; remove the singleton assumption only after all call sites receive the dependency container.
4. Add account-scoped update-watch persistence.
5. Split calendar source events from per-account reminder/notes state.
6. Add AppState scope registry and migrate known keys.
7. Keep public game/developer/detail/update repositories shared.
8. Keep Spark save scanning device-local; separate any account-owned UI preference from local filesystem scan results.
9. Integrate request-generation checks into every async service/store before enabling account switching.
10. Keep Patreon session and any future Patreon-owned data in a separate provider namespace.

Do not partially change shared V3 repositories to use V4 model types. Keep production V3 stable until a coherent V4 repository graph exists.

## 8. Required test matrix before cutover

### Schema and conversion
- Empty V3 store.
- Populated V3 store with every model family.
- Legacy V3 personal rows remain unassigned when no proof exists.
- Valid explicit ownership mapping assigns only matching numeric itch IDs.
- Conflicting/duplicate mapping aborts before promotion.
- Shared game/developer/detail/update rows remain singletons.
- Device-local Spark metadata is preserved without account ownership.
- Calendar rows cover source-derived, user-created, and mixed personal settings.
- AppState known scopes and unknown-key preservation.
- Unicode/delimiter composite IDs and deterministic re-run.

### Recovery
- Failure before snapshot completion.
- Failure after snapshot and before V4 creation.
- Failure during transform.
- Failure after staging validation.
- Failure during promotion.
- Process restart after promotion but before completion marker.
- Corrupt V4 staging while V3 remains readable.
- SQLite WAL content preserved.
- Re-running migration does not duplicate rows or alter the source.

### Runtime isolation
- Account A and B can own the same game with independent status/favorite/notes/history/collections/watches.
- Switching A to B reloads B's records only.
- Signing out immediately hides A's private data without deleting it.
- Signing back into A restores A's records.
- Delayed A responses cannot update B or write after sign-out.
- Same-account profile refresh does not invalidate legitimate requests.
- Patreon identity remains independent.
- Unknown/unassigned records are never exposed as a logged-in account's data.

## 9. Implementation gates

- Gate 1: this audit and ownership policy reviewed; no production schema change.
- Gate 2: account-aware repositories and store lifecycle covered by tests, still running against V3 test fixtures or isolated test containers.
- Gate 3: deterministic V3-to-V4 converter tested against fixture databases and interruption injection.
- Gate 4: V4 staging bootstrap, backup, validation, promotion, and rollback tests pass.
- Gate 5: full app build and regression suite pass; no unscoped account-owned repository remains.
- Gate 6: only then enable V4 startup behind a controlled migration path.

## 10. Explicit non-goals for this slice

- No merge of PR #61.
- No V4 production startup.
- No V3 data mutation or migration.
- No automatic ownership inference from current login, email, username, or Patreon.
- No automatic deletion of unassigned data.
- No scheduled daily CI or monitoring tasks.
