# Spec Delta

## MODIFIED Requirements

### Requirement: Documented app prerequisites and gated rollout
The README SHALL document the required app scopes, Messages Tab, private-channel invitations, token setting, conversion task, background-jobs prerequisite, comment image delivery, and approval-gated live verification. It MUST also document inbound event setup, import-user permissions, plugin migrations, and Hubot cutover. Development verification MUST use stubbed HTTP and MUST NOT send live Slack messages.

#### Scenario: Operator follows the rollout documentation
- **WHEN** an operator prepares to enable the integration
- **THEN** the documented sequence is create/install the app, enable Messages Tab, invite the bot, configure the disabled integration, dry run, convert, perform a separately approved live test, then enable ordinary delivery
- **AND** it lists `files:write`, `chat:write`, `chat:write.customize`, `users:read.email`, `im:write`, and `groups:read` for channel conversion and association source classification, without requiring `chat:write.public`
- **AND** association setup additionally lists `commands`, `reactions:write`, and `im:read`, and requires app reinstallation after adding scopes
- **AND** it states that replies can remain disabled for outbound-only use, distinguishes inbound app-DM use, and requires local/maintenance copies to retain delivery off

#### Scenario: Existing installation prepares for image delivery
- **WHEN** an operator reads the comment image instructions
- **THEN** the README states that `files:write` is required and scope changes require app reinstallation
- **AND** a short paragraph describes same-journal and inline image attachments, markup stripped only in the Slack copy, missing images skipped at delivery, and possible duplication on retry

#### Scenario: Operator enables inbound processing
- **WHEN** an operator follows the inbound setup instructions
- **THEN** the README supplies the public HTTPS event request URL and challenge/signing-secret setup, subscriptions `message.groups` and `message.im`, and added bot scopes `groups:history`, `im:history`, `files:read`, and `users:read`, with app reinstallation
- **AND** it explains `signing_secret`, `import_enabled` defaulting off, and `import_user_id`, including creation of an active import user and project membership with view-issues/add-notes permissions and attachment access where needed
- **AND** it explains that the new link table requires plugin migrations and scopes processing to private channels and the app's DMs, not public channels, group DMs, or person-to-person DMs
- **AND** enabling import is paired with disabling Hubot's preview, thread, and `#N+=` listeners while leaving its other commands and scheduled reports on Hubot

Sources: existing rollout contract at `openspec/specs/slack-app-delivery/spec.md:120–139`; D7, D10, D15–D16 and D12 setup baseline; the conversation-info, shortcut and reaction scope contracts in [design sources](../../design.md#provider-contracts). Existing image/inbound/outbound setup guarantees above are retained; the scope-use amendment does not add actor source-channel membership authorization.
