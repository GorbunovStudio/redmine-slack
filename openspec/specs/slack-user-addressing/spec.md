# slack-user-addressing Specification

## Purpose

Address workflow participants through their Redmine identities while producing valid Slack mentions and app direct messages without changing stored legacy preferences.

## Requirements

### Requirement: Resolve current Slack identity from a Redmine user
Mentions and DM recipients SHALL be passed as Redmine user references and resolved only during delivery. A stored `U…` or `W…` member ID MUST take precedence; otherwise resolution MUST reuse the user's successful member cache or use the current Redmine email through `users.lookupByEmail`, never a Slack username or display-name search.

#### Scenario: Explicit member preference bypasses email lookup
- **WHEN** the referenced Redmine user has a member-ID-shaped Slack preference
- **THEN** delivery uses that member ID without calling email lookup

#### Scenario: Empty or legacy preference uses email
- **WHEN** the referenced user has an empty or non-ID preference
- **THEN** delivery reuses the user's cached member ID or uses the current Redmine email for lookup and the returned member ID
- **AND** it leaves the stored preference unchanged, including non-ID source values

#### Scenario: Identity changes while work is queued
- **GIVEN** a message was composed with a Redmine user reference and there is no cached member lookup for that user
- **WHEN** the user's preference or primary email changes before the job runs
- **THEN** the job resolves the current identity instead of a queued Slack-name or email snapshot
- **AND** no identity API was called during issue saving

### Requirement: Only trusted mentions render as Slack mentions
Generated mention placeholders SHALL render as `<@U…>` or `<@W…>` only after successful identity resolution. An unresolved mention MUST render its referenced user's plain name with Slack control characters escaped; text supplied by users MUST NOT become a reference merely by resembling an internal placeholder.

#### Scenario: Lookup cannot resolve a mention
- **WHEN** the email lookup returns `users_not_found`, the user has no email, or the referenced user no longer exists
- **THEN** the message contains the plain fallback name rather than `<@login>`, a raw placeholder, or an empty mention
- **AND** fallback text containing Slack control characters does not create markup or another mention

#### Scenario: Literal placeholder-like text remains text
- **WHEN** a comment includes text resembling the plugin's mention placeholder
- **THEN** only placeholders generated from actual Redmine-user references are resolved
- **AND** the literal comment text is not interpreted as a user reference

### Requirement: Escape user-controlled Slack text
The plugin SHALL escape `&`, `<`, and `>` in user-controlled comment text outside recognized Redmine-login mentions, captured-assignee names, and reminder-list display values before composing Slack messages. Generated mentions, issue links, and broadcast alerts MUST retain their Slack syntax.

#### Scenario: Literal Slack controls in a comment remain text
- **WHEN** a comment contains literal Slack control syntax, ordinary text with Slack control characters, and a recognized Redmine login
- **THEN** the literal controls and ordinary text are escaped
- **AND** the recognized login becomes a resolved Slack mention

#### Scenario: User-controlled names and reminder values remain text
- **WHEN** a captured-assignee name or a reminder entry's project, tracker, subject, status, or priority contains Slack control characters
- **THEN** those display values are escaped without breaking the generated issue link

#### Scenario: Generated broadcast remains active
- **WHEN** the plugin composes a high-priority alert
- **THEN** its generated `<!channel>` broadcast syntax remains unescaped

### Requirement: Recognize only existing Redmine logins in comments
Comment conversion SHALL recognize `@word` only at start-of-text or after a non-word character before `@`, and only when it identifies an existing Redmine login. That boundary MUST preserve email addresses without separate email-span exclusion. Unknown handles MUST remain unchanged; mention-based support routing and duplicate suppression MUST use the same recognized Redmine identities.

#### Scenario: Known login at an eligible boundary
- **WHEN** a comment contains a known Redmine login at the start or after an eligible non-word boundary
- **THEN** that occurrence becomes a deferred mention for the corresponding Redmine user
- **AND** dot, hyphen, and underscore login characters retain their existing supported meaning

#### Scenario: Email or embedded text is not a mention
- **WHEN** a comment contains an email address, an `@` embedded after a word character, or an unknown `@word`
- **THEN** those occurrences remain as typed and do not trigger identity lookups or client-mention routing

#### Scenario: Explicit mention prevents duplicate automatic mention
- **WHEN** a comment explicitly references its assignee or executor who would otherwise be automatically mentioned
- **THEN** duplicate suppression compares Redmine user identity before deferred Slack resolution
- **AND** the notification retains the intended recipient without adding another copy for that user

### Requirement: Direct messages target the app's conversation
A resolvable DM recipient SHALL be opened through `conversations.open(users: member_id)` and the message MUST be posted to the returned `D…` channel ID with existing customization. An unresolved recipient MUST be skipped and logged without a fallback post to another person, channel, or Slackbot.

#### Scenario: Open or resume the app DM
- **WHEN** a reviewer or executor DM has a resolvable member ID and no cached DM channel
- **THEN** delivery opens or resumes that member's app DM and posts to the returned DM channel ID
- **AND** it never passes the member ID directly as `chat.postMessage`'s destination

#### Scenario: Recipient cannot be resolved
- **WHEN** the recipient user is missing, has no usable email or member preference, or has no matching Slack account
- **THEN** no DM open or post occurs and the skip is logged by a safe reason code

### Requirement: Cache only successful addressing results
Successful email-to-member lookups and opened DM channel IDs SHALL be cached for 24 hours. Member cache keys MUST use the Redmine user ID and DM cache keys the resolved member ID; misses and failures MUST NOT be cached. An email change can reuse that person's member ID until expiry under the single-workspace/token scope. [Sources](../../design.md#sources-and-numeric-provenance).

#### Scenario: Successful results are reused until expiry
- **WHEN** subsequent messages resolve the same Redmine user and member before expiry
- **THEN** the successful member lookup and DM open results are reused without repeating those API calls
- **AND** expiry permits fresh lookup and DM opening

#### Scenario: Miss does not suppress a later valid account
- **WHEN** an email lookup misses or a DM open fails and another message attempts resolution later
- **THEN** it makes the required API call again rather than reusing a negative cache entry

### Requirement: Preference forms and read behaviour remain compatible
Account and administrator forms SHALL retain their existing Slack preference storage key and successful-save behaviour. Reading preferences MUST NOT write to the database, and failed user updates MUST NOT save a new Slack preference. Help text MUST explain member-ID override and email fallback without rewriting legacy values.

#### Scenario: Successful account and admin saves
- **WHEN** the account form is saved by PUT or an administrator successfully creates or updates a user
- **THEN** the submitted preference is saved with existing whitespace trimming

#### Scenario: Failed update or read-only access
- **WHEN** a user update fails validation or an empty preference is read
- **THEN** the preference is not changed or persisted as a side effect
