# Slack Workflow Notifications

## Purpose

Preserve the custom issue workflow, message content, recipient context, and privacy guarantees while its Slack addressing and delivery mechanism change.

## ADDED Requirements

### Requirement: Preserve event selection and message content
The plugin SHALL preserve the listener's existing high-priority creation, priority-escalation, selected story-progress, acceptance, return, assignment-transfer, detail-change, comment, and changeset notification rules and texts. Links, attachments, colors, thumbnails, moods, and existing limits MUST remain unchanged except for the specified addressing and broadcast syntax changes.

#### Scenario: Existing workflow events still produce the same notifications
- **WHEN** an issue change meets an existing creation, escalation, progress, acceptance, return, transfer, details, or comment rule
- **THEN** the same notification types and existing wording/attachments are composed at their existing successful-save hooks, with the new addressing representation and a separate job for each message
- **AND** no previously inactive event branch, ordinary-priority creation notification, or scheduled reminder is introduced

#### Scenario: Broadcast alerts use explicit Slack syntax
- **WHEN** a high-priority creation or priority-escalation alert is composed
- **THEN** its old `@channel:` prefix is replaced with `<!channel>` and the remaining alert text is preserved

#### Scenario: Post-updates remains independent
- **WHEN** Post Issue Updates is off but Slack delivery is on
- **THEN** issue-update notifications are suppressed according to the existing gate
- **AND** the setting does not newly disable creation or changeset notification types that were not governed by that gate

### Requirement: Preserve client and acceptance routing
The workflow SHALL retain support routing when the journal author, current assignee, previous assignee, or a recognized comment mention meets its existing client-role rule. Accepted-story progress MUST retain its main-channel override, using the updated channel configuration contract.

#### Scenario: Client participation selects support
- **WHEN** an author, current/previous assignee, or recognized comment mention is a client under the existing rule
- **THEN** the corresponding update or comment selects its existing support route

#### Scenario: Acceptance returns progress to main
- **WHEN** an accepted-story progress event would otherwise use support routing
- **THEN** its progress message uses the main route as before

### Requirement: Before-save workflow effects survive disabled delivery
Before saving, the plugin SHALL preserve clearing Is return, incrementing Returns count, and stripping a leading `[silent-update]` from saved notes while suppressing that comment notification. These effects MUST run even when delivery is disabled and MUST preserve normal save/rollback behaviour.

#### Scenario: Return flag and silent prefix are processed
- **WHEN** an issue with its return flag set is saved with a leading `[silent-update]` note
- **THEN** the return flag is cleared, the return count is incremented, and the saved note lacks that prefix
- **AND** that comment is not composed for Slack, including while delivery is disabled

#### Scenario: Issue-specific listener state does not cross edits
- **WHEN** separate issue edits interleave their before/after-save hooks
- **THEN** their silent/return/previous-state decisions remain isolated and are cleared after notification processing

### Requirement: Private note text never enters queued messages
Private note text SHALL be excluded before composing channel or DM messages and MUST NOT enter background-job arguments or Slack payloads. Other eligible non-comment changes in the same update MUST retain their existing notifications without the private text.

#### Scenario: Private note accompanies another change
- **WHEN** an update contains a private note and an otherwise eligible details or progress change
- **THEN** any retained notification excludes the private note from both persisted job arguments and eventual HTTP payloads

### Requirement: Reminder lists keep recipient context and request-time state
Review and assigned-work reminder lists SHALL still be queried and formatted as their intended recipient during event processing, then restore the previous current user even on failure. The existing saved queries, review permission condition, assigned-list limit, and empty-list suppression MUST remain; jobs MUST NOT rebuild lists after save.

#### Scenario: Ready-for-review produces recipient-specific reminders
- **WHEN** the existing ready-for-review event qualifies an executor for reminders
- **THEN** review and assigned lists use the executor's query context and existing selection/formatting rules
- **AND** each nonempty list becomes a separate DM addressed by that executor's Redmine user reference

#### Scenario: Restore the editor after recipient query
- **WHEN** a recipient query succeeds or raises an error
- **THEN** the previous current-user context is restored

#### Scenario: Saved state changes before delivery
- **GIVEN** reminder text was composed during the qualifying update
- **WHEN** issue state changes again before the delivery job runs
- **THEN** delivery retains the already-composed list rather than querying a different list

### Requirement: Preserve reviewer DMs and changeset journal behaviour
The existing manager-triggered reviewer DM SHALL keep its recipient, text, and attachments. Changeset-driven notifications MUST use the successfully saved issue journal, revision link, and native translation text; a failed issue save MUST NOT create its notification job.

#### Scenario: Manager return alerts reviewer
- **WHEN** a return satisfies the existing manager/reviewer DM condition
- **THEN** a separate message with the existing text and issue attachment is addressed to the reviewer's Redmine user reference

#### Scenario: Changeset updates a saved issue
- **WHEN** the changeset listener successfully saves an eligible issue change
- **THEN** the notification retains the issue text, revision URL, saved journal detail fields, and native translated changeset text
- **AND** its message is enqueued after the listener's successful issue save without a new transaction wrapper
