# slack-app-delivery Specification

## Purpose

Deliver the existing Redmine notifications through a safely configured Slack app without network calls during issue saves, and expose predictable cancellation and failure behaviour.

## Requirements

### Requirement: Bot token secret setting
The plugin SHALL replace the Slack URL control with an always-empty bot-token secret control and a Configured / Not configured indicator. Blank or omitted submissions MUST preserve the stored token, nonblank submissions MUST replace it, and the token parameter MUST be filtered from logs.

#### Scenario: Save unrelated settings without losing the secret
- **GIVEN** a token is configured
- **WHEN** an administrator saves settings with the token input blank or omitted
- **THEN** the same token remains stored and the input renders empty with Configured status
- **AND** the saved delivery and post-updates controls retain their independent semantics

#### Scenario: Configure or replace a token
- **WHEN** an administrator submits a nonblank bot token
- **THEN** it replaces the stored token without appearing in response HTML or unfiltered request logs
- **AND** an installation without a token displays Not configured with an empty input

### Requirement: Customized JSON Web API posts
The plugin SHALL post to `chat.postMessage` using JSON and a Bearer bot token. It MUST preserve composed text, attachments, username, configured icon, and event-specific icon precedence for channel and DM messages, omit `link_names`, send `unfurl_links: false` and `unfurl_media: false` so Slack shows no link previews, and treat JSON boolean `ok: true`, not the HTTP status alone, as success.

#### Scenario: Customized post succeeds
- **WHEN** a delivery job sends a composed channel or DM message and Slack returns a successful response with `ok: true`
- **THEN** the destination is its conversation ID and attachments are a JSON array, not a webhook form payload
- **AND** username and icon customization are retained, with the event emoji overriding the configured icon as before
- **AND** the token occurs only in the Authorization header, never job arguments or URLs
- **AND** the request sets `unfurl_links` and `unfurl_media` to `false`, so no link preview is shown

#### Scenario: Successful HTTP status contains a Slack rejection
- **WHEN** Slack returns a successful HTTP status with `ok: false` and `invalid_auth`
- **THEN** the message is rejected and logged by code rather than counted as delivered

#### Scenario: Legacy endpoint cannot be used as a fallback
- **WHEN** a legacy webhook setting or project Slack URL remains stored but the token is absent
- **THEN** no webhook or Slack API request is made and no new delivery job is queued

### Requirement: Edit message persistence uses the existing transaction
Each composed notification SHALL have its own background job. Edit notifications MUST enqueue within the existing edit transaction so rollback discards its jobs. The producer MUST NOT perform Slack HTTP or defer enqueueing to an after-commit callback.

#### Scenario: Committed edit makes messages available without producer HTTP
- **WHEN** an issue edit commits with eligible notifications
- **THEN** each composed message has its own persisted job
- **AND** no Slack HTTP request was made by the producer

#### Scenario: Rollback discards pending edit messages
- **WHEN** the existing issue-edit transaction containing eligible notifications rolls back
- **THEN** none of that transaction's Slack delivery jobs survives or can contact Slack

#### Scenario: Failed save produces no notification job
- **WHEN** an issue save fails validation
- **THEN** no Slack notification job is created for the rejected change

### Requirement: Dedicated queue dependency
The plugin SHALL require `00_gorbunovstudio_background_jobs` version `1.1.0` or later and register its `slack` queue through the supplied dedicated-queue hook with exactly one thread. Ordinary messages MUST retain FIFO delivery; a retry-delayed message can be overtaken as accepted by operator decision 19. [Sources](../../design.md#sources-and-numeric-provenance).

#### Scenario: Required hook is available
- **WHEN** the plugin initializes with the required background-jobs release
- **THEN** it registers the dedicated Slack queue through that plugin's hook and every Slack delivery job uses that queue
- **AND** it does not configure the shared scheduler's internal queue layout or increase its thread budget

#### Scenario: Dependency is too old
- **WHEN** the required background-jobs plugin is absent or below the declared version
- **THEN** the normal plugin dependency check rejects initialization instead of silently sharing the general queue

### Requirement: Delivery can cancel queued work
The existing Enable Slack delivery switch SHALL default to off, including when absent. The producer MUST not enqueue while it is off, and every job execution MUST read the current switch before resolution or HTTP and drop work when off without affecting issue-save side effects.

#### Scenario: Disable before execution or retry
- **GIVEN** a message was queued while delivery was enabled
- **WHEN** its initial execution or a retry starts after delivery is disabled
- **THEN** it completes without identity lookups, DM opening, or posting
- **AND** later re-enabling delivery does not resurrect that discarded message

### Requirement: Rate limits use Slack's wait
HTTP 429 and Slack `ratelimited` responses SHALL reschedule delivery after the response's `Retry-After` interval without blocking the worker. A missing or unusable header MUST use the transient retry policy rather than an invented cooldown. This policy applies during lookup, DM opening, and posting.

#### Scenario: Rate limit supplies a retry interval
- **WHEN** a delivery-time method returns HTTP 429 or `ratelimited` with a valid `Retry-After`
- **THEN** the same message is scheduled after that interval on the Slack queue
- **AND** the worker can handle other messages during the wait

#### Scenario: Rate-limit header is unusable
- **WHEN** the response indicates rate limiting without a usable `Retry-After`
- **THEN** the message follows the transient retry policy without fabricating a Slack-specific wait

### Requirement: Transient failures have bounded retries
Network errors, timeouts, HTTP 5xx, `internal_error`, and `service_unavailable` SHALL use Rails' default retry policy: five total transient attempts, three seconds apart. [Sources](../../design.md#sources-and-numeric-provenance).

#### Scenario: A temporary failure recovers
- **WHEN** a lookup, DM open, or post fails transiently and a later permitted attempt succeeds
- **THEN** the job retries under the default policy and completes on success

#### Scenario: Transient attempts are exhausted
- **WHEN** transient failures exhaust the default retry policy
- **THEN** the message is dropped with a safe classification and no additional retry is scheduled

#### Scenario: Accepted request times out
- **WHEN** a post is accepted by Slack but the client times out before receiving success
- **THEN** the timeout follows the same retry policy even if the later attempt duplicates the post

### Requirement: Permanent failures do not leak secrets
Any response outside success, rate limits, transient failures, and the defined identity miss SHALL be dropped and logged by sanitized error code or HTTP status only. No log or raised transport error MUST contain the token, raw response, headers, email, or message content; job arguments MUST NOT be logged.

#### Scenario: Known permanent Slack rejection
- **WHEN** Slack returns `invalid_auth`, `missing_scope`, `channel_not_found`, `not_in_channel`, `is_archived`, or `messages_tab_disabled`
- **THEN** delivery stops without retry and logs only its sanitized error code

#### Scenario: An unlisted error is still permanent
- **WHEN** Slack returns another `ok: false` error outside the explicit retry and identity-miss classes
- **THEN** the message is dropped without retry and without logging raw response content

#### Scenario: Transport exception contains sensitive text
- **WHEN** a network exception contains headers, token-like content, or an email in its message
- **THEN** retry/drop diagnostics expose only a safe local classification, not that exception message

### Requirement: Documented app prerequisites and gated rollout
The README SHALL document the required app scopes, Messages Tab, private-channel invitations, token setting, conversion task, background-jobs prerequisite, and approval-gated live verification. Development verification MUST use stubbed HTTP and MUST NOT send live Slack messages.

#### Scenario: Operator follows the rollout documentation
- **WHEN** an operator prepares to enable the integration
- **THEN** the documented sequence is create/install the app, enable Messages Tab, invite the bot, configure the disabled integration, dry run, convert, perform a separately approved live test, then enable ordinary delivery
- **AND** it lists `chat:write`, `chat:write.customize`, `users:read.email`, `im:write`, and conversion-only `groups:read`, without requiring `chat:write.public`
- **AND** it states that replies can remain disabled and local/maintenance copies must retain delivery off
