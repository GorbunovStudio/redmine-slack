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

Restart Redmine, and you should see the plugin show up in the Plugins page.
Under the configuration options, set the Slack API URL to the URL for an
Incoming WebHook integration in your Slack account.

## Delivery Control

Open Administration > Plugins > Redmine Slack > Configure and select
**Enable Slack delivery** to allow notifications. Delivery defaults to off,
including for existing configurations that do not have this setting.
The **Post Issue Updates** checkbox remains a separate notification-type choice.

The plugin checks delivery before preparing a send and again after the database
transaction commits. Disabling delivery also cancels a pending send. Changing
the setting requires no image rebuild or application restart.

Database backups include this setting. Keep it off on local and maintenance
copies. To disable it from the upgraded Redmine root:

```sh
RAILS_ENV=production bundle exec rails runner 'Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge("delivery_enabled" => "0")'
```

## Customized Routing

You can also route messages to different channels on a per-project basis. To
do this, create a project custom field (Administration > Custom fields > Project)
named `Slack Channel`. If no custom channel is defined for a project, the parent
project will be checked (or the default will be used). To prevent all notifications
from being sent for a project, set the custom channel to `-`.

For more information, see http://www.redmine.org/projects/redmine/wiki/Plugins.
