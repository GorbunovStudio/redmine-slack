# Proposal

## Why

Forwarded Redmine comments currently omit their images, leaving Slack readers without the screenshots needed to understand the discussion. The approved upload spike established that the existing Slack app can share comment text and uploaded images together while preserving message customization.

## What Changes

- Collect image attachments added in the comment's journal and inline references to the issue's attachments, following the configured note formatter and deduplicating by attachment ID.
- Remove inline image markup from the Slack comment text without modifying the saved Redmine note; retain existing mention handling and routing.
- Queue attachment IDs, not file content or paths; read and recheck images during background delivery and skip unavailable or no-longer-image attachments.
- Deliver image-bearing comments as a single Slack message using external file upload and completion with the rendered comment as `initial_comment`; retain `chat.postMessage` when no deliverable images remain.
- Apply existing cancellation, sanitized error classification, and retry behavior to uploads; retries restart the upload sequence.
- Document `files:write` and image delivery behavior. Preserve private-note, blank-note, and silent-update suppression and every non-comment notification path.

## Capabilities

### New Capabilities

None; the existing workflow and delivery capabilities own these behaviors.

### Modified Capabilities

- `slack-workflow-notifications`: Select comment images, strip inline image markup, and preserve comment eligibility, routing, and private-note exclusion while leaving non-comment content unchanged.
- `slack-app-delivery`: Add external image upload delivery, delivery-time attachment reads and text-only fallback, reuse failure handling, and document the additional scope.

## Impact

Implementation touches `lib/redmine_slack/listener.rb`, `lib/redmine_slack/client.rb`, `app/jobs/redmine_slack/delivery_job.rb`, `test/redmine7_smoke.rb`, and `README.md`; a small plugin-local extraction helper may be used if it keeps listener code clear. It uses Redmine's attachment model and configured formatter, the existing HTTPClient dependency, and Slack's `files.getUploadURLExternal`, raw upload URL, and `files.completeUploadExternal` endpoints. No settings, persistent storage, services, schema changes, new dependencies, or fixed upload count/size caps are introduced. The app already has `files:write` and was reinstalled; this proposal authorizes no live calls or rollout.
