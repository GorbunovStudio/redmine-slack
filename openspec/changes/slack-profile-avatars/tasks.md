# Tasks

Implementation starts only after lead review and a separate apply instruction. All boxes are intentionally unchecked in this specs-only task.

## 1. Persisted avatar state and association safety

- [ ] 1.1 Add the small avatar-cache service with explicit-member eligibility, numeric image-field selection and documented URL compatibility checks; verify focused synthetic-profile tests cover largest compatible image, invalid/query-bearing URLs, absent fields, and Slack-generated pictures without image downloads.
- [ ] 1.2 Add the four-field avatar preference state and fresh locked read/merge operations; verify tests use independent user/preference instances to prove persisted visibility, malformed-state fallback, and retention of newer unrelated preference values during worker completion.
- [ ] 1.3 Update the existing association setter to merge against current persisted preferences and invalidate only changed associations; verify trimming, same-ID cache retention, A → B/clear invalidation, legacy-value preservation, first preference creation, read-only getter behavior, and existing successful/failed account/admin form tests.
- [ ] 1.4 Document explicit-member-only avatar association, persisted URL storage, 24-hour freshness/cooldown provenance, and stale-while-refreshing behavior in README; verify the text does not imply email-matched avatars, a new setting, or image-file storage.

## 2. Transactional refresh and existing retry handling

- [ ] 2.1 Add the refresh job on the existing `slack` queue with transaction-bound enqueue, current settings/token checks, and user/member-only arguments; verify stubbed tests call only `users.info`, keep tokens out of arguments/metadata, and make no Slack calls when the token is absent without changing delivery/import switches.
- [ ] 2.2 Connect the cache service's due-refresh operation to locked deadline rechecks and the recorded unfinished GoodJob lookup; verify a nonexecuting GoodJob integration test covers concurrent/repeated requests, long delayed retries, completed/deleted job eligibility, and rollback/failed-enqueue cleanup without starting workers.
- [ ] 2.3 Guard each execution and completion by current association and job ID, merging results into fresh locked preferences; verify queued and in-flight A → B/clear changes, an A → B → A sequence, and obsolete completion/error handling cannot restore A's image or overwrite B's state.
- [ ] 2.4 Reuse existing transient retry defaults, safe permanent-error handling, and `Retry-After` rescheduling; verify stubbed rate limits, invalid headers, transient exhaustion, `missing_scope`, nil-picture success, stale-image retention on API failure, and 24-hour terminal failure suppression/expiry.
- [ ] 2.5 Document `users:read`, app reinstallation after scope changes, token-only profile-read prerequisites, and independence from notification/import enablement; verify the README does not direct operators to enable delivery/import or send a message to test avatars.

## 3. Avatar rendering and reload compatibility

- [ ] 3.1 Add and register the guarded avatar helper prepend at `gravatar_avatar_tag` for Gravatar-enabled users, retaining the core `gravatar` call; verify parsed HTML tests assert the same encoded default in `src` and 2x `srcset`, normal/doubled sizes, unchanged hash/rating/title/classes, and no forced default or render-time HTTP.
- [ ] 3.2 Add the Gravatar-disabled direct-image branch with normal image attributes and an equivalent size class; verify custom/default sizes, caller title/alt/classes, cold/stale caches, and unchanged anonymous/group/string-email/unsaved-user and initials behavior in both settings modes.
- [ ] 3.3 Extend reload coverage for the helper patch and new job and exercise additionals sizing compatibility; verify repeated reloads attach current modules once without callback growth, and helper/integration assertions retain the requested size box with the actual additionals patch where available.
- [ ] 3.4 Document deterministic-versus-live validation boundaries and the later approval-gated real-account checks; verify the evidence template includes Gravatar-present, Gravatar-absent, high-density, and Gravatar-disabled cases without asserting real CDN acceptance from fixtures or proposing a proxy/browser-probe alternative.

## 4. Integrated verification and handoff

- [ ] 4.1 Run the plugin's guarded local smoke and reload suites using the established local test procedure after implementation, with all HTTP stubbed and delivery/import settings preserved; record exact commands/output/exit statuses, and use the approved isolated scratch-DB procedure rather than bypass any guard if the existing environment is unsuitable.
- [ ] 4.2 Run `openspec validate slack-profile-avatars --type change --strict --no-interactive` and inspect the final diff; verify no schema, schedules, dependencies, new switches, core/additionals edits, notification/import behavior changes, or unrelated fixes, then save results for lead review without committing or archiving.

## Workflow follow-up

- Lead reviews the active artifacts before delegating implementation; agents do not commit. Keep the change active unless the user later requests archival.
- Production build/rollout and deployed-revision verification are separate lead-controlled work under the established Redmine deployment/safety procedure; inspect bundled worktrees for unrelated changes. Do not enable delivery/import, send messages, repair data, or change unrelated configuration.
- A later approved live-validation window must confirm actual profile permission, public image accessibility, and provider fallback at both densities for real accounts with/without Gravatar. If this fails, report the evidence and ask before changing the approved fallback mechanism; do not silently expand this task.
