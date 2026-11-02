# Slack chat plugin for Redmine

This plugin posts updates to issues in your Redmine installation to a Slack
channel. Improvements are welcome! Just send a pull request.

## Screenshot

![screenshot](https://raw.github.com/sciyoshi/redmine-slack/gh-pages/screenshot.png)

## Installation

From your Redmine plugins directory, clone this repository as `redmine_slack` (note
the underscore!):

    git clone https://github.com/sciyoshi/redmine-slack.git redmine_slack

You will also need the `httpclient` dependency, which can be installed by running

    bundle install

from the plugin directory.

Install `00_gorbunovstudio_background_jobs` version `1.1.0` or newer at
`plugins/00_gorbunovstudio_background_jobs` before this plugin at
`plugins/redmine_slack`. This plugin reserves one thread using the background
jobs dedicated `slack` queue hook; it does not change the shared thread budget.
Run the plugin migration from the Redmine root to create the Slack message link
table, then restart Redmine so that queue registration takes effect:

```sh
RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=redmine_slack
```

Create a Slack app, install it in the workspace, and grant these bot scopes:
`chat:write`, `chat:write.customize`, `users:read.email`, `im:write`, `files:write`, and
`groups:read` (used only for channel conversion). `chat:write.public` is not
required. Scope changes require reinstalling the app. Enable the App Home Messages
Tab; replies can remain disabled for outbound-only use, but enable them to use
inbound app DMs.
See Slack's documentation for [posting](https://docs.slack.dev/reference/methods/chat.postMessage/),
[email lookup](https://docs.slack.dev/reference/methods/users.lookupByEmail/),
[opening DMs](https://docs.slack.dev/reference/methods/conversations.open/), and
[listing conversations](https://docs.slack.dev/reference/methods/conversations.list/).
Invite the bot to each private channel it must use.

Restart Redmine, open the plugin configuration, and enter the bot token in the
empty password field. The status shows whether a token is configured; leaving
the field blank preserves the existing token, and entering a new token replaces it.
Keep delivery disabled until conversion and a separately approved live test.

Users or administrators can set a Slack member ID (`U…` or `W…`) in the
existing Slack preference as an override. Otherwise delivery looks up the
current Redmine email. Legacy preference values remain unchanged.

## Slack event import

For inbound use, configure the Events API request URL as
`https://redmine.gorbunov.studio/redmine_slack/events`. Enter the app signing secret
in **Slack signing secret** before Slack verifies the URL; the empty field
preserves the existing secret and its status shows whether one is configured.
Subscribe to bot events `message.groups` and `message.im`, add bot scopes
`groups:history`, `im:history`, `files:read`, and `users:read`, and reinstall the
app. Processing covers private channels containing the app and app DMs, not
public channels, group DMs, or person-to-person DMs.

Create an active Redmine user for Slack imports and select it as **Slack import
user**. Add it to each relevant project with permission to view issues and add
notes, and attachment access where files are expected. **Enable Slack import**
defaults off and is independent of outbound delivery; keep it off until the
cutover. When enabling it, disable only Hubot's preview, thread, and `#N+=`
listeners; leave Hubot's other commands and scheduled reports running.

For inbound rollback, disable import and leave the event job in place until
queued work has consumed the disabled state. Remove the Slack subscription before
removing the endpoint or job; retain message links, comments, and attachments.

## Delivery Control

Open Administration > Plugins > Redmine Slack > Configure and select
**Enable Slack delivery** to allow notifications. Delivery defaults to off,
including for existing configurations that do not have this setting.
The **Post Issue Updates** checkbox remains a separate notification-type choice.

The plugin enqueues one job per message only while delivery is enabled and a
token is present. Each execution and retry checks the current setting and token
before resolving identities or contacting Slack. Disabling delivery discards
queued work as it runs; re-enabling it does not revive discarded messages.
Edit jobs are enqueued in the existing edit transaction, so a rollback discards
them. Creation and changeset jobs are enqueued at their existing successful-save
hooks. Changing the delivery setting requires no image rebuild or restart.

The dedicated worker handles ordinary messages in order; delayed retries may be
overtaken. Rate limits with a valid Retry-After are rescheduled for that interval;
other transient failures retry up to five total attempts, three seconds apart.
A timed-out request may have been accepted by Slack and a retry can duplicate it.
Permanent errors are dropped with a safe code. Successful member lookups and DM
channels are cached for 24 hours; a cold cache after a restart performs lookups
again, and an email change can reuse a cached member until expiry.

Comment notifications include image attachments added in the same journal and
existing issue images referenced inline. Image markup is stripped only from the
Slack copy; missing images are skipped at delivery, and retries can duplicate
the resulting message.

Database backups include this setting. Keep it off on local and maintenance
copies. To disable it from the upgraded Redmine root:

```sh
RAILS_ENV=production bundle exec rails runner 'Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge("delivery_enabled" => "0")'
```

## Customized Routing

You can also route messages to different channels on a per-project basis. To
do this, create a project custom field (Administration > Custom fields > Project)
named `Slack Channel`, and optionally `Slack Support Channel`. Configure private
conversation IDs (`C…` or `G…`) in these fields and in the default channel;
invite the bot to each private conversation. Main routing uses the project's own
value, then its parent's effective main route, then the default. Support routing
uses its own value, then its parent's effective support route, then its own main
route. A nonblank `-`, old `#name`, or invalid value disables that project's
route; a nil result from an ancestor permits the child's normal fallback.

After inviting the bot and while delivery is disabled, run from the Redmine root:

```sh
RAILS_ENV=production bundle exec rake redmine_slack:convert_channels
RAILS_ENV=production APPLY=1 bundle exec rake redmine_slack:convert_channels
```

The first command is a dry run. Review every location before applying. The
task lists visible private conversations through every page and matches exact
current names; it reports each matched, unresolved, invalid or unchanged
location and summarizes matched, unresolved, invalid, unchanged and applied
counts. Invite the bot or correct renamed channels when names are unresolved.
Apply converts matched names even if other entries remain unresolved or invalid;
those entries stay unchanged and the command exits unsuccessfully. An API error
prevents all writes. Rerun the dry run after conversion; existing IDs are unchanged.
Delivery never resolves channel names at send time.

## Rollout and rollback

1. Create and install the app, enable the Messages Tab, invite it to all private
   destinations, and install the required background-jobs release. Restart the
   application and configure the token while delivery remains disabled.
2. Run the conversion dry run, resolve reported names, apply conversion, and
   rerun the dry run to confirm the stored values.
3. Obtain separate approval for the exact live-test destination, recipient, and
   text. In that approved window only, temporarily enable delivery, verify
   channel routing, customization, explicit mentions, and the app DM (not
   Slackbot), then disable delivery again. Development verification uses stubs.
4. Enable ordinary delivery only after the approved test passes. Keep local and
   maintenance copies, including restored databases, disabled.

For rollback, first disable delivery and leave the job class available until
queued jobs have consumed the disabled state. Keep conversion output to restore
stored channel values if an operator explicitly rolls back. Restoring `#name`
values alone does not restore the legacy integration; do not silently re-enable
it or delete existing preferences, custom fields, or GoodJob tables.

For more information, see http://www.redmine.org/projects/redmine/wiki/Plugins.
