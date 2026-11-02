# Spec Delta

## Purpose

Receive authenticated Slack events promptly and apply the configured inbound integration policy without doing Slack or issue work in the webhook request.

Sources: [approved requirements](/home/andre/projects/redmine/tickets/slack-comment-import/requirements.md), ingress/configuration and message-selection decisions; [numeric provenance](../../design.md#sources-and-numeric-provenance).

## ADDED Requirements

### Requirement: Verify the raw Slack request
The HTTP event endpoint SHALL verify Slack's `v0=` HMAC-SHA256 signature over `v0:<timestamp>:<raw body>` with `signing_secret`, using constant-time comparison, and reject missing/invalid signatures or timestamps more than five minutes from local time. The replay window comes from [Slack request verification](https://docs.slack.dev/authentication/verifying-requests-from-slack).

#### Scenario: Authentic request reaches processing
- **WHEN** Slack sends a correctly signed request with an acceptable timestamp
- **THEN** its unchanged raw body is the signature input and the verified payload can be processed without a Redmine login or CSRF token

#### Scenario: Invalid or replayed request
- **WHEN** the secret or verification headers are missing, the signature does not match, or the timestamp is outside the replay window in either direction
- **THEN** the request is rejected and no event job is enqueued

### Requirement: Challenge response and asynchronous acknowledgement
The endpoint SHALL answer verified `url_verification` with its `challenge`; for each verified `event_callback` it SHALL enqueue a single event job and return HTTP 200 without Slack API calls or issue processing. This keeps acknowledgement within Slack's three-second response requirement ([Events API](https://docs.slack.dev/apis/events-api), Responding to events).

#### Scenario: Slack verifies the request URL
- **WHEN** a verified `url_verification` arrives while import is disabled
- **THEN** the response contains the challenge and no event job is enqueued

#### Scenario: Callback is handed off immediately
- **WHEN** a verified `event_callback` arrives
- **THEN** the endpoint enqueues its event without resolving users, fetching a parent, downloading files, reading issues, or posting previews
- **AND** the successful acknowledgement does not wait for the job to execute

#### Scenario: Slack retries a callback
- **WHEN** Slack repeats a verified callback
- **THEN** it is enqueued again without an event-ID store
- **AND** repeated previews are accepted while imported-comment deduplication follows the message-link contract

### Requirement: Inbound settings preserve secret semantics
The plugin SHALL add `signing_secret`, `import_enabled` defaulting off, and `import_user_id` selected from active Redmine users. The signing-secret input MUST always render empty with Configured / Not configured status, preserve its stored value on blank/omitted submission, replace it on nonblank submission, and be filtered from request logs.

#### Scenario: Save and display the secret
- **WHEN** an administrator configures or replaces the signing secret and then views the settings
- **THEN** the value is saved but absent from response HTML and unfiltered parameters, and the empty control displays Configured
- **AND** an installation without the secret displays Not configured

#### Scenario: Save unrelated configuration
- **GIVEN** a signing secret and bot token are stored
- **WHEN** an administrator submits settings with either secret blank or omitted
- **THEN** the stored secrets are preserved and the import switch and active-user selection save normally
- **AND** the existing outbound delivery and post-updates controls keep their semantics

### Requirement: Recheck import configuration during execution
Every event-job execution and retry SHALL read current settings before resolution, Slack API calls, or issue changes. If import is disabled, the signing secret or bot token is absent, or the selected import user is missing/inactive, it MUST discard the event; enabling import later MUST NOT revive discarded work. Inbound processing uses `import_enabled`, independently of the outbound delivery switch.

#### Scenario: Disable or remove configuration after enqueueing
- **WHEN** an event job starts after import is disabled or required configuration becomes unavailable
- **THEN** it completes without previews, identity/history lookups, downloads, or Redmine writes

#### Scenario: Import runs with outbound delivery disabled
- **WHEN** import is fully configured and enabled but ordinary outbound delivery is disabled
- **THEN** eligible inbound events are still processed
- **AND** ordinary Redmine notification delivery remains disabled

### Requirement: Restrict eligible conversations and messages
The integration SHALL process only private-channel and app-DM message events: new messages with no subtype, `file_share`, or `thread_broadcast`, `message_changed`, and `message_deleted`. It MUST ignore bot-originated messages (`bot_id` or `bot_message`), including nested message data for change/delete events, and every other subtype; public channels, group DMs, and person-to-person DMs are excluded.

#### Scenario: Human posts text or files
- **WHEN** a human posts an eligible new message, `file_share`, or `thread_broadcast` in a private channel containing the bot or in the app's DM
- **THEN** it can produce previews and a routed import, including a message whose only content is files

#### Scenario: Bot, unsupported subtype, or excluded conversation
- **WHEN** a message is bot-originated, has an unsupported subtype, or belongs to an excluded conversation
- **THEN** no preview or comment operation is performed

### Requirement: Reuse queue and safe failure behavior
Inbound work SHALL use the existing `slack` queue, bot client, sanitized error classification, and retry/rate-limit handling without a new service, queue, or gem. Event job arguments MUST NOT be logged; diagnostics MUST NOT disclose credentials, raw responses, headers, emails, or message content. Individual file failures follow the file-import requirement instead of cancelling the comment.

#### Scenario: Lookup or preview is rate limited or transiently fails
- **WHEN** a job's Slack API call encounters a classified rate limit or transient error
- **THEN** the existing nonblocking retry policy applies and a retry rechecks import settings
- **AND** permanent API failures stop with only a safe classification
