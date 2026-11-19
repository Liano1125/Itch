# V4 Update-Watch Runtime Guardrails

## Async request ownership

`AccountUpdateWatchRuntimeCoordinator` captures `ItchAccountRequestContext` before awaiting the fetch closure. It verifies both canonical account identity and session generation immediately after the await, before any repository write. A stale response is discarded without persistence or notification.

## Notification namespace

V4 UpdateWatch notifications use `itchPocket.update.v4.<encoded-account>.game.<encoded-game>` plus an operation generation suffix. The coordinator validates the session before authorization and after notification add. If the session changes while add is suspended, it removes only that generation-specific stale request. Account cleanup removes only the selected account namespace; passing nil clears the V4 UpdateWatch namespace.

## Boundaries

- This coordinator is V4-only and is not wired into the production V3 GameUpdateMonitorStore.
- V3 notification identifiers remain unchanged until a separately reviewed cutover.
- The V4 runtime accepts an injected fetch closure; it does not reuse authenticated Patreon cookies or claim that URLSession.shared is account-independent.
- The repository still requires an explicit account-scoped V4 ModelContext.
