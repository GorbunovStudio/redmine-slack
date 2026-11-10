# Spec Delta

## MODIFIED Requirements

### Requirement: Explicit marker takes precedence over thread routing
An eligible new message SHALL import to at most one issue. The first `#N+=` marker anywhere in its text MUST select that issue and be removed from the note, overriding a stored association or parent-derived target. Otherwise a reply MUST use its stored root association when present, then parent-reference fallback. Requested history MUST use its selected association target when no marker exists. Sources: D12 routing/history baseline and the existing marker contract.

#### Scenario: Multiple markers in a thread reply
- **WHEN** a thread reply contains multiple import markers and its parent references a different issue
- **THEN** only the first marker selects the target, only that marker is removed, and no second comment is created
- **AND** a stored thread association does not override that explicit marker

#### Scenario: No target
- **WHEN** ordinary event processing sees a markerless message that is not a reply, or a reply with neither a stored association nor an issue reference in its fetched parent
- **THEN** it creates no Redmine comment
- **AND** a pre-existing root becomes eligible through its selected association target only as part of requested history import

#### Scenario: Association precedes a conflicting parent reference
- **WHEN** a markerless reply's root has a stored association and its text or attachments reference another issue
- **THEN** the stored association selects the reply's issue without fetching the parent to choose a target
- **AND** the original message text remains the source for ordinary mention previews

#### Scenario: Historical root or reply with an explicit marker
- **WHEN** requested history considers an eligible root or reply containing an import marker
- **THEN** its first marker selects the target instead of the history request's association target
- **AND** existing message-ID import tracking still prevents a second comment if that message was already imported

### Requirement: Parent text and attachments determine a thread target
For a reply without an explicit marker or stored root association, the integration SHALL fetch the exact thread parent and select its first issue reference using the shared reference syntax. It MUST inspect parent text followed by attachment titles and text in attachment order, including bot-authored Redmine notifications; it MUST NOT import the parent itself as a result of that lookup. Sources: D12 routing baseline and the existing parent-reference contract.

#### Scenario: Reply to a Redmine notification
- **WHEN** the parent is a bot notification with the issue reference in an attachment title or text rather than its main text, and no stored association selects the reply's issue
- **THEN** the human reply targets that first referenced issue

#### Scenario: Parent text precedes attachment references
- **WHEN** parent text and attachments reference different issues and no marker or stored association selects the reply's issue
- **THEN** the first reference in the parent text wins; if absent, the first attachment reference wins

#### Scenario: Removing an association restores fallback
- **WHEN** a stored association has been removed and an eligible markerless reply's parent still references an issue
- **THEN** parent-reference lookup selects the target as before without recreating the association
- **AND** the parent is not itself imported by that lookup
