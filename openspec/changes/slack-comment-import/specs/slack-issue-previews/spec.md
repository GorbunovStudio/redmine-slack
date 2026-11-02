# Spec Delta

## Purpose

Show useful issue context for Slack references while limiting disclosed issue information to what the configured import user can view.

Source: [approved requirements](/home/andre/projects/redmine/tickets/slack-comment-import/requirements.md), issue-reference and preview decisions. Numeric issue syntax and the single-reply/deduplication behavior below come from that source, not a Slack limit.

## ADDED Requirements

### Requirement: Recognize issue numbers and configured Redmine URLs
The integration SHALL recognize `#123`-style issue references and issue URLs built from the configured Redmine protocol and host with `/issues/123`, optionally followed by a query or anchor. Plain URLs and Slack's `<url>` and `<url|label>` forms MUST resolve consistently, preserving first-reference order and deduplicating issue IDs.

#### Scenario: Mixed repeated references
- **WHEN** message text contains a number reference and plain or Slack-wrapped configured-host URLs for the same issue, followed by another issue
- **THEN** each distinct issue appears once, in its first-reference order

#### Scenario: URL belongs elsewhere
- **WHEN** a URL uses another host or protocol or is not an issue URL
- **THEN** that URL is not treated as a Redmine issue reference

### Requirement: Reply once in the source conversation
An eligible new message with visible issue references SHALL produce a single reply containing each referenced issue once, excluding issue IDs named by `#N+=` markers. A thread reply MUST receive the preview in the same thread; a top-level message MUST receive it at the conversation's top level. Change and deletion events MUST NOT produce previews.

#### Scenario: Top-level and threaded references
- **WHEN** an eligible top-level message references visible issues
- **THEN** a combined preview is posted at the top level of the same conversation
- **AND** for an eligible thread reply the combined preview instead uses that reply's parent thread

#### Scenario: Explicit import marker and other references
- **WHEN** text includes `#123+=`, another occurrence of `#123`, and a reference to another visible issue
- **THEN** the marker's issue is excluded from the preview and the other issue is previewed normally

#### Scenario: Retried event
- **WHEN** Slack repeats a new-message callback or a preview attempt is retried after an uncertain post
- **THEN** a repeated preview is allowed without adding preview deduplication storage

### Requirement: Preview content is permission filtered and escaped
Previews SHALL show the tracker, issue number, project, subject, status, priority, issue link, and full description, with user-controlled values escaped for Slack and link unfurling disabled. Only issues visible to the configured import user MUST be included; missing or invisible issues MUST be skipped silently.

#### Scenario: Issue details contain Slack control characters
- **WHEN** a visible referenced issue has control characters in its displayed values or description
- **THEN** the preview retains those values as text, with the generated issue link intact and both link/media unfurling disabled
- **AND** the description is included rather than omitted or truncated by a new plugin limit

#### Scenario: Referenced issues cannot be disclosed
- **WHEN** some referenced issues are missing or invisible to the import user
- **THEN** only the visible issues appear, with no not-found or permission-error message
- **AND** if none remain, no preview is posted
