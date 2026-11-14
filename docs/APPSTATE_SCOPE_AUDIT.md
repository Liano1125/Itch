# AppState Scope Audit (V3 → V4)

Status: source-level audit; no schema or runtime behavior changes.

## Purpose

V3 stores all `DBAppState` rows under one globally unique string key. That is not sufficient for a multi-account app: some values describe the device, some describe shared public caches, and some describe the currently authenticated itch account.

This audit records the key families found in the application source and the proposed ownership boundary. It is a migration design input, not permission to assign legacy rows to the currently signed-in account.

## Scope vocabulary

- **Device** — belongs to this installation or local filesystem, independent of itch/Patreon login.
- **App-global cache** — disposable metadata for shared public catalog/cache work; it is not private account data.
- **itch account** — derived from a verified numeric itch user ID and stored as `itch:<id>`; never inferred from the active account during migration.
- **Patreon account** — independent identity namespace. Never infer an itch↔Patreon relationship from matching email or username.
- **Legacy/unclassified** — preserve without assigning an owner until a deterministic proof or explicit claim/import exists.

## Key-family inventory

| Key / pattern | Current writer | Proposed scope | Confidence and migration treatment |
|---|---|---|---|
| `devlogSync.lastDate` | `GameUpdateMonitorStore` | itch account | Provisional. Historical devlog sync is driven by the account's monitored/library games. Preserve as legacy until the account association is proven. |
| `devlogSync.lastMessage` | `GameUpdateMonitorStore` | itch account | Provisional; presentation state for the historical sync operation. Keep paired with the corresponding account's sync result. |
| `devlogSync.lastResults` | `GameUpdateMonitorStore` | itch account | Provisional; result payload can reflect the set of games processed for that account. Do not expose across accounts. |
| `itchPocket.devlogAutoSync.lastAttempt` | `DevlogAutoSync` | itch account | Provisional; throttles refresh work driven by the account's library/monitor state. |
| `itchPocket.sparkLastSyncAt.v2` | `SparkSyncStore` | Device | Scans the app's local Documents/Allsaves folder. The timestamp describes a device-local scan, not an itch identity. |
| `gameDetail.fetchStatus.<gameID>` | `GameDetailRepository` | App-global cache | Shared public game-detail fetch status. The game detail record itself is shared catalog data. |
| `gameDetail.lastSuccessfulFetch.<gameID>` | `GameDetailRepository` | App-global cache | Shared public game-detail freshness metadata. |
| `detailPrefetch.lastSuccess.<gameID>` | `GameDetailRepository` (legacy read path) | App-global cache / legacy alias | Read for backward compatibility; retain until the legacy alias is explicitly retired. |
| `avatarFailure.<canonical-key>` | `PatreonAvatarService` | App-global cache | Failure backoff for a public developer/avatar URL; safe to rebuild, but do not mix it with account identity. |
| `itchPocket.avatarResolver.version` | `PatreonAvatarService` | App-global cache | Global resolver/cache invalidation version. |
| Any other key | Unknown / future writer | Legacy/unclassified | Preserve byte-for-byte and report for review. Never default to the active account. |

### Other persistence that is not DBAppState

- `itchPocket.launchTab` and `itchPocket.appearance` are stored through `@AppStorage` / `UserDefaults`; treat them as device preferences, not V3 `DBAppState` rows.
- OAuth credentials are stored through Keychain, not `DBAppState`. Credentials must never be copied into a migration report or plain-text app state.
- Patreon identity is separate from itch identity. A Patreon login must not be mapped to an itch account by email, username, or profile similarity.
- Spark save files live in the app's Documents directory; their metadata is device-local unless a future explicit export/import feature says otherwise.

## Repository and deletion behavior

- `AppStateRepository` currently addresses rows by a single global `key`. It has no scope parameter and cannot safely distinguish two accounts using the same key.
- `removeAll(matchingKeyPrefix:)` is currently used by cache cleanup for the `avatarFailure.` family.
- The unqualified `removeAll()` API deletes every `DBAppState` row. It must not be used as a routine account-switch/sign-out cleanup mechanism.
- `restore(_:for:)` is transaction-aware, but it also operates on the globally keyed row. A future scoped repository must include scope in lookup, snapshot, restore, and delete operations.
- Legacy migration copies V1/V2 app-state keys without assigning an owner. That preservation behavior must remain.

## Required V4 design before implementation

1. Add an explicit scope discriminator to persisted state. A practical identity is a deterministic composite key such as `<scope-id>|<logical-key>`, with a separately retained logical key for diagnostics and compatibility.
2. Enforce uniqueness on the composite identity, not on the logical key alone, so the same logical key can exist independently for multiple itch accounts.
3. Make every repository operation require an explicit scope (read, write, snapshot, restore, prefix deletion, and enumeration). Avoid implicit "current account" defaults in migration code.
4. Keep device and app-global cache state outside account partitions. Keep itch and Patreon identities in separate namespaces.
5. Introduce a versioned, reviewed key registry. Unknown keys remain legacy/unclassified and are preserved; no catch-all assignment is allowed.
6. Account-scoped historical rows are not assigned merely because one account is signed in during upgrade. Use independent ownership evidence or a user-confirmed claim/import flow.
7. Account switching must change the scoped view, not delete another account's state. Sign-out must hide account data without destructive cleanup unless explicitly requested.
8. Add tests for identical logical keys across two accounts, device/global isolation, unknown-key preservation, prefix deletion within one scope, rollback, and interrupted migration.

## Validation boundary

This is a source-level classification, not a scan of a user's real database. It does not prove the ownership of any existing V3 row. The PR #66 preflight counts rows and marks all V3 `AppState` rows for ownership review; it intentionally does not expose their key names or payload values.

No V3 schema, V4 schema, startup path, production database, or runtime behavior is changed by this document.
