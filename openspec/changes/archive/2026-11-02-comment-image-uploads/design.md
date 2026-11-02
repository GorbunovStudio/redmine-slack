# Design

## Context

See [proposal.md](proposal.md) for motivation. The listener already guards comment eligibility, composes tokenized text and routing, and enqueues through `speak` inside the existing edit transaction. `DeliveryJob` resolves identities and posts through `Client`; shared client classification and job handlers already own cancellation, retries, drops, and safe diagnostics. HTTPClient currently supports GET and JSON API requests, and the smoke transport rejects unexpected endpoints. The approved spike established external upload compatibility; the web-process worker can read attachment files.

## Goals / Non-Goals

**Goals:** Extend the existing comment pipeline without changing its transaction, routing, or non-comment contracts.

**Non-Goals:** Remote-image fetching, full formatting conversion, non-image uploads, new settings/storage/services/dependencies, schema changes, resumable uploads, or idempotency machinery.

## Decisions

### Collect images only after the existing comment eligibility guard

After the existing private/blank/silent guard, combine `journal.attachments` filtered by `image?` with inline images from the original note, deduplicating by attachment ID in stable discovery order. Redmine's journal helper selects added attachment details (`property == 'attachment'`, present value, ID in `prop_key`), excluding removals. A small local helper follows `Setting.text_formatting`: CommonMark `![alt](filename)` or Textile `!filename!`; other formatter names are not reinterpreted. Decode local filenames as core does, resolve with `Attachment.latest_attach(issue.attachments, filename)` (case-insensitive latest creation time/ID), and then check `image?`. Exclude targets with a URL scheme.

Strip those recognized image spans, including external, missing, and non-image targets, from a copy of the note before existing mention tokenization. Keep saved notes and text/routing composition intact. Do not add a blank guard after stripping, so an image-only note remains eligible.

**Alternatives rejected:** All issue attachments would include unrelated images; journal-only selection omits inline reuse; full HTML conversion risks changing established text and mention behavior.

### Keep attachment references in the job and read bytes during each attempt

Return IDs alongside comment text/channel and extend only the comment `speak` call with an optional argument. Serialize them under `image_attachment_ids`, distinct from Slack's existing `attachments` objects; omit the key when empty. Do not persist file content, filenames, paths, tokens, upload URLs, or Slack upload IDs.

After the existing settings guard and destination/mention resolution, reload each attachment, recheck `image?`, and read `diskfile` in binary mode immediately before uploading. Skip missing records/local read failures, isolating that rescue from transport errors. Use actual byte length and release each buffer before reading the next. Envelopes without IDs or with all images skipped use the unchanged customized `chat.postMessage` path, including unfurl flags. No fixed count or size cap is added; the approved decision relies on Redmine's attachment setting.

**Alternative rejected:** Reading/serializing bytes during save adds request work and job payload size without benefiting deferred delivery.

### Add external upload methods to the existing client

Retain HTTPClient TLS/timeouts and existing authenticated methods. Add:

- `files.getUploadURLExternal`: form-encoded POST with `filename` and byte `length`, using Bearer authorization and the shared JSON API response path.
- Raw POST to the returned `upload_url`: binary body, not JSON/form/multipart, without the Slack Bearer header.
- `files.completeUploadExternal`: authenticated JSON POST with the successfully uploaded file IDs, resolved `channel_id`, rendered comment as `initial_comment`, and the existing `username` / selected `icon_url` or `icon_emoji` customization. Do not include Slack message attachment objects, `link_names`, `blocks`, or unsupported `unfurl_*` parameters.

Acquire/upload each available image, then complete the combined file list once, without a separate text post. Use the combined-message requirement's completion-success rule without inspecting share metadata or polling. Slack discards uncompleted uploads, so no cleanup worker is needed.

**Alternative rejected:** Calling completion per image creates separate messages. Posting text before or after upload duplicates the comment. The old upload API and external image links are not the approved delivery mechanism.

### Reuse failures and restart uploads on retry

API methods retain shared `Client#request` classification. Raw upload uses existing rate-limit handling, then HTTP status only: successful statuses accept any body, server errors/transport failures are transient, and other unsuccessful statuses drop. The existing "Permanent failures do not leak secrets" requirement applies to upload requests too.

Let existing job handlers reschedule/drop API failures without a text substitute. Every retry rechecks settings/attachment availability, acquires fresh URLs, and resends all deliverable images; no upload state is persisted. Retain current retry counts and delays.

**Alternative rejected:** Resuming partial state, deduplicating uncertain completions, or custom retry budgets exceeds the approved scope.

### Reuse the guarded test harness and existing setup documentation

Expand `SlackSmokeTransport` only for the named APIs and an explicitly synthetic upload URL; capture request encoding, bytes, headers, order, and completion JSON while preserving existing guards/restoration. Fully test new raw-upload status handling, but test only a success and representative shared-path failure for each upload API method. Cover whole-sequence retry/no-substitute behavior once rather than repeating existing classification, cancellation, or rollback suites.

Make a single README update: add `files:write` with scope-change reinstallation guidance and a short paragraph covering same-journal/inline image attachments, markup removal only in Slack, missing images skipped at delivery, and possible duplicates on retry. Leave other documentation unchanged.

## Risks / Trade-offs

- [Retry after uncertain completion can duplicate a message] → Accepted existing delivery trade-off; no exactly-once guarantee.
- [Each image must fit in a binary buffer] → Sequential reads bound memory to the current file rather than the entire comment's image set.
- [Completion lacks unfurl controls] → The approved spike supplies evidence for the required no-preview behavior, not an unsupported request flag.

## Migration Plan

Use the existing release process after stubbed acceptance and review, with any deployment/live verification separately authorized; this operator's app already has the required scope and was reinstalled.

Rollback to the previous plugin makes pending image envelopes post composed text only because it ignores the extra key; already stripped markup is not restored, and Redmine data is unchanged.

## Sources and numeric provenance

- Approved requirements and live spike: `/home/andre/projects/redmine/tickets/slack-comment-image-uploads/requirements.md`; supplemental final decisions: sibling `02-propose.prompt.md` and `02-propose-review1.prompt.md`. These establish combined-message shape, the external upload sequence, same-journal plus inline scope, delivery-time file reads, absence of fixed caps, whole-sequence retries, and the simplified coverage/documentation scope. The single combined message and single completion per attempt are required behavior, not a guessed Slack limit.
- Existing implementation: `lib/redmine_slack/listener.rb`, `lib/redmine_slack/client.rb`, `app/jobs/redmine_slack/delivery_job.rb`, `test/redmine7_smoke.rb`, and `README.md` in this plugin. Retain their current retry/timeout settings rather than adding new numeric configuration.
- Redmine checkout: `/home/andre/projects/redmine/app/app/models/journal.rb` (`attachments`), `/home/andre/projects/redmine/app/app/models/attachment.rb` (`image?`, `latest_attach`), and `/home/andre/projects/redmine/app/lib/redmine/wiki_formatting/inline_attachments_scrubber.rb` (filename decoding/matching). Line references in the task are source locations, not configuration values.
- Supplied Slack documentation, not fetched during this proposal: [external upload completion](https://docs.slack.dev/reference/methods/files.completeUploadExternal) and [working with files](https://docs.slack.dev/messaging/working-with-files). The approved spike supplies the observed raw upload success, form acquisition, customization, asynchronous share metadata, and no-preview results. No maximum file count was verified or assumed.
- The smoke command in [tasks.md](tasks.md) comes from the archived `migrate-to-slack-app/tasks.md`; its filename identifies the existing harness, not a new version constraint. Task/section numbering and literal syntax examples are identifiers, not tunable numeric values.
