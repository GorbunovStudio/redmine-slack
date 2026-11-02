# Spec Delta

## MODIFIED Requirements

### Requirement: Convert Slack text to CommonMark narrowly
Imported notes SHALL render the message's `rich_text` blocks in order, ignoring other block types, and use text conversion only when no `rich_text` block exists. New imports MUST use `event.blocks`; edits MUST use `event.message.blocks`. Literal content and explicit rich-text formatting MUST follow the scenarios below. Routing, routing markers, and previews MUST continue to use the unchanged message `text`.

#### Scenario: Rich text is the note source, not the routing source
- **WHEN** an eligible message has `rich_text` blocks alongside other block types and its `text` differs from their content
- **THEN** only the rich-text blocks supply the note body, while routing and previews still inspect the original `text`
- **AND** other block types contribute no note content and do not trigger text fallback

#### Scenario: Literal text cannot invent CommonMark structure
- **WHEN** a rich-text text element contains characters meaningful to CommonMark
- **THEN** backslash, backtick, asterisk, underscore, tilde, square brackets, angle brackets, and pipe are backslash-escaped everywhere, and an ampersand starting an entity-like sequence is backslash-escaped
- **AND** at line start, `#`, `-`, `+`, `=`, `>` and an ordered-list number's `.` or `)` are escaped where they would introduce formatting
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
