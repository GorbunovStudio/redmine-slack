# Spec Delta

## Purpose

Associate Slack discussions with Redmine issues after issue creation, allowing authorized people and API clients to import existing discussion and route future replies without editing the source message.

Product decision meanings and the distinction between explicit operator decisions and implementation-request baseline choices are recorded in [design sources](../../design.md#product-sources). Sources below use those decision keys; they do not imply that every baseline detail was separately selected by the operator.

## ADDED Requirements

### Requirement: Identify one thread target without changing message identity
An association SHALL identify one issue using the Slack conversation ID and original root-message `ts` string. A root MUST have at most one associated issue, while an issue MUST support multiple roots. Human-authored, bot-authored and unthreaded roots in supported private channels and app DMs MUST be eligible for association. Sources: D2 and D12 baseline.

#### Scenario: Several discussions concern the same issue
- **WHEN** two distinct roots are associated with the same issue
- **THEN** both associations exist independently and each thread's replies can select that issue
- **AND** replacing one association changes only that root's target

#### Scenario: Preserve exact identifiers
- **WHEN** a caller supplies a root-message ID such as `1731427200.000123`
- **THEN** the stored and returned ID retains the original string exactly, without a date or floating-point conversion
- **AND** the same message ID in a different conversation identifies a different source

#### Scenario: Link a bot root or a discussion with no replies yet
- **WHEN** an authorized invoker associates a bot-authored or currently unthreaded root
- **THEN** the association can be saved without requiring the root's author to have a Redmine account
- **AND** later eligible human replies use that association, while bot messages remain ineligible for import

### Requirement: Authorize the association invoker independently of comment authors
Slack management SHALL use the initiating Slack member's mapped active Redmine account. API management MUST use its authenticated Redmine account. The message author and configured import-user fallback MUST NOT authorize management on an invoker's behalf. Sources: D9, D15; existing identity resolution contract.

#### Scenario: A team member links a client-authored message
- **WHEN** a mapped active team member invokes management on a client's root
- **THEN** management checks the team member's rights, not the client's
- **AND** any imported comment still uses the existing source-author attribution and import permission checks

#### Scenario: No authorized mapped Slack actor
- **WHEN** the Slack invoker has no mapped active Redmine account or lacks the required issue capabilities
- **THEN** no association change or requested history/indication work is applied
- **AND** the configured import user's rights do not provide a management fallback
- **AND** the response does not disclose unauthorized issue details or existing association details

### Requirement: Apply issue capabilities and the additional API permission
Create/change/remove SHALL require the actor to see the relevant issue and add notes. Change MUST check both current and replacement issues; removal MUST check the current issue. API operations MUST additionally require `manage_slack_associations_via_api` in each relevant issue project. Read-only API inspection MUST require visibility and that permission, without add-notes. Sources: D10, D15.

#### Scenario: A replacement issue alone is accessible
- **WHEN** an actor can manage the proposed issue but cannot view or add notes to the currently associated issue
- **THEN** changing the association is denied without changing its target

#### Scenario: API permission is missing on one affected project
- **WHEN** an API caller has view/add-notes rights but lacks the dedicated permission on the current or replacement issue's project
- **THEN** the requested change is denied
- **AND** a Slack action does not acquire an additional dedicated Slack-management permission requirement

#### Scenario: Read-only API inspection without comment permission
- **WHEN** an authenticated API actor can view the associated issue and has the dedicated permission, but cannot add notes
- **THEN** inspection returns the association
- **AND** changing or removing it is denied

### Requirement: Require inbound readiness for create and change
Create/change SHALL require inbound import enabled, a configured signing secret and bot token, and an active configured import user. Otherwise the request MUST be rejected without storing a target or requesting history/indication work. Outbound delivery MUST NOT be a prerequisite. Source: D16; inherited inbound readiness contract.

#### Scenario: Import is ready while outbound delivery is off
- **WHEN** an authorized create/change request arrives with all inbound prerequisites satisfied and outbound delivery disabled
- **THEN** the association is saved and its requested inbound work can proceed

#### Scenario: An inbound prerequisite is unavailable
- **WHEN** import is disabled, either secret/token is absent, or the configured import user is missing/inactive
- **THEN** create/change is rejected without altering an existing association
- **AND** no history, preview or reaction operation is scheduled by that request

### Requirement: Keep authorized API inspection and removal available without replay
Authorized API inspection/removal SHALL remain available when inbound import is disabled or incomplete. Removal then MUST change stored state only, without Slack calls. Queued association side effects MUST recheck inbound readiness and discard unavailable work; re-enabling import MUST NOT replay suppressed history, previews or reactions. Source: D16 and the inherited execution-gate contract.

#### Scenario: API removal while import is disabled
- **WHEN** an API caller authorized for removal requests an existing association while inbound import is disabled
- **THEN** the stored association is removed without Slack lookups, preview posts or reaction calls
- **AND** past comments, attachments and import records remain intact

#### Scenario: Disable after work was requested
- **WHEN** a queued history or indication operation starts with inbound prerequisites unavailable
- **THEN** it performs no Slack calls or comment import
- **AND** later re-enabling import permits future events but does not resurrect that discarded operation

#### Scenario: Disabled inspection needs no Slack connection
- **WHEN** a caller authorized for inspection requests an existing association while the token or signing secret is absent
- **THEN** the stored association is returned without resolving Slack identities or fetching conversation data

### Requirement: Offer a confirmed Slack management flow
A message shortcut SHALL identify the selected root, using a reply's root when invoked on a reply. Its modal MUST support issue selection, optional existing-discussion import, and changing/removing an existing association. It MUST show the authorized target issue's title for confirmation before applying create/change; opening or cancelling MUST NOT mutate the association. Sources: D6 and D12 shortcut/modal baseline.

#### Scenario: Invoke the shortcut on a reply
- **WHEN** a team member invokes the shortcut on a reply
- **THEN** management concerns that reply's root, not a separate association keyed by the reply's own message ID
- **AND** the user can review the issue title and history choice before confirming

#### Scenario: Cancel before confirmation
- **WHEN** the user enters an issue number but dismisses the modal before confirmation
- **THEN** no association or import request is saved and no indication is posted

#### Scenario: Change or remove an existing association
- **WHEN** an authorized invoker confirms a replacement or removal using the modal
- **THEN** the shared lifecycle and issue-capability rules apply, without the API-only permission requirement
- **AND** historical comments are not moved or deleted

### Requirement: Authenticate Slack interactions and respect response deadlines
Interaction requests SHALL verify the original raw-body signature and replay window before reading the form-encoded JSON `payload`. Valid interactions MUST be acknowledged and modal triggers used within Slack's three-second windows. Slow identity/history work MUST NOT delay opening behind ordinary queued Slack work. Interaction content and credentials MUST remain absent from diagnostics. Sources: D9; existing safe ingress; Slack interaction/modals contracts.

#### Scenario: Signed form payload starts the flow
- **WHEN** Slack sends a valid signed message-shortcut form request
- **THEN** a generic modal can open promptly without disclosing issue/association details before authorization
- **AND** slower lookups can update that view to an authorized confirmation after acknowledgement

#### Scenario: Signature or replay check fails
- **WHEN** an interaction has missing/invalid authentication or a timestamp outside the existing five-minute replay window
- **THEN** the request is rejected before opening a view, enqueueing management work or changing an association

#### Scenario: Ordinary Slack work is waiting
- **WHEN** the Slack worker is occupied with history or file work when a shortcut arrives
- **THEN** modal opening does not depend on that backlog
- **AND** an expired single-use trigger is not retried as ordinary history work

#### Scenario: Diagnostics cover the new request shape
- **WHEN** a form interaction or new background operation is logged or fails
- **THEN** raw `payload`, response URLs, credentials, message content and job arguments are not exposed
- **AND** failures use the inherited sanitized classifications rather than raw Slack responses

### Requirement: Provide a source-keyed authenticated JSON API
The API SHALL expose GET, PUT and DELETE `/redmine_slack/thread_association.json`. GET/DELETE MUST accept `channel_id` and `root_message_ts` query parameters; PUT MUST accept a `thread_association` JSON object containing those strings, `issue_id`, and optional `import_existing` defaulting false. Responses MUST expose the association, not Slack message content. Sources: D7, D10, D15–D16 and D12 API baseline; route shape is a design choice.

#### Scenario: Create and inspect after issue creation
- **WHEN** an authorized authenticated API caller PUTs a valid previously unassociated source and issue
- **THEN** the API returns 201 with `thread_association` containing `channel_id`, `root_message_ts` and `issue_id`
- **AND** authorized GET returns 200 with the same fields and no Slack discussion body
- **AND** success reports saved association state, not completion of queued Slack/history work

#### Scenario: Replace or repeat an association
- **WHEN** an authorized PUT addresses an existing source
- **THEN** it replaces the issue target, or retains the same target, and returns 200
- **AND** `import_existing: true` requests a history pass even for the same target, with existing message-ID deduplication preventing duplicate comments

#### Scenario: Remove and then inspect
- **WHEN** an authorized DELETE removes an existing association
- **THEN** the API returns 204 with no body
- **AND** later inspection finds no association at that source

#### Scenario: Reject invalid or unauthorized calls
- **WHEN** API authentication is absent, issue permissions are insufficient, the source/issue input is invalid, or create/change is not inbound-ready
- **THEN** the API returns respectively an authentication failure, a generic authorization/not-found response, validation failure, or readiness conflict, without mutation or queued side effects
- **AND** these use HTTP 401, 403/404, 422 and 409 respectively, with no unauthorized issue/association details in the response

### Requirement: Retain the supported source boundary without actor channel authorization
Association create/change SHALL validate an existing root in a private channel or app DM readable by the configured bot, retaining original identifiers. Public channels, group DMs and person-to-person DMs MUST NOT gain association support. The invoker's source-channel membership MUST NOT be separately authorized. Sources: D10 and D12 supported-conversation baseline; existing eligibility contract.

#### Scenario: The bot can read a supported private source
- **WHEN** an otherwise authorized API caller supplies a valid supported root without a verified source-channel Slack identity
- **THEN** the request is not denied for missing actor membership verification
- **AND** ordinary per-message Redmine import checks still apply

#### Scenario: Unsupported source or non-root API identifier
- **WHEN** create/change addresses an unsupported conversation type, a missing message, or an API root identifier that actually identifies a reply
- **THEN** no association is stored for that input
- **AND** the caller receives a validation/not-found result rather than a fabricated target

### Requirement: Import requested history using existing message tracking
Selected existing-discussion import SHALL process eligible root/reply history chronologically across all returned pages, excluding bots and unsupported messages. It MUST use the existing per-message author, formatting, attachment, permission and identifier-deduplication rules, without generating ordinary mention previews for each historical message. Sources: D5 and D12 history baseline; existing comment-import contract.

#### Scenario: Paginated client discussion
- **WHEN** existing-discussion import is selected for a thread with several history pages, a human root, files and human replies
- **THEN** eligible messages from each page are considered in chronological history order and files use the existing attachment pipeline
- **AND** a bot-authored root or unsupported reply is skipped without preventing eligible human replies

#### Scenario: No historical import selected
- **WHEN** an association is saved without existing-discussion import
- **THEN** it does not initiate a history pass or import the pre-existing root merely because it was associated
- **AND** subsequent eligible replies route using the association

#### Scenario: Repeat after a different issue already received messages
- **WHEN** history import encounters a message already represented by an import record, including a deletion tombstone or an import on another issue
- **THEN** that message creates no second comment or attachment import and is not copied to the new issue
- **AND** no content comparison or similarity analysis is performed

#### Scenario: The association changes while requested history waits
- **WHEN** a history request selected one issue but the stored association changes before its execution
- **THEN** that history request retains its selected association target, subject to explicit markers and current per-message import checks
- **AND** new event processing uses the current association rather than migrating old journals

### Requirement: Preserve imported history through association changes
Changing/removing an association SHALL affect association-based routing without moving/deleting existing comments, attachments or import records. Later Slack edits/deletions MUST continue to synchronize the original imported journal under the existing rules. Removal MUST leave explicit-marker and parent-reference routing available. Sources: D6 and D12 lifecycle baseline; existing synchronization contract.

#### Scenario: Reassign then edit an old imported reply
- **WHEN** a thread is reassigned and a previously imported message receives a newer Slack edit or deletion
- **THEN** only its original imported journal is synchronized under the existing edit/deletion rules
- **AND** the new issue receives only eligible messages not already imported elsewhere

#### Scenario: Unlink a root that still mentions an issue
- **WHEN** an association is removed but the root still contains a recognized issue reference
- **THEN** a subsequent markerless reply can still import through the unchanged parent-reference fallback
- **AND** removing the association does not promise that all marker/reference-based importing stops

### Requirement: Show the association without rewriting the root
Successful association indication SHALL add the bot's `ticket` reaction to the root and post the existing visibility-filtered issue preview in that root's thread when available on create/change. Change MUST retain the reaction; removal with permitted Slack side effects MUST remove only the bot's reaction. Root content MUST remain unchanged, including bot roots. Sources: D3–D4, D6 and D12 indication baseline.

#### Scenario: Indicate a newly linked client or bot root
- **WHEN** association-indication work succeeds for a client-authored or bot-authored root whose issue is visible to the configured import user
- **THEN** the root has the bot's ticket reaction and the thread receives the issue preview
- **AND** neither root gains a footer, text badge or other content modification

#### Scenario: Repeated reaction and later removal
- **WHEN** the bot already has the reaction during an add, or no longer has its own reaction during removal
- **THEN** the desired reaction end state is treated as reached without removing another participant's reaction
- **AND** removing/changing an association does not rewrite or delete older preview replies

### Requirement: Reuse preview disclosure and queued failure behavior
Association previews SHALL retain the existing preview fields, full escaped description, configured-import-user visibility filter, customization and disabled unfurls. Historical imports and indication MUST use the existing queued rate-limit/transient/permanent-failure policy. A later Slack failure MUST NOT roll back an already-saved association or introduce a reconciliation ledger. Sources: D3, D11, D16; existing preview/failure contracts.

#### Scenario: Authorized actor can see an issue that the import user cannot
- **WHEN** an association is authorized for the invoker but its issue is invisible to the configured import user
- **THEN** its issue preview is skipped under the existing filter rather than disclosing it using the invoker's rights
- **AND** there is no new channel-by-project disclosure policy

#### Scenario: Preview content and uncertain posting
- **WHEN** a visible issue is previewed and a Slack call later times out or is rate limited
- **THEN** preview content retains tracker, issue number/link, project, subject, status, priority and full escaped description
- **AND** existing retry policy applies, including its accepted possibility of repeated previews, while persisted association state remains saved

### Requirement: Document setup and use stubbed automated verification
Setup documentation SHALL describe the association migration, API permission/authentication, routes, interaction URL/shortcut, required added scopes and reinstallation, and D16's disabled-state behavior. Automated verification MUST use stubbed Slack HTTP and the existing local-runtime safety guards, not send real Slack messages. Sources: D7, D10, D15–D16 and existing rollout/testing contract.

#### Scenario: Prepare the existing Slack app
- **WHEN** an operator follows the new setup instructions
- **THEN** the documentation identifies `commands`, `reactions:write`, `im:read`, and source-classification use of `groups:read`, retaining `groups:history` and `im:history` for history
- **AND** it distinguishes the interaction URL from the Events API URL and explains the dedicated project-role API permission

#### Scenario: Validate without live disclosure
- **WHEN** automated association tests run
- **THEN** their known synthetic HTTP endpoints are stubbed, unknown HTTP requests remain rejected, and no live Slack destination is contacted
- **AND** actual app scopes, live timing and any live send require separately authorized operational verification
