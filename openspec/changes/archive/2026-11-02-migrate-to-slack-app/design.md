# Design

## Context

See [proposal.md](proposal.md) for motivation and capability boundaries. The source of operator decisions is [requirements.md](../../../../../tickets/slack-app-integration/requirements.md), as refined by the final [review decisions](../../../../../tickets/slack-app-integration/02-propose-slack-review1.prompt.md); the relevant port history is [plugin-migration.md, section 8](../../../../../docs/plugin-migration.md#8-redmine_slack).

The existing `SlackListener` already centralizes sends in `speak`, separates per-issue before/after-save state, and builds recipient-specific reminder lists before delivery. Settings, project custom values, and user preferences are the only plugin-owned data. The inspected background-jobs checkout is still at its current API; the supplied minimum-version/hook contract is a planned prerequisite, not an already implemented capability.

## Goals / Non-Goals

**Goals:** Keep the workflow methods responsible for their existing decisions, put only Slack addressing and HTTP in the job, and make the conversion reviewable without sending messages. Express the complete acceptance contract as added specs because the main spec directory is empty.

**Non-Goals:** No replacement notification engine, additional queue infrastructure, cache service, persistent identity table, schema migration, dependency gem, or scheduler internals in this plugin. Implementation and runtime verification are outside this proposal-writing operation.

## Decisions

### Configuration and credential boundary

Use setting key `bot_token`, replacing the Slack URL control, with a narrowly scoped, idempotently prepended `SettingsController` patch matching only `redmine_slack`. Reuse the GitHub plugin's blank-or-omitted preservation, always-empty password control, Configured / Not configured indicator, and `filter_parameters` registration; unlike a prefilled field, this does not disclose the credential in HTML or erase it when other settings are saved.

Only a nonblank submitted token replaces the stored value; keep the existing delivery and post-updates switch semantics and other displayed settings. A missing token prevents enqueueing and is also handled safely if a previously queued job encounters it; neither the stored `slack_url` nor a project `Slack URL` field is consulted as a fallback, because one bot identity now owns all destinations. Legacy keys, if present, are ignored rather than requiring a data migration.

Install a workspace Slack app with exactly `chat:write`, `chat:write.customize`, `users:read.email`, `im:write`, and `groups:read`; the last scope is used only by conversion. The private-channel model does not require `chat:write.public`, channel history, events, an inbound endpoint, or Slack username enumeration [S-post, S-lookup, S-open, S-list].

### Request composition and serializable job arguments

Retain event detection, channel selection, issue/revision URLs, existing message wording and attachments, configured username/icon, per-event icon override, before-save state, and reminder queries in the request/hook. Passing a live Issue or asking the job to reconstruct a journal/reminder list is rejected: later state and a different `User.current` would change the existing notifications.

Introduce a small message-template helper in `lib/redmine_slack/` so trusted mention placeholders are typed fragments, not replaceable magic strings in user input. A delivery argument is a string-keyed hash of ordinary ActiveJob-serializable values:

```ruby
{
  'destination' => {'kind' => 'channel', 'id' => channel_id},
  # A DM instead uses {'kind' => 'user', 'user_id' => recipient.id}.
  'text_parts' => [
    {'redmine_user_id' => assignee.id, 'fallback' => assignee.name},
    ', it is your turn now!'
  ],
  'attachments' => prepared_attachments,
  'username' => configured_username,
  'icon_url' => configured_icon_url,
  'icon_emoji' => effective_icon_emoji
}
```

The strings are illustrative, not replacements for the listener's existing texts. Optional payload keys are omitted when absent, as in the existing sender; attachments remain the composed array of ordinary hashes, including the existing empty attachment objects in reminders. A user reference is an integer ID, not a login, Slack preference snapshot, email, or serialized User; no credential or webhook URL enters job arguments.

The exact mention placeholder format is a hash with `redmine_user_id` and `fallback` inside `text_parts`. At execution, join string fragments unchanged and render only these hash fragments as `<@member_id>` or the Slack-escaped fallback name; literal text resembling a hash or placeholder stays literal. Existing attachment content has no generated mention slots and is not rescanned, so there is no accidental mention discovery in issue descriptions, links, or attachments.

Replace the workflow-generated `@channel:` prefix with `<!channel>` while leaving the rest of each alert unchanged [S-format]. Do not globally rewrite user-entered `@channel` text and do not send `link_names`.

For comments, use one shared boundary-aware login tokenizer for explicit mentions, client-mention routing, and duplicate suppression by Redmine user ID. It recognizes the existing ASCII login token characters (letters/digits initially; then letters/digits, underscore, dot, or hyphen), requires start-of-text or a non-word character immediately before `@`, and emits a typed slot only for an existing `User.find_by_login` match; this boundary keeps email addresses intact without a separate email-span pass. This replaces Slack-name comparisons, which are meaningless before deferred resolution, while leaving unknown handles unchanged.

### Transactional enqueue and queue ownership

Make `speak` a guarded `RedmineSlack::DeliveryJob.perform_later(envelope)` boundary: one composed message becomes one job, with no HTTP or `ActiveRecord.after_all_transactions_commit` callback. The class inherits `ActiveJob::Base`, sets `queue_as :slack` and `self.enqueue_after_transaction_commit = false`, and leaves priorities at their shared default; jobs enqueued within Redmine's existing edit transaction are discarded when that transaction rolls back [G-enqueue, R-enqueue].

Redmine's edit controller already wraps both hooks in `Issue.transaction` (`app/app/controllers/issues_controller.rb:668–698`), so no new transaction boundary is needed. Its creation hook follows the committed `@issue.save` (`:151–159`), and the changeset listener proceeds only after `issue.save` succeeds; both enqueue normally at those existing points, without a controller around-action or a new changeset transaction. Verify edit rollback with one persisted-job test using a nonexecuting GoodJob adapter rather than extending atomicity beyond the edit path [review decision 1].

Declare `requires_redmine_plugin :'00_gorbunovstudio_background_jobs', version_or_higher: '1.1.0'` in registration and call `GorbunovStudioBackgroundJobs.dedicated_queue :slack, threads: 1` from `init.rb`. This is the whole Slack-side queue configuration: the fixed background-jobs contract owns allocation from its existing thread budget, general-worker exclusion, startup validation, and scheduler initialization; this change does not set a GoodJob queue string or pool size.

Use the single dedicated worker and GoodJob's existing creation-order dequeue default for ordinary FIFO [G-order; operator decision 19]. No separate concurrency limiter or sleep-based posting throttle is added; a delayed retry can be overtaken, as explicitly accepted, and Slack supplies rate-limit waits.

At the start of every execution, including retries, call `Setting.check_cache` and take a fresh settings snapshot before looking up users, touching addressing caches, or making HTTP calls. This uses Redmine's existing cross-process setting invalidation (`app/app/models/setting.rb:306–319`) and makes the execution-time delivery switch effective outside an HTTP request; off means discard without Slack calls, not postpone until it is re-enabled.

### Member and DM resolution

Load referenced users with `User.find_by(id:)`, not an active-only query, to preserve existing role/account choices, including the port history's locked tester. Prefer a trimmed stored value matching `\A[UW][A-Z0-9]+\z`; otherwise use the user's current primary Redmine email in `users.lookupByEmail`, not a Slack display-name or username search [S-format, S-lookup].

A missing Redmine user, missing email, or `users_not_found` result is an unresolved identity. An unresolved mention uses its request-time fallback name with Slack control-character escaping; an unresolved DM is skipped with a safe local reason code, without modifying any preference. Permanent API failures such as `invalid_auth` are message failures, not identity misses; their handling is in the table below.

For a resolved DM member, call `conversations.open` with that single ID in `users`, then post to the returned `D…` ID [S-open]. Sending to a member ID is rejected because customization would put the message in the Slack system user's DM rather than the app's DM [S-post, “Sending messages as other entities”].

### Cache contract and production suitability

Use explicit `Rails.cache.read` / success-only `write(..., expires_in: 24.hours)` for these keys; the duration is operator decision 9, not a calculated rate-limit precaution:

| Purpose | Logical key array | Stored value |
| --- | --- | --- |
| Successful email lookup | `['redmine_slack', 'member', user.id]` | Returned member ID |
| Opened DM | `['redmine_slack', 'dm', member_id]` | Returned DM channel ID |

One workspace and one token are in scope, so user and member keys are sufficient; an email change can reuse that person's cached member ID until the 24-hour expiry [review decision 3]. Explicit member preferences bypass the member cache, while email fallback first reuses that user's successful cache result and otherwise looks up the current Redmine email. Do not cache misses, exceptions, or failed DM opens and do not rewrite preferences after a lookup. The documented Tier 3 allowance for email lookup is 50+ calls/minute [S-lookup, S-rate]; occasional uncached misses are the operator's chosen trade-off.

The checked production config uses `ActiveSupport::Cache::FileStore` at `Rails.root/tmp/cache`: Redmine's `config/environments/production.rb:17–19,42–43` enables caching and leaves its alternative store commented out; `config/application.rb:84–90` calls the file store the default and configures a separate memory store only for search. No active override or `additional_environment.rb` exists in the inspected config tree; Rails' pinned default supplies the path [R-cache-default]. FileStore performs direct file reads and atomic writes [R-file-store], so the in-process GoodJob thread uses it without an HTTP request and without writing beneath the read-only plugin mount. This is source verification of configuration and thread suitability, not a production runtime probe; no separate thread test is required [review decision 7].

### HTTP boundary and error classification

Add `RedmineSlack::Client` using the existing HTTPClient dependency, default certificate roots, and the current five-second connect/send/receive timeouts (`lib/redmine_slack/listener.rb:279–284`). Reuse the GitHub client's fixed-origin endpoint construction, JSON/Bearer convention, and safe typed-error approach rather than copying its unrelated token-generation code or adding another HTTP gem.

All calls go to `https://slack.com/api/`; write methods send a JSON body with `Content-Type: application/json` and `Authorization: Bearer <bot_token>`, and GET lookups/list calls put only their method arguments in the query. `chat.postMessage` receives the rendered text, destination ID, attachments, and composed customization; the event emoji keeps its existing precedence over the configured icon. Success is JSON boolean `ok: true`, not the HTTP status alone [S-post].

Use these five classifications for delivery-time methods [review decision 4]:

| Observation | Classification | Job outcome |
| --- | --- | --- |
| JSON boolean `ok: true` | Success | Continue resolution or finish delivery, using returned IDs without additional response-ID prefix validation; never log the returned message body. |
| HTTP 429 or JSON `error: ratelimited` | Rate limited | `rescue_from` the safe rate-limit error and `retry_job wait: error.wait` using `Retry-After`, preserving queue and arguments; if the header is absent or unusable, use the transient policy. No worker sleep or invented cooldown/ceiling [S-rate, operator decision 20]. |
| Network/IO/socket/TLS errors or timeouts; HTTP 5xx; JSON `internal_error` or `service_unavailable` | Transient | `retry_on RedmineSlack::TransientError` without wait/attempt overrides: five total transient attempts, three seconds apart [R-retry, B-readme]. On exhaustion log a safe classification and complete without another retry. |
| Parsed `users.lookupByEmail` response with `ok: false` and `users_not_found` | Identity miss | No cache write; use mention fallback, or skip the unresolved recipient's DM. |
| Everything else, including `invalid_auth`, `missing_scope`, `channel_not_found`, `not_in_channel`, `is_archived`, `messages_tab_disabled`, or an unlisted error | Drop | Log only the sanitized error code or HTTP status, with no body, headers, token, or exception message; do not retry. |

The identity-miss exception applies only to `users_not_found` from `users.lookupByEmail`, because it needs the mandated plain-name fallback rather than dropping the message. There is no separate malformed-success class or extra response-ID validation; anything outside the first four classes follows the drop row.

Use typed errors with code-only messages (sanitize API codes to identifier characters) so framework retry logs cannot leak HTTPClient exception text, request headers, emails, or the credential. Set `self.log_arguments = false` on the job and log unresolved-recipient skips with a local reason, not email or message content. Do not rescue arbitrary programming errors into retries. A timeout after Slack accepted a post can duplicate it on retry; this is explicitly accepted rather than adding a deduplication store [operator decision 20].

### Private-channel routing and conversion

Keep the existing `channel_for_project` / `support_channel_for_project` recursion exactly, changing only each method's final validity check from a leading `#` to a `C…` / `G…` channel ID. Main selection is project main, parent method result, then default; support selection is project support, parent support-method result, then the project's main-method result. The final validity check happens within each recursive call: an ancestor's disabled/invalid value returns nil and the child can fall through as it does today, while a project's own nonblank `-`, `#name`, or invalid value still suppresses that project's route. A parent's valid support result can already include its main/default fallback and still precedes the child's main route [review decision 2].

Only `C…` / `G…` channel IDs enter channel delivery envelopes, and the bot must be invited to the private conversation [S-post]. Keep the workflow's support selection and accepted-story main override unchanged; no send-time name API is introduced.

Provide `redmine_slack:convert_channels`, dry run unless explicitly invoked with `APPLY=1`. It reads the default `channel` and every stored project custom value for the two named fields, including inactive/archived projects; it does not materialize inherited values or touch user preferences, webhook keys, or unrelated custom fields.

Fetch `conversations.list(types: 'private_channel', limit: 100)` with the configured token, following `response_metadata.next_cursor` until blank even when an intermediate page is empty. The page size is Slack's documented default, not a new tuning value [S-list]. Include archived conversations as the API does by default; listing remains metadata-only and works while delivery is off.

After collecting all pages successfully, map each stored `#name` by exact current `name` without `#`. Print one line per configured location containing the setting key or project ID/identifier and field name, original value, proposed ID or unresolved reason, and planned/applied/unchanged status; report repeated names at every location. Blank, `-`, and already-ID values remain unchanged; report other invalid values without rewriting them. A name the bot cannot see is reported as unresolved (not invited or renamed), not guessed from another workspace or historical names.

Dry run performs no persistent writes. Apply rewrites only resolved stored names, retaining unresolved/invalid values and merging only `channel` into plugin settings; use one database transaction after enumeration so API failure cannot leave a half-enumerated conversion. The operator performs this one-time conversion without lock-and-compare concurrency machinery [review decision 5]. Summarize matched, unresolved, invalid, unchanged, and applied locations; return a non-success result when anything is unresolved or invalid, while allowing resolved locations to be converted. An API failure aborts before all writes with only a safe code/status; rate-limit output can include its documented `Retry-After` wait for a later rerun. Rerunning is idempotent because IDs are never reconverted.

## Risks / Trade-offs

- [Wrong or inaccessible private destination] → Reject names during delivery, invite the app before conversion, and report every unresolved stored location; preserve existing per-call disabled/invalid handling and recursive nil fallbacks.
- [Deferred execution changes data] → Snapshot message content and routes; resolve only current user identity and the execution-time token/switch in the worker. Reminder queries and issue-state decisions never move to the worker.
- [Accepted post times out] → Permit duplicates under the fixed retry policy; do not add storage or unsupported exactly-once claims.
- [Cache is local to a container filesystem] → Treat it as a disposable optimization; a restart/cold filesystem merely causes fresh lookups, and cache misses never rewrite authoritative preferences.
- [An email changes before cache expiry] → Accept reusing that person's member ID for up to 24 hours under the single-workspace/token scope [review decision 3].
- [Settings cache is normally request-checked] → Explicitly use Redmine's existing invalidation before every execution, including retries, instead of caching the delivery switch in the job arguments.
- [Async tests start real workers or leak settings] → Retain the existing local-host/start-disabled guards, use the ActiveJob test adapter for most tests and a nonexecuting GoodJob adapter only for transaction integration, stub all HTTP verbs, and restore adapters/cache/settings/current-user state.

## Migration Plan

The README will give this order as operator actions, not development automation:

- Create/install the Slack app with the declared scopes; enable App Home's Messages Tab (replies can remain disabled) and communicate its notification/customization behaviour [S-post].
- Invite the bot into every configured private main/support/default channel. Install the background-jobs hook release before this dependent plugin and restart through the existing deployment procedure; keep Slack delivery disabled and enter the token through its empty secret field.
- From the Redmine application root run `RAILS_ENV=production bundle exec rake redmine_slack:convert_channels`, review each location and resolve invisible/renamed channels, then run `RAILS_ENV=production APPLY=1 bundle exec rake redmine_slack:convert_channels` and rerun the dry run to confirm ID-only routing. These commands are documented, not executed by this planning task.
- Obtain separate approval for the exact live-test destination, recipient, and text. Only in that approved window, temporarily enable delivery for the controlled test and disable it afterward; verify channel routing, customization, explicit mentions, and the app's DM rather than Slackbot. Development uses stubs only.
- Enable ordinary delivery only after the approved test passes; retain the independent post-updates setting. Keep the switch off on local/maintenance copies, including restored databases.

Rollback starts by disabling delivery and letting queued jobs consume that state while their class remains available. Retain the recorded conversion output so stored channels can be restored if an operator explicitly rolls back the plugin; restoring `#name` alone does not restore legacy webhook capabilities. Do not remove the job class while work remains, silently re-enable webhook delivery, or delete existing preferences/custom fields/GoodJob tables.

## Sources and numeric provenance

All durations, retry counts, page sizes, worker counts, and version bounds above come from these sources; no additional safety ceilings, miss TTLs, message truncations, or pacing intervals are introduced. Existing workflow constants, the assigned-list limit, description truncation, and avatar sizing remain at their values in `lib/redmine_slack/listener.rb` rather than being retuned.

- **Operator**: [requirements.md](../../../../../tickets/slack-app-integration/requirements.md), especially decisions 9 and 16–24, as refined by the final [review decisions](../../../../../tickets/slack-app-integration/02-propose-slack-review1.prompt.md); the fixed hook/minimum-version contract is in [the task](../../../../../tickets/slack-app-integration/02-propose-slack.prompt.md#contract-fixed-for-the-background-jobs-change-designed-in-parallel).
- **B-readme**: [background-jobs README](../../../../redmine-gorbunovstudio-background-jobs/README.md), retry defaults and existing runtime/pool prerequisites. Thread-budget internals stay there.
- **G-enqueue**: [GoodJob configuration](../../../../../tickets/gorbunovstudio-background-jobs/good_job-src/lib/good_job/configuration.rb), default enqueue-after-commit and its resolver; [adapter](../../../../../tickets/gorbunovstudio-background-jobs/good_job-src/lib/good_job/adapter.rb), `enqueue_at`.
- **G-order**: Same configuration's `dequeue_query_sort`, and [GoodJob job scopes](../../../../../tickets/gorbunovstudio-background-jobs/good_job-src/app/models/good_job/job.rb), `creation_ordered` / `dequeueing_ordered`.
- **S-post**: https://docs.slack.dev/reference/methods/chat.postMessage/
- **S-lookup**: https://docs.slack.dev/reference/methods/users.lookupByEmail/
- **S-open**: https://docs.slack.dev/reference/methods/conversations.open/
- **S-list**: https://docs.slack.dev/reference/methods/conversations.list/
- **S-rate**: https://docs.slack.dev/apis/web-api/rate-limits/
- **S-format**: https://docs.slack.dev/messaging/formatting-message-text/
- **R-cache-default**: https://github.com/rails/rails/blob/v8.1.4/railties/lib/rails/application/configuration.rb (`@cache_store`), checked alongside [Redmine production config](../../../../../app/config/environments/production.rb) and [application config](../../../../../app/config/application.rb).
- **R-file-store**: https://github.com/rails/rails/blob/v8.1.4/activesupport/lib/active_support/cache/file_store.rb (`read_serialized_entry` / `write_serialized_entry`).
- **R-retry**: https://github.com/rails/rails/blob/v8.1.4/activejob/lib/active_job/exceptions.rb (`retry_on` defaults and `retry_job`).
- **R-enqueue**: https://github.com/rails/rails/blob/v8.1.4/activejob/lib/active_job/enqueue_after_transaction_commit.rb.
