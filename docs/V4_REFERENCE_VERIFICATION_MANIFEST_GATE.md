# V4 Reference Verification Manifest Gate

The V4 migration coordinator now runs `V4StoreReferenceVerifier` against the clean staging context after the field-by-field payload verifier and before building the migration manifest.

The report is embedded in the manifest using stable diagnostic codes only. It contains the number of checks and diagnostics, never account identifiers, notes, tokens, or user-authored values.

The manifest promotion predicate requires a present, valid reference-verification report. Missing reports add `migration.references.notRun`; invalid reports add their stable diagnostics and block eligibility. Older serialized manifests without this optional field still decode, but fail closed because the report is absent.

This is an integration gate only. It does not mean all V3 domains have been migrated, nor does it authorize production cutover. Domain coverage, backup, SQLite integrity, read-only reopen, crash recovery, atomic promotion, restart validation, and rollback remain separate gates.
