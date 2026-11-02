# Proposal

## Why

Slack issue previews and comment import still depend on Hubot even though the plugin already owns the notification app. Move those listeners into the plugin so thread replies, explicit comment markers, files, edits, and deletions work through that app, including for participants without Redmine accounts.

## What Changes

- Receive signed Slack Events API callbacks over HTTP and process them asynchronously on the existing `slack` queue.
- Add a signing-secret field, an import switch defaulting off, and an active-user selector for the Redmine import identity.
- Preview referenced, visible issues in the originating conversation, with Hubot-compatible content and thread placement.
- Import eligible messages through Redmine models with reverse identity resolution, CommonMark conversion, and validated file attachments.
- Track message-to-journal links for import idempotency and synchronization of Slack edits and deletions.
- Document app subscriptions/scopes, import-user project permissions, migrations, and the Hubot listener cutover; preserve existing outbound delivery behavior.

## Capabilities

### New Capabilities

- `slack-event-ingress`: Signed HTTP callbacks, asynchronous event eligibility, import configuration, and inbound setup.
- `slack-issue-previews`: Reference recognition and permission-filtered issue previews in Slack.
- `slack-comment-import`: Comment routing, identity and attribution, text/files, message links, and edit/deletion synchronization.

### Modified Capabilities

- `slack-app-delivery`: Extend rollout documentation for inbound use and qualify the outbound-only guidance that app replies may remain disabled.

## Impact

Implementation will touch plugin routes/controllers, `init.rb`, the settings patch/view, a new event job and local import helpers, the existing Slack client, a link model/migration, `README.md`, and `test/redmine7_smoke.rb`. It reuses the current HTTP dependency, queue, retry classification, cache, and Redmine journal/attachment APIs; no new gem, service, queue, or event-ID store is introduced.

Public channels, group DMs, person-to-person DMs, unfurls, shortcuts, backfill, edit history, and changes to Hubot code or its other commands/reports are outside scope. The approved source is `/home/andre/projects/redmine/tickets/slack-comment-import/requirements.md`; this proposal does not authorize deployment, live Slack verification, or implementation.
