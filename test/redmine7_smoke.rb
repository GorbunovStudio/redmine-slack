require 'minitest/autorun'
require 'action_controller/test_case'

module SlackSmokeTransport
  class << self
    attr_accessor :requests, :status, :error
  end
  self.requests = []
  self.status = 200

  def post(url, body, *arguments)
    raise SlackSmokeTransport.error if SlackSmokeTransport.error
    SlackSmokeTransport.requests << {url: url, payload: JSON.parse(body.fetch(:payload))}
    Struct.new(:status).new(SlackSmokeTransport.status)
  end
end

HTTPClient.prepend(SlackSmokeTransport)

class SlackWorkflowSmokeTest < ActionController::TestCase
  tests IssuesController

  setup do
    raise 'Run only against the upgraded local db service' unless ActiveRecord::Base.connection_db_config.host == 'db'
    raise 'Local Slack delivery must start disabled in plugin settings' if Setting.plugin_redmine_slack.with_indifferent_access[:delivery_enabled] == '1'
    @connection = ActiveRecord::Base.connection
    @connection.begin_transaction(joinable: false)
    @routes = Rails.application.routes
    @user = User.active.where(admin: true).first!
    @request.session[:user_id] = @user.id
    @request.session[:tk] = @user.generate_session_token
    @request.session[:sudo_timestamp] = Time.now.to_i
    User.current = @user
    Setting.plugin_redmine_slack = {'slack_url' => 'https://example.invalid/slack-fixture',
      'channel' => '#fixture-main', 'username' => 'fixture-bot', 'icon' => ':robot_face:', 'post_updates' => '1'}
    @issue = Issue.joins(:custom_values).where(custom_values: {custom_field_id: 8}).where.not(custom_values: {value: [nil, '']}).first!
    @issue.custom_field_values = {'27' => '0', '31' => '0'}
    @executor = User.find(@issue.custom_value_for(8).value)
    @executor.rslack_preference[:username] = 'UFIXTURE01'
    @user.rslack_preference[:username] = 'UFIXTURE02' unless @user == @executor
    @listener = SlackListener.new
    @messages = []
    messages = @messages
    @listener.define_singleton_method(:speak) do |message, channel, attachments = [], url = nil, icon = nil|
      messages << {text: message, channel: channel, attachments: attachments, url: url, icon: icon}
    end
    @listener.define_singleton_method(:channel_for_project) { |_project| '#fixture-main' }
    @listener.define_singleton_method(:support_channel_for_project) { |_project| '#fixture-support' }
    @listener.define_singleton_method(:url_for_project) { |_project| 'https://example.invalid/slack-fixture' }
    SlackSmokeTransport.requests.clear
  end

  teardown do
    @connection.rollback_transaction if @connection
    User.current = nil
    Setting.clear_cache
    SlackSmokeTransport.error = nil
    SlackSmokeTransport.status = 200
  end

end

class SlackWorkflowBehaviorSmokeTest < SlackWorkflowSmokeTest
  tests IssuesController

  def test_return_fields_and_silent_prefix_are_preserved
    @issue.custom_field_values = {'14' => '1', '12' => '2'}
    journal = @issue.init_journal(@user, '[silent-update]Fixture note')
    @listener.prepare_issue_update(issue: @issue, journal: journal)
    assert_equal 0, @issue.custom_field_value(14).to_i
    assert_equal 3, @issue.custom_field_value(12).to_i
    assert_equal 'Fixture note', journal.notes
    message, = @listener.send(:prepare_comment_message, @issue, journal, '#fixture-main')
    assert_equal '', message
    @issue.save!
    assert_equal 0, @issue.reload.custom_field_value(14).to_i
    assert_equal 3, @issue.custom_field_value(12).to_i
  end

  def test_progress_event_and_main_support_routing
    journal = @issue.init_journal(@executor, 'Fixture progress')
    @listener.prepare_issue_update(issue: @issue, journal: journal)
    @issue.status_id = 8
    journal.details.build(property: 'attr', prop_key: 'status_id', old_value: '2', value: '8')
    assert_equal SlackListener::PROGRESS_EVENT_STORY_READY_FOR_REVIEW, @listener.send(:get_progress_event, @issue, journal)
    @listener.define_singleton_method(:is_client) { |_user, _project| true }
    @listener.define_singleton_method(:can_review_code) { |_user, _project| false }
    @listener.define_singleton_method(:build_assigned_list) { |_recipient| '' }
    @listener.notify_issue_update(issue: @issue, journal: journal)
    assert @messages.any? { |message| message[:channel] == '#fixture-support' }
    @messages.clear
    journal.user = @user
    @issue.status_id = 9
    @listener.notify_issue_update(issue: @issue, journal: journal)
    assert @messages.any? { |message| message[:channel] == '#fixture-main' && message[:text].include?('accepted') }
  end

  def test_public_mentions_private_notes_and_silent_updates
    journal = @issue.init_journal(@user, "Fixture @#{@executor.login}")
    @listener.prepare_issue_update(issue: @issue, journal: journal)
    message, channel = @listener.send(:prepare_comment_message, @issue, journal, '#fixture-main')
    assert_includes message, '<@UFIXTURE01>'
    assert_equal '#fixture-main', channel
    journal.notes = 'Private fixture secret'
    journal.private_notes = true
    message, = @listener.send(:prepare_comment_message, @issue, journal, '#fixture-main')
    assert_equal '', message
    @listener.notify_issue_update(issue: @issue, journal: journal)
    refute @messages.any? { |payload| payload[:text].include?('Private fixture secret') }
  end

  def test_return_alert_and_reviewer_direct_message
    @executor = User.active.where.not(id: 3).first!
    @executor.rslack_preference[:username] = 'URETURN001'
    executor = @executor
    @listener.define_singleton_method(:get_executor) { |_issue| executor }
    editor = User.active.where.not(id: @executor.id).first!
    @issue.assigned_to = @executor
    @issue.status_id = 4
    journal = @issue.init_journal(editor, '')
    journal.details.build(property: 'attr', prop_key: 'assigned_to_id', old_value: editor.id.to_s, value: @executor.id.to_s)
    @listener.instance_variable_set(:@isReturn, true)
    reviewer = @executor
    @listener.define_singleton_method(:get_reviewer) { |_issue| reviewer }
    message, attachment, = @listener.send(:prepare_return_message, @issue, journal)
    assert_includes message, 'Issue was returned'
    assert_equal 'danger', attachment.fetch(:color)
    journal.user = User.find(3)
    message, _attachment, _icon, direct = @listener.send(:prepare_return_message, @issue, journal)
    assert message.present?
    assert_equal 'URETURN001', direct.fetch(:channel)
  end

  def test_reviewer_reminders_are_addressed_to_executor
    journal = @issue.init_journal(@executor, '')
    @listener.prepare_issue_update(issue: @issue, journal: journal)
    @issue.status_id = 8
    journal.details.build(property: 'attr', prop_key: 'status_id', old_value: '2', value: '8')
    recipients = []
    @listener.define_singleton_method(:is_client) { |_user, _project| false }
    @listener.define_singleton_method(:can_review_code) { |_user, _project| true }
    @listener.define_singleton_method(:build_review_list) { |recipient| recipients << recipient.id; 'Fixture review reminder' }
    @listener.define_singleton_method(:build_assigned_list) { |recipient| recipients << recipient.id; 'Fixture assigned reminder' }
    @listener.notify_issue_update(issue: @issue, journal: journal)
    assert_equal [@executor.id, @executor.id], recipients
    reminders = @messages.select { |message| message[:text].include?('Fixture') }
    assert_equal 2, reminders.length
    assert reminders.all? { |message| message[:channel] == 'UFIXTURE01' }
  end

  def test_client_mention_uses_support_channel
    journal = @issue.init_journal(@user, "Fixture @#{@executor.login}")
    client_id = @executor.id
    @listener.define_singleton_method(:is_client) { |user, _project| user.id == client_id }
    message, channel = @listener.send(:prepare_comment_message, @issue, journal, '#fixture-main')
    assert message.present?
    assert_equal '#fixture-support', channel
  end

  def test_empty_preference_read_does_not_write
    @user.rslack_preference[:username] = ''
    user = User.find(@user.id)
    original = user.pref.attributes.deep_dup
    assert_equal '', user.rslack_preference[:username]
    assert user.pref.attributes == original
    refute user.pref.changed?
  end

  def test_high_priority_and_assignment_messages
    @issue.priority_id = 5
    @listener.controller_issues_new_after_save(issue: @issue)
    assert @messages.any? { |message| message[:text].include?('important issue') }
    @messages.clear
    journal = @issue.init_journal(@user, '')
    @listener.prepare_issue_update(issue: @issue, journal: journal)
    @issue.assigned_to = @executor
    journal.details.build(property: 'attr', prop_key: 'assigned_to_id', old_value: nil, value: @executor.id.to_s)
    @listener.instance_variable_set(:@isReturn, false)
    message, = @listener.send(:prepare_assigned_change_message, @issue, journal)
    assert message.present?
    @issue.priority_id = 6
    @listener.instance_variable_set(:@previous_priority_id, 4)
    message, = @listener.send(:prepare_priority_change_message, @issue, journal)
    assert_includes message, 'priority has been raised'
  end

  def test_changeset_notification_uses_saved_journal_and_native_translation
    @issue.init_journal(@user, 'Fixture changeset update')
    @issue.subject = 'Slack fixture changeset'
    repository = Struct.new(:project, :identifier_param).new(@issue.project, 'fixture-repository')
    changeset = Struct.new(:repository, :revision, :comments).new(repository, 'fixture-revision', 'Fixture commit')
    @listener.model_changeset_scan_commit_for_issue_ids_pre_issue_update(issue: @issue, changeset: changeset)
    assert_equal 1, @messages.length
    message = @messages.first
    assert_includes message[:text], 'Slack fixture changeset'
    assert_includes message[:attachments].first[:text], 'fixture-revision'
    refute_includes message[:attachments].first[:text], 'translation missing'
    assert_equal 'Fixture changeset update', @issue.journals.order(id: :desc).first.notes
  end

  def test_project_routing_and_parent_fallback
    listener = SlackListener.new
    channel_field = ProjectCustomField.find_by!(name: 'Slack Channel')
    support_field = ProjectCustomField.find_by!(name: 'Slack Support Channel')
    @issue.project.custom_field_values = {channel_field.id.to_s => '#fixture-project', support_field.id.to_s => '#fixture-support'}
    assert_equal '#fixture-project', listener.send(:channel_for_project, @issue.project)
    assert_equal '#fixture-support', listener.send(:support_channel_for_project, @issue.project)
    @issue.project.custom_field_values = {channel_field.id.to_s => '-'}
    assert_nil listener.send(:channel_for_project, @issue.project)
    assert_equal 'https://example.invalid/slack-fixture', listener.send(:url_for_project, @issue.project)
  end

  def test_reminder_queries_use_recipient_and_restore_current_user
    @user.rslack_preference[:username] = 'UFIXTURE02'
    previous_user = User.current
    [4, 8].each do |query_id|
      expected = begin
        User.current = @executor
        IssueQuery.find(query_id).issues.map(&:id)
      ensure
        User.current = previous_user
      end
      actual = @listener.send(:issues_for_recipient, query_id, @executor).map(&:id)
      assert_equal expected, actual
      assert_equal previous_user, User.current
    end
    assert_operator @listener.send(:get_assigned_issues, @executor).length, :<=, 10
  end

  def test_hook_state_is_per_issue_and_cleared_after_notification
    second = Issue.where.not(id: @issue.id).first!
    first_journal = @issue.init_journal(@user, '[silent-update]Fixture hidden')
    second_journal = second.init_journal(@user, 'Fixture public')
    SlackHook.instance.controller_issues_edit_before_save(issue: @issue, journal: first_journal)
    SlackHook.instance.controller_issues_edit_before_save(issue: second, journal: second_journal)
    first_state = @issue.instance_variable_get(:@redmine_slack_listener)
    second_state = second.instance_variable_get(:@redmine_slack_listener)
    refute_same first_state, second_state
    assert first_state.instance_variable_get(:@silent_update)
    refute second_state.instance_variable_get(:@silent_update)
    SlackHook.instance.controller_issues_edit_after_save(issue: @issue, journal: first_journal)
    refute @issue.instance_variable_defined?(:@redmine_slack_listener)
    assert_empty SlackSmokeTransport.requests
  end

  def test_issue_save_and_failed_save_with_live_delivery_disabled
    get :show, params: {id: @issue.id}
    assert_response :success
    csrf_token = css_select('meta[name="csrf-token"]').first['content']
    original_subject = @issue.subject
    put :update, params: {id: @issue.id, authenticity_token: csrf_token,
      issue: {subject: '', notes: 'Fixture invalid update'}}
    assert_response :success
    assert_equal original_subject, @issue.reload.subject
    put :update, params: {id: @issue.id, authenticity_token: csrf_token,
      issue: {subject: original_subject, notes: '[silent-update]Fixture valid update', custom_field_values: {'27' => '0', '31' => '0'}}}
    assert_response :redirect
    assert_equal 'Fixture valid update', @issue.journals.order(id: :desc).first.notes
    assert_empty SlackSmokeTransport.requests
  end
end

class SlackMyAccountSmokeTest < SlackWorkflowSmokeTest
  tests MyController

  def test_account_preference_form_and_put_save
    get :account
    assert_response :success
    assert_select 'input[name="redmine_slack[username]"]', count: 1
    csrf_token = css_select('meta[name="csrf-token"]').first['content']
    put :account, params: {authenticity_token: csrf_token, user: {firstname: @user.firstname},
      pref: {}, redmine_slack: {username: ' UACCOUNT01 '}}
    assert_response :redirect
    assert_equal 'UACCOUNT01', User.find(@user.id).rslack_preference[:username]
  end
end

class SlackUserAdminSmokeTest < SlackWorkflowSmokeTest
  tests UsersController

  def test_admin_create_saves_slack_preference
    get :new
    assert_response :success
    csrf_token = css_select('meta[name="csrf-token"]').first['content']
    post :create, params: {authenticity_token: csrf_token,
      user: {login: 'slack-fixture-user', firstname: 'Slack', lastname: 'Fixture',
        mail: 'slack-fixture@example.invalid', password: 'FixturePassword_104!', password_confirmation: 'FixturePassword_104!'},
      pref: {}, redmine_slack: {username: ' UCREATED01 '}}
    assert_response :redirect
    assert_equal 'UCREATED01', User.find_by!(login: 'slack-fixture-user').rslack_preference[:username]
  end

  def test_admin_update_and_failed_update_keep_preferences_consistent
    get :edit, params: {id: @user.id}
    assert_response :success
    assert_select 'input[name="redmine_slack[username]"]', count: 1
    csrf_token = css_select('meta[name="csrf-token"]').first['content']
    put :update, params: {id: @user.id, authenticity_token: csrf_token, user: {firstname: @user.firstname}, pref: {}, redmine_slack: {username: 'UADMIN001'}}
    assert_response :redirect
    assert_equal 'UADMIN001', User.find(@user.id).rslack_preference[:username]
    put :update, params: {id: @user.id, authenticity_token: csrf_token, user: {firstname: ''}, pref: {}, redmine_slack: {username: 'UMUSTNOTSAVE'}}
    assert_response :success
    assert_equal 'UADMIN001', User.find(@user.id).rslack_preference[:username]
  end
end

class SlackSettingsSmokeTest < SlackWorkflowSmokeTest
  tests SettingsController

  def test_admin_controls_slack_delivery_in_plugin_settings
    get :plugin, params: {id: 'redmine_slack'}
    assert_response :success
    assert_select 'input[type=hidden][name="settings[delivery_enabled]"][value="0"]'
    assert_select '#settings_delivery_enabled[type=checkbox][value="1"]:not([checked])'
    csrf_token = css_select('meta[name="csrf-token"]').first['content']

    post :plugin, params: {id: 'redmine_slack', authenticity_token: csrf_token,
      settings: Setting.plugin_redmine_slack.merge('delivery_enabled' => '1')}
    assert_response :redirect
    assert_equal '1', Setting.plugin_redmine_slack['delivery_enabled']
    assert SlackListener.new.send(:delivery_enabled?)
    get :plugin, params: {id: 'redmine_slack'}
    assert_response :success
    assert_select '#settings_delivery_enabled[checked]'

    post :plugin, params: {id: 'redmine_slack', authenticity_token: csrf_token,
      settings: Setting.plugin_redmine_slack.merge('delivery_enabled' => '0')}
    assert_response :redirect
    assert_equal '0', Setting.plugin_redmine_slack['delivery_enabled']
    refute SlackListener.new.send(:delivery_enabled?)
    assert_equal '1', Setting.plugin_redmine_slack['post_updates']
    assert_empty SlackSmokeTransport.requests
  end
end

class SlackDeliverySmokeTest < Minitest::Test
  def setup
    raise 'Run only against the upgraded local db service' unless ActiveRecord::Base.connection_db_config.host == 'db'
    raise 'Local Slack delivery must start disabled in plugin settings' if Setting.plugin_redmine_slack.with_indifferent_access[:delivery_enabled] == '1'
    SlackSmokeTransport.requests.clear
    SlackSmokeTransport.status = 200
    SlackSmokeTransport.error = nil
    @listener = SlackListener.new
    @delivery_settings = {}.with_indifferent_access
    settings = @delivery_settings
    @listener.define_singleton_method(:slack_settings) { settings }
  end

  def teardown
    SlackSmokeTransport.error = nil
    SlackSmokeTransport.status = 200
  end

  def test_disabled_switch_suppresses_all_requests
    assert_equal '0', Redmine::Plugin.find(:redmine_slack).settings[:default]['delivery_enabled']
    [nil, '0', 'false', true].each do |value|
      @delivery_settings[:delivery_enabled] = value
      @listener.speak('Fixture', '#fixture', [], 'https://example.invalid/fixture')
      assert_empty SlackSmokeTransport.requests
    end
  end

  def test_deliver_after_commit_and_discard_after_rollback
    @delivery_settings[:delivery_enabled] = '1'
    ActiveRecord::Base.transaction do
      @listener.speak('Fixture committed', '#fixture', [], 'https://example.invalid/fixture')
      assert_empty SlackSmokeTransport.requests
    end
    assert_equal 1, SlackSmokeTransport.requests.length
    assert_equal 'Fixture committed', SlackSmokeTransport.requests.first.fetch(:payload).fetch('text')
    assert_equal '#fixture', SlackSmokeTransport.requests.first.fetch(:payload).fetch('channel')
    ActiveRecord::Base.transaction do
      @listener.speak('Fixture rolled back', '#fixture', [], 'https://example.invalid/fixture')
      raise ActiveRecord::Rollback
    end
    assert_equal 1, SlackSmokeTransport.requests.length
  end

  def test_delivery_disabled_before_commit_cancels_pending_notification
    @delivery_settings[:delivery_enabled] = '1'
    ActiveRecord::Base.transaction do
      @listener.speak('Fixture cancelled', '#fixture', [], 'https://example.invalid/fixture')
      assert_empty SlackSmokeTransport.requests
      @delivery_settings[:delivery_enabled] = '0'
    end
    assert_empty SlackSmokeTransport.requests
  end

  def test_transport_failures_do_not_raise_or_expose_endpoint
    @delivery_settings[:delivery_enabled] = '1'
    SlackSmokeTransport.status = 429
    @listener.speak('Fixture rejected', '#fixture', [], 'https://example.invalid/fixture')
    assert_equal 1, SlackSmokeTransport.requests.length
    SlackSmokeTransport.error = IOError.new('Fixture transport failure')
    @listener.speak('Fixture failed', '#fixture', [], 'https://example.invalid/fixture')
    assert_equal 1, SlackSmokeTransport.requests.length
  end
end