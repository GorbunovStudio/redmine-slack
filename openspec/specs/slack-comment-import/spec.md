# slack-comment-import Specification

## Purpose

Keep eligible Slack messages and their files as attributed Redmine issue comments, synchronizing later Slack edits and deletions without duplicate imports or notification loops.

Source: [approved requirements](/home/andre/projects/redmine/tickets/slack-comment-import/requirements.md), comment-import and edit/deletion decisions. The comment cardinality, reference examples, blank-line rules, and permitted download origin below are approved behavior, not new limits.

The approved [review refinements](/home/andre/projects/redmine/tickets/slack-comment-import/02-propose-review1.prompt.md) define the reported-size precheck and in-memory binary handling.

## Requirements

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
Imported notes SHALL render the message's `rich_text` and `table` blocks in order, ignoring other block types, and use text conversion only when neither exists. New imports MUST use `event.blocks`; edits MUST use `event.message.blocks`. Literal content and explicit rich-text formatting MUST follow the scenarios below. Routing, routing markers, and previews MUST continue to use the unchanged message `text`.

#### Scenario: Rich text is the note source, not the routing source
- **WHEN** an eligible message has `rich_text` blocks alongside other block types and its `text` differs from their content
- **THEN** only the rich-text and table blocks supply the note body, while routing and previews still inspect the original `text`
- **AND** other block types contribute no note content and do not trigger text fallback

#### Scenario: Table blocks become CommonMark tables
- **WHEN** a message has a `table` block, alone or between `rich_text` blocks
- **THEN** it renders in block order as a pipe table whose first row is the header, separated from neighboring blocks by a blank line, and it does not trigger text fallback
- **AND** a `column_settings` `align` of `center` or `right` sets that column's alignment, while a missing, null, or other setting keeps the default
- **AND** `raw_text` cells, `raw_number` cells (using `text`, otherwise `value`), and `rich_text` cells follow the same escaping and style rules as other rich text, with pipes backslash-escaped, line breaks inside a cell written as `<br>`, and rows shorter than the widest row padded with empty cells
- **AND** Redmine's rendered HTML shows a table with the header cells in `th`, the other rows in `td`, cell content literal, and the message's other blocks before and after it
- **AND** a table with no cells contributes no content

#### Scenario: Unsupported types are logged by name
- **WHEN** rendering a message with `rich_text` or `table` blocks skips or only approximates content, such as another top-level block type, an unknown block-level rich-text element, an inline element handled by the generic `text`/`url` fallback, or a table cell that is not `raw_text`, `raw_number`, or `rich_text`
- **THEN** a new import or an edit logs one warning, `Slack import rendered unsupported types (a, b)`, listing each type once in alphabetical order
- **AND** a type name that is not lowercase letters, digits, and underscores up to 40 characters is logged as `unknown`, and message content is never logged
- **AND** a message that renders fully, or that uses text conversion because it has no `rich_text` or `table` block, logs nothing and imports exactly as before

#### Scenario: Literal text cannot invent CommonMark structure
- **WHEN** a rich-text text element contains characters meaningful to CommonMark
- **THEN** backslash, backtick, asterisk, underscore, tilde, square brackets, angle brackets, and pipe are backslash-escaped everywhere, and an ampersand starting an entity-like sequence is backslash-escaped
- **AND** at line start, `#`, `-`, `+`, `=`, `>` and an ordered-list number's `.` or `)` are escaped where they would introduce formatting
- **AND** a literal `!` immediately preceding a generated link is escaped so it does not create an image
- **AND** other characters remain as typed, including `#123`, `@login`, `/`, and ordinary `.`, preserving readable note source and Redmine issue links and mentions
- **AND** Redmine's rendered HTML displays `# TODO later`, `text` followed by `---`, `__init__`, `2*3*4`, `<div>`, and entity-like text literally rather than as headings, rules, emphasis, HTML, or decoded entities

#### Scenario: Explicit styles and inline code
- **WHEN** text elements carry bold, italic, strike, or code styles
- **THEN** bold uses `**…**`, italic uses `*…*`, and strike uses `~~…~~`, with leading and trailing whitespace outside emphasis markers
- **AND** code uses a valid code span with a backtick delimiter longer than any backtick run inside and no escaping of its content
- **AND** Redmine's rendered HTML shows the intended strong, emphasis, strikethrough, and code elements rather than treating Slack bold as italic

#### Scenario: Links preserve labels, styles, and destinations
- **WHEN** a rich-text link has a label and optional styles, or has no label
- **THEN** a labeled link becomes `[label](url)` with its label escaped and styled, while an unlabeled link uses the URL itself
- **AND** a destination containing spaces or parentheses uses `<…>` destination form
- **AND** rendered labeled links, including `mailto:` links, have the intended destination and label styling

#### Scenario: Users, channels, groups, and broadcasts
- **WHEN** rich text contains user, channel, usergroup, or broadcast elements
- **THEN** a user resolves through the existing identity rules to `@login` when linked, otherwise an escaped Slack display name
- **AND** channel and usergroup names come from the matching `<#ID|name>` or `<!subteam^ID|name>` token in message `text`, using `#name` or the group label respectively
- **AND** absent or empty names become `#channel` or `@group`, without new Slack API calls
- **AND** broadcasts become `@here`, `@channel`, or `@everyone`

#### Scenario: Emoji, dates, and other elements
- **WHEN** rich text contains emoji, date, or another inline element type
- **THEN** emoji with `unicode` use its Unicode code points, custom emoji without it use `:name:`, and dates use their `fallback` text
- **AND** another element contributes its `text`, otherwise its `url`, otherwise nothing, with literal content protected by the text-escaping rules
- **AND** rendered Unicode emoji are characters rather than shortcodes, including the Unicode equivalent of `:tada:`

#### Scenario: Remove only the first explicit marker before escaping
- **WHEN** a `#N+=` import has that marker in a rich-text text element, including a styled element, and later marker occurrences also exist
- **THEN** the first occurrence in the first text element containing it is removed before escaping and styling
- **AND** later occurrences remain in the note, and only the target selected from message `text` receives a comment

#### Scenario: Entities, links, mentions, and channels
- **WHEN** no rich-text block exists and Slack text contains `<@U…>`, `<url|label>`, `<url>`, `<#C…|name>`, and broadcast controls alongside encoded entities
- **THEN** the note retains the existing first-marker removal, linked-user or display-name mention resolution, labeled-link conversion, bare wrapped HTTP/HTTPS URL conversion, named-channel conversion, and broadcast conversion
- **AND** `&amp;` is decoded, while `&lt;` and `&gt;` stay encoded rather than becoming raw HTML, except that line-start `&gt;` is converted to a quote marker
- **AND** unrelated emphasis, code, and other Slack formatting remains as written, without the rich-text escaping or broad formatting translation

#### Scenario: Text fallback corrects the measured token cases
- **WHEN** a message without rich text contains `<mailto:a@b.com|a@b.com>`, another `<scheme:…|label>`, `<!date^…|Nov 14>`, `<!subteam^S1|@devs>`, `<@U333|old>`, or `<#C456|>`
- **THEN** labeled scheme tokens become links, the date becomes its fallback, the group becomes its label or `@group` if empty or absent, the labeled user resolves identically to an unlabeled user, and the empty channel label becomes `#channel`
- **AND** no other text-fallback behavior changes

#### Scenario: Edits render the nested message and retain attribution
- **WHEN** an eligible newer edit carries `message.blocks` for an existing imported journal
- **THEN** its note body is re-rendered by the same rules as a new message, using the nested message's `text` for token names and marker removal
- **AND** the existing fallback-author line stays first when present, and the journal's issue, author, attachments, and edit eligibility rules remain unchanged

### Requirement: Separate quote blocks from following text
Rich-text block-level elements SHALL use blank-line separation except consecutive `rich_text_list` elements, which MUST use a single newline. Sections, preformatted blocks, quotes, and lists MUST follow the scenarios below, dropping Slack's trailing section newline. Text fallback SHALL retain Hubot's quote fix without adding a separator where one already exists.

#### Scenario: Sections, fenced code, and quotes
- **WHEN** rich text contains `rich_text_section`, `rich_text_preformatted`, and `rich_text_quote` elements followed by ordinary content
- **THEN** a section renders its inline elements, preformatted content uses a valid fenced code block with its fences on their own lines and longer than any backtick run inside, and each quote line has a `> ` prefix
- **AND** code content is unescaped, its first line remains code rather than a language identifier, and embedded backticks do not close the fence
- **AND** block-level blank-line separation keeps following ordinary content outside the code block or quote
- **AND** Slack's trailing section newline is dropped rather than adding an extra separator

#### Scenario: Nested bullet and ordered lists remain one list
- **WHEN** consecutive `rich_text_list` elements contain bullet and ordered items with `indent` levels
- **THEN** bullet items use `- `, ordered items use `N. `, and each indent level contributes four spaces
- **AND** consecutive list elements are separated by a single newline so Redmine's rendered HTML nests the items under either bullet or ordered parents rather than splitting them into separate lists or code blocks

#### Scenario: Ordered list offset controls the displayed start
- **WHEN** an ordered rich-text list supplies an `offset`
- **THEN** its numbering begins at `offset` + 1 and increments for successive items
- **AND** Redmine's rendered ordered list reflects that starting number

#### Scenario: Slack removed the quote separator
- **WHEN** text fallback contains a quoted block immediately followed by ordinary text
- **THEN** the imported note inserts a blank line so the following text does not become part of the quotation
- **AND** an existing blank separator is retained without adding another

### Requirement: Import all available message file types
Every file on the new message SHALL be eligible, not only images. Downloads MUST use the bot token and `url_private_download` or, if absent, `url_private`, and MUST be restricted to `https://files.slack.com`. Redmine's existing attachment validation and attachment-add permission MUST apply; no plugin-specific size, count, or extension limits are added.

#### Scenario: Authenticated files of different types
- **WHEN** a routed message contains an image and a non-image file on the permitted origin
- **THEN** authenticated downloads use the preferred private-download URLs and both valid files are attached in the comment's journal

#### Scenario: Missing preferred URL or disallowed origin
- **WHEN** a file lacks a private-download URL but has a private URL on the permitted origin
- **THEN** the private URL is used
- **AND** a non-HTTPS URL or another host is not fetched or sent the token

#### Scenario: Slack sends a file placeholder
- **WHEN** a file object has `file_access` `check_file_info` instead of its metadata and URLs
- **THEN** the full file object is fetched with `files.info` and imported like any other file
- **AND** a permanent `files.info` error skips only that file, while the comment and other files are saved
- **AND** every skipped file is logged with a safe reason code and no message content

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
A `message_deleted` event SHALL locate its message by `deleted_ts`, set `deleted_at`, and replace linked notes with `_Deleted in Slack on <date and time>_`, a blank line, then the prior text as a quote with each line prefixed by `> ` (blank lines by `>`). Attachments MUST remain; repeated deletion MUST NOT quote the note again, and subsequent edits MUST be ignored.

#### Scenario: Delete a multiline imported note
- **WHEN** Slack deletes an imported comment containing multiple paragraphs
- **THEN** the journal retains its attachments and shows the italic deletion line followed by the prior note in a blockquote, preserving blank lines and visible rich-text content

#### Scenario: Delete before import arrives
- **WHEN** a deletion arrives for a message with no link
- **THEN** a link with no journal and with `deleted_at` is stored so a late new-message event cannot import it

#### Scenario: Delete after the journal was removed
- **WHEN** the link exists but its journal no longer does
- **THEN** the link is marked deleted without recreating or replacing the missing journal
