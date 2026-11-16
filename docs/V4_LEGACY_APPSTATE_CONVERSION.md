# V3 → V4 AppState Scope Conversion

Status: isolated conversion slice. This code does not switch production persistence, rewrite V3 rows, or infer historical account ownership.

## Scope classification

The converter reads V3 `DBAppState` rows and writes V4 `DBScopedAppState` rows:

- Established `device` keys go to the V4 device scope.
- Established `appGlobal` keys go to the V4 app-global scope.
- Account-scoped, unknown, and provisional classifications go to the V4 `legacy-unclassified` scope until independently reviewed.

Even when a key's semantic family is known to be account-scoped, the V3 row does not identify which historical account owns it. The active itch session and Patreon identity are not used as migration inputs.

## Safety properties

- Requires clean source and destination contexts.
- Requires an empty V4 scoped-AppState table; no merge into partially migrated data.
- Copies string, date, data, and updatedAt values without mutating V3.
- Sorts rows by key and returns a SHA-256 inventory digest over keys only; payload values are excluded.
- Does not promote provisional registry classifications automatically, even when their proposed scope is device or app-global.
- Rolls back destination pending inserts if saving fails.

## Deferred

This does not resolve ownership of account-scoped keys, convert other V3 model families, create a durable migration manifest, copy SQLite stores, promote a staging store, or change app startup. Device/app-global classification follows the current source-reviewed registry and should remain subject to the migration manifest's registry-version check.

## Tests

`V4LegacyAppStateConverterTests` verifies known device/app-global placement, quarantine of account/unknown/provisional keys, exact payload preservation, V3 source immutability, and staging preconditions.