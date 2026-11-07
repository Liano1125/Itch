# Patreon integration architecture

Status: planned foundation for itchPocket.

## Product role

Patreon is a creator identity, membership, and creator-activity provider. itch.io remains the primary source for game discovery, game pages, library records, and game metadata. Patreon data enriches the canonical creator record and may later contribute membership and creator-update information.

A user's own Patreon account connection is optional. Public creator profile resolution must continue to work for users who have not connected Patreon.

## API policy

- Use Patreon API v2 only. Public API v1 is scheduled to stop responding on October 7, 2026.
- Register a v2 OAuth client in Patreon's Clients & API Keys portal.
- Start with least-privilege scopes: `identity`. Add `identity.memberships` only when membership features are implemented and the user explicitly consents.
- Request `campaigns.posts` only for a feature that is confirmed to be accessible under the authorized campaign context. Do not assume a user's membership grants access to every creator's posts or paid content.
- Use explicit API v2 `fields` and `include` parameters. Handle null/masked profile attributes and API rate limits.

## OAuth and secret handling

Patreon's OAuth client secret must never be embedded in the iOS binary, Info.plist, GitHub repository, or user defaults.

The production flow requires a small HTTPS backend:
1. iOS requests an authorization URL from the backend.
2. Backend creates and stores a short-lived OAuth state value and redirects the user to Patreon.
3. Patreon redirects to the backend callback.
4. Backend validates state and exchanges the authorization code using the client secret.
5. Backend stores access/refresh tokens encrypted at rest and refreshes them server-side.
6. Backend returns only a short-lived, single-use app handoff code to the iOS app.
7. iOS stores non-secret connection metadata (Patreon user ID, display name, profile URL, scopes, and sync timestamps). No Patreon access or refresh token is stored in the app.

Disconnecting must revoke/delete server-side credentials where supported and clear local account metadata.

## Data model direction

- Keep `DBDeveloper` as the canonical creator identity shared by all games.
- Store provider identities as explicit links: itch.io profile URL/ID, Patreon campaign/user ID and URL, Discord URL/ID.
- Keep the user's connected Patreon account separate from public Patreon creator profiles.
- Store creator posts and membership snapshots as separate records in later milestones; do not overload `DBGameUpdate` with unrelated Patreon posts.
- Preserve source URL, provider ID, publication time, visibility/access metadata, and last-synced time for every imported item.

## Delivery milestones

### Milestone 1 — public creator identity and media
- Resolve public Patreon creator profile URLs and current profile avatars.
- Prefer the actual profile image, not the Open Graph share image.
- Support animated image data (GIF and other ImageIO-supported animated formats) based on file contents/MIME, not URL suffix.
- Use a stale-while-revalidate avatar cache and keep one canonical avatar per creator.
- Do not require the user's Patreon account to be connected.

### Milestone 2 — account connection foundation
- Add a Patreon account card under My → Accounts & Services.
- Add backend-backed OAuth connect, connection status, sync status, and disconnect.
- Display only fields returned by the granted scopes.
- Do not ship a fake connect button or a client-side secret.

### Milestone 3 — creator and membership features
- Sync the current user's profile and, with consent, memberships.
- Match supported creators to canonical `DBDeveloper` records using Patreon campaign IDs/URLs and verified profile links.
- Show membership state only when the API explicitly returns it.
- Never infer paid access from a public page or a pledge amount alone.

### Milestone 4 — creator activity
- Evaluate which creator posts are actually available to the authorized app.
- Add a dedicated creator-post store and timeline.
- Link posts to games only when the relationship is verified.
- Integrate eligible updates into the calendar without duplicating itch.io devlogs.

## Operational requirements

- Backend secrets live only in deployment environment secrets.
- Use HTTPS, OAuth state validation, short-lived one-time handoff codes, and encrypted token storage.
- Log sync outcomes without logging tokens, email addresses, or private membership details.
- Respect Patreon API rate limits and retry-after guidance.
- Treat iOS background refresh as best-effort; foreground synchronization is authoritative.
