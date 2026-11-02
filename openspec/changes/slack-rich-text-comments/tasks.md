# Tasks

## 1. Rich-text conversion and formatter coverage

- [ ] 1.1 Add optional blocks input and the nested renderer to `lib/redmine_slack/inbound_message.rb`; add a real Redmine CommonMark formatter helper in `test/redmine7_smoke.rb` with hardbreaks enabled, and verify rich-text blocks render in order, other block types are ignored, and marker/reference/preview methods still use original text.
- [ ] 1.2 Implement literal escaping and style/code-span rendering; verify formatter HTML for Slack bold, italic, strike, boundary whitespace, inline backticks, `# TODO later`, `text` followed by `---`, `__init__`, `2*3*4`, literal `<div>`, entity-like text, and literal list/table syntax, while `#123`, `@login`, slashes, and ordinary dots remain usable and readable.
- [ ] 1.3 Implement link, user, channel, usergroup, broadcast, emoji, date, and unknown-element mappings; verify HTML for escaped/styled labels, unlabeled URLs, mailto links, destinations with spaces/parentheses, linked and unlinked users, available/empty/missing channel/group labels, broadcasts, Unicode/custom emoji, date fallbacks, and unknown-element text/URL/empty fallbacks, with no added Slack API calls.
- [ ] 1.4 Implement sections, fenced code, quotes, lists, and their separators; verify HTML for a multiline code block containing backticks, text after a quote, nested bullet/ordered lists under both parent types, an ordered offset, and section trailing-newline handling.
- [ ] 1.5 Implement first-marker consumption during rich-text traversal; verify a styled text element loses only its first marker and later occurrences remain, without changing the original routing text.

## 2. Text-only compatibility and regression coverage

- [ ] 2.1 Keep the existing text path with only the approved scheme-link, date/group, labeled-user, empty-channel, and encoded-angle-bracket corrections; verify formatter HTML for every measured fallback token and literal encoded `<div>`, including a message with no blocks and one with only non-rich-text blocks.
- [ ] 2.2 Replace the obsolete `test_slack_text_conversion_and_quote_separation` converter-string expectations with formatter HTML checks; verify retained ampersand decoding, legacy untouched emphasis/code, mentions, links, broadcasts, and quote separation both with and without an existing blank line, without keeping duplicate assertions.

## 3. Importer integration and lifecycle regressions

- [ ] 3.1 Pass create-event blocks and nested edit-message blocks into `InboundMessage` in `lib/redmine_slack/comment_importer.rb`; verify saved-note HTML for both paths with conflicting text/block content and with distinct top-level versus nested edit blocks so the selected source is unambiguous.
- [ ] 3.2 Extend importer/event-job tests to verify the fallback-author line stays first for rich-text creation and editing, routing/previews still follow text references, and existing author, issue, watermark, attachment, deduplication, and deletion guarantees continue to pass.

## 4. Integration verification

- [ ] 4.1 From `/home/andre/projects/redmine/docker`, run `docker compose exec -T app bundle exec ruby -r ./config/environment.rb plugins/redmine_slack/test/redmine7_smoke.rb` with local Slack delivery disabled and HTTP stubbed; verify the complete smoke suite passes.
- [ ] 4.2 From `/home/andre/projects/redmine/plugins/redmine-slack`, run `openspec validate slack-rich-text-comments --strict`; verify exit status is zero and the change is valid.
- [ ] 4.3 Review the implementation diff against the delta spec and verify no new settings, storage, gems, Slack API calls, numeric limits, or unrelated routing/lifecycle changes were introduced.
