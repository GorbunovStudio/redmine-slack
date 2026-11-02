# Tasks

All boxes are implementation work, not actions performed while writing this proposal. Use the scenario names in the linked specs as test descriptions or comments in `test/redmine7_smoke.rb`; every row in the coverage map below must have an assertion. Numeric configuration values and their sources are centralized in [design.md](design.md#sources-and-numeric-provenance).

## 1. Dependency contract and isolated test harness

- [x] 1.1 In `init.rb`, declare the fixed background-jobs minimum version and call its dedicated Slack-queue hook exactly as designed; verify registration/hook-argument tests cover “Required hook is available” and “Dependency is too old” in [app delivery](specs/slack-app-delivery/spec.md), without implementing that plugin's internals or changing the pool budget.
- [x] 1.2 Extend the standalone harness to intercept HTTPClient GET and JSON POST, provide response status/body/headers, and fail any unexpected network request; verify a synthetic request to each allowed API is captured and an unknown request cannot reach the network. Preserve the `db` host/start-disabled guards, rollback isolation, and restoration of adapters, Rails cache, settings, and current user.
- [x] 1.3 Document the required background-jobs release, installed plugin paths, no-new-gem/schema constraint, and restart prerequisite in README; verify the dependency statements match `init.rb` and the fixed contract in the design.

## 2. Credential control and Web API client

- [x] 2.1 Add `bot_token` settings support, log filtering, the plugin-scoped SettingsController patch, and the empty password control/presence indicator in `app/views/settings/_slack_settings.html.erb`; remove the Slack URL control. Verify both “Save unrelated settings without losing the secret” variants, “Configure or replace a token”, Not configured rendering, and continued independent delivery/post-updates control behaviour with controller/form assertions.
- [x] 2.2 Add the explicitly loaded `RedmineSlack::Client` and safe typed errors in `lib/redmine_slack/`, reusing HTTPClient, existing certificate defaults/timeouts, fixed Slack API origin, JSON/Bearer writes, and GET query encoding; verify captured headers, arrays, customization keys, absent `link_names`, and `ok: true` versus `ok: false` in “Customized post succeeds” / “Successful HTTP status contains a Slack rejection”.
- [x] 2.3 Implement the design's five-row classification table: success, rate limited, transient, identity miss, and drop; verify table-driven stub responses for every row, all named dropped errors and an unlisted error, plus an exception containing synthetic token/email text that does not appear in diagnostics. Cover “Known permanent Slack rejection”, “An unlisted error is still permanent”, and “Transport exception contains sensitive text” using code-only or HTTP-status logging, without extra response-ID validation.
- [x] 2.4 Replace webhook installation instructions with app creation/installation, the exact scope list, Messages Tab with optional disabled replies, and the secret-control instructions in README; verify the scope and UI wording against the client methods and app-delivery “Operator follows the rollout documentation” scenario, citing the Slack documentation from the design.

## 3. Deferred user addressing and message templates

- [x] 3.1 Add the typed text-fragment helper and member resolver from the design, preserving string content and resolving current Redmine users/preferences and uncached emails only when invoked by delivery; verify [user addressing](specs/slack-user-addressing/spec.md) scenarios “Explicit member preference bypasses email lookup”, “Empty or legacy preference uses email”, “Identity changes while work is queued”, “Lookup cannot resolve a mention”, and “Literal placeholder-like text remains text”. Include missing users/emails, both member preference prefixes, locked users, and escaped fallback-name control characters.
- [x] 3.2 Replace comment extraction/conversion with the shared Redmine-login tokenizer requiring start-of-text or a non-word character before `@`, and user-ID duplicate tracking; verify “Known login at an eligible boundary”, “Email or embedded text is not a mention”, and “Explicit mention prevents duplicate automatic mention” using start/punctuation, dot/hyphen/underscore, email, unknown-login, and embedded-word fixtures. Use no separate email-span exclusion and check client routing uses the same recognized-user set.
- [x] 3.3 Add success-only member/DM caching with `['redmine_slack', 'member', user.id]` / `['redmine_slack', 'dm', member_id]` and the design's TTL, plus `conversations.open` for DMs; verify “Open or resume the app DM”, “Recipient cannot be resolved”, “Successful results are reused until expiry”, and “Miss does not suppress a later valid account”. Assert no negative entries, unchanged legacy preferences, no direct member-ID posting, and no cached DM from a failed open; allow reuse of the person's cached member ID after an email change until expiry.
- [x] 3.4 Keep the account/admin preference key and existing successful/failed-save behaviour, updating labels/help to explain member-ID override and Redmine-email fallback; verify “Successful account and admin saves” / “Failed update or read-only access” using the existing account PUT, admin create/update, failed update, trimming, and no-write read tests. Add matching README guidance and verify it does not promise username/display-name lookup or preference auto-rewriting.

## 4. Private-channel routing and explicit conversion

- [x] 4.1 Keep `channel_for_project` / `support_channel_for_project` recursion unchanged, replacing only each final leading-`#` check with channel-ID validity; verify [channel routing](specs/slack-channel-routing/spec.md) scenarios “Configured private conversation ID”, “Project's own nonblank invalid destination suppresses its route”, “Main field and parent fallback”, “Ancestor's invalid result permits the child's fallback”, “Support follows existing recursive precedence”, and “Root support falls back to main”. Cover IDs, own invalid suppression, ancestor nil fallbacks, and no listing calls during send preparation.
- [x] 4.2 Add `lib/tasks/redmine_slack.rake` with `redmine_slack:convert_channels`, dry-run default and explicit `APPLY=1`, using only paginated private `conversations.list` metadata; verify “Dry-run report covers every stored location”, “Explicit apply rewrites only matched names”, “Match appears after an empty intermediate page”, and “Name is invisible or renamed” with stubbed pages and transactional fixture values, including duplicate names at different locations and inactive projects.
- [x] 4.3 Implement the per-location report, summary/non-success outcomes, one write transaction after complete enumeration, and idempotent reruns; verify “Mixed resolved and unresolved values”, “Enumeration fails before completion”, and “Rerun after conversion”. Assert non-success when anything is unresolved/invalid, no apply writes on listing failure, no writes at all in dry run, no inherited-value materialization, no token in output, and no mutation of unrelated settings/preferences/custom fields; add no lock-and-compare check.
- [x] 4.4 Update settings help and README for private IDs, bot invitations, the recursive fallback and `-` semantics, exact dry-run/apply commands, unresolved-name remediation, partial conversion/non-success output, and reruns; verify every documented option and report category matches the task tests and that no send-time name resolution is described.

## 5. Background delivery and preserved workflow

- [x] 5.1 Add `app/jobs/redmine_slack/delivery_job.rb` with the designed queue, `enqueue_after_transaction_commit = false`, `log_arguments = false`, `Setting.check_cache` and a fresh settings snapshot, absent-token guard, fragment rendering, DM opening, and customized post; replace `speak`'s webhook/after-commit code with guarded envelope enqueue. Remove `url_for_project` and webhook arguments/gates from every caller, retaining issue/revision URLs. Verify “Legacy endpoint cannot be used as a fallback”, disabled/missing switch cases, no secret in arguments or argument logs, and “Disable before execution or retry” without resolution calls.
- [x] 5.2 Implement rate-limit rescheduling and default transient retries with safe exhaustion handling and no worker sleep; verify “Rate limit supplies a retry interval”, “Rate-limit header is unusable”, “A temporary failure recovers”, “Transient attempts are exhausted”, and “Accepted request times out”. Exercise lookup, open, and post stages, assert scheduled wait/queue/arguments, and prove permanent errors never retry.
- [x] 5.3 Retain enqueueing within the existing edit transaction and plain enqueue at the existing successful creation/changeset save hooks; add no controller around-action or changeset transaction wrapper. Verify “Committed edit makes messages available without producer HTTP” and “Failed save produces no notification job”; cover “Rollback discards pending edit messages” with one rollback test using a nonexecuting GoodJob adapter and actual persisted-row assertions. Leave live workers stopped and roll back all fixture changes; creation/changeset success coverage remains in 5.4 and 5.7.
- [x] 5.4 Wire the listener's generated mentions and reviewer/executor DM destinations to Redmine references, retaining event selection/texts/attachments and using explicit broadcast syntax only in generated alerts; verify [workflow](specs/slack-workflow-notifications/spec.md) scenarios “Existing workflow events still produce the same notifications”, “Broadcast alerts use explicit Slack syntax”, “Post-updates remains independent”, “Client participation selects support”, and “Acceptance returns progress to main”. Retain creation/escalation, all existing progress paths, return colors, assignment, details, URLs, thumbnail/mood, and inactive-branch suppression assertions; render fixtures through the new template helper where final text is asserted.
- [x] 5.5 Preserve before-save return/silent effects and per-issue cleanup; verify “Return flag and silent prefix are processed” while delivery is off and on, and “Issue-specific listener state does not cross edits”. Retain the existing real-controller successful/failed edit smoke cases with no network calls.
- [x] 5.6 Preserve early private-note exclusion and request-time reminder queries; verify “Private note accompanies another change”, “Ready-for-review produces recipient-specific reminders”, “Restore the editor after recipient query”, and “Saved state changes before delivery”. Assert private text absent from both job arguments and final stubbed payloads, recipient contexts restored on success/error, unchanged query/list limits and empty-list suppression, and no query rerun from the job.
- [x] 5.7 Retain reviewer-return and changeset journal behaviour; verify “Manager return alerts reviewer” and “Changeset updates a saved issue” with separate user-reference DM envelopes, expected issue attachments, native translation text, revision URLs, and the saved journal.
- [x] 5.8 Update README's delivery/control, retry/duplicate, edit-rollback versus successful-save enqueue behaviour, cold-cache, and rollout/rollback sections to match the implementation; verify the documented order is app, invitations, dry run, conversion, separately approved controlled live test, then ordinary delivery, and remove old after-commit/webhook claims. Live test execution is not part of the development task list.

## 6. Integration acceptance

- [x] 6.1 Run the complete guarded, HTTP-stubbed standalone smoke suite with the command below and retain its full result; verify existing preserved workflow/form coverage and every spec scenario in the map pass, with settings/adapters/cache/current user restored and no live messages. Do not treat the historical test/assertion counts as a fixed ceiling.
- [x] 6.2 Run `openspec validate migrate-to-slack-app --strict` from this repository and retain full output/exit status; verify no warnings/errors, all capability deltas still align with the implementation, and no new gem/table/migration or background-jobs-owned scheduler changes were introduced.

Smoke command (the supplied existing harness command; execute during implementation verification, not proposal creation):

```sh
cd /home/andre/projects/redmine/docker
docker compose exec -T app bundle exec ruby -r ./config/environment.rb plugins/redmine_slack/test/redmine7_smoke.rb
```

### Scenario coverage map

| Capability requirements (all scenarios under each) | Test-bearing tasks |
| --- | --- |
| App delivery: Bot token secret setting | 2.1 |
| App delivery: Customized JSON Web API posts | 2.2–2.3, 5.1 |
| App delivery: Edit message persistence uses the existing transaction | 5.3 |
| App delivery: Dedicated queue dependency | 1.1 |
| App delivery: Delivery can cancel queued work | 5.1 |
| App delivery: Rate limits use Slack's wait; Transient failures have bounded retries | 2.3, 5.2 |
| App delivery: Permanent failures do not leak secrets | 2.3, 5.2 |
| App delivery: Documented app prerequisites and gated rollout | 2.4, 4.4, 5.8 |
| User addressing: Resolve current Slack identity from a Redmine user; Only trusted mentions render as Slack mentions | 3.1 |
| User addressing: Recognize only existing Redmine logins in comments | 3.2 |
| User addressing: Direct messages target the app's conversation | 3.3 |
| User addressing: Cache only successful addressing results | 3.3 |
| User addressing: Preference forms and read behaviour remain compatible | 3.4 |
| Channel routing: Private-channel destinations use IDs; Preserve recursive main and support selection | 4.1 |
| Channel routing: Conversion is dry run unless explicitly applied; Enumerate only visible private channels through all pages | 4.2 |
| Channel routing: Conversion failures and reruns are auditable | 4.3 |
| Workflow: Preserve event selection and message content; Preserve client and acceptance routing | 5.4 |
| Workflow: Before-save workflow effects survive disabled delivery | 5.5 |
| Workflow: Private note text never enters queued messages; Reminder lists keep recipient context and request-time state | 5.6 |
| Workflow: Preserve reviewer DMs and changeset journal behaviour | 5.7 |

## Workflow follow-up

- Review and deploy the separately owned background-jobs hook release before deploying this dependent plugin.
- Perform production metadata reads, conversion writes, and the live test only under the applicable environment approvals; none is authorized by this development/proposal checklist.
- Archive the change only after implementation, scenario verification, and review are complete.
