# Proposal

## Why

A client discussion can start in Slack before its Redmine issue exists. Associate the discussion after issue creation so its existing messages and future replies can become issue comments without asking the client to edit the root message.

## What Changes

- Store one issue target per Slack conversation/root-message pair, allowing multiple roots per issue (D2; one-target model is the implementation-request baseline under D12).
- Provide a Slack message shortcut with issue confirmation and optional history import, plus authenticated JSON API inspection, upsert and removal (D6–D7; shortcut/history/API operation shape follows the D12 baseline).
- Authorize the invoker, independently of the message author: visibility and add-notes for management, and an additional dedicated permission for API operations; API inspection needs visibility and that permission, not add-notes (D9–D10, D15).
- Require inbound readiness for create/change; retain authorized API inspection/removal while disabled, with database-only removal and no automatic side-effect replay (D16). Outbound delivery is not a prerequisite.
- Route new replies by explicit import marker, then association, then existing parent-reference lookup. Import requested history through the current importer and message-ID deduplication; retain previous journals on change/unlink (D5–D6 and the D12 baseline).
- Indicate associations using the baseline root reaction and existing issue preview in the thread, without modifying root text or adding a footer. Preserve preview content/visibility and existing per-message import checks (D3–D4, D9–D11).
- Exclude source-channel membership authorization, extra channel-disclosure rules, issue creation, and agent-driven specification drafting (D8, D10–D11).

## Capabilities

### New Capabilities

- `slack-thread-associations`: Stored thread targets, lifecycle/actor authorization, Slack confirmation, authenticated API, requested historical imports, readiness and visible indication.

### Modified Capabilities

- `slack-comment-import`: Insert stored association routing between explicit markers and parent-reference fallback, including association-targeted root/history imports without changing import tracking or synchronization.
- `slack-app-delivery`: Amend the rollout documentation contract so `groups:read` covers association source classification as well as channel conversion, retaining existing setup and gated-live-verification guarantees.

## Impact

Source citations in this section describe the starting integration at commit `ea9f54be00032003680ca8fc4c7705fb19095193`.

- Plugin-local association model/migration, shared lifecycle/routing helpers, a signed interaction endpoint, a Redmine-authenticated API controller, existing-client extensions and queued history/indication work. Starting routing/preview are inline in `app/jobs/redmine_slack/event_job.rb:39–65`; import tracking is in `lib/redmine_slack/comment_importer.rb:11–55` and `db/migrate/001_create_redmine_slack_message_links.rb:3–9`.
- Reuse the existing identity resolver, preview composition, signature verification, importer and `slack` queue; do not change Redmine core or the background-jobs plugin. Their starting integration points are `lib/redmine_slack/member_resolver.rb:33–47`, `app/controllers/redmine_slack/events_controller.rb:6–12`, and `init.rb:25–26,44`.
- Document the new API permission, routes, migration, shortcut/interactivity setup and `commands`, `reactions:write`, `im:read` scopes. `groups:read` becomes relevant to source classification, not only conversion; existing history scopes remain required (`README.md:34–44,103–120`). Extend stubbed smoke/reload tests; no live Slack calls are part of automated validation.
