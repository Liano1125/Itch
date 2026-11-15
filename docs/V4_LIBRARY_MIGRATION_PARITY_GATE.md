# V4 Library Migration Parity Gate

This slice adds a validation gate between the read-only V3 migration preflight and the V4 legacy library converter.

## Gate behavior

- Rejects any V3 preflight report containing structural integrity issues.
- Compares V3 source counts against V4 converted counts for library entries, collections, collection memberships, and status-history rows.
- Fails on the first count mismatch with a domain-specific diagnostic.
- Does not inspect or include user-authored notes, calendar text, credentials, or private payloads.

## Intended call order

1. Open the authoritative V3 source read-only and ensure it is quiescent.
2. Run `V3MigrationPreflight.inspect(context:)`.
3. Convert the four personal-library model families into an empty V4 staging context using `V4LegacyLibraryConverter`.
4. Run `V4LibraryMigrationParityGate.validate(source:converted:)`.
5. Persist the resulting reports in the later durable migration manifest before any promotion is considered.

This gate does not itself create snapshots, open or promote disk stores, perform rollback/restart recovery, or switch production startup to V4.

## Tests

`V4LibraryMigrationParityGateTests` covers exact count acceptance, count mismatch rejection, and refusal of structurally invalid V3 sources.