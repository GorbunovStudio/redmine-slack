# Design

## Context

See [proposal.md](proposal.md) for motivation and [the delta spec](specs/slack-comment-import/spec.md) for the rendering contract. `InboundMessage` currently accepts only `text`; its marker/reference methods also serve routing and previews, while `CommentImporter#create` and `#edit` each call `convert`, strip the body, and prepend attribution when required.

`MemberResolver` already implements reverse identity and display-name lookup. The current conversion/quote test in `test/redmine7_smoke.rb` asserts converter strings, and existing event-job tests cover author selection, edit watermarks, routing, files, and duplicate suppression.

This design is needed because the renderer and both importer call sites must agree on the message source while CommonMark escaping must distinguish literal content from generated markup.

## Goals / Non-Goals

**Goals:** Keep one conversion entry point for imported bodies and make rendered HTML the acceptance boundary.

**Non-Goals:** Introduce a general Slack markup parser, change other consumers of `InboundMessage`, or repair historical journal text.

## Decisions

1. **Keep `InboundMessage` as the facade.** Add an optional blocks argument and one nested rich-text renderer in `lib/redmine_slack/inbound_message.rb`; `convert(resolver)` chooses it by presence of a `rich_text` block, leaving marker/reference methods text-only. This uses the structure Slack already provides instead of reconstructing intent from ambiguous mrkdwn or adding a parallel import pipeline.

2. **Escape literal leaves before generating markup.** Centralize the delta spec's literal escaping and apply styles afterward, with unescaped code content handled separately. Escaping the completed output would destroy intentional markup, while escaping extra ordinary punctuation would damage readable Redmine references.

3. **Dispatch inline elements directly by type.** Use small renderer methods for the spec's mappings, reusing `MemberResolver` and extracting channel/group labels from the original message text. This avoids a new lookup service, dependency, or Slack API call; unsupported elements use the specified text/URL fallback rather than a speculative parser.

4. **Compose structural output separately from inline output.** Render each block-level element, then join it using the spec's block/list separator rules and dynamically sized code delimiters. This preserves actual list/quote boundaries instead of applying global newline or fence replacements to already-rendered content.

5. **Consume the explicit marker during text-element traversal.** Keep per-render state so only the first marker occurrence in the first matching text element is removed before literal escaping or styling. Global substitution would remove later user-written markers, and changing the original message text would affect routing and label lookup.

6. **Isolate the existing text converter as the compatibility path.** Make only the approved scheme-link, date/group/user/channel token, and encoded-angle-bracket corrections there. Applying the rich-text escape/style pipeline to this path would change legacy behavior beyond the approved fixes.

7. **Pass blocks at the existing create/edit boundary.** Supply `event['blocks']` on create and the nested `message['blocks']` on edit, keeping current body stripping, leading fallback-author composition, transaction, and edit eligibility logic in place. Duplicating those responsibilities inside the renderer would risk changing journal authorship or synchronization behavior.

8. **Test through the real Redmine formatter.** Add a shared test helper using `Redmine::WikiFormatting::CommonMark::Formatter` with local hardbreaks enabled, and assert HTML for the delta scenarios while replacing obsolete conversion-string assertions. A generic Markdown library or string-only expectation would miss the Redmine behavior that exposed these failures.

## Risks / Trade-offs

- Literal escaping, whitespace around styles, and backtick delimiters can interact → exercise them together through HTML assertions, including styled links and code containing backticks.
- List source can look correct while rendering as separate lists or code → assert actual nested bullet/ordered HTML and ordered-list start values.
- Text-only fallback deliberately retains its other formatting limitations → keep separate no-block fixtures so rich-text fixes cannot silently broaden fallback behavior.
- Slack may omit channel/group names or send unfamiliar elements → cover the specified local fallbacks without adding lookup requests.
- Create and edit payloads have different shapes → use importer/event-job fixtures with distinct top-level and nested content to prove the correct body is used and attribution stays first.

## Migration Plan

This is a code-only follow-up on `slack-comment-import`; no data migration is needed. After implementation, run the local smoke command in `tasks.md` before the normal plugin release; only new imports and subsequently accepted edits use the new rendering. Rolling back the code restores the previous converter for future processing without rewriting saved notes.
