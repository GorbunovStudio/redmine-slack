# Proposal

## Why

The current Slack `text` converter produces incorrect Redmine CommonMark HTML: Slack bold becomes italic, code fences break, and literal text can become headings, emphasis, or raw HTML. The approved follow-up to PR #4 uses Slack's structured rich text to preserve the message's intended presentation and tests the rendered result rather than converter strings.

## What Changes

- Render imported comment bodies from Slack rich-text blocks, with literal-text protection and explicit element mappings.
- Retain text-only compatibility with the approved token and entity corrections.
- Apply the rendering contract to new imports and edits while preserving marker routing and fallback attribution.
- Replace obsolete converter-string checks with real Redmine CommonMark HTML assertions covering the measured failures and structured content.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `slack-comment-import`: revise “Convert Slack text to CommonMark narrowly” and “Separate quote blocks from following text” to specify rich-text rendering and its text-only fallback.

## Impact

- Implementation surface: `lib/redmine_slack/inbound_message.rb` (and a sibling renderer if needed), the create/edit conversion calls in `lib/redmine_slack/comment_importer.rb`, and `test/redmine7_smoke.rb`.
- Existing `MemberResolver` remains the identity source; event ingress, issue routing, previews, permissions, attachment handling, deduplication, and deletion behavior are outside this change.
- No new settings, storage, gems, Slack API calls, or numeric limits; no migration or backfill of existing notes.

Approved source: [rich-text requirements](/home/andre/projects/redmine/tickets/slack-comment-import/requirements-rich-text.md).
