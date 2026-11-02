# Spec Delta

## MODIFIED Requirements

### Requirement: Customized JSON Web API posts
Except for comments with deliverable images, the plugin SHALL post to `chat.postMessage` using JSON and a Bearer bot token. It MUST preserve composed text, attachments, username, configured icon, and event-specific icon precedence for channel and DM messages, omit `link_names`, send `unfurl_links: false` and `unfurl_media: false` so Slack shows no link previews, and treat JSON boolean `ok: true`, not the HTTP status alone, as success.

#### Scenario: Customized post succeeds
- **WHEN** a delivery job sends a composed channel or DM message without deliverable comment images and Slack returns a successful response with `ok: true`
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

### Requirement: Documented app prerequisites and gated rollout
The README SHALL document the required app scopes, Messages Tab, private-channel invitations, token setting, conversion task, background-jobs prerequisite, comment image delivery, and approval-gated live verification. Development verification MUST use stubbed HTTP and MUST NOT send live Slack messages.

#### Scenario: Operator follows the rollout documentation
- **WHEN** an operator prepares to enable the integration
- **THEN** the documented sequence is create/install the app, enable Messages Tab, invite the bot, configure the disabled integration, dry run, convert, perform a separately approved live test, then enable ordinary delivery
- **AND** it lists `files:write`, `chat:write`, `chat:write.customize`, `users:read.email`, `im:write`, and conversion-only `groups:read`, without requiring `chat:write.public`
- **AND** it states that replies can remain disabled and local/maintenance copies must retain delivery off

#### Scenario: Existing installation prepares for image delivery
- **WHEN** an operator reads the comment image instructions
- **THEN** the README states that `files:write` is required and scope changes require app reinstallation
- **AND** a short paragraph describes same-journal and inline image attachments, markup stripped only in the Slack copy, missing images skipped at delivery, and possible duplication on retry

## ADDED Requirements

### Requirement: Comment images share the rendered comment message
A comment with deliverable images SHALL use Slack external upload and combined completion with `channel_id`, uploaded file IDs, rendered text as `initial_comment`, and username/icon customization. The message SHALL contain the comment and images together, without a separate text post or link previews. Completion `ok: true` SHALL mean success. Unsupported `unfurl_*` parameters MUST NOT be sent to completion.

#### Scenario: Upload images with customized comment text
- **WHEN** a comment job has deliverable images
- **THEN** each image obtains an upload URL with form-encoded `filename` and byte `length`, then sends raw file bytes to that URL
- **AND** a combined JSON `files.completeUploadExternal` call shares all uploaded IDs in the resolved conversation with the rendered comment, username, and selected `icon_url` or `icon_emoji`
- **AND** authenticated Slack API calls use the Bearer token but the raw upload request does not carry that token
- **AND** the comment retains its issue link, quotation, and resolved mentions, with no separate `chat.postMessage` call

### Requirement: Attachment bytes are resolved only during delivery
Queued comment images SHALL be represented only by attachment IDs, not bytes, paths, URLs, or upload state. Every delivery attempt SHALL recheck those attachments and skip images that are gone, unreadable, or no longer classified as images. If none remain, delivery SHALL use the existing text post. The plugin MUST NOT impose a fixed upload count or size cap.

#### Scenario: Producer queues references without reading file content
- **WHEN** an eligible image comment is saved
- **THEN** its normal transaction-bound comment job contains deduplicated attachment IDs alongside the existing text and destination
- **AND** issue-save processing neither reads image bytes nor makes upload requests

#### Scenario: Some attachments become unavailable
- **WHEN** delivery finds both readable image attachments and attachments that were deleted, became unreadable, or are no longer images
- **THEN** only the remaining readable images are uploaded with the comment

#### Scenario: No deliverable images remain
- **WHEN** an old envelope has no image IDs or all selected attachments are unavailable at delivery
- **THEN** the existing customized `chat.postMessage` path sends the already-composed text without attempting image upload

### Requirement: Upload stages reuse existing delivery failure policy
Upload URL acquisition, raw upload, and completion SHALL use the existing rate-limit and failure classification. Every retry SHALL restart the entire upload sequence without persisted upload state. API failures MUST NOT trigger a text-only substitute. The existing "Permanent failures do not leak secrets" requirement SHALL also apply to upload requests.

#### Scenario: Rate limit at any upload stage
- **WHEN** any upload stage returns a rate limit with a usable `Retry-After`
- **THEN** the same job is rescheduled using that interval without blocking the worker
- **AND** the next execution restarts URL acquisition for all still-deliverable images

#### Scenario: API failures use the existing classification without text substitution
- **WHEN** an upload API stage fails
- **THEN** transient failures, including unusable rate-limit headers, follow the existing bounded retry policy and permanent failures drop under the existing classification
- **AND** no text-only substitute is posted

#### Scenario: Raw upload is judged by HTTP status only
- **WHEN** the raw upload endpoint responds or its transport fails
- **THEN** a successful HTTP status is accepted even with a non-JSON body, without requiring a Slack API envelope
- **AND** after existing rate-limit handling, server-error HTTP statuses and transport failures are transient and other unsuccessful HTTP statuses drop
