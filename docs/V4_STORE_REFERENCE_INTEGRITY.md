# V4 Store Reference Integrity

The read-only V4 reference verifier is a staging safety gate. It does not mutate records, repair relationships, claim legacy ownership, or promote a store.

It validates:
- itch account identity using numeric user ID and deterministic account ID;
- account ownership and stable identities for library entries, collections, memberships, and status events;
- membership references to a collection in the same account scope and to an existing shared game;
- scoped AppState stable identity;
- shared calendar source event identity and optional source-update references;
- account calendar event ownership/game references and account overlay references to an existing source event;
- deterministic identity of quarantined legacy calendar rows.

A nil account ID is accepted only on the explicitly legacy-capable library models. Account calendar events and overlays must reference an existing account. Diagnostics are stable codes and never include account IDs, notes, or user content.

The verifier refuses contexts with pending changes. Callers must open a clean, independently validated V4 staging context and keep the migration owner lock held for the full pipeline. This gate complements SQLite integrity checks and V3-to-V4 field parity; it does not replace either.
