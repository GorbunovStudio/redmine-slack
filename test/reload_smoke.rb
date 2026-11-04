require 'minitest/autorun'

# Redmine 7 reloads lib/redmine and runs init.rb again on every code reload.
# Run in the local development environment, where reloading is enabled:
#   docker compose exec -T app bundle exec rails runner plugins/redmine_slack/test/reload_smoke.rb
class SlackReloadSmokeTest < Minitest::Test
  PATCHES = {
    'User' => 'RedmineSlack::UserPatch',
    'MyController' => 'RedmineSlack::MyControllerPatch',
    'UsersController' => 'RedmineSlack::UsersControllerPatch',
    'SettingsController' => 'RedmineSlack::SettingsPatch'
  }.freeze
  HOOKS = %w[RedmineSlack::ViewHooks SlackHook].freeze

  def setup
    raise 'Run only in development with code reloading enabled' unless Rails.env.development? && Rails.application.config.reloading_enabled?
  end

  def test_lib_is_reloadable_and_follows_zeitwerk_conventions
    Rails.autoloaders.main.eager_load_dir(Redmine::Plugin.find(:redmine_slack).directory + '/lib')
    assert Rails.autoloaders.main.unloadable_cpath?('RedmineSlack'), 'RedmineSlack is not reloadable'
    assert Rails.autoloaders.main.unloadable_cpath?('SlackListener'), 'SlackListener is not reloadable'
    assert Rails.autoloaders.main.unloadable_cpath?('SlackHook'), 'SlackHook is not reloadable'
  end

  def test_patches_and_hooks_survive_reloads
    assert_attached
    sizes = nil
    3.times do
      Rails.application.reloader.reload!
      assert_attached
      current = [Rails.application.reloader._prepare_callbacks.count, Rails.application.config.filter_parameters.size]
      assert_equal sizes, current, 'reload callbacks or filtered parameters grow with each reload' if sizes
      sizes = current
    end
  end

  private

  def assert_attached
    PATCHES.each do |target, patch|
      assert target.constantize < patch.constantize, "#{target} lacks #{patch}"
    end
    listeners = Redmine::Hook.listeners.map { |listener| listener.class.name }
    HOOKS.each do |hook|
      assert_includes listeners, hook
      assert hook.constantize < Redmine::Hook::Listener, "#{hook} subclasses a stale Redmine::Hook::Listener"
    end
    assert_includes Redmine::Hook.hook_listeners(:controller_issues_edit_after_save).map { |listener| listener.class.name }, 'SlackHook'
    assert_equal 1, GorbunovStudioBackgroundJobs.instance_variable_get(:@dedicated_queues).fetch('slack')
    assert_kind_of Class, RedmineSlack::DeliveryJob
  end
end
