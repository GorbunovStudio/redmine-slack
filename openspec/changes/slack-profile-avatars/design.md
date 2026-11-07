# Design

## Context

See [proposal.md](proposal.md) for motivation and [the delta](specs/slack-profile-avatars/spec.md) for acceptance behavior. The approved scope is in `/home/andre/projects/redmine/tickets/slack-profile-avatars/requirements.md` and `02-propose.prompt.md`.

Observed integration points:

- Redmine `app/app/helpers/avatars_helper.rb:39–53` handles anonymous/group cases before Gravatar or initials. Its private `gravatar_avatar_tag` at lines 76–90 **overwrites** `options[:default]` with `Setting.gravatar_default`, adds the gravatar class/title, extracts email, and calls `gravatar`.
- Core `app/lib/plugins/gravatar/lib/gravatar.rb:49–57,65–79` produces both normal `src` and doubled-size `srcset`, URL-encodes the default, and removes provider options before building the image tag. Additionals `lib/additionals/patches/gravatar_patch.rb:23–29` prepends `gravatar` to add the `s<size>` box class.
- `Preference` currently supports only `:username`, backed by `user.pref[:rslack_username]`; its getter is read-only. Account/admin patches call its setter only after successful user saves. `UserPreference#others` is a serialized hash (`app/app/models/user_preference.rb:25–28,73–89`), not a separate row per setting.
- `MemberResolver` accepts trimmed `\A[UW][A-Z0-9]+\z` overrides and otherwise does email lookup. Its identity caches use `24.hours` (`lib/redmine_slack/member_resolver.rb:8–19,24–30,33–46`). Avatar association must not use that resolver's email fallback or its `Rails.cache` storage.
- `Client#user_info` already calls `users.info`; `Client` already classifies safe transient, rate-limit, and permanent errors. `DeliveryJob`/`EventJob` already select the `slack` queue, suppress argument logging, enqueue inside transactions, and use Rails default transient retries plus `Retry-After` rescheduling. `init.rb` attaches reloadable patches idempotently.

## Goals / Non-Goals

**Goals:** One narrowly guarded helper patch, one small persisted-cache service, one profile-read job, and a focused preference-setter change. Keep one authoritative database-backed refresh decision across web/worker instances, without a new cache backend.

**Non-Goals:** No core/additionals edits, general preference concurrency overhaul, generic job abstraction, additional identity resolution, workspace/token-generation tracking, image proxy, browser Gravatar probing, scheduler, or new reliability subsystem. Existing notification/import gates and retry behavior are not refactored.

## Decisions

### 1. Patch the actual user-aware helper boundary

Add `RedmineSlack::AvatarsHelperPatch` and idempotently prepend it to `AvatarsHelper` from the existing `init.rb` prepare block. Keep overridden private methods private and include the helper in reload checks.

With Gravatar enabled, intercept **`gravatar_avatar_tag(user, options)`**, not just outer `avatar` options. When no eligible cached URL is returned, call `super` untouched. For an eligible cached URL, reproduce only core's small tag-preparation branch: duplicate options, set the custom default to that URL, preserve the gravatar class/title/email normalization and caller attributes, and call the existing `gravatar`. Do not force default or alter hashing, rating, configured avatar server, or size. Let `gravatar` generate both densities and let additionals' existing prepend supply its size class. Do not copy the Gravatar URL builder or post-process HTML; either approach risks diverging between `src` and `srcset`.

With Gravatar disabled, override outer **`avatar`** only for an eligible persisted, non-anonymous `User` with a cached compatible URL. Render a normal escaped `image_tag` using the existing default alt/title conventions, caller options and requested/default size, `avatar` plus caller classes, and the `s<size>` box class. Provider-only options must not become HTML attributes. A single largest available cached source is sufficient for this direct image; no second profile fetch is needed for density. All other inputs delegate to `super`, including missing URLs, anonymous/group/string-email inputs and unsaved users. Do not change `avatar_edit_link` or general `gravatar_for` calls.

This small guarded copy is preferable to thread-local user context, a third global `gravatar` interception, or overriding the entire core avatar helper. Add helper tests against the maintained core behavior so later core changes are visible.

### 2. Define a usable picture without fetching image bytes

Use only the explicitly stored member ID with the existing resolver's trimmed pattern; never call `MemberResolver#member` for this feature. Read `users.info` profile fields matching numeric `image_<size>`, largest numeric size first, and choose the first compatible URL. Size numbers come from the response fields, not a new configured image size. Do not require `is_custom_image`: Slack-generated profile pictures are still profile pictures. Ignore arbitrary nonnumeric fields rather than treating them as another source or resizing API.

Parse URLs with the existing URI dependency: require HTTPS, host present, port 443, no userinfo, query, or fragment, and a case-insensitive path extension allowed by Gravatar (`jpg`, `jpeg`, `gif`, `png`, `heic`). Reject incompatible values, do not remove query strings or invent a new URL, and never download, mirror, or HEAD the image. Reapply this inexpensive compatibility check when using persisted URLs. Provider documentation describes public web-viewable images, but parsing alone cannot prove public accessibility or Gravatar security-scan acceptance; that is a live-validation boundary, not permission for page-render network requests.

Use the same compatibility contract with Gravatar disabled to avoid two cache policies. Successful profile retrieval with no compatible image replaces the cached URL with nil. An API failure instead retains the previous same-association URL.

### 3. Keep four cache fields in existing preferences

Keep `:rslack_username` unchanged. Add one server-owned `:rslack_avatar` hash within `UserPreference#others` with only:

- `member_id`: the explicit association for the stored image/refresh;
- `url`: the compatible image URL or nil;
- `refresh_after`: next normal render-triggered refresh time;
- `job_id`: the ActiveJob ID of the most recently requested refresh.

Use the existing `24.hours` interval for initial enqueue suppression, freshness after success (including an image miss), and cooldown after permanent/exhausted failure. This is a reuse of the existing identity-cache policy, **not** a Slack-documented avatar lifetime. No second numeric failure interval, stale-image maximum age, or in-flight timeout is introduced. Completion updates `refresh_after` to completion time plus that interval; a job not run yet retains its enqueue-time deadline.

Keep this state in a small `RedmineSlack::AvatarCache` service rather than expanding the public preference getter to perform work. Missing or malformed avatar state is treated as uncached. Avatar reads use freshly loaded persisted preference state, not an arbitrary caller's memoized `user.pref`, so an old `User` instance cannot supply a previous association's picture after a successful association change. No existing preference row or no persisted explicit association means no cache write or refresh.

### 4. Serialize only the needed preference changes and enqueue atomically

When refresh is due, lock and reload the existing preference row, then recheck the current explicit association and deadline. For that same association, also check whether the recorded `job_id` is still unfinished in the existing GoodJob persistence (`GoodJob::Job.unfinished` filtered by `active_job_id`). This covers queued, running, and delayed-retry work even beyond 24 hours without an invented lease, heartbeat, pending flag, or timeout. Completed/deleted jobs do not block a due refresh. Only consult this queue state when the normal deadline is due.

Instantiate the refresh job to obtain its existing ActiveJob ID, merge the four avatar fields into the freshly loaded preference, and enqueue in the **same database transaction**. Set `enqueue_after_transaction_commit = false`, as existing Slack jobs do. Treat an unsuccessful enqueue/expected enqueue error as failure of that transaction, so neither the marker nor GoodJob row survives; keep the existing cached/default render rather than install an orphaned claim. Unexpected programming errors are not converted into API retries.

This uses the already required GoodJob dependency, not a new uniqueness system. `GoodJob::Job.unfinished` includes future retries and has `finished_at: nil`; `active_job_id` is already stored by the installed background-jobs migration. The local pinned GoodJob source documents these scopes at `tickets/gorbunovstudio-background-jobs/good_job-src/app/models/good_job/job.rb:84–117`; the adapter persists through `Job.enqueue` (`lib/good_job/adapter.rb:178–234`). Validate the transaction with a nonexecuting GoodJob adapter, since the in-memory ActiveJob test adapter cannot prove database rollback or cross-render deduplication.

Update the existing `Preference#[]=` association path to lock/reload persisted preferences before merging its submitted trimmed username. Clear only avatar state when the normalized explicit association changes; keep the cache when the trimmed member ID is the same. Preserve all unrelated `others` values and real preference columns. For an association's first preference row, serialize creation on the existing User row; no table or uniqueness migration is needed. Keep unsaved-user assignment and successful/failed form-save behavior compatible.

Every plugin-owned avatar mutation, including worker completion, starts from a fresh locked preference record and changes only its keys; never save the worker's old whole hash or reload/discard arbitrary dirty controller preferences. Core saves unrelated preferences before the existing controller after-actions. This is protection against this feature overwriting newer unrelated values, not a global redesign of Redmine's concurrent preference writers.

### 5. Bind work to the current association and existing job identity

Queue only the Redmine user ID and expected explicit member ID. The job already carries its own `job_id`; no token, email, URL, full user, or extra generation token is needed. Before HTTP and again under the preference lock before completion, require current username/member association and stored `job_id` to match. Old work returns without API calls when already obsolete and cannot write a result, clear newer state, or extend B's deadline if the association changed in flight. The existing job ID also rejects an obsolete refresh after a newer request for the same member, including an A → B → A sequence.

On every execution/retry use `Setting.check_cache` and the current `bot_token`. No token means no HTTP. A configured token permits profile reads independently of `delivery_enabled` and `import_enabled`; those controls still guard messages/events and remain unchanged. A previously cached public image remains renderable without a token when its explicit association still matches, but no new refresh is requested.

Use `Client#user_info(expected_member_id)` and no other Slack method. Reuse `retry_on RedmineSlack::TransientError` without wait/attempt overrides, `rescue_from RedmineSlack::RateLimitError { retry_job wait: error.wait }`, and existing safe permanent-error logging. Successful retrieval saves the selected URL or nil and advances `refresh_after`. Permanent failure or exhausted transient retries advances that deadline while retaining any same-association URL; rate-limit/transient rescheduling does not release the outstanding job. Set `log_arguments = false` and log only sanitized client classifications, never response data or image URLs. Do not introduce broad exception retries or a new shared job base class.

### 6. Verification and numeric/provider provenance

- **24-hour freshness and cooldown:** existing `MemberResolver` `24.hours`, reused by design to avoid a new tuning decision. It is deliberately separate from that resolver's success-only addressing cache; the existing addressing spec remains unchanged.
- **Transient wait/count:** current `DeliveryJob`/`EventJob` `retry_on` declarations and README's Rails defaults (five total attempts, three seconds apart). Do not specify different numeric values in the new job.
- **Rate-limit wait:** existing `Client#rate_limit!` parses Slack's `Retry-After`; valid values are not capped or replaced with another constant.
- **Image/default contract:** [Gravatar image documentation](https://docs.gravatar.com/sdk/images/), “Default Image” (public HTTP(S), standard ports, recognizable extension, no query string; default only when no matching avatar). HTTPS is selected because [Slack's user object](https://docs.slack.dev/reference/objects/user-object) documents HTTPS square web-viewable `image_*` pictures.
- **Profile permission:** [users.info](https://docs.slack.dev/reference/methods/users.info) needs bot `users:read`; image retrieval does not require email or a new client method. Document reinstall after scope changes using the existing README convention.

Deterministic tests can prove eligible inputs, selection/rejection of synthetic URLs, cache persistence across fresh instances, serialization/transaction behavior, old-result rejection, HTML attributes, both encoded Gravatar defaults and size values, unchanged special inputs, argument secrecy, and stubbed client retry outcomes. Extend existing `test/redmine7_smoke.rb` and `test/reload_smoke.rb` patterns; all HTTP remains stubbed, and delivery/import state must be restored and start-disabled guards retained. A focused helper fixture can exercise the additionals prepend without modifying that plugin. Use actual installed additionals in the local integration check where available.

These tests **cannot** prove that a real Slack image is unauthenticated/public, passes Gravatar's scanner, remains reachable, or that a particular account has a registered Gravatar. Later separately approved live validation must use real associated accounts with and without Gravatar, verify normal/high-density image rendering and Gravatar-disabled behavior, and record results without tokens or sensitive URLs. Do not claim these checks passed from stubs or make live calls during specs.

## Risks / Trade-offs

- [Real profile image is incompatible or Gravatar rejects it] → Keep existing defaults for rejected candidates; report the live limitation. Do not silently implement a proxy, strip URL parameters, or adopt a browser probe. An alternative fallback mechanism would require a user-approved scope/design change.
- [Public image URL eventually stops loading] → Refresh on a later eligible render and retain ordinary provider/browser behavior. No image storage, on-error JavaScript, download verifier, or hard stale-age policy is added.
- [Request-time database work] → Fresh reads and due-refresh row locks are accepted for correct cross-process state; no network work or long-held locks around HTTP. Repeated fresh-cache renders do not mutate preferences or inspect job rows.
- [GoodJob model coupling] → Reuse its installed documented scopes, not scheduler internals; cover unfinished retry and persisted rollback in focused integration tests. A timestamp alone was rejected because a delayed retry can outlive that timestamp and permit duplicate work.
- [Concurrent legacy/core preference writers] → Plugin mutations lock/reload and merge only owned keys; broader pre-existing stale-writer races are out of scope. Verify unrelated settings saved before worker completion are retained.
- [Single configured workspace] → Match existing plugin scope. Do not add workspace switching, token fingerprints, or cache generations; a future workspace-migration feature must define its own invalidation contract.

## Migration Plan

No schema/data migration, scheduler, or new service is required. After lead review and separate implementation authorization, document `users:read`, rebuild/restart through the established Redmine release procedure, and verify the deployed revision. Do not enable delivery/import, send test messages, change production configuration, or perform a live profile check without the applicable separate approval.

New preferences appear lazily on the first eligible avatar request; until a worker completes, existing defaults render. For rollback, stop/drain outstanding avatar-refresh jobs or keep their job class available until consumed before removing the implementation. Retain existing user preferences; do not perform a production cleanup or data repair as an implicit rollback step.
