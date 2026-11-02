# Spec Delta

## Purpose

Keep eligible Slack messages and their files as attributed Redmine issue comments, synchronizing later Slack edits and deletions without duplicate imports or notification loops.

Source: [approved requirements](/home/andre/projects/redmine/tickets/slack-comment-import/requirements.md), comment-import and edit/deletion decisions. The comment cardinality, reference examples, blank-line rules, and permitted download origin below are approved behavior, not new limits.

The approved [review refinements](/home/andre/projects/redmine/tickets/slack-comment-import/02-propose-review1.prompt.md) define the reported-size precheck and in-memory binary handling.

## ADDED Requirements

### Requirement: Explicit marker takes precedence over thread routing
An eligible new message SHALL import to at most one issue. The first `#N+=` marker anywhere in its text MUST select that issue and be removed from the note, overriding any thread-derived target. Without a marker, only a thread reply with a referenced issue in its fetched parent can import; otherwise nothing is imported.

#### Scenario: Multiple markers in a thread reply
- **WHEN** a thread reply contains multiple import markers and its parent references a different issue
- **THEN** only the first marker selects the target, only that marker is removed, and no second comment is created

#### Scenario: No target
- **WHEN** a new message has no marker and is not a thread reply, or its parent has no issue reference
- **THEN** it creates no Redmine comment

### Requirement: Parent text and attachments determine a thread target
For a reply without an explicit marker, the integration SHALL fetch the exact thread parent and select its first issue reference using the shared reference syntax. It MUST inspect parent text followed by attachment titles and text in attachment order, including bot-authored Redmine notifications; it MUST NOT import the parent itself as a result of that lookup.

#### Scenario: Reply to a Redmine notification
- **WHEN** the parent is a bot notification with the issue reference in an attachment title or text rather than its main text
- **THEN** the human reply targets that first referenced issue

#### Scenario: Parent text precedes attachment references
- **WHEN** parent text and attachments reference different issues
- **THEN** the first reference in the parent text wins; if absent, the first attachment reference wins

### Requirement: Resolve the Slack member to a Redmine identity
The Slack member SHALL map through an existing member-ID Slack preference first, otherwise through `users.info` email to an active Redmine user. Successful reverse lookups MUST be cached like existing successful member lookups, but misses/failures MUST NOT be cached and preferences MUST NOT be rewritten. Slack display names MUST NOT be used to match Redmine accounts.

#### Scenario: Preference overrides email
- **WHEN** a Slack member ID matches a Redmine user's Slack preference but the Slack email points elsewhere
- **THEN** the preference-linked Redmine user is selected

#### Scenario: Email match or no account
- **WHEN** no preference matches the member
- **THEN** an active user matching the `users.info` email is selected if available, otherwise the member is treated as unlinked
- **AND** successful reverse resolution is reused from cache while misses can be retried by later messages

### Requirement: Authorize the chosen author and attribute fallback imports
A linked user SHALL author the journal only if the issue is visible to them and they may add notes. Otherwise the configured import user MUST author it with a leading `**<Slack display name>** (Slack):` line, but only in a project where that user is a member and can view the issue and add notes. A denied import MUST be skipped and logged without content or a Slack feedback message.

#### Scenario: Linked member has issue access
- **WHEN** a linked Redmine user can view the target issue and add notes
- **THEN** the journal author is that user and no fallback attribution line is added

#### Scenario: Unlinked or unauthorized member uses import identity
- **WHEN** the member has no linked account or the linked user lacks the required issue access
- **THEN** an authorized project-member import user authors the comment with the Slack display-name attribution

#### Scenario: Import identity cannot act in the project
- **WHEN** fallback is required but the import user is not a project member, cannot see the issue, or cannot add notes
- **THEN** no comment or files are saved and only a safe skip reason is logged

### Requirement: Convert Slack text to CommonMark narrowly
Imported text SHALL decode `&amp;`, `&lt;`, `&gt;`; convert member mentions to `@login` when linked or the Slack display name otherwise; convert labeled links to CommonMark links and bare wrapped links to URLs; convert named channel references to `#name` and broadcast references to `@here`, `@channel`, `@everyone`. Other Slack formatting MUST remain as written.

#### Scenario: Entities, links, mentions, and channels
- **WHEN** Slack text contains `<@U…>`, `<url|label>`, `<url>`, `<#C…|name>`, and broadcast controls alongside encoded entities
- **THEN** the saved note uses the specified CommonMark/plain-text forms with linked-user or display-name mention resolution
- **AND** unrelated emphasis, code, and other Slack formatting is not broadly translated

### Requirement: Separate quote blocks from following text
Text conversion SHALL retain Hubot's quote fix by inserting a blank line after a `>` quote block when the following nonquoted text lacks that separation, without adding another separator where one already exists.

#### Scenario: Slack removed the quote separator
- **WHEN** a quoted block is immediately followed by ordinary text
- **THEN** the imported note separates them with a blank line so the following text does not become part of the quotation

### Requirement: Import all available message file types
Every file on the new message SHALL be eligible, not only images. Downloads MUST use the bot token and `url_private_download` or, if absent, `url_private`, and MUST be restricted to `https://files.slack.com`. Redmine's existing attachment validation and attachment-add permission MUST apply; no plugin-specific size, count, or extension limits are added.

#### Scenario: Authenticated files of different types
- **WHEN** a routed message contains an image and a non-image file on the permitted origin
- **THEN** authenticated downloads use the preferred private-download URLs and both valid files are attached in the comment's journal

#### Scenario: Missing preferred URL or disallowed origin
- **WHEN** a file lacks a private-download URL but has a private URL on the permitted origin
- **THEN** the private URL is used
- **AND** a non-HTTPS URL or another host is not fetched or sent the token

### Requirement: Precheck reported file size and retain binary bytes in memory
The integration SHALL skip a file before downloading when Slack-reported `size` exceeds the current Redmine attachment-size limit in kilobytes. Remaining downloads MUST be held in memory as binary bytes; Redmine MUST still validate the actual downloaded size and extension.

#### Scenario: Slack reports a file over the current limit
- **WHEN** a file's reported size exceeds the Redmine attachment-size setting read at runtime
- **THEN** the file is skipped without a download and the note and other valid files remain eligible for import

#### Scenario: Reported size permits a binary download
- **WHEN** a file's reported size is within the current limit, including equal to it
- **THEN** it is eligible for download and its bytes are kept in memory without text transcoding
- **AND** Redmine validates its actual byte size and extension before it is attached

### Requirement: File failures do not discard the note
A file that cannot be downloaded or is rejected by Redmine SHALL be skipped while the comment is still saved with its other valid files. A file-only message MUST create a journal carrying its valid attachments and, for fallback authorship, the attribution line; it MUST NOT require invented note text. Later edits MUST NOT add, remove, or redownload attachments.

#### Scenario: Some files fail
- **WHEN** downloads or Redmine size/extension validation reject some files
- **THEN** the note and remaining valid files are saved together without a Slack error reply

#### Scenario: File-only comment
- **WHEN** an authorized routed message has no note text but has a valid file
- **THEN** a journal is saved with the attachment detail and any required fallback attribution

#### Scenario: Slack edit changes the file list
- **WHEN** an imported message is edited to add or remove files
- **THEN** its existing Redmine attachments are unchanged and no new download occurs

### Requirement: Import journals without outbound echo
The job SHALL create comments through the issue model, not the issues controller, without inserting `[silent-update]`. Imported comments MUST NOT trigger the plugin's controller-hook outbound notifications, while normal Redmine comment email notifications remain enabled.

#### Scenario: Save imported comment
- **WHEN** the import job saves a text or file-bearing comment
- **THEN** its note has no plugin-added silent marker, no outbound notification job is created by the controller hooks, and normal email-notification behavior is retained

### Requirement: Link imports atomically and deduplicate by message
The integration SHALL keep a single link per unique `channel_id` and `message_ts`, with `journal_id` (nullable), `slack_user_id`, `author_name`, `last_edited_ts`, and `deleted_at`. A journal-bearing link MUST commit in the same transaction as its journal; a repeated new-message event for an existing link MUST do nothing to that comment or its attachments.

#### Scenario: Retry an already imported message
- **WHEN** the same message is delivered again, including after a job retry
- **THEN** the existing link prevents an additional journal or attachment import

#### Scenario: Save rolls back
- **WHEN** saving the import fails and its transaction rolls back
- **THEN** neither its journal nor its link remains committed

### Requirement: Apply only newer edits to existing imports
A `message_changed` event SHALL rewrite the linked journal's notes only when it is not deleted, the journal still exists, and `message.edited.ts` is newer than `last_edited_ts`. It MUST use the same text conversion and attribution, update the edit watermark, and retain the journal's author and issue even if issue references change. An edit MUST NOT create a previously absent import.

#### Scenario: Newer edit changes the target reference
- **WHEN** a linked message receives a newer edit naming another issue
- **THEN** only the original journal's notes and edit watermark change, preserving its issue, author, attribution style, and attachments

#### Scenario: Stale, deleted, unlinked, or missing journal
- **WHEN** an edit repeats an old/equal timestamp, follows deletion, has no import link, or its journal no longer exists
- **THEN** it makes no journal change and does not create a comment

### Requirement: Retain deleted comments as marked history
A `message_deleted` event SHALL locate its message by `deleted_ts`, set `deleted_at`, and replace linked notes with `_Deleted in Slack on <date and time>_`, a blank line, then the prior text with each nonblank line wrapped in `~~…~~`. Attachments MUST remain; repeated deletion MUST NOT wrap the note again, and subsequent edits MUST be ignored.

#### Scenario: Delete a multiline imported note
- **WHEN** Slack deletes an imported comment containing multiple paragraphs
- **THEN** the journal retains its attachments and shows the italic deletion line followed by line-wise strikethrough, preserving blank lines

#### Scenario: Delete before import arrives
- **WHEN** a deletion arrives for a message with no link
- **THEN** a link with no journal and with `deleted_at` is stored so a late new-message event cannot import it

#### Scenario: Delete after the journal was removed
- **WHEN** the link exists but its journal no longer does
- **THEN** the link is marked deleted without recreating or replacing the missing journal
