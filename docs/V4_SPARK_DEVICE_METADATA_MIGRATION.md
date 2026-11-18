# V4 Spark Device Metadata Migration

## Ownership decision

`DBSparkMetadata` records are derived from Ren'Py save files scanned from this installation's local `Documents/Allsaves`. They describe local play time, last save, Ren'Py version, save count, and scan time. They are **device-scoped**, not itch-account-scoped and not Patreon-account-scoped.

The migration preserves these rows as device metadata. It must never attach them to whichever itch account happens to be signed in during migration. A future multi-device sync feature would need a separate explicit device identity and conflict policy; this migration does not create either.

## Conversion contract

- Source V3 remains authoritative and read-only.
- Each attempt writes to a fresh disposable V4 staging store.
- The destination Spark table must be empty before conversion.
- Every row must reference a game present in the shared catalog.
- Copy all fields: `gameID`, `runtimeSeconds`, `lastSaveAt`, `renpyVersion`, `saveCount`, `scannedAt`.
- The verifier compares every field and detects missing, extra, duplicate, or mutated rows.
- The Manifest records the domain scope as `device` and requires a successful field-by-field report before counting the domain as covered.
- V4 reference validation independently checks that every Spark row references an existing game.

## Deliberately not migrated in this slice

- `DBTranslation` is a bounded cache (maximum 1,200 entries; retention trims toward 1,000). Current call sites use only public game-description and devlog scopes. Preserve these rows field-by-field in V4 to avoid needless translation-provider requests and possible API/quota costs. Unknown scopes fail closed rather than being copied into a shared cache.
- `DBDiscoverySnapshot` is a TTL cache whose payloads are decoded through `DiscoveryCacheStore`. Expired entries are discarded on read. It is intentionally omitted from V4 staging; the manifest records its source row count and key-only inventory digest with an explicit `discardedRebuildableCache` disposition, and verifies that the destination cache remains empty.
- `DiscoveryFeedSnapshotCache` is already a separate cache file with a 30-day maximum age and stale-while-refresh behavior. It is outside the SwiftData migration and should remain so.
- `DBUpdateWatch` mixes polling validators with an enable/disable preference. Its ownership must be split or explicitly classified before migration; do not infer it belongs to the current account.

## Safety boundary

This change does not modify V3, infer account ownership, wire V4 into app startup, or promote/switch the production store. If a later converter fails after Spark has been saved, discard the entire staging store and start a new attempt from a fresh snapshot.
