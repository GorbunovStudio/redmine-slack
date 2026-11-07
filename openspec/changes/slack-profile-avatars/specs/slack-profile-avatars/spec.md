# Spec Delta

## Purpose

Display the explicitly associated Slack member's profile picture as a Redmine avatar fallback while preserving Gravatar priority, existing avatar presentation, and asynchronous profile retrieval.

## ADDED Requirements

### Requirement: Only explicit member associations enable Slack avatars
Slack avatar fallback SHALL apply only to persisted Redmine users whose trimmed Slack preference matches the existing `U…` or `W…` member-ID format. Empty, legacy-name, and email-only associations MUST retain existing avatar behavior without avatar-related email lookup or profile refresh.

#### Scenario: Explicit member association
- **WHEN** a persisted user's Slack preference contains a valid explicit member ID with surrounding whitespace
- **THEN** avatar fallback uses that trimmed ID as the association
- **AND** no email lookup is performed

#### Scenario: Email resolution does not expand avatar eligibility
- **WHEN** a user has an empty or legacy-name preference, including a user whose email successfully resolves for notifications
- **THEN** avatar rendering remains unchanged and does not request a Slack avatar refresh
- **AND** the stored preference is not rewritten

### Requirement: Gravatar retains priority at both image densities
With Gravatar enabled, a usable cached Slack image SHALL be supplied as the custom default for both the normal and 2x Gravatar URLs. A registered Gravatar MUST retain priority; without a usable cached Slack image, the configured Redmine default MUST remain unchanged.

#### Scenario: Cached Slack fallback is encoded consistently
- **WHEN** an explicitly associated user with a usable cached Slack image renders with Gravatar enabled
- **THEN** the image source and 2x source-set URL request the user's existing Gravatar hash with the same URL-encoded Slack default
- **AND** normal and doubled size values and existing rating behavior remain intact without forcing the default

#### Scenario: Cold or unusable cache
- **WHEN** the user's first refresh is incomplete or no usable Slack image is cached
- **THEN** the existing configured Gravatar default, including its initials behavior, is used
- **AND** rendering does not wait for Slack

### Requirement: Slack precedes initials when Gravatar is disabled
With Gravatar disabled, an eligible user's usable cached Slack picture SHALL render directly before the initials fallback. Without such a picture, existing initials or empty-output behavior MUST remain unchanged.

#### Scenario: Cached picture with Gravatar off
- **WHEN** an eligible user with a usable cached picture renders with Gravatar disabled
- **THEN** the avatar uses the cached HTTPS image URL directly without a Gravatar request

#### Scenario: No cached picture with Gravatar off
- **WHEN** an eligible user without a usable cached picture renders with Gravatar disabled
- **THEN** the user's existing initials avatar remains visible while refresh is pending

### Requirement: Non-user avatars and presentation remain compatible
Anonymous, group, string-email, and unsaved-user avatar behavior SHALL remain unchanged. Slack avatar fallback MUST preserve caller sizing, classes, title and alt semantics, the standard avatar class, and the existing additionals size-box behavior without modifying core or additionals.

#### Scenario: Existing special avatar paths
- **WHEN** an anonymous user, group, string-email input, or unsaved user renders with Gravatar enabled or disabled
- **THEN** it follows the existing path with no Slack refresh or image substitution

#### Scenario: Sized avatar with caller attributes
- **WHEN** an eligible user renders a cached fallback with a custom size, class, title, or alt value
- **THEN** those attributes retain their meaning without duplicate standard classes
- **AND** Gravatar images retain additionals' size class and direct Slack images retain an equivalent size box

### Requirement: Cached image URLs obey the fallback provider contract
Only profile image URLs compatible with the documented Gravatar custom-default contract SHALL be cached as usable fallbacks: public HTTPS on port 443, recognizable image extension, and no query string. Non-URL, credential-bearing, fragment-bearing, or otherwise incompatible candidates MUST NOT replace existing defaults. The application MUST NOT download or proxy image bytes.

#### Scenario: Profile offers multiple image candidates
- **WHEN** a successful profile response contains numeric-size image fields, including incompatible candidates
- **THEN** the largest compatible numeric-size image URL is selected without rewriting its path or stripping query parameters to manufacture compatibility
- **AND** no custom-image-upload flag is required

#### Scenario: No compatible candidate remains
- **WHEN** a successful profile response contains no usable image URL
- **THEN** the cached picture is cleared for that association and existing defaults apply
- **AND** no image fetch or immediate repeated profile refresh is attempted

### Requirement: Avatar state persists across application processes
Avatar image URLs, their associated member ID, and refresh bookkeeping SHALL use existing persisted user preferences rather than a per-process cache. A successful refresh MUST be visible to a newly loaded user in another application process; stale images for the same association MUST remain usable while refreshing or after API failure.

#### Scenario: Worker refresh is visible to the web process
- **WHEN** a background refresh saves a usable profile image and another user instance loads the preferences
- **THEN** it can render that image without relying on worker-local memory or filesystem cache

#### Scenario: Stale cached image remains during an API outage
- **WHEN** an eligible user's cached image is stale and refresh is pending, retrying, or has failed
- **THEN** rendering retains that association's cached image without waiting for the API

### Requirement: Refreshes are asynchronous and deduplicated
Eligible avatar rendering SHALL request a background refresh only when due and a bot token is configured. Concurrent renders MUST produce only one outstanding refresh for the same association, including during delayed retries. Normal refresh eligibility SHALL use the existing 24-hour identity-cache interval. Page rendering MUST NOT call Slack or probe Gravatar.

#### Scenario: First render and repeated render
- **WHEN** multiple renderers encounter the same uncached explicit association
- **THEN** one refresh is persisted to the existing Slack queue and all renderers use the existing default
- **AND** no profile API call is made during rendering

#### Scenario: Fresh cache and later expiry
- **WHEN** the cache is within 24 hours of a completed refresh
- **THEN** rendering does not enqueue another refresh
- **AND** after that interval, a later render permits one new refresh

#### Scenario: Outstanding work is delayed beyond freshness
- **WHEN** an existing refresh remains queued, executing, or waiting for an API-directed retry after its normal refresh interval
- **THEN** new renders do not enqueue a competing refresh for that association

#### Scenario: Enqueue fails or its transaction rolls back
- **WHEN** creating a refresh job fails or its containing transaction rolls back
- **THEN** no orphaned pending-refresh claim suppresses the next otherwise eligible render

### Requirement: Refresh uses the existing safe Slack API and retry policy
Background refresh SHALL read the current server-side token and request only the explicit member's profile. It MUST reuse existing transient retries and API-directed rate-limit waits. Permanent failures and exhausted retries MUST retain same-association cached images and suppress render-triggered reattempts for 24 hours after failure, using the same interval as freshness.

#### Scenario: Successful profile fetch
- **WHEN** an eligible refresh executes with a configured token
- **THEN** it calls `users.info` for the explicit member and persists the selected URL or absence of a usable picture
- **AND** it performs no email lookup, DM opening, notification post, or import operation

#### Scenario: Rate limited or transiently unavailable
- **WHEN** the profile API returns a rate limit or transient failure
- **THEN** valid `Retry-After` determines the reschedule, while absent or invalid headers and other transient failures follow the existing bounded retry defaults
- **AND** later page renders do not bypass the pending retry

#### Scenario: Missing scope or exhausted retries
- **WHEN** a profile request fails permanently, including `missing_scope`, or exhausts transient retries
- **THEN** diagnostics expose only the existing safe error classification and no immediate render-triggered refresh is queued
- **AND** a render after the 24-hour failure interval can request another refresh

### Requirement: Tokens and delivery controls retain their boundaries
Tokens MUST NOT enter avatar HTML, image URLs, cached avatar metadata, job arguments, or logs. Missing tokens MUST prevent profile requests. Avatar profile reads SHALL be independent of notification-delivery and event-import enablement, and MUST NOT change those settings or send Slack messages.

#### Scenario: Delivery and import remain disabled
- **WHEN** an avatar refresh executes with a configured token while delivery and import are disabled
- **THEN** only the profile-read operation is permitted and both switches remain disabled

#### Scenario: Token disappears before execution
- **WHEN** the token is absent at initial execution or retry
- **THEN** no Slack request is made and existing avatar defaults or the usable same-association cached image remain available

### Requirement: Association changes cannot expose another member's cached picture
Cached images and refresh results MUST be bound to the explicit association. Changing or clearing it SHALL immediately make the previous association's picture ineligible. Work queued or completed for an obsolete association MUST NOT restore its image or overwrite newer refresh state.

#### Scenario: Member changes before rendering or execution
- **WHEN** a user's explicit association changes from member A to member B or is cleared
- **THEN** subsequent avatar rendering ignores A's cached image even with a previously loaded user instance
- **AND** A's queued refresh cannot populate the current cache

#### Scenario: Association changes while Slack responds
- **WHEN** a refresh for member A is in flight and the association or current refresh changes before its result is saved
- **THEN** the obsolete result and its completion bookkeeping are discarded
- **AND** B's eligible refresh is not delayed by A's old cache state

### Requirement: Avatar writes preserve preference semantics and unrelated values
Avatar refresh and association writes SHALL merge their own keys into freshly loaded preferences under database serialization, preserving unrelated settings and legacy values. The existing Slack preference getter MUST remain read-only; failed account or administrator saves MUST NOT persist a new association or invalidate its avatar cache.

#### Scenario: Another preference changes before the worker writes
- **WHEN** another request saves an unrelated preference after the refresh loaded the user but before completion
- **THEN** saving the avatar result preserves that newer unrelated preference and current Slack association

#### Scenario: Successful and failed account saves
- **WHEN** an account or administrator successfully saves a changed Slack preference
- **THEN** it retains existing trimming and invalidates only avatar state tied to the previous association
- **AND** submitting the same trimmed member ID retains its avatar cache
- **AND** a failed user update or plain preference read leaves persisted association and avatar state unchanged

### Requirement: Provider prerequisites and validation limits are explicit
Documentation SHALL state that avatar refresh needs `users:read` and app reinstallation after scope changes, without requiring notification/import enablement. It MUST distinguish deterministic URL/HTML tests from live confirmation of public image access, Gravatar fallback acceptance, and registered-Gravatar priority for real accounts.

#### Scenario: Review or rollout evidence describes validation honestly
- **WHEN** the feature is documented and its test results are reported
- **THEN** stubbed profile and HTML assertions are not presented as proof that a real Slack image is public or accepted by Gravatar
- **AND** separately approved live validation covers both Gravatar-present and Gravatar-absent accounts and high-density rendering without sending messages
