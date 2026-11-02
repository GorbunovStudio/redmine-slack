# Spec Delta

## MODIFIED Requirements

### Requirement: Preserve event selection and message content
The plugin SHALL preserve the listener's existing high-priority creation, priority-escalation, selected story-progress, acceptance, return, assignment-transfer, detail-change, comment, and changeset notification rules and texts. Links, attachments, colors, thumbnails, moods, and existing limits MUST remain unchanged except for the specified addressing and broadcast syntax changes and comment image handling defined below.

#### Scenario: Existing workflow events still produce the same notifications
- **WHEN** an issue change meets an existing creation, escalation, progress, acceptance, return, transfer, details, or comment rule
- **THEN** the same notification types and existing wording/attachments are composed at their existing successful-save hooks, with the new addressing representation and a separate job for each message
- **AND** only comment messages gain image uploads and removal of inline image markup
- **AND** no previously inactive event branch, ordinary-priority creation notification, or scheduled reminder is introduced

#### Scenario: Broadcast alerts use explicit Slack syntax
- **WHEN** a high-priority creation or priority-escalation alert is composed
- **THEN** its old `@channel:` prefix is replaced with `<!channel>` and the remaining alert text is preserved

#### Scenario: Post-updates remains independent
- **WHEN** Post Issue Updates is off but Slack delivery is on
- **THEN** issue-update notifications are suppressed according to the existing gate
- **AND** the setting does not newly disable creation or changeset notification types that were not governed by that gate

### Requirement: Private note text never enters queued messages
Private note text SHALL be excluded before composing channel or DM messages and MUST NOT enter background-job arguments or Slack payloads. Images from a private-note journal MUST NOT be queued or uploaded through that journal's comment. Other eligible non-comment changes in the same update MUST retain their existing notifications without the private text or its comment images.

#### Scenario: Private note accompanies another change
- **WHEN** an update contains a private note and an otherwise eligible details or progress change
- **THEN** any retained notification excludes the private note from both persisted job arguments and eventual HTTP payloads
- **AND** it contains no comment-image attachment IDs and makes no file upload requests for that journal

## ADDED Requirements

### Requirement: Comment images come from journal additions and inline references
Eligible public comments SHALL include images added in their journal and images referenced inline by attachment filename in the note using the configured formatter's image syntax. Only issue attachments classified as images SHALL qualify. External references with a URL scheme MUST NOT be uploaded or fetched. The resulting selection SHALL be deduplicated by attachment ID.

#### Scenario: Same-journal additions select only images
- **WHEN** an eligible comment's journal records added image and non-image attachments alongside an attachment removal
- **THEN** only the added image attachments are selected from those journal details
- **AND** unrelated existing issue images are not included unless referenced inline

#### Scenario: CommonMark inline image resolves an existing attachment
- **GIVEN** the configured formatter is `common_mark`
- **WHEN** an eligible note contains `![screenshot](screen.png)` referencing an issue image attachment
- **THEN** the latest attachment matching that filename under Redmine's attachment filename resolution is selected
- **AND** duplicate filenames use Redmine's case-insensitive latest-attachment ordering

#### Scenario: Textile inline image resolves an existing attachment
- **GIVEN** the configured formatter is `textile`
- **WHEN** an eligible note contains `!screen.png!` referencing an issue image attachment
- **THEN** the latest attachment matching that filename under Redmine's attachment filename resolution is selected
- **AND** the other formatter's image syntax is not independently interpreted

#### Scenario: Duplicate and unresolvable references
- **WHEN** a note repeatedly references an image also added in the same journal and references an external URL, a missing filename, and a non-image attachment
- **THEN** the qualifying attachment ID appears only once in the selection
- **AND** external, missing, and non-image references add no upload and cause no external image fetch

### Requirement: Slack comment text omits inline image markup
The Slack copy of a comment SHALL omit recognized inline image markup in the configured formatter, including external and unresolved image references. The saved Redmine note MUST remain unchanged. Surrounding text, issue links, quotations, recognized textual mentions, automatic mention deduplication, and existing main/support routing SHALL retain their behavior.

#### Scenario: Remove image markup without changing the note
- **WHEN** an eligible comment contains surrounding text, local and external image markup, and a recognized textual user mention
- **THEN** the Slack text retains the surrounding text and rendered mention but omits the image markup
- **AND** the stored note retains its original markup
- **AND** the existing client-mention support route and automatic mention deduplication remain effective

### Requirement: Comment image collection does not bypass comment eligibility
Private notes, originally blank notes, and comments suppressed by `[silent-update]` SHALL produce no comment job or uploads. An image-only nonblank note SHALL remain eligible after image markup removal. Image handling MUST NOT bypass delivery or post-updates gates or add images to non-comment notifications.

#### Scenario: Attachment-only edit remains quiet
- **WHEN** an edit adds image attachments but its note is blank
- **THEN** no comment delivery job or comment image upload is produced

#### Scenario: Image-only note remains a comment
- **WHEN** an eligible nonblank note consists only of recognized image markup
- **THEN** a comment job is still produced with the normal issue link, comment header, and selected image IDs
