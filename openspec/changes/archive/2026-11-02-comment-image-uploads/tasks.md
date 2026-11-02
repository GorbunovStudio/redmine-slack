# Tasks

These boxes describe future implementation work; none is performed by this proposal. Follow [design.md](design.md) and the linked capability deltas. Keep development HTTP fully stubbed. The existing retry/timeout configuration remains unchanged; provenance and the reason for no fixed upload caps are recorded in the design.

## 1. Extend the isolated transport harness

- [x] 1.1 Extend `SlackSmokeTransport` in `test/redmine7_smoke.rb` to capture the named upload APIs and an explicitly synthetic upload URL, including form bodies, binary bodies, headers, and queued responses; verify these fixture requests are captured and unexpected API/upload destinations still raise locally without network access. Preserve existing disabled-startup, database-host, rollback, and settings/cache/adapter/current-user restoration guards.

## 2. Implement upload client request shapes

- [x] 2.1 Add form-encoded `files.getUploadURLExternal`, raw binary upload, and JSON `files.completeUploadExternal` methods to `lib/redmine_slack/client.rb` using the existing HTTPClient instance/configuration and shared API response classification. Test a success for each Slack API method, asserting filename/actual byte length, combined file-ID array, JSON encoding, and Bearer authorization; assert the raw request has exact bytes and no Bearer header. Verify “Upload images with customized comment text” request shapes in [app delivery](specs/slack-app-delivery/spec.md). Failure/status coverage is consolidated in task 4.3.

## 3. Collect comment images and serialize attachment references

- [x] 3.1 Add small formatter-specific image extraction/stripping logic to the listener or existing plugin namespace; verify CommonMark and Textile syntax under their matching setting, local filename decoding, Redmine latest-attachment resolution including case-insensitive duplicate names, missing/non-image targets, and external schemes. Assert the other formatter's syntax is not independently interpreted and external references cause no fetch. Cover all inline-selection scenarios in [workflow notifications](specs/slack-workflow-notifications/spec.md).
- [x] 3.2 After `prepare_comment_message`'s existing eligibility guard, combine image additions from `journal.attachments` with resolved inline images and deduplicate IDs; verify mixed additions/removals/non-images, unrelated issue attachments, and repeated inline references to a same-journal addition. Cover “Same-journal additions select only images” and “Duplicate and unresolvable references”.
- [x] 3.3 Feed a cleaned copy of notes into existing text/mention composition, return image IDs with the comment result, and extend only that `notify_issue_update` / `speak` call path with an optional image-ID argument and distinct envelope key. Verify “Remove image markup without changing the note”, “Image-only note remains a comment”, and “Producer queues references without reading file content”; assert the original note is unchanged and the envelope contains IDs but no bytes, paths, URLs, filenames added as image metadata, upload state, or credentials.
- [x] 3.4 Add comment privacy and eligibility assertions for private notes with same-journal/inline images and blank attachment-only edits. Assert no image IDs reach any non-comment job and no file bytes or HTTP are read during producer processing. Verify “Private note accompanies another change” and “Attachment-only edit remains quiet”; retain existing silent-update, delivery/post-updates gate, before-save side-effect, client routing, mention deduplication, event wording, and broadcast tests without adding duplicate scenarios.

## 4. Deliver combined image comments and preserve failure handling

- [x] 4.1 Extend `DeliveryJob#perform` after existing settings and destination resolution to load attachments from envelope IDs, recheck `image?`, read binary bytes sequentially from `diskfile`, and skip only missing records/local read failures. Add tests for deleted, unreadable, changed-to-non-image, and mixed available/unavailable attachments; verify “Some attachments become unavailable” and “No deliverable images remain” with old/empty envelopes and all-skipped lists. Assert fallback preserves customization and unfurl flags and that Slack transport errors are not swallowed by file-read rescue.
- [x] 4.2 For remaining images, acquire/upload each file and issue a combined completion with resolved destination, rendered text as `initial_comment`, username and selected icon; verify “Upload images with customized comment text”. Assert issue link/quote/mentions survive, completion follows the combined-message success rule, unsupported completion fields are absent, and no separate text post occurs.
- [x] 4.3 Reuse shared API error classification and existing job handlers; add one representative failure for each Slack API upload method rather than per-stage error-class tables. Fully test new raw-upload handling: successful status with a non-JSON body, rate limiting with usable/unusable headers, server-error statuses, transport failures, and other unsuccessful statuses. Verify the three upload-failure scenarios once: rate-limit rescheduling restarts URL acquisition and all still-deliverable uploads after partial progress; transient/permanent API failures use existing retry/drop behavior without a text-only substitute; raw responses use HTTP status rather than Slack JSON. Retain existing classification/logging/exhaustion/accepted-timeout tests and numeric policies instead of duplicating them; assert no upload state is persisted.
- [x] 4.4 Retain text-only channel/DM customization, legacy endpoint suppression, and Slack JSON rejection tests; verify their assertions continue to pass with the upload branch present, relying on existing cancellation and transaction/rollback coverage without new image-specific retests.
- [x] 4.5 Make the single README update: add `files:write` to the scope list with a note that scope changes require app reinstallation, and add a short paragraph on same-journal/inline image attachments, markup stripped in the Slack copy, missing images skipped at delivery, and possible duplicates on retry. Verify both documentation scenarios in [app delivery](specs/slack-app-delivery/spec.md); leave other README content unchanged and add no operator-specific scope exemption, migration, cap, polling, or asynchronous-sharing discussion.

## 5. Integration acceptance

- [x] 5.1 Run the complete guarded HTTP-stubbed smoke suite using the supplied command below and retain full output and exit status; verify all mapped scenarios and existing workflow regressions pass, no unexpected request reaches the network, and fixture/settings/adapter/cache/current-user state is restored. This command is implementation verification only, not part of proposal creation.
- [x] 5.2 Run `openspec validate comment-image-uploads --strict` from the plugin repository and retain full output and exit status; verify the artifacts match the implemented behavior and that no new settings, storage, services, dependencies, migrations, upload caps, retry constants, or non-comment upload paths were introduced.

Existing harness command, sourced from the archived migration tasks:

```sh
cd /home/andre/projects/redmine/docker
docker compose exec -T app bundle exec ruby -r ./config/environment.rb plugins/redmine_slack/test/redmine7_smoke.rb
```

### Scenario coverage map

Every scenario under the requirement named below must have an assertion or, for README requirements, a documented verification. Existing tests can provide retained regression coverage.

| Capability requirement | Test-bearing tasks |
| --- | --- |
| Workflow: Preserve event selection and message content | 3.4, 4.4, 5.1 |
| Workflow: Private note text never enters queued messages | 3.4 |
| Workflow: Comment images come from journal additions and inline references | 3.1, 3.2 |
| Workflow: Slack comment text omits inline image markup | 3.3, 3.4 |
| Workflow: Comment image collection does not bypass comment eligibility | 3.3, 3.4 |
| App delivery: Customized JSON Web API posts | 4.1, 4.4 |
| App delivery: Documented app prerequisites and gated rollout | 4.5 |
| App delivery: Comment images share the rendered comment message | 2.1, 4.2 |
| App delivery: Attachment bytes are resolved only during delivery | 3.3, 4.1 |
| App delivery: Upload stages reuse existing delivery failure policy | 4.3 |

## Workflow follow-up

- Review artifacts before implementation; this proposal does not authorize applying the change.
- Deployment, scope changes for any other installation, and any live Slack verification require separate authorization; no Docker, database, network, or Slack calls are part of proposal creation.
- Archive only after implementation, stubbed acceptance, and review are complete.
