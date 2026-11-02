# Proposal

## Why

The custom workflow depends on per-message destinations, sender customization, and direct messages that modern incoming webhooks cannot preserve. A Slack app using member and conversation IDs replaces the legacy transport without changing the workflow, while moving network calls out of issue-save requests.

## What Changes

- **BREAKING**: Replace webhook delivery and the Slack URL control with a safely handled bot token and JSON `chat.postMessage` requests; retain sender names, icons, attachments, event moods, and the delivery/update switches.
- Resolve mentions and DM recipients from Redmine user references in delivery jobs, using explicit member-ID preferences or email lookup. Preserve non-ID preferences, render unresolved mentions as names, and skip unresolved DMs.
- **BREAKING**: Route private-channel notifications by conversation ID rather than `#name`; retain project/parent/default and main/support rules and the `-` sentinel. Provide a dry-run-first, paginated channel conversion task.
- Enqueue each composed message on the dedicated `slack` queue, using the existing edit transaction so rolled-back edits discard their jobs; creation and changeset notifications enqueue after successful saves without new transaction wrappers. Recheck the delivery switch in the job and classify success, rate limits, transient failures, identity misses, and dropped errors.
- Document app installation, scopes, Messages Tab, bot invitations, token handling, conversion, and the approval-gated rollout. Extend the existing stubbed standalone smoke suite rather than performing live Slack delivery.

## Capabilities

### New Capabilities

- `slack-app-delivery`: Secret configuration, customized Web API posting, asynchronous delivery with edit-transaction rollback, queue dependency, cancellation, and error handling.
- `slack-user-addressing`: Redmine-backed mention and DM addressing, comment login recognition, successful-resolution caches, and preference compatibility.
- `slack-channel-routing`: ID-only private-channel routing, inheritance/disable semantics, and explicit channel-name conversion.
- `slack-workflow-notifications`: Existing custom event selection, message content, privacy, reminder-query context, and issue-save side effects across the transport change.

### Modified Capabilities

None. The main spec inventory is empty; all requirements are added capabilities, including the preserved workflow contract.

## Impact

Changes are confined to this plugin's initialization, listener, settings/preferences views and patches, new delivery/client/addressing helpers and job, a conversion rake task, README, and smoke tests. Reuse existing settings, custom values, preferences, `httpclient`, and GoodJob's existing database tables; add no table, migration, or gem.

The Slack-side dependency requires `00_gorbunovstudio_background_jobs` version `1.1.0` and calls its fixed `dedicated_queue` hook. The separately designed background-jobs change owns scheduler layout, thread-budget enforcement, and that version release; this change does not implement them. Slack threads, Block Kit redesign, batching, Slack username/display-name lookup, send-time channel-name resolution, and live delivery during development are excluded.
