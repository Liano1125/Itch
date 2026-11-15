# V3 AppState Ownership Audit

Status: source audit and migration design only. This document does not change V3/V4 schemas, runtime repositories, background task behavior, startup, credentials, or persisted user data.

Audit baseline: `audit/v4-update-watch-ownership` at `7229aff9b2f299a9322aca3377aeb6bd9776d3f3`.

## 1. Executive summary

The V3 `DBAppState` table is globally keyed and has no owner field. A key's semantic scope can be inferred from its source-reviewed usage, but the owner of any historical account-scoped row cannot be inferred from the currently signed-in account.

The existing V4 `AppStateScopeRegistry` and `ScopedAppStateRepository` provide the right foundation:
- explicit device, app-global, itch-account, Patreon-account, and legacy-unclassified scopes;
- explicit account identifiers, with no implicit current-account resolver;
- scoped deletes and typed values;
- no automatic V3 row import.

The remaining risk is not the V4 repository primitive. It is migrating and wiring each feature to the correct scope, and making legacy rows reviewable without silently claiming them.

## 2. Source-reviewed V3 key inventory

| V3 key / family | Current source usage | Proposed semantic scope | Confidence | Migration rule |
|---|---|---|---|---|
| `devlogSync.lastDate` | `GameUpdateMonitorStore` historical Devlog sync result | itch account | provisional | Preserve as legacy/unassigned; never attach to current itch login |
| `devlogSync.lastMessage` | `GameUpdateMonitorStore` historical Devlog sync result | itch account | provisional | Same |
| `devlogSync.lastResults` | `GameUpdateMonitorStore` historical Devlog sync result payload | itch account | provisional | Same; do not expose across accounts |
| `itchPocket.devlogAutoSync.lastAttempt` | `DevlogAutoSync` six-hour throttle/completion marker | itch account | provisional | Preserve as legacy/unassigned; rebuild per-account throttle state |
| `itchPocket.sparkLastSyncAt.v2` | `SparkSyncStore` timestamp after scanning local Documents/Allsaves save files | device | established | May be migrated to device scope only after key/value validation; otherwise quarantine |
| `gameDetail.fetchStatus.<gameID>` | `GameDetailRepository` fetch completeness status | app-global | established | Rebuildable public game-detail metadata; retain as app-global only if its source fetch policy remains account-independent |
| `gameDetail.lastSuccessfulFetch.<gameID>` | `GameDetailRepository` successful detail fetch timestamp | app-global | established | Same |
| `detailPrefetch.lastSuccess.<gameID>` | Legacy alias read by `GameDetailRepository` | app-global | provisional | Keep as legacy alias; resolve precedence and validate game ID before optional migration |
| `avatarFailure.<key>` | `PatreonAvatarService` retry/backoff marker keyed by creator/avatar resolution identity | app-global | established | Rebuildable retry metadata; never treat as Patreon account preference |
| `itchPocket.avatarResolver.version` | `PatreonAvatarService` resolver cache version | app-global | established | Rebuildable app-wide version marker |

The source-reviewed registry currently classifies these keys/families. Any V3 key not explicitly covered by the registry remains `legacyUnclassified`; do not widen matching rules based only on a guessed prefix.

## 3. Account-scoped Devlog state: correctness issue to fix before V4 wiring

Two source paths use global V3 AppState for account-dependent Devlog work:

### Historical sync projection

`GameUpdateMonitorStore` loads and writes:
- `devlogSync.lastDate`
- `devlogSync.lastMessage`
- `devlogSync.lastResults`

The store is a singleton, and these values are currently loaded without an itch account scope. They describe the last historical sync of the signed-in user's library, so they must be scoped to the canonical itch account ID in V4.

### Automatic sync throttle

`DevlogAutoSync.refreshIfNeeded` captures a library request context and correctly checks that context before writing its completion marker. However, it currently reads and writes one global key, `itchPocket.devlogAutoSync.lastAttempt`.

That means a successful recent sync for account A can cause account B to be throttled for up to six hours, even though the result is not account B's work. The post-await session guard prevents a stale A result from writing after a switch, but it does not partition the initial throttle read.

V4 must use an explicit itch-account scope for both the read and write. The account ID used for the lookup must be the same ID captured in the request context; a session switch must not redirect an in-flight completion marker into the new account's scope.

## 4. Device and app-global state boundaries

### Device scope

- `itchPocket.launchTab` and `itchPocket.appearance` are `@AppStorage` preferences in `ContentView`; they are device-local UI preferences, not V3 `DBAppState` rows.
- `itchPocket.sparkLastSyncAt.v2` records a scan of the local `Documents/Allsaves` folder. Its current semantics are device-local, not itch-account or Patreon-account state.

### App-global scope

- Game detail fetch status/date are keyed by game ID and support shared canonical `DBGameDetail` records. Keep them app-global only while fetched content is demonstrably account-independent. If age-gated, private, or cookie-personalized game pages are cached, those records need a separate privacy/ownership design.
- Avatar resolver version and creator avatar retry markers describe app-wide rebuildable resolution work, not the currently connected Patreon user's preferences.

App-global does not mean safe to share blindly: any fetched payload that may contain private or account-personalized content must be reviewed separately from its cache key.

## 5. Patreon identity and credential boundary

`PatreonAccountService` currently holds one active Patreon account in memory and stores its session token in Keychain under `patreon_session_token`. The credential must remain in Keychain; never copy it into `DBAppState`, `DBScopedAppState`, migration manifests, logs, or diagnostics.

V4's `patreonAccount` AppState scope is available for future Patreon-account preferences, but the source audit found no current Patreon-account AppState key family to migrate. Do not manufacture one. If multi-Patreon-account support is later required, design a separate credential/account lifecycle with explicit account identity and secure Keychain item names; that is outside this AppState migration slice.

## 6. Unknown legacy rows

A key not classified by the source-reviewed registry must remain in `legacyUnclassified`.

Migration must:
- preserve the exact original key and typed value;
- record source row identity and validation diagnostics;
- never assign ownership from the active session, username, currently linked Patreon account, or device state;
- reject duplicate source keys or invalid typed-value combinations before staging writes;
- avoid deleting V3 rows during conversion;
- require explicit user/account claim evidence before moving an account-scoped legacy value into a real account scope.

## 7. Required implementation and test gates

1. Every V4 feature read/write supplies an explicit `AppStateScope`; no implicit active-account fallback.
2. Devlog historical sync projection is isolated between two itch accounts.
3. Devlog auto-sync throttle is independent between two itch accounts.
4. A delayed account A completion cannot write to account B after a switch.
5. Device preferences and Spark local-save scan marker remain device-scoped.
6. Game detail and avatar metadata remain app-global only under documented account-independent fetch policies.
7. Unknown V3 keys survive as legacy/unclassified with exact typed values.
8. No historical account-scoped row is assigned to the active account without independent ownership evidence.
9. Patreon tokens remain exclusively in Keychain and never appear in migration output.
10. Account switch/sign-out cleanup removes only the departing account's scoped state; it must not call unqualified `removeAll()` against the shared state table.

## 8. Scope boundary

This PR is audit/documentation only. It does not:
- change `DBAppState` or `DBScopedAppState`;
- wire `ScopedAppStateRepository` into production feature stores;
- change the global Devlog throttle behavior yet;
- move Keychain credentials;
- add multi-Patreon-account support;
- migrate, delete, or rewrite any V3 AppState row;
- connect V4 to production startup or promote the V4 database.

The next implementation slice should first add explicit account-scoped Devlog state APIs and tests in isolated V4 services, without replacing the currently active V3 production path. A separate, reviewed cutover must follow only after the complete database snapshot, parity, atomic promotion, restart recovery, and rollback gates are satisfied.
