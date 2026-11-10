require 'redmine'

Rails.application.config.filter_parameters |= [:bot_token, :signing_secret, :event, :payload]

prepare_patches = proc do
	User.include RedmineSlack::UserPatch unless User < RedmineSlack::UserPatch
	MyController.include RedmineSlack::MyControllerPatch unless MyController < RedmineSlack::MyControllerPatch
	UsersController.include RedmineSlack::UsersControllerPatch unless UsersController < RedmineSlack::UsersControllerPatch
	SettingsController.prepend RedmineSlack::SettingsPatch unless SettingsController < RedmineSlack::SettingsPatch
	AvatarsHelper.prepend RedmineSlack::AvatarsHelperPatch unless AvatarsHelper < RedmineSlack::AvatarsHelperPatch
end
# Redmine runs this file again after every code reload; Zeitwerk loads lib/.
prepare_patches.call
RedmineSlack::ViewHooks
SlackHook

Redmine::Plugin.register :redmine_slack do
	name 'Redmine Slack'
	author 'Samuel Cormier-Iijima'
	url 'https://github.com/sciyoshi/redmine-slack'
	author_url 'http://www.sciyoshi.com'
	description 'Slack chat integration'
	version '0.1'

	requires_redmine :version_or_higher => '7.0.0'
	requires_redmine_plugin :'00_gorbunovstudio_background_jobs', :version_or_higher => '1.1.0'
	permission :manage_slack_associations_via_api, {}, :require => :member

	settings \
		:default => {
			'delivery_enabled' => '0',
			'import_enabled' => '0',
			'import_user_id' => '',
			'signing_secret' => '',
			'bot_token' => '',
			'callback_url' => 'http://slack.com/callback/',
			'channel' => nil,
			'icon' => 'https://raw.github.com/sciyoshi/redmine-slack/gh-pages/icon.png',
			'username' => 'redmine',
			'display_watchers' => 'no'
		},
		:partial => 'settings/slack_settings'
end

GorbunovStudioBackgroundJobs.dedicated_queue :slack, threads: 1
