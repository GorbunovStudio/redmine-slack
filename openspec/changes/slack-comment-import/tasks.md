# Tasks

These are implementation-stage tasks, not authorization to execute them during proposal writing. Acceptance is defined by the delta specs; commands and operational constants come from the approved requirements and [design sources](design.md#sources-and-numeric-provenance), not task numbering.

## 1. Signed ingress and configuration

- [ ] 1.1 Add the inbound defaults/filter entry in `init.rb` and extend `lib/redmine_slack_settings_patch.rb` plus `app/views/settings/_slack_settings.html.erb`; extend settings smoke tests to verify the import-off default, active-user options, secret replacement/blank-or-omitted preservation, empty rendering/status, log filtering, and unchanged outbound controls.
- [ ] 1.2 Add `config/routes.rb` and the event controller following the inspected GitHub pattern; add request tests for raw-body signatures, replay rejection in both time directions, missing secret/headers, unauthenticated/CSRF-free valid callbacks, and challenge responses while import is off, asserting rejected requests enqueue nothing.
- [ ] 1.3 Add `RedmineSlack::EventJob` with current-setting checks, existing queue/error handlers, and argument logging disabled; add tests asserting callback-only enqueue/acknowledgement without issue reads or HTTP, repeated callbacks enqueue again, disabled/missing configuration discards queued work, and inbound works independently of outbound delivery.
- [ ] 1.4 Update the README app/settings sections with the exact request URL, signing/challenge setup, subscriptions, added scopes/reinstallation, and inbound settings; verify it distinguishes outbound-only replies-disabled guidance from app-DM usage and does not change existing outbound prerequisites.

## 2. Message interpretation and issue previews

- [ ] 2.1 Add `InboundMessage` reference parsing and marker selection, and expose the existing Slack escape implementation for reuse; add tests for ordered/deduplicated number references, configured-host/protocol URLs with query/anchor and Slack wrappers, unrelated URLs, first-marker selection, and marker-target preview exclusion.
- [ ] 2.2 Implement event filtering and combined preview composition/posting; add smoke tests for human plain/file-share messages, top-level versus thread placement, all required issue fields including full escaped description, import-user visibility/missing-issue skips, configured customization/unfurl flags, and no previews for bot/unsupported/change/delete events or excluded conversation types.
- [ ] 2.3 Extend the existing client for `conversations.history` and the smoke endpoint allow-list for that method; add exact-parent request/response tests and thread-routing tests covering text before attachment titles/text, bot-notification parents, no reference, and explicit-marker precedence without an unnecessary parent lookup.

## 3. Identity, journal creation, and durable links

- [ ] 3.1 Add the link model and plugin migration with the approved columns and composite unique index; verify migration application in the local test environment and test a journal-less deletion row, without extra event/history tables.
- [ ] 3.2 Extend the client for `users.info`, reverse member resolution, and its stub allow-list; add tests for preference precedence, active case-insensitive email fallback, success-only caching with the inherited expiry, uncached misses/failures, Slack display-name retrieval, and unchanged preferences/outbound resolver behavior.
- [ ] 3.3 Implement narrow text conversion and quote separation; add tests for entities, linked/unlinked member mentions, labeled/bare links, named channel/broadcast references, unchanged other formatting, and quoted blocks with and without an existing blank separator.
- [ ] 3.4 Add model-based comment creation in `CommentImporter` with author selection, fallback attribution, and transaction-bound link creation; add tests for linked authors, denied linked-user fallback, import-user project membership/visibility/note permission failures, safe skip logs/no Slack feedback, duplicate events, unique-index collisions, and failed-save rollback of both link and journal.
- [ ] 3.5 Update the README import-user and migration sections; verify they explain creation of an active user, project membership, issue-view/add-notes and attachment access, and the new plugin migration instead of retaining the old no-table statement.

## 4. Files in the imported journal

- [ ] 4.1 Add private-file download support to the existing client using in-memory binary (`ASCII-8BIT`) Strings, Bearer authentication, the preferred/fallback URL fields, and the exact permitted origin, skipping reported sizes above runtime `Setting.attachment_max_size.to_i.kilobytes` before downloading; extend stubs only for explicit synthetic file URLs and test the runtime precheck and equal-limit boundary, binary encoding/bytes, auth headers, URL preference, disallowed origin/scheme, and continued rejection of unknown HTTP endpoints.
- [ ] 4.2 Pass binary Strings to `Attachment#file=` through Redmine's normal model/validation path within the import transaction and restore current-user state; add integration tests for image/non-image files in the same journal, actual byte-size/extension validation, per-file download failures, and preservation of the note and other valid files.
- [ ] 4.3 Add file-only tests for linked and fallback authors, asserting attachment journal details and required attribution without invented note text; verify no controller-hook delivery job or inserted silent marker and normal configured Redmine journal notification behavior for imported comments.

## 5. Edit and deletion synchronization

- [ ] 5.1 Implement string-backed edit watermarks with exact numeric comparison and original-journal updates; add tests for newer/equal/older edits, unchanged issue/author/attribution despite changed references, ignored changed file lists, missing journals, absent links, and no import created by an edit.
- [ ] 5.2 Implement deletion lookup by `deleted_ts`, journal rendering, and no-journal tombstones in the link transaction; test the italic dated heading, strikethrough on each nonblank prior-note line, preserved blank lines/attachments, repeated deletion, missing journal, ignored later edits, and deletion-before-import suppression.
- [ ] 5.3 Update the README cutover section and verify that enabling import is paired with disabling only Hubot's preview, thread, and `#N+=` listeners, leaving other commands/reports intact; check that documented rollback disables inbound work without deleting links or comments.

## 6. Integration acceptance

- [ ] 6.1 Add and run one end-to-end stubbed test for signed callback → job → import → edit → delete, then run the existing outbound smoke cases; completion requires both to pass.
- [ ] 6.2 From `/home/andre/projects/redmine/docker`, run `docker compose exec -T app bundle exec ruby -r ./config/environment.rb plugins/redmine_slack/test/redmine7_smoke.rb` and record the result; completion requires a passing suite with stubbed HTTP and no live Slack calls.
- [ ] 6.3 From `/home/andre/projects/redmine/plugins/redmine-slack`, run `openspec validate slack-comment-import --strict` and verify a successful exit with no validation findings.
