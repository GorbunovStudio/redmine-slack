# Design

## Context

See [proposal.md](proposal.md#why) for the motivation. This design extends the plugin's inbound integration, not its outgoing notification rules.

- `EventJob` gates inbound work on current settings and an active import user, selects marker/parent targets and composes previews inline (`app/jobs/redmine_slack/event_job.rb:21–65`). `CommentImporter` already owns unique message-ID skipping, author authorization, attachments, journals and synchronization (`lib/redmine_slack/comment_importer.rb:11–94`).
- Import records have a composite unique channel/message key and an optional journal, including deletion tombstones; they do not store a root-to-issue target (`db/migrate/001_create_redmine_slack_message_links.rb:3–9`). Reverse Slack identity resolution already chooses active Redmine accounts (`lib/redmine_slack/member_resolver.rb:33–47`).
- The sole route is the JSON Events API callback, whose controller uses signature authentication rather than a Redmine login (`config/routes.rb:1`, `app/controllers/redmine_slack/events_controller.rb:2–26`). The plugin registers no association permission (`init.rb:17–42`).
- Slack work uses one existing queue thread (`init.rb:44`). The client has five-second phase timeouts and shared safe error classification (`lib/redmine_slack/client.rb:14–16,82–124`); those timeouts and a queued opening cannot satisfy the interaction trigger window by themselves.

### Product sources

These decision keys describe product choices and distinguish explicit decisions from the feature's design baseline:

- **D2:** one issue can have associations from multiple Slack root messages.
- **D3–D4:** reuse the bot's existing issue-mention preview; do not add the proposed footer to bot-authored roots.
- **D5:** duplicate detection stays lightweight and identifier-based, never content/similarity based.
- **D6–D7:** support changing/removing associations and a Redmine API enabling association after issue creation.
- **D8:** sending a discussion to an agent to draft an issue specification remains outside this feature.
- **D9–D11:** association access follows the invoking person, not the message author. Add a dedicated API permission, omit source-channel actor-membership authorization, and accept the existing preview's disclosure without extra channel restrictions.
- **D15:** management needs actor visibility and add-notes; API management additionally needs its dedicated permission. Replacement checks both current and new issues, removal the current issue. API inspection needs visibility and the API permission without add-notes.
- **D16:** reject create/change unless inbound import is enabled/configured. Authorized API inspection/removal remains available while disabled/incomplete, with removal limited to stored state and no Slack calls then. Do not replay suppressed history/indication work later; outbound delivery is not a prerequisite.
- **Implementation-request baseline under D12:** the supplied conversation proposed one target per thread, message shortcut/modal confirmation, optional history import, a ticket reaction, marker → association → parent precedence, unchanged past journals, and API inspect/change/remove. These are design choices carried from that baseline, not separate verbatim operator selections. D6 supersedes the earlier exclusion of change/unlink, and D4 removes its footer. The initial requested outcome is to attach a discussion's existing and future messages after issue creation and visibly mark client-authored roots.

### Provider contracts

Use these public contracts rather than new integration assumptions:

- [Message retrieval](https://docs.slack.dev/messaging/retrieving-messages/): `ts` is a string message identifier unique in its conversation; replies identify their root with `thread_ts`.
- [Shortcuts](https://docs.slack.dev/interactivity/implementing-shortcuts/), [interaction payloads](https://docs.slack.dev/reference/interaction-payloads/shortcuts-interaction-payload/) and [interaction handling](https://docs.slack.dev/interactivity/handling-user-interaction/): message actions include invoking user/message/channel context; form-encoded requests contain JSON in `payload`; acknowledgement and single-use triggers have three-second windows; shortcuts need `commands`.
- [Modals](https://docs.slack.dev/surfaces/modals/) and [`views.open`](https://docs.slack.dev/reference/methods/views.open/): open promptly with the trigger, use view IDs for later updates, and use a submission's `response_action: update` acknowledgement to retain a working view. Opening adds no OAuth scope of its own.
- [`conversations.replies`](https://docs.slack.dev/reference/methods/conversations.replies/): cursor-paginated parent/replies and chronological history; the current method contract lists bot `groups:history`/`im:history` scopes. Do not introduce a user token based on outdated restrictions.
- [`conversations.info`](https://docs.slack.dev/reference/methods/conversations.info/): supported type indicators, with private-channel/app-DM `groups:read`/`im:read` scopes. Type classification is distinct from actor-membership authorization.
- [`reactions.add`](https://docs.slack.dev/reference/methods/reactions.add/) and [`reactions.remove`](https://docs.slack.dev/reference/methods/reactions.remove/): bot `reactions:write`; `already_reacted` and `no_reaction` identify the requested bot-reaction end states.
- [Redmine REST authentication](https://www.redmine.org/projects/redmine/wiki/Rest_api#Authentication): use enabled REST API authentication, including `X-Redmine-API-Key`, rather than accept the event callback's login-free model.

## Goals / Non-Goals

**Goals:** separate management authorization from comment authorship; keep one shared target policy for future events and requested history; preserve existing journal identity and conversion; meet interactive deadlines without a second worker/service; make saved-state success distinct from asynchronous Slack effects.

**Non-Goals:** a second import ledger, preview deduplication, compensating transactions across Slack/Redmine, source-channel membership checks, a new Slack-management permission, a new queue/gem, root-message editing, a Slack discussion export API, Redmine core/background-worker changes, or agent drafting. Existing avatar code and unrelated changes remain untouched.

## Decisions

### Separate durable thread targets from imported-message history

Add `app/models/redmine_slack/thread_association.rb` and migration `002_create_redmine_slack_thread_associations.rb`. Store non-null string `channel_id`/`root_message_ts` and an issue ID; add a composite unique source index and an issue-ID index. Keep provider identifiers unchanged rather than parse timestamps for identity. An issue can therefore have many roots without limiting it to one source (D2 and baseline model).

Do not overload `MessageLink`: its existing meaning is a message import or deletion tombstone, and its nullable journal supports deletion-before-import (`lib/redmine_slack/comment_importer.rb:77–94`). No change to that schema or existing import records is needed. Do not backfill associations by scanning existing notes or root content; marker/reference routing remains valid without stored associations.

### One lifecycle manager authorizes each operation

Add a plugin-local `AssociationManager` shared by the modal worker/controller and `ThreadAssociationsController`. It accepts the actor explicitly, source tuple, desired issue and history option; the API adapter additionally selects the API permission check. Slack adapters resolve the invoking `user.id` through `MemberResolver#user`; they never pass the source message author as the management actor or use the importer fallback (D9, D15).

Use `Issue#visible?` and `Issue#notes_addable?` for create/change/remove. Register `manage_slack_associations_via_api` as a project-role permission with its human-readable label, without a new project-module enablement toggle. API calls also check that permission in every relevant issue project. Inspection checks only visibility plus that API permission. Existing import checks use these issue predicates for authors but cannot authorize the new manager (`lib/redmine_slack/comment_importer.rb:15–24`).

Authorize the current target loaded for the mutation, not a stale target from modal metadata. Serialize existing-row changes in a transaction; the composite unique index handles competing source creation. A competing insert must re-enter the same current-target authorization path rather than blindly overwrite an association not checked by the actor. This is the least mechanism that maintains D15 at the new external mutation entry points, not a separate concurrency policy or lock service.

For create/change, validate string source identifiers, use `conversations.info` to retain the private-channel/app-DM boundary, and reuse `Client#conversation_parent` to find the exact root (`lib/redmine_slack/client.rb:27–30`). A source API `root_message_ts` naming a reply is invalid; the Slack shortcut instead normalizes its known reply context before calling the manager. Root existence/type validation is about the supplied source, not the actor's Slack membership (D10). No regex-based timestamp conversion, channel-by-project allow-list or extra content inspection is needed.

### Keep readiness and offline API operations distinct

Extract/share the current inbound-readiness predicate: `import_enabled == '1'`, nonblank signing secret and bot token, and active configured import user (`app/jobs/redmine_slack/event_job.rb:21–26`). D16 applies it to create/change and every history/indication execution. A failure rejects create/change before provider source validation, persistence or enqueue; queued work observed while unavailable is discarded and is not resumed by re-enabling.

API inspection and removal use the stored row plus Redmine authorization, so they need neither Slack lookups nor a configured bot. Removal while not ready deletes only the association; it enqueues no Slack effect. Do not make the API permission, add-notes on inspection, outbound delivery, or Slack connectivity an extra readiness condition. The disabled-state exception is an API contract, not a new disabled-state Slack-removal mode. Slack management still uses D15 for its invoked operations; no additional switch-specific Slack-removal policy is introduced.

### Expose a small source-keyed API

Use a normal Redmine `ApplicationController` with API authentication enabled for `show`, `update`, and `destroy`, and require the authenticated account. Do not subclass the event controller or share its CSRF/login exemptions. Register:

- `GET /redmine_slack/thread_association.json?channel_id=CFIXTURE&root_message_ts=1731427200.000123` for inspection.
- `PUT /redmine_slack/thread_association.json` with `{"thread_association":{"channel_id":"CFIXTURE","root_message_ts":"1731427200.000123","issue_id":123,"import_existing":false}}` for create/replace/repeat. Omitted `import_existing` is false.
- `DELETE` at the same URL with the source query parameters for removal.

PUT returns 201 when created, 200 when updating; GET returns 200; bodies contain only `thread_association` with source strings and issue ID. DELETE returns 204. Absent/inaccessible associations or issues use generic 404 responses; an authenticated but unpermitted operation can use generic 403, missing API authentication 401, malformed/unsupported source input 422, and unmet create/change readiness 409. Use safe local error identifiers such as `not_authorized`, `invalid_source`, `not_found`, and `import_not_ready`, never raw provider bodies. Pre-persistence provider failures use inherited safe classification without saving a fabricated source; queued failures after persistence do not turn a successful saved-state response into a rollback.

PUT is an upsert operation, not a second association per source. A repeated PUT can request a fresh optional history pass; existing import records make that pass safe. GET is not a list of private Slack content, and no route exports a thread. A singleton source-tuple resource avoids path/format parsing of timestamp dots and supplies the four baseline operations without redundant controllers. The precise verbs/statuses are this design's API shape, not a claim that D7 dictated them.

### Preserve routing precedence and reuse the importer for history

Extract a small shared target resolver around the existing marker and parent-reference logic (`app/jobs/redmine_slack/event_job.rb:39–48`). For new replies: first explicit marker; then current stored root association; then exact-parent lookup. Lookup the association before fetching a parent. A top-level message without a marker does not newly become a historical root import merely because its old event is delivered again. The requested history worker supplies the selected association target explicitly for its eligible root and replies, after marker precedence. Root/parent references and normal mention previews continue to use original text (`lib/redmine_slack/inbound_message.rb:3–35`).

Add `ThreadImportJob` on the existing `slack` queue, with source tuple and the issue ID selected by that history request, not a mutable association record alone. Iterate `conversations.replies` cursor pages in chronological order. Reuse only the new-message eligibility/routing helper and `CommentImporter#create`; do not replay each historical message through `EventJob`, which requires event-only `channel_type` and also posts ordinary previews (`app/jobs/redmine_slack/event_job.rb:27–36,50–65`). No artificial history-size cap, content comparison, imported-ID cache or per-message preview pass is needed.

The existing importer already skips every persisted channel/message identity before issue lookup, then protects the journal/link transaction with its unique index (`lib/redmine_slack/comment_importer.rb:11–55`). This covers repeat requests, overlapping events, old imports on another issue and tombstones. It also owns active source-author resolution, configured-user fallback, file checks and formatting; reuse it unchanged for those responsibilities. Snapshotting the selected history target prevents a later reassign from silently changing a previously requested history destination; current per-message import checks still run. New events observe current associations at execution. Older journals retain their original link and target for edits/deletions (`lib/redmine_slack/comment_importer.rb:60–94`).

### Open promptly, then resolve and confirm in the existing modal

Add POST `/redmine_slack/interactions` and an `InteractionsController` separate from Events API JSON parsing. Extract the existing raw signature verifier (`app/controllers/redmine_slack/events_controller.rb:6–12`), preserve its five-minute replay window, and parse the signed form's `payload` JSON after verification. Extend `init.rb:3` parameter filtering with `payload`, and keep all new job arguments unlogged like `EventJob` (`app/jobs/redmine_slack/event_job.rb:5`). Do not use the supplied `response_url` for arbitrary HTTP or persist it as a response mechanism; view APIs and the fixed Slack client are sufficient.

The message shortcut uses callback ID `redmine_slack_manage_thread`. Normalize source context with `message.thread_ts || message.ts`, then open a generic modal with issue input and an unchecked history option. It contains no current issue details until the invoker is resolved and authorized. Opening is the small synchronous exception to queued Slack I/O: give `views.open` a per-request total deadline shorter than the remaining three-second interaction window; do not use three independent five-second phase waits, queue the trigger, or retry an expired trigger. Keep this deadline local to opening, not a global transport change.

After opening, an `InteractionJob` on `slack` can resolve identity/current association and update the view with authorized management choices. Submission of issue/history choices immediately acknowledges with a working `response_action: update` view; queued resolution updates that view to show the authorized issue title and explicit confirmation. Confirmation calls the shared manager and rechecks authorization against current state. Removal uses the same invoker policy; cancellation has no lifecycle side effect. Carry only source tuple, actor/stage and submitted choices in returned modal metadata, not tokens or permission grants. This avoids a new session table and keeps external payloads as inputs to be authorized rather than proof of rights.

### Extract exact previews and queue visible indication

Extract a reusable preview composer from `EventJob`'s existing issue filter/content/payload customization (`app/jobs/redmine_slack/event_job.rb:50–65`), reusing `MessageTemplate.escape` (`lib/redmine_slack/message_template.rb:3–5`). Ordinary mention previews retain current placement; association work supplies the root `thread_ts` and selected issue. Keep the configured-import-user visibility filter even if the invoker could see more. Importing a history page does not cause an additional preview for every reference.

Use an `AssociationIndicationJob` after the association transaction commits: add the bot's `ticket` reaction and post the current selected issue's shared preview on create/change; retain the reaction across replacement; remove the bot's reaction on enabled removal. Old preview messages are historical replies, not an editable source of truth; the stored association is authoritative. Do not modify roots or add a footer (D4).

Extend `Client` with conversation-info/replies, view open/update, and reaction methods using its existing request transport. Treat only `already_reacted` on add and `no_reaction` on remove as desired bot-reaction end states; other provider failures retain normal classification. History and indication jobs inherit current queue, retry/rate-limit behavior and readiness checks (`app/jobs/redmine_slack/event_job.rb:3–26`, `lib/redmine_slack/client.rb:82–124`). Do not hold a database transaction across Slack calls, roll back a saved association because a later preview failed, or introduce a recovery/preview ledger. Existing transient retries can duplicate posts or overtake other work; indication is not an atomic cross-system transaction.

## Risks / Trade-offs

- **Private-source actor membership is not verified.** An API account granted the special permission can request imports from a private source the bot can read, even without a mapped member of that source. → Accepted by D10; retain Redmine actor and per-message import checks, without adding the rejected Slack membership policy. No prevalence measurement is claimed.
- **Full issue previews can reach Slack participants without Redmine access.** → Accepted by D11 with D3 preview reuse. Keep the configured-import-user filter; do not add channel-by-project disclosure restrictions. No prevalence measurement is claimed.
- **Saved association and Slack indication are not atomic.** A permanent error or a delayed retry overtaking later work can leave stale/missing reactions or repeated historical previews. → Retain the existing safe retry/drop policy, saved-state API semantics and manual lifecycle operations; no speculative reconciliation/compensation mechanism. The ordinary case has no measured frequency. Requested history still deduplicates journals by message ID.
- **Documentation and stubs cannot prove installed scopes or live timing.** → Automated tests verify payloads, request-path deadline separation and inherited safety rules; any live check needs separate operational authorization. Current client/queue constraints are documented above rather than treated as live performance evidence.

## Migration Plan

1. In an authorized environment, apply the new plugin migration before enabling the new association flow. Retain inbound/outbound off on maintenance/local database copies. Existing message links and journals remain unchanged; no automatic association backfill runs.
2. Configure POST `/redmine_slack/interactions` as the Slack interactivity URL and the message shortcut callback. Add `commands`, `reactions:write`, and `im:read`; retain existing `groups:history`, `im:history` and `groups:read`, documenting that the latter now supports source classification too. Reinstall after scope changes. Keep the existing Events API URL/subscriptions intact (`README.md:103–120`).
3. Enable REST API authentication where required and grant `manage_slack_associations_via_api` to the intended project roles. Document source tuple fields, PUT/GET/DELETE examples, create/change readiness and the offline API inspection/removal exception.
4. Run local stubbed migration/smoke/reload/loader checks described in tasks. Live posting, real credentials/destinations and actual scope/timing verification are separate approved operations; no test task silently enables production traffic.
5. For rollback, disable inbound import and remove the shortcut/interactivity configuration before removing job/controller classes; allow already queued classes to consume disabled work. Deploy the previous plugin revision while retaining the association table, original message links and journals. Do not run a destructive down-migration or replay suppressed indication/history automatically. Existing marker/parent routing needs no association conversion.
