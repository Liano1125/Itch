# V4 Update-Watch Ownership Audit

Status: audit/design only. This document does not change the V3 schema, V4 schema, production repositories, startup path, notifications, or user data.

Audit baseline: `feat/v4-library-migration-parity-gate` at `dc58c2ef619b3e2eaf74b3a83ea544781a334b7f`.

## 1. Executive decision

Do not migrate `DBUpdateWatch` directly into a single V4 account-scoped table yet.

The V3 row combines two different kinds of state:

1. User intent: whether this account wants to monitor a game (`isEnabled`).
2. HTTP polling state: ETag, Last-Modified, body hash, last-check time, and whether a baseline has been established.

Those have different ownership and sharing rules. The V3 model has no account ID, so the user intent cannot be assigned to the currently signed-in itch account. The HTTP metadata may be shareable for public game pages, but the current request path has not proved that its responses are independent of cookies or account state.

Keep production on V3 until the split, migration policy, notification ownership, and account-scoped AppState are implemented and tested together.

## 2. V3 model and write/read behavior

Current model: `DBUpdateWatch` in `Sources/Services/DatabaseModels.swift`.

| Field | Current meaning | V4 ownership assessment |
|---|---|---|
| `gameID` | Unique row key and game reference | Natural key for shared poll state; also part of an account-watch composite key |
| `isEnabled` | User opt-in used to select monitored games | Account preference; V3 ownership is unknown |
| `entityTag` | HTTP ETag validator | Candidate shared poll metadata, pending request privacy audit |
| `lastModified` | HTTP Last-Modified validator | Candidate shared poll metadata, pending request privacy audit |
| `contentHash` | Hash of normalized response body | Candidate shared poll metadata, pending request privacy audit |
| `lastCheckedAt` | Last successful check timestamp | Candidate shared poll metadata, pending request privacy audit |
| `hasBaseline` | Whether initial response baseline exists | Candidate shared poll metadata, pending request privacy audit |

The current `UpdateMonitorRepository` and `GameUpdateMonitorRepository` read and write the whole table by game ID. The store is a singleton and its watch dictionary is keyed only by game ID. Disabling a watch deletes the row; the persisted `isEnabled` field is still read and used when selecting targets.

The V3 preflight already counts update-watch rows and flags missing game references, but the V4 legacy library converter and parity gate currently cover only library entries, collections, collection memberships, and status-history rows. Update watches remain outside the converter/parity gate.

## 3. Request privacy and whether polling metadata is shared

The current monitor check uses `URLSession.shared.data(for:)` against the game URL with an HTML Accept header. The code does not explicitly attach a cookie header in this method, but `URLSession.shared` can use the shared cookie storage. Therefore, do not assume the response validators or body hash are globally reusable until request cookie behavior and the actual response scope are verified.

The separate historical Devlog sync path explicitly reads itch.io cookies from `WKWebsiteDataStore.default().httpCookieStore` and attaches them to RSS requests. It also writes summary/results to globally keyed AppState entries:

- `devlogSync.lastDate`
- `devlogSync.lastMessage`
- `devlogSync.lastResults`

These historical-sync keys describe work performed for a user's library and should be treated as itch-account-scoped state in V4, not device-global state. The explicit cookie use is also a reminder that public-looking game content paths may have age-gate or account-dependent responses.

Before promoting HTTP metadata to a shared V4 poll-state model, verify:
- whether the monitor request sends cookies through shared URLSession storage;
- whether requests ever carry account-specific headers or credentials;
- whether age-gated/private pages can produce account-dependent response bodies;
- whether redirects and canonical game URLs are stable across accounts;
- whether a response hash can safely be shared without leaking personalized content.

If any of these cannot be proven, retain the metadata in a legacy/unassigned migration record until a safe rebuild policy is defined. Never copy uncertain account-derived validators into shared state.

## 4. Proposed V4 separation (names are provisional)

### Account preference

A future account-owned record, provisionally `DBAccountUpdateWatch`:

- `accountID`
- `gameID`
- `isEnabled`
- stable composite identity based on account ID + game ID

All reads and writes must require an explicit canonical itch account ID. Two accounts must be able to independently enable or disable monitoring for the same game.

### Shared polling metadata

A future shared record, provisionally `DBGameUpdatePollState`:

- `gameID`
- `entityTag`
- `lastModified`
- `contentHash`
- `lastCheckedAt`
- `hasBaseline`

Create/populate this shared record only after the request privacy audit proves the fetched representation is account-independent. Otherwise use an explicitly unassigned/quarantined representation or rebuild the baseline after a clean public request.

Do not put account preference fields in the shared poll record, and do not duplicate public poll metadata once per account.

## 5. V3 migration policy

- Every V3 `DBUpdateWatch` row has unknown account ownership unless an independent durable mapping is found and validated against the numeric itch user ID.
- Preserve the user-intent portion (`isEnabled`) as legacy/unassigned. Do not assign it to the currently logged-in account.
- Preserve the HTTP metadata in the migration inventory, but do not promote it to shared poll state until the privacy audit in section 3 passes.
- Preserve source game ID and all original validator/baseline fields for traceability.
- Reject missing-game references, duplicate identities, or conflicting converted state before staging writes.
- A future explicit claim/import flow may let a user claim unassigned watch preferences; that is outside this migration slice.

## 6. Notifications and account switching

The current update-monitor notification identifier is based on game ID alone. V4 notification identity must include the account scope (or use a dedicated account-owned namespace) so one account cannot remove, replace, or receive another account's watch notification.

Account switch/sign-out must:
- invalidate in-flight checks using account ID + session generation;
- prevent stale results from committing watch preferences or polling state;
- remove only the departing account's pending/delivered notifications;
- preserve unrelated notifications and shared public poll metadata;
- rebuild the destination account's notification projection from its own watch preferences.

The existing V4 calendar notification coordinator is a useful lifecycle pattern, but update-monitor notifications require their own IDs and tests.

## 7. Required tests before implementation/cutover

1. Two accounts can independently enable/disable the same game.
2. Account A's watch list is never visible in account B's repository/store.
3. Legacy V3 `isEnabled` is unassigned when no ownership proof exists.
4. Shared poll metadata is copied only when a testable public-request policy permits it.
5. Cookie-dependent or otherwise personalized responses never enter shared poll state.
6. Duplicate/missing game references abort conversion before staging writes.
7. Account A's delayed check cannot commit after switching to B or signing out.
8. Notification identifiers and cleanup are account-scoped and preserve unrelated notifications.
9. Historical Devlog sync AppState keys are scoped to the itch account, and stale async results cannot overwrite another account's summary.
10. Repeated migration is deterministic and does not duplicate rows.

## 8. Scope boundary

This PR is documentation/audit only. It intentionally does not:
- add V4 update-watch models;
- alter V3 `DBUpdateWatch`;
- change the current singleton store or repositories;
- change notification behavior;
- migrate historical Devlog AppState;
- wire V4 into production startup;
- create snapshots, promote stores, or perform rollback.

Implementation should be a later isolated PR after the remaining ownership and request-privacy questions are resolved.
