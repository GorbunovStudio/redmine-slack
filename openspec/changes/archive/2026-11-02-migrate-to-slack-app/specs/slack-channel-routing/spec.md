# Slack Channel Routing

## Purpose

Route existing workflow notifications to explicitly configured private Slack conversations and provide an auditable transition from stored names to conversation IDs.

## ADDED Requirements

### Requirement: Private-channel destinations use IDs
The default channel and project Slack Channel / Slack Support Channel fields SHALL accept conversation IDs. A project's own nonblank `-`, `#name`, or invalid value MUST yield no destination for that route. Names MUST NOT be resolved during delivery, and private destinations MUST require bot membership.

#### Scenario: Configured private conversation ID
- **WHEN** an eligible notification selects a configured conversation ID
- **THEN** delivery uses that ID without calling a channel-name lookup API
- **AND** a Slack membership rejection follows the permanent-error policy rather than posting elsewhere

#### Scenario: Project's own nonblank invalid destination suppresses its route
- **WHEN** a project's own channel field is `-`, begins with `#`, or is invalid
- **THEN** that route yields no destination and no message is queued for it
- **AND** its parent/default is not substituted within that project's routing call

### Requirement: Preserve recursive main and support selection
Routing SHALL preserve the existing recursion and validate the selected value within each call. Main selection MUST use project main, parent main result, then default; support MUST use project support, parent support result, then project main result. A nil result from an ancestor's disabled/invalid value MUST allow the child's existing fallback.

#### Scenario: Main field and parent fallback
- **WHEN** a project has its own valid main ID
- **THEN** it overrides the parent/default main route
- **AND** clearing that field selects the parent's effective main route or the default when no ancestor supplies a value

#### Scenario: Ancestor's invalid result permits the child's fallback
- **WHEN** a project's main field is blank and its parent's main call returns nil for `-`, `#name`, or an invalid value
- **THEN** the child falls through to its configured default channel as before
- **AND** a nil parent support result likewise allows the child's existing main-route fallback

#### Scenario: Support follows existing recursive precedence
- **WHEN** project support is blank and its parent has an effective support route
- **THEN** that parent route is selected, including its existing main/default fallback, ahead of the child's main route
- **AND** an explicit child support ID overrides that inherited route

#### Scenario: Root support falls back to main
- **WHEN** a root project's support field is blank
- **THEN** its effective main route supplies support routing

### Requirement: Conversion is dry run unless explicitly applied
The channel conversion task SHALL default to reporting without persistent writes and SHALL rewrite values only with explicit `APPLY=1`. It MUST inspect the default channel and every stored project value of the two channel fields, without materializing inherited values or modifying unrelated settings and preferences.

#### Scenario: Dry-run report covers every stored location
- **WHEN** the conversion task is invoked without the apply flag while delivery is off
- **THEN** it reports each configured location, original value, resolved ID or unresolved reason, and planned/unchanged status
- **AND** it writes no settings or custom values and sends no message or DM
- **AND** repeated names are reported at every location, including inactive or archived projects

#### Scenario: Explicit apply rewrites only matched names
- **WHEN** the task is invoked with `APPLY=1` after successful enumeration
- **THEN** it replaces resolved stored `#name` values with their IDs and reports applied locations
- **AND** existing IDs, blank values, `-`, unrelated settings, and all user preferences remain unchanged

### Requirement: Enumerate only visible private channels through all pages
Conversion SHALL use `conversations.list` with `types=private_channel` and the configured token's `groups:read` scope. It MUST follow every nonblank pagination cursor, match exact current names, and report configured names the bot cannot see rather than infer IDs or use send-time resolution.

#### Scenario: Match appears after an empty intermediate page
- **WHEN** a private-channel listing page has no channels but a nonblank next cursor
- **THEN** enumeration continues and can match names on later pages

#### Scenario: Name is invisible or renamed
- **WHEN** a configured name is absent from the complete visible channel list
- **THEN** every location using it is reported as unresolved, with not-invited-or-renamed guidance
- **AND** its stored value is left untouched

### Requirement: Conversion failures and reruns are auditable
Conversion SHALL finish enumeration before applying writes in one transaction, report a summary and a non-success result for unresolved or invalid locations, and leave those values untouched. API failure MUST abort before writes with safe diagnostics. Reruns MUST preserve already-converted IDs.

#### Scenario: Mixed resolved and unresolved values
- **WHEN** apply encounters both resolvable names and unresolved or invalid locations
- **THEN** resolved locations are converted while unresolved/invalid values remain unchanged
- **AND** per-location output and totals distinguish matched, applied, unchanged, unresolved, and invalid results and the task returns non-success

#### Scenario: Enumeration fails before completion
- **WHEN** a listing page fails authentication, rate limiting, transport, or another API error
- **THEN** the task exits without persistent changes and reports only a safe error code or status
- **AND** a supplied Retry-After wait can be reported without disclosing the token

#### Scenario: Rerun after conversion
- **WHEN** the task is run after names have been converted to IDs
- **THEN** it reports those IDs unchanged and does not convert them again
