# V4 Update-Watch Account Scope

## V4 model boundary

- `DBAccountUpdateWatch` is keyed by the canonical pair `(accountID, gameID)`.
- The enable/disable preference and all HTTP validators remain account-scoped. The current V3 monitor uses `URLSession.shared`; cookie/session independence has not been demonstrated.
- `AccountScopedUpdateWatchRepository` requires an explicit canonical `itch:<positive-user-id>` and a V4 `ModelContext` for every operation.
- The repository is not wired into V3 startup or `GameUpdateMonitorStore`.

## Legacy handling

- V3 `DBUpdateWatch` has no account owner. No owner is inferred from the active login, library membership, or game URL.
- `quarantineLegacyRows()` copies every field into `DBLegacyUpdateWatch`, preserving the V3 source row. The copy is idempotent and marks broken game references without dropping the record.
- The quarantine model has no account ID. A later explicit user claim/import flow must record provenance and be independently idempotent.

## Remaining safety work

This slice does not add request-session generation checks, account-namespaced local notifications, a dedicated cookie-free HTTP client, migration coordinator integration, production startup wiring, or cutover. The migration manifest must continue blocking non-empty update-watch ownership rows until quarantine conversion and field-by-field verification are integrated into the staging pipeline.
