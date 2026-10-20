require 'redmine'

Rails.autoloaders.main.ignore(File.join(__dir__, 'lib'))
require_relative 'lib/redmine_slack/view_hooks'
require_relative 'lib/redmine_slack/listener'
require_relative 'lib/redmine_slack_user_patch'
require_relative 'lib/redmine_slack_my_controller_patch'
require_relative 'lib/redmine_slack_users_controller_patch'

prepare_patches = proc do
	User.include RedmineSlack::UserPatch unless User < RedmineSlack::UserPatch
	MyController.include RedmineSlack::MyControllerPatch unless MyController < RedmineSlack::MyControllerPatch
	UsersController.include RedmineSlack::UsersControllerPatch unless UsersController < RedmineSlack::UsersControllerPatch
end
Rails.application.reloader.to_prepare(&prepare_patches)
prepare_patches.call

Redmine::Plugin.register :redmine_slack do
	name 'Redmine Slack'
	author 'Samuel Cormier-Iijima'
	url 'https://github.com/sciyoshi/redmine-slack'
	author_url 'http://www.sciyoshi.com'
	description 'Slack chat integration'
	version '0.1'

	requires_redmine :version_or_higher => '7.0.0'

	settings \
		:default => {
			'delivery_enabled' => '0',
			'callback_url' => 'http://slack.com/callback/',
			'channel' => nil,
			'icon' => 'https://raw.github.com/sciyoshi/redmine-slack/gh-pages/icon.png',
			'username' => 'redmine',
			'display_watchers' => 'no'
		},
		:partial => 'settings/slack_settings'
end
