# Proposal

## Why

Redmine currently falls back to its configured Gravatar default or initials even when a user has explicitly associated a Slack member whose profile picture is available. Add that picture as a fallback without replacing a registered Gravatar or performing Slack requests while rendering pages.

## What Changes

- For persisted Redmine users with an explicit `U…` or `W…` Slack preference, use a cached, usable Slack profile image as Gravatar's custom default; when Gravatar is disabled, use it before initials.
- Fetch profile metadata asynchronously on demand through the existing Slack client and `slack` queue. Persist the image URL and refresh bookkeeping in existing user preferences, with deduplicated refreshes and the existing retry handling.
- Reuse the existing `24.hours` identity-cache interval for avatar refresh eligibility and failure suppression, rather than introduce another tuning value.
- Reject cache results for a changed association, preserve unrelated preference values, and keep core avatar attributes and additionals sizing compatibility.
- Document `users:read`, public-image restrictions, and what stubbed tests can establish versus later, separately approved live validation.
- Do not add email-based avatar association, tables, migrations, schedules, settings switches, dependencies, image downloads, or notification/import changes.

## Capabilities

### New Capabilities

- `slack-profile-avatars`: Explicit-member avatar fallback, persisted profile-image caching, and asynchronous refresh through the existing job infrastructure.

### Modified Capabilities

None. Existing `slack-user-addressing` continues to resolve email fallback for mentions and DMs, not avatars; its read-only preference getter and form-save semantics remain intact. `slack-app-delivery` continues to govern notifications, not the separate read-only profile fetch.

## Impact

- Plugin-local avatar helper patch registered through the existing reload-safe `init.rb` pattern; Redmine core and additionals remain unmodified.
- Existing preference adapter plus a small avatar-cache service and a new profile-refresh ActiveJob; existing `Client#user_info` needs no new endpoint or transport.
- Existing `UserPreference#others` and GoodJob persistence only; no deployment migration or new queue/thread allocation.
- Deterministic helper, preference, enqueue/retry, concurrency, and reload tests; README prerequisites and live-validation caveats. The bot token remains server-side and delivery/import remain unchanged.
