# V4 account calendar notification projection

## Scope

This slice adds a V4-only notification projection coordinator. It does not connect the coordinator to the V3 `GameCalendarStore`, app startup, or account-switch UI. V4 calendar persistence is still not the production runtime source.

## Ownership and identifiers

- Every notification identifier is namespaced by the canonical itch account ID and calendar event ID.
- The device notification center is treated as a rebuildable projection, never as the source of calendar data.
- Account IDs must be canonical `itch:<positive-user-id>`; Patreon IDs and display names are rejected.
- Only identifiers beginning with `itchPocket.calendar.v4.` are eligible for cleanup. Other app notifications and notifications from other apps are untouched.

## Rebuild behavior

- On account switch, pending and delivered notifications for the previous account are removed.
- When the previous account is unknown (such as cold-launch restore after an interrupted sign-out), the whole app-owned V4 namespace is cleared before rebuilding the active account.
- Existing notifications for the destination account are removed before rebuilding, making the projection idempotent.
- Sign-out removes all notifications in the V4 calendar namespace.
- Only enabled reminders with a future fire date are scheduled.
- Authorization is checked before scheduling; denied or declined authorization produces no notification requests.
- A caller-provided session validator and an internal operation generation reject stale work after awaits, including notification-add completion.
- Each rebuild uses a generation-specific notification identifier; a stale completion can remove its own request without deleting a newer rebuild's replacement.

## Validation status

The coordinator is covered by the dedicated XCTest target. CI must pass on the latest PR head before this slice is considered validated.

## Integration boundary

The caller must capture `ItchSessionOperationContext` from `ItchAccountSession`, pass the previous and current canonical itch account IDs, obtain events from `AccountScopedCalendarRepository.resolvedEvents()`, and provide an `isCurrent` closure that validates the captured context. The coordinator is deliberately not wired into V3 until the V4 migration/cutover is independently validated.
