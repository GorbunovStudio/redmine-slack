# Design

## Context

See [proposal.md](proposal.md) for motivation and the delta specs for the acceptance contract. The inspected plugin currently has no inbound route or migrations: `init.rb` registers settings and the dedicated queue, `DeliveryJob` refreshes settings and owns retry handlers, and `Client` centralizes authenticated API requests and sanitized errors.

`SlackListener#speak` validates outbound destinations and queues delivery only when outbound delivery is enabled; its notification entry points are controller hooks, not general issue-save callbacks. Redmine's `Issue#init_journal`, attachment-add callbacks, and `Journal` notification callback support model-based notes and attachment-only journals without invoking those hooks; `Journal#editable_by?` is a separate interactive-edit predicate, not an automatic restriction on direct model updates.

## Goals / Non-Goals

**Goals:** Add an inbound path beside the existing outbound path, reusing local helpers and Redmine's model behavior rather than routing through its HTTP API.

**Non-Goals:** No replacement delivery engine, infrastructure service, event ledger, extra settings, custom attachment limits, conflict detection, or persisted edit/upload history.

## Decisions

### Signed HTTP ingress

Add `POST /redmine_slack/events` using a plain `ActionController::Base` controller with `skip_forgery_protection`, `request.raw_post`, the specified HMAC/replay check, and `secure_compare`, following the inspected GitHub webhook pattern instead of a login-bearing Redmine controller. Challenge responses stay synchronous; event callbacks only enqueue `RedmineSlack::EventJob` and acknowledge, keeping all issue/Slack work outside Slack's response deadline [R, S-sign, S-events].

### Configuration and execution gate

Extend the current settings registration, secret-preservation patch, and settings partial for exactly the approved inbound controls, with `signing_secret` filtered like `bot_token`; `EventJob` refreshes settings with `Setting.check_cache` and requires enabled import, both credentials, and an active import user on every attempt. The gate is independent of `delivery_enabled`, so previews use the existing client's `post_message` directly rather than `speak` or `DeliveryJob`, whose outbound gate and lack of thread metadata are unsuitable for inbound replies [R].

### Queue and failure reuse

Put `EventJob` on `slack`, disable argument logging, and reuse `DeliveryJob`'s typed retry/rate-limit/drop handlers without changing their defaults or client timeouts. Add only `users.info`, `conversations.history`, and an authenticated private-file download method to `Client`; API lookups/previews follow the shared policy, while download failures are caught at the individual-file boundary so they do not discard the note [R, C-client, C-job].

### Shared message interpretation and previews

Use a local `InboundMessage` helper for ordered issue references, explicit-marker removal, and narrow Slack-to-CommonMark conversion, reusing the existing `escape` implementation for preview values by making it a shared helper with the listener delegating to it. `EventJob` filters conversation/subtype/bot origin (including nested event messages), then builds the combined preview attachment list from issues visible to the import user, retaining configured customization and unfurl flags and supplying `thread_ts` only for a reply; duplicating parser/escaping logic or adding preview state is unnecessary [R, C-listener].

### Exact parent retrieval

For a reply without a marker, call `conversations.history` with the channel, `latest: thread_ts`, `inclusive: true`, and `limit: 1`, use only the message whose `ts` equals the requested parent, and scan its text then each attachment's title/text. This adapts Hubot's exact-parent history lookup to the existing client's Web API path and includes the attachment text needed by the approved routing contract, rather than enumerating a whole thread [R, H-thread].

### Reverse identity and authorization

Extend `MemberResolver` to match trimmed member-ID preferences first, otherwise use `users.info` plus `User.active.having_mail(email)`, caching successful reverse user IDs by Slack member with the existing successful-lookup lifetime and resolving display names from the Slack profile. Select a linked author with `issue.visible?(user)` and `issue.notes_addable?(user)`, otherwise require those predicates plus `import_user.member_of?(issue.project)` for attributed fallback; this preserves account attribution without granting unlinked participants the permissions of an unrestricted integration identity [R, C-resolver, R-user, R-permissions].

### In-memory downloads

Before downloading an allowed-origin file, skip it when Slack-reported `size` exceeds runtime `Setting.attachment_max_size.to_i.kilobytes`; hold the remaining downloads as binary (`ASCII-8BIT`) Strings for `Attachment#file=`, matching `DeliveryJob`'s memory-based byte handling and Redmine's `String#size` path [R-review, R-attachments, C-job]. Downloads do not follow redirects (HTTPClient's default), and a non-2xx response fails only that file [R-review].

### Journal and file persistence

Pass valid downloads through Redmine attachment creation/validation after `issue.init_journal(author, notes)` and before saving the issue, with the selected author as `User.current` restored in `ensure`. A local `CommentImporter` helper owns that operation and skips each rejected/unavailable file, because the existing attachment callbacks supply same-journal details (including file-only notes) and ordinary email behavior without controller hooks, a silent marker, or custom attachment rules [R, R-journals, R-attachments].

### Minimal durable message link

Create `redmine_slack_message_links` with `channel_id` and `message_ts` strings under a composite unique index, nullable `journal_id`, strings `slack_user_id`, `author_name`, `last_edited_ts`, and datetime `deleted_at`, using the neighboring plugin's migration style. Check for an existing link before import, then insert the link and save/update its journal reference in the same transaction, treating a uniqueness collision as a duplicate rather than adding event IDs, issue IDs, or history columns; deletion-only rows can omit unavailable author metadata [R, R-migration].

### Edits and deletions update the original journal

Keep Slack timestamps as strings and compare edit watermarks numerically without floating-point loss, initialize the watermark from the posted message's edit timestamp or original timestamp, and atomically rewrite linked notes plus the watermark while retaining the existing attribution style, saved `author_name`, journal author, issue, and attachments. Apply the specified deletion rendering using the deletion event's time formatted through Redmine's date/time helper, atomically mark the link (or create a no-journal tombstone), and ignore subsequent edits/repeated deletions; direct journal updates avoid rerouting, interactive edit-permission additions, conflict checks, or edit-history storage [R, R-journals, R-format].

### Guarded verification and documentation

Extend `SlackSmokeTransport` only for the required API methods and explicit synthetic Slack-file URLs, retaining its rejection of unknown HTTP, the harness's existing local/start-disabled guards, and state restoration. Update the existing README setup/rollout sections rather than adding a parallel manual, and qualify the old outbound-only replies-disabled guidance so it does not contradict inbound app-DM use [R, C-test].

## Risks / Trade-offs

- [Slack retries or uncertain preview posts repeat previews] → Accepted; comment identity is durable, preview/event identity is not.
- [Delayed retries are overtaken by edits or deletions] → Edit watermarks reject stale updates, deletion tombstones block late imports, and edits never create missing imports.
- [Some files cannot be retained] → Preserve the note and valid files; use Redmine's existing validation rather than a new fallback upload mechanism.
- [Slack overwrites a manually edited imported note] → The approved synchronization contract owns that note; no conflict detection is added.
- [Normal comment emails reach project participants] → Retain Redmine's configured notifications; preventing a Slack echo does not suppress email.

## Migration Plan

After implementation and stubbed acceptance, use the existing release process to install the plugin migration while import remains off, create/configure the import user and its project memberships, and complete the app setup in the modified documentation requirement. Enable import when the named Hubot listeners are disabled; this planning operation performs neither action.

Rollback starts by disabling import and leaving the event-job class available until queued events consume that state; remove the app subscription before removing its endpoint or job class. Retain message links, journals, and attachments, and leave ordinary outbound delivery and Hubot's unrelated commands/reports unchanged; resuming old listeners is an explicit operator cutover, not an automatic rollback action.

## Sources and numeric provenance

- **R:** `/home/andre/projects/redmine/tickets/slack-comment-import/requirements.md`, the approved final decisions. This supplies the single job per callback, single preview reply, single comment/link per message, marker/reference syntax, quote/deletion blank-line rules, allowed file origin, settings/events/scopes, and excluded behavior; counts here are requirements, not invented tuning values.
- **R-review:** `/home/andre/projects/redmine/tickets/slack-comment-import/02-propose-review1.prompt.md`, the approved file-handling and coverage refinements; Redmine's existing attachment-size setting is used without introducing a numeric cap.
- **S-sign:** [Slack request verification](https://docs.slack.dev/authentication/verifying-requests-from-slack), supplied by R: `v0`, HMAC-SHA256, and the five-minute replay window.
- **S-events:** [Slack Events API](https://docs.slack.dev/apis/events-api), supplied by R: successful acknowledgement within three seconds and the HTTP 200 callback response selected in R; [file-share event](https://docs.slack.dev/reference/events/message/file_share) supplies the supported file-bearing subtype. These URLs were supplied, not fetched during planning.
- **C-client / C-job:** `lib/redmine_slack/client.rb` and `app/jobs/redmine_slack/delivery_job.rb`, read in this checkout; reuse their error handling and defaults without new retry counts, waits, or timeout values.
- **C-listener / C-resolver:** `lib/redmine_slack/listener.rb` (`escape`, `speak`, controller hooks) and `lib/redmine_slack/member_resolver.rb`; the reverse cache inherits the existing `24.hours` successful-lookup expiry rather than introducing a new duration.
- **H-thread:** `/home/andre/projects/redmine/docker-images/hubot/scripts/redmine.coffee`, thread listener's exact-parent request (`latest`, `inclusive`, `count: 1`); `limit: 1` expresses that same parent cardinality with `conversations.history`. Its preview title/description and quote-fix code were also read; approved R takes precedence over Hubot differences.
- **R-user / R-permissions:** `/home/andre/projects/redmine/app/app/models/user.rb` (`having_mail`); `principal.rb` (`member_of?`); `issue.rb` (`visible?`, `notes_addable?`, `attachments_addable?`). Attachment addition uses the core predicate, not an invented separate permission key.
- **R-journals / R-attachments / R-format:** `/home/andre/projects/redmine/app/app/models/issue.rb` (journal creation and attachment callbacks), `journal.rb` (empty-note details, notifications, edit predicate), `attachment.rb` and `/home/andre/projects/redmine/app/lib/plugins/acts_as_attachable/lib/acts_as_attachable.rb` (validation/persistence), and `/home/andre/projects/redmine/app/lib/redmine/wiki_formatting/common_mark/formatter.rb` (`strikethrough: true`).
- **R-migration:** `/home/andre/projects/redmine/plugins/redmine-gorbunovstudio-github/db/migrate/001_create_github_pull_requests.rb`, including the local `ActiveRecord::Migration[8.1]` API version and composite unique-index style; that plugin's controller/routes provide the inspected webhook pattern.
- **C-test:** `test/redmine7_smoke.rb`; the smoke command in `tasks.md` is copied from R and is an implementation-stage check, not a command executed during this proposal. Task numbers, source locations, dates, API names, and example issue IDs are identifiers, not new operational constants.
