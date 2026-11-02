require 'minitest/autorun'
require 'action_controller/test_case'
require 'rake'

module SlackSmokeTransport
  class << self
    attr_accessor :requests, :status, :error, :body, :headers, :responses
  end
  self.requests = []
  self.status = 200
  self.body = '{"ok":true}'
  self.headers = {}

  def request(*_arguments)
    raise 'Unexpected HTTP request'
  end

  def get(url, query = nil, headers = nil, *)
    capture('GET', url, query, headers)
  end

  def post(url, body, *arguments)
    if body.is_a?(Hash) && body.key?(:payload) && url.to_s.start_with?('https://example.invalid/')
      raise SlackSmokeTransport.error if SlackSmokeTransport.error
      SlackSmokeTransport.requests << {url: url, payload: JSON.parse(body.fetch(:payload))}
      return Struct.new(:status).new(SlackSmokeTransport.status)
    end
    capture('POST', url, body, arguments.first)
  end

  def capture(method, url, body, headers)
    allowed = {'GET' => %w[users.lookupByEmail conversations.list], 'POST' => %w[conversations.open chat.postMessage]}
    endpoint = url.to_s.split('?').first
    raise 'Unexpected HTTP request' unless allowed.fetch(method).any? { |name| endpoint == "https://slack.com/api/#{name}" }
    raise SlackSmokeTransport.error if SlackSmokeTransport.error
    SlackSmokeTransport.requests << {method: method, url: url.to_s, body: body, headers: headers}
    response = SlackSmokeTransport.responses&.shift
    Struct.new(:status, :body, :headers).new(*(response || [SlackSmokeTransport.status, SlackSmokeTransport.body, SlackSmokeTransport.headers]))
  end
end

HTTPClient.prepend(SlackSmokeTransport)

class SlackTransportSmokeTest < ActiveSupport::TestCase
  def test_api_requests_are_captured_and_unknown_requests_are_blocked
    client = HTTPClient.new
    SlackSmokeTransport.requests.clear
    SlackSmokeTransport.status = 429
    SlackSmokeTransport.body = '{"ok":false}'
    SlackSmokeTransport.headers = {'Retry-After' => '7'}
    response = client.get('https://slack.com/api/users.lookupByEmail', {})
    assert_equal 429, response.status
    assert_equal '{"ok":false}', response.body
    assert_equal '7', response.headers['Retry-After']
    client.get('https://slack.com/api/conversations.list', {})
    %w[conversations.open chat.postMessage].each { |method| client.post("https://slack.com/api/#{method}", '{}') }
    assert_equal 4, SlackSmokeTransport.requests.length
    assert_raises(RuntimeError) { client.get('https://example.invalid/unexpected') }
    assert_raises(RuntimeError) { client.post('https://example.invalid/unexpected', '{}') }
    assert_raises(RuntimeError) { client.request('DELETE', 'https://example.invalid/unexpected') }
  ensure
    SlackSmokeTransport.requests.clear
    SlackSmokeTransport.status = 200
    SlackSmokeTransport.body = '{"ok":true}'
    SlackSmokeTransport.headers = {}
    SlackSmokeTransport.responses = nil
  end
end

class SlackClientSmokeTest < ActiveSupport::TestCase
  def setup
    SlackSmokeTransport.requests.clear
    SlackSmokeTransport.status = 200
    SlackSmokeTransport.body = '{"ok":true}'
    SlackSmokeTransport.headers = {}
    SlackSmokeTransport.error = nil
    @client = RedmineSlack::Client.new('xoxb-synthetic-secret')
  end

  def teardown
    SlackSmokeTransport.error = nil
    SlackSmokeTransport.status = 200
    SlackSmokeTransport.body = '{"ok":true}'
    SlackSmokeTransport.headers = {}
    SlackSmokeTransport.requests.clear
  end

  def test_customized_post_succeeds_and_rejection_does_not
    payload = {channel: 'C123', text: 'fixture', attachments: [{text: 'attachment'}], username: 'bot', icon_emoji: ':wave:'}
    assert_equal true, @client.post_message(payload)['ok']
    request = SlackSmokeTransport.requests.last
    assert_equal 'Bearer xoxb-synthetic-secret', request[:headers]['Authorization']
    assert_equal 'application/json', request[:headers]['Content-Type']
    assert_equal JSON.parse(JSON.generate(payload)), JSON.parse(request[:body])
    refute JSON.parse(request[:body]).key?('link_names')
    refute_includes request[:url], 'xoxb-synthetic-secret'
    SlackSmokeTransport.body = '{"ok":false,"error":"invalid_auth"}'
    assert_equal 'invalid_auth', assert_raises(RedmineSlack::DropError) { @client.post_message(payload) }.message
  end

  def test_response_classification_and_safe_transport_error
    %w[invalid_auth missing_scope channel_not_found not_in_channel is_archived messages_tab_disabled unlisted_error].each do |code|
      SlackSmokeTransport.body = {ok: false, error: code}.to_json
      assert_equal code, assert_raises(RedmineSlack::DropError) { @client.post_message({}) }.message
    end
    %w[internal_error service_unavailable].each do |code|
      SlackSmokeTransport.body = {ok: false, error: code}.to_json
      assert_raises(RedmineSlack::TransientError) { @client.open_conversation('U123') }
    end
    SlackSmokeTransport.body = '{"ok":false,"error":"users_not_found"}'
    assert_raises(RedmineSlack::IdentityMiss) { @client.lookup_by_email('fixture@example.invalid') }
    assert_raises(RedmineSlack::DropError) { @client.post_message({}) }
    SlackSmokeTransport.status = 503
    assert_raises(RedmineSlack::TransientError) { @client.post_message({}) }
    SlackSmokeTransport.status = 429
    SlackSmokeTransport.headers = {'Retry-After' => '7'}
    assert_equal 7, assert_raises(RedmineSlack::RateLimitError) { @client.post_message({}) }.wait
    SlackSmokeTransport.headers = {}
    assert_raises(RedmineSlack::TransientError) { @client.post_message({}) }
    SlackSmokeTransport.status = 200
    SlackSmokeTransport.body = '{"ok":false,"error":"ratelimited"}'
    SlackSmokeTransport.headers = {'retry-after' => '8'}
    assert_equal 8, assert_raises(RedmineSlack::RateLimitError) { @client.post_message({}) }.wait
    SlackSmokeTransport.error = IOError.new('xoxb-synthetic-secret fixture@example.invalid')
    error = assert_raises(RedmineSlack::TransientError) { @client.lookup_by_email('fixture@example.invalid') }
    assert_equal 'transport_error', error.message
    SlackSmokeTransport.error = HTTPClient::ReceiveTimeoutError.new('xoxb-synthetic-secret fixture@example.invalid')
    assert_equal 'transport_error', assert_raises(RedmineSlack::TransientError) { @client.post_message({}) }.message
  end
end

class SlackDependencySmokeTest < ActiveSupport::TestCase
  def test_required_hook_is_available
    assert_equal 1, GorbunovStudioBackgroundJobs.instance_variable_get(:@dedicated_queues).fetch('slack')
  end

  def test_dependency_is_too_old
    dependency = Redmine::Plugin.find(:'00_gorbunovstudio_background_jobs')
    version = dependency.version
    dependency.version('1.0.0')
    assert_raises(Redmine::PluginRequirementError) do
      load Rails.root.join('plugins/redmine_slack/init.rb')
    end
  ensure
    dependency.version(version) if dependency && version
  end
end

class SlackWorkflowSmokeTest < ActionController::TestCase
  tests IssuesController

  setup do
    raise 'Run only against the upgraded local db service' unless ActiveRecord::Base.connection_db_config.host == 'db'
    raise 'Local Slack delivery must start disabled in plugin settings' if Setting.plugin_redmine_slack.with_indifferent_access[:delivery_enabled] == '1'
    @connection = ActiveRecord::Base.connection
    @connection.begin_transaction(joinable: false)
    @previous_user = User.current
    @previous_adapter = ActiveJob::Base.queue_adapter
    @previous_cache = Rails.cache
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
    @listener.define_singleton_method(:speak) do |message, channel, attachments = [], icon = nil|
      if message.is_a?(Array)
        resolver = Object.new
        resolver.define_singleton_method(:member) { |id| User.find_by(id: id)&.rslack_preference&.[](:username) }
        message = RedmineSlack::MessageTemplate.render(message, resolver)
      end
      messages << {text: message, channel: channel, attachments: attachments, icon: icon}
    end
    @listener.define_singleton_method(:channel_for_project) { |_project| '#fixture-main' }
    @listener.define_singleton_method(:support_channel_for_project) { |_project| '#fixture-support' }
    SlackSmokeTransport.requests.clear
  end

  teardown do
    @connection.rollback_transaction if @connection
    User.current = @previous_user
    ActiveJob::Base.queue_adapter = @previous_adapter if @previous_adapter
    Rails.cache = @previous_cache if @previous_cache
    Setting.clear_cache
    SlackSmokeTransport.error = nil
    SlackSmokeTransport.status = 200
    SlackSmokeTransport.body = '{"ok":true}'
    SlackSmokeTransport.headers = {}
    SlackSmokeTransport.responses = nil
  end

end

class SlackMemberSmokeTest < SlackWorkflowSmokeTest
  include ActiveSupport::Testing::TimeHelpers
  setup do
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  def test_current_identity_and_literal_text
    resolver = RedmineSlack::MemberResolver.new(RedmineSlack::Client.new('fixture-token'))
    reference = RedmineSlack::MessageTemplate.mention(@executor)
    @executor.rslack_preference[:username] = 'WOVERRIDE1'
    assert_equal 'WOVERRIDE1', resolver.member(@executor.id)
    @executor.rslack_preference[:username] = 'UOVERRIDE1'
    assert_equal '<@UOVERRIDE1>', RedmineSlack::MessageTemplate.render([reference], resolver)
    assert_empty SlackSmokeTransport.requests
    @executor.rslack_preference[:username] = 'legacy-name'
    SlackSmokeTransport.body = '{"ok":true,"user":{"id":"ULOOKUP1"}}'
    assert_equal '<@ULOOKUP1>', RedmineSlack::MessageTemplate.render([reference], resolver)
    assert_equal 'legacy-name', @executor.rslack_preference[:username]
    assert_equal @executor.mail, SlackSmokeTransport.requests.last[:body][:email]
    assert_equal '{"redmine_user_id":1}', RedmineSlack::MessageTemplate.render(['{"redmine_user_id":1}'], resolver)
    Rails.cache.clear
    SlackSmokeTransport.body = '{"ok":false,"error":"users_not_found"}'
    reference['fallback'] = '<@danger> & name'
    assert_equal '&lt;@danger&gt; &amp; name', RedmineSlack::MessageTemplate.render([reference], resolver)
    assert_equal 'Missing', RedmineSlack::MessageTemplate.render([{'redmine_user_id' => -1, 'fallback' => 'Missing'}], resolver)
    @executor.update_columns(status: User::STATUS_LOCKED)
    @executor.rslack_preference[:username] = 'WLOCKED1'
    assert_equal 'WLOCKED1', resolver.member(@executor.id)
    @executor.rslack_preference[:username] = ''
    @executor.email_address.update_columns(address: '')
    SlackSmokeTransport.requests.clear
    assert_nil resolver.member(@executor.id)
    assert_empty SlackSmokeTransport.requests
  end

  def test_successful_member_and_dm_cache_without_negative_entries
    resolver = RedmineSlack::MemberResolver.new(RedmineSlack::Client.new('fixture-token'))
    @executor.rslack_preference[:username] = 'legacy'
    SlackSmokeTransport.body = '{"ok":false,"error":"users_not_found"}'
    assert_nil resolver.member(@executor.id)
    assert_nil Rails.cache.read(['redmine_slack', 'member', @executor.id])
    SlackSmokeTransport.body = '{"ok":true,"user":{"id":"UMEMBER1"}}'
    assert_equal 'UMEMBER1', resolver.member(@executor.id)
    assert_equal 'UMEMBER1', resolver.member(@executor.id)
    assert_equal 2, SlackSmokeTransport.requests.length
    SlackSmokeTransport.body = '{"ok":false,"error":"invalid_auth"}'
    assert_raises(RedmineSlack::DropError) { resolver.dm('UMEMBER1') }
    assert_nil Rails.cache.read(['redmine_slack', 'dm', 'UMEMBER1'])
    SlackSmokeTransport.body = '{"ok":true,"channel":{"id":"DDM1"}}'
    assert_equal 'DDM1', resolver.dm('UMEMBER1')
    assert_equal 'DDM1', resolver.dm('UMEMBER1')
    assert_equal 4, SlackSmokeTransport.requests.length
    refute SlackSmokeTransport.requests.any? { |request| request[:url].end_with?('/chat.postMessage') }
    assert_equal({'users' => 'UMEMBER1'}, JSON.parse(SlackSmokeTransport.requests.last[:body]))
    assert_equal 'legacy', @executor.rslack_preference[:username]
    @executor.email_address.update_columns(address: 'changed@example.invalid')
    assert_equal 'UMEMBER1', resolver.member(@executor.id)
    travel 24.hours + 1.second do
      SlackSmokeTransport.body = '{"ok":true,"user":{"id":"UNEW1"}}'
      assert_equal 'UNEW1', resolver.member(@executor.id)
      SlackSmokeTransport.body = '{"ok":true,"channel":{"id":"DNEW1"}}'
      assert_equal 'DNEW1', resolver.dm('UMEMBER1')
    end
  end

  def test_comment_tokenizer_boundaries_and_duplicates
    @executor.update_columns(login: 'fixture.name-test_user')
    login = @executor.reload.login
    text = "@#{login} (@#{login}) x@#{login} test@example.invalid @unknown_fixture"
    parts, users = RedmineSlack::MessageTemplate.tokenize(text)
    assert_equal [@executor.id], users.map(&:id)
    assert_equal 2, parts.count { |part| part.is_a?(Hash) }
    assert_includes parts.join, "x@#{login} test@example.invalid @unknown_fixture"
    @issue.assigned_to = @executor
    journal = @issue.init_journal(@user, "@#{login}")
    executor = @executor
    @listener.define_singleton_method(:get_executor) { |_issue| executor }
    message, = @listener.send(:prepare_comment_message, @issue, journal, '#fixture-main')
    assert_equal 1, message.count { |part| part.is_a?(Hash) && part['redmine_user_id'] == @executor.id }
  end
end

class SlackConversionSmokeTest < SlackWorkflowSmokeTest
  setup do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
    load Rails.root.join('plugins/redmine_slack/lib/tasks/redmine_slack.rake') unless Rake::Task.task_defined?('redmine_slack:convert_channels')
    @previous_apply = ENV['APPLY']
    @field = ProjectCustomField.find_by!(name: 'Slack Channel')
    @support = ProjectCustomField.find_by!(name: 'Slack Support Channel')
    @other_project = Project.where.not(id: @issue.project.id).first!
    @other_project.update_columns(status: Project::STATUS_ARCHIVED)
    @values = [[@issue.project, @field, '#fixture-convert'], [@other_project, @support, '#fixture-convert']].map do |project, field, name|
      value = CustomValue.find_or_initialize_by(customized_type: 'Project', customized_id: project.id, custom_field_id: field.id)
      value.value = name
      value.save!
      value
    end
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('channel' => '#fixture-convert', 'bot_token' => 'fixture-secret')
    @pages = [
      {ok: true, channels: [], response_metadata: {next_cursor: 'second'}},
      {ok: true, channels: [], response_metadata: {next_cursor: 'third'}},
      {ok: true, channels: [{name: 'fixture-convert', id: 'CFIXTURE1'}], response_metadata: {next_cursor: ''}}
    ]
  end

  teardown do
    ENV['APPLY'] = @previous_apply
    SlackSmokeTransport.responses = nil
  end

  def run_conversion(apply: false, pages: @pages)
    ENV['APPLY'] = apply ? '1' : nil
    SlackSmokeTransport.responses = pages.map { |page| page.is_a?(Array) ? page : [200, page.to_json, {}] }
    task = Rake::Task['redmine_slack:convert_channels']
    task.reenable
    output, = capture_io do
      begin
        task.invoke
      rescue RuntimeError => error
        @conversion_error = error.message
      end
    end
    output
  end

  def test_dry_run_and_apply_across_empty_page_and_duplicate_locations
    original = Setting.plugin_redmine_slack.deep_dup
    output = run_conversion
    assert_includes output, 'setting channel: "#fixture-convert" => CFIXTURE1 planned'
    @values.each { |value| assert_includes output, "project #{value.customized_id}/"; assert_equal '#fixture-convert', value.reload.value }
    assert_equal original, Setting.plugin_redmine_slack
    assert_equal 'third', SlackSmokeTransport.requests.last[:body][:cursor]
    output = run_conversion(apply: true)
    assert_includes output, 'CFIXTURE1 applied'
    @values.each { |value| assert_equal 'CFIXTURE1', value.reload.value }
    assert_equal 'CFIXTURE1', Setting.plugin_redmine_slack['channel']
    refute_includes output, 'fixture-secret'
    assert_includes run_conversion, 'CFIXTURE1" => unchanged'
  end

  def test_unresolved_and_failed_enumeration_do_not_write_names
    @values.first.update!(value: '#missing-fixture')
    @values.last.update!(value: 'invalid-fixture')
    output = run_conversion(apply: true)
    assert_includes output, 'unresolved (not invited or renamed)'
    assert_includes output, 'invalid unchanged'
    assert_equal 'Slack conversion: unresolved_or_invalid', @conversion_error
    assert_equal '#missing-fixture', @values.first.reload.value
    assert_equal 'invalid-fixture', @values.last.reload.value
    assert_equal 'CFIXTURE1', Setting.plugin_redmine_slack['channel']
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('channel' => '#fixture-convert')
    run_conversion(apply: true, pages: [@pages.first, [403, '{"ok":false,"error":"invalid_auth"}', {}]])
    assert_equal 'Slack conversion: http_403', @conversion_error
    assert_equal '#fixture-convert', Setting.plugin_redmine_slack['channel']
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

  def test_return_and_silent_effects_are_independent_of_delivery_switch
    %w[0 1].each do |enabled|
      Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('delivery_enabled' => enabled, 'bot_token' => 'fixture-token')
      @issue.custom_field_values = {'14' => '1', '12' => '2'}
      journal = @issue.init_journal(@user, '[silent-update]Fixture hidden')
      journal.notes = '[silent-update]Fixture hidden'
      @listener.prepare_issue_update(issue: @issue, journal: journal)
      assert_equal 0, @issue.custom_field_value(14).to_i
      assert_equal 3, @issue.custom_field_value(12).to_i
      assert_equal 'Fixture hidden', journal.notes
      message, = @listener.send(:prepare_comment_message, @issue, journal, '#fixture-main')
      assert_equal '', message
    end
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
    assert_includes message, RedmineSlack::MessageTemplate.mention(@executor)
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
    assert_includes message.grep(String).join, 'Issue was returned'
    assert_equal 'danger', attachment.fetch(:color)
    journal.user = User.find(3)
    message, _attachment, _icon, direct = @listener.send(:prepare_return_message, @issue, journal)
    assert message.present?
    assert_equal @executor, direct.fetch(:channel)
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
    assert reminders.all? { |message| message[:channel] == @executor }
    @messages.clear
    @listener.define_singleton_method(:build_review_list) { |_recipient| '' }
    @listener.define_singleton_method(:build_assigned_list) { |_recipient| '' }
    @listener.notify_issue_update(issue: @issue, journal: journal)
    refute @messages.any? { |message| message[:channel] == @executor }
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
    assert @messages.first[:text].start_with?('<!channel>')
    @messages.clear
    @issue.priority_id = 4
    @listener.controller_issues_new_after_save(issue: @issue)
    assert_empty @messages
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
    assert message.start_with?('<!channel>')
  end

  def test_progress_variants_and_independent_post_updates
    journal = @issue.init_journal(@user, '')
    executor = @executor
    @listener.define_singleton_method(:get_executor) { |_issue| executor }
    events = {
      SlackListener::PROGRESS_EVENT_STORY_CLAIMED => 'will take care',
      SlackListener::PROGRESS_EVENT_STORY_READY_FOR_REVIEW => 'ready for Review',
      SlackListener::PROGRESS_EVENT_STORY_PASSED_THE_REVIEW => 'passed the Review',
      SlackListener::PROGRESS_EVENT_STORY_PASSED_TESTING => 'hid your bugs',
      SlackListener::PROGRESS_EVENT_STORY_ACCEPTED => 'was just accepted'
    }
    events.each do |event, wording|
      parts, attachment, icon = @listener.send(:prepare_progress_message, @issue, journal, event)
      assert_includes Array(parts).grep(String).join, wording
      assert_equal 'good', attachment[:color]
      assert attachment[:thumb_url].present?
      assert icon.present?
    end
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('post_updates' => '0')
    @listener.notify_issue_update(issue: @issue, journal: journal)
    assert_empty @messages
    @issue.priority_id = 5
    @listener.controller_issues_new_after_save(issue: @issue)
    assert_equal 1, @messages.length
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
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('channel' => 'CDEFAULT')
    project_class = Struct.new(:parent, :values) do
      def custom_field_value(id); values[id]; end
    end
    parent = project_class.new(nil, {channel_field.id => 'CPARENT', support_field.id => 'GSUPPORT'})
    child = project_class.new(parent, {channel_field.id => 'CCHILD', support_field.id => 'GCHILD'})
    assert_equal 'CCHILD', listener.send(:channel_for_project, child)
    assert_equal 'GCHILD', listener.send(:support_channel_for_project, child)
    child.values.clear
    assert_equal 'CPARENT', listener.send(:channel_for_project, child)
    assert_equal 'GSUPPORT', listener.send(:support_channel_for_project, child)
    %w[- #old invalid].each do |invalid|
      child.values[channel_field.id] = invalid
      assert_nil listener.send(:channel_for_project, child)
      child.values.clear
      parent.values[channel_field.id] = invalid
      assert_equal 'CDEFAULT', listener.send(:channel_for_project, child)
    end
    parent.values[support_field.id] = '-'
    child.values[channel_field.id] = 'CCHILD'
    assert_equal 'CCHILD', listener.send(:support_channel_for_project, child)
    parent.values.clear
    assert_equal 'CDEFAULT', listener.send(:support_channel_for_project, parent)
    assert_empty SlackSmokeTransport.requests
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
    original_find = IssueQuery.method(:find)
    IssueQuery.define_singleton_method(:find) { |_id| raise 'fixture query error' }
    assert_raises(RuntimeError) { @listener.send(:issues_for_recipient, 8, @executor) }
    assert_equal previous_user, User.current
  ensure
    IssueQuery.define_singleton_method(:find, original_find) if original_find
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

  def test_failed_issue_save_does_not_enqueue
    ActiveJob::Base.queue_adapter = :test
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('delivery_enabled' => '1', 'bot_token' => 'fixture-token', 'channel' => 'CFIXTURE1')
    get :show, params: {id: @issue.id}
    csrf_token = css_select('meta[name="csrf-token"]').first['content']
    put :update, params: {id: @issue.id, authenticity_token: csrf_token,
      issue: {subject: '', notes: 'Fixture invalid update'}}
    assert_response :success
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == RedmineSlack::DeliveryJob }
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

  def test_token_is_preserved_replaced_filtered_and_never_rendered
    get :plugin, params: {id: 'redmine_slack'}
    assert_select '#slack-bot-token-status', text: 'Not configured'
    assert_select 'input[type=password][name="settings[bot_token]"][value=""]'
    assert_select '#settings_slack_url', count: 0
    csrf_token = css_select('meta[name="csrf-token"]').first['content']
    post :plugin, params: {id: 'redmine_slack', authenticity_token: csrf_token,
      settings: {bot_token: 'xoxb-fixture-token', delivery_enabled: '0', post_updates: '1'}}
    assert_equal 'xoxb-fixture-token', Setting.plugin_redmine_slack['bot_token']
    assert_equal '[FILTERED]', @request.filtered_parameters['settings']['bot_token']
    get :plugin, params: {id: 'redmine_slack'}
    assert_select '#slack-bot-token-status', text: 'Configured'
    assert_select 'input[type=password][name="settings[bot_token]"][value=""]'
    refute_includes response.body, 'xoxb-fixture-token'
    ['', nil].each do |value|
      submitted = {delivery_enabled: '0', post_updates: '1'}
      submitted[:bot_token] = value unless value.nil?
      post :plugin, params: {id: 'redmine_slack', authenticity_token: csrf_token, settings: submitted}
      assert_equal 'xoxb-fixture-token', Setting.plugin_redmine_slack['bot_token']
      assert_equal '1', Setting.plugin_redmine_slack['post_updates']
      assert_equal '0', Setting.plugin_redmine_slack['delivery_enabled']
    end
    post :plugin, params: {id: 'redmine_slack', authenticity_token: csrf_token,
      settings: {bot_token: 'xoxb-replacement'}}
    assert_equal 'xoxb-replacement', Setting.plugin_redmine_slack['bot_token']
  end

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

class SlackDeliverySmokeTest < SlackWorkflowSmokeTest
  setup do
    ActiveJob::Base.queue_adapter = :test
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @producer = SlackListener.new
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('bot_token' => 'fixture-token', 'delivery_enabled' => '1')
  end

  def test_switch_and_legacy_endpoint_never_enqueue
    assert_equal '0', Redmine::Plugin.find(:redmine_slack).settings[:default]['delivery_enabled']
    [nil, '0', 'false', true].each do |value|
      Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('delivery_enabled' => value)
      @producer.speak('Fixture', 'CFIXTURE1')
      assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
    end
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('delivery_enabled' => '1', 'bot_token' => '')
    @producer.speak('Fixture', 'CFIXTURE1')
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
    assert_empty SlackSmokeTransport.requests
  end

  def test_enqueue_without_secrets_and_cancel_before_execution
    @producer.speak('Fixture', 'CFIXTURE1', [{text: 'attachment'}], ':event:')
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    assert_equal 'slack', job[:queue]
    refute_includes job[:args].to_json, 'fixture-token'
    refute RedmineSlack::DeliveryJob.log_arguments
    assert_empty SlackSmokeTransport.requests
    envelope = ActiveJob::Arguments.deserialize(job[:args]).first
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('delivery_enabled' => '0')
    RedmineSlack::DeliveryJob.perform_now(envelope)
    assert_empty SlackSmokeTransport.requests
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('delivery_enabled' => '1')
    SlackSmokeTransport.status = 503
    RedmineSlack::DeliveryJob.perform_now(envelope)
    retry_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    SlackSmokeTransport.requests.clear
    Setting.plugin_redmine_slack = Setting.plugin_redmine_slack.merge('delivery_enabled' => '0')
    ActiveJob::Base.execute(retry_job)
    assert_empty SlackSmokeTransport.requests
  end

  def test_job_posts_customized_json_to_channel
    @producer.speak('Fixture', 'CFIXTURE1', [{text: 'attachment'}], ':event:')
    envelope = ActiveJob::Arguments.deserialize(ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args]).first
    RedmineSlack::DeliveryJob.perform_now(envelope)
    payload = JSON.parse(SlackSmokeTransport.requests.last[:body])
    assert_equal 'CFIXTURE1', payload['channel']
    assert_equal 'Fixture', payload['text']
    assert_equal ':event:', payload['icon_emoji']
    assert_equal 'fixture-bot', payload['username']
    assert_equal [{'text' => 'attachment'}], payload['attachments']
    refute payload.key?('link_names')
  end

  def test_unresolvable_dm_is_skipped_and_resolved_dm_uses_opened_channel
    @executor.rslack_preference[:username] = ''
    SlackSmokeTransport.body = '{"ok":false,"error":"users_not_found"}'
    @producer.speak('Fixture DM', @executor, [{}])
    envelope = ActiveJob::Arguments.deserialize(ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args]).first
    RedmineSlack::DeliveryJob.perform_now(envelope)
    assert_equal 1, SlackSmokeTransport.requests.length
    assert SlackSmokeTransport.requests.first[:url].end_with?('/users.lookupByEmail')
    SlackSmokeTransport.requests.clear
    @executor.rslack_preference[:username] = 'UDIRECT1'
    SlackSmokeTransport.responses = [[200, '{"ok":true,"channel":{"id":"DDIRECT1"}}', {}], [200, '{"ok":true}', {}]]
    RedmineSlack::DeliveryJob.perform_now(envelope)
    assert SlackSmokeTransport.requests.first[:url].end_with?('/conversations.open')
    assert_equal 'DDIRECT1', JSON.parse(SlackSmokeTransport.requests.last[:body])['channel']
  ensure
    SlackSmokeTransport.responses = nil
  end

  def test_retries_rate_limits_and_transient_errors_at_each_stage
    @executor.rslack_preference[:username] = ''
    envelope = {'destination' => {'kind' => 'user', 'user_id' => @executor.id}, 'text_parts' => ['fixture']}
    successes = [
      {ok: true, user: {id: 'UMEMBER1'}},
      {ok: true, channel: {id: 'DDM1'}},
      {ok: true}
    ]
    3.times do |stage|
      Rails.cache.clear
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      replies = successes.first(stage).map { |body| [200, body.to_json, {}] }
      replies << [429, '{}', {'Retry-After' => '7'}]
      SlackSmokeTransport.responses = replies
      started = Time.now.to_f
      RedmineSlack::DeliveryJob.perform_now(envelope)
      queued = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      assert_equal 'slack', queued[:queue]
      assert_in_delta started + 7, queued[:at], 2
      assert_equal envelope, ActiveJob::Arguments.deserialize(queued[:args]).first
      SlackSmokeTransport.responses = successes.drop(stage).map { |body| [200, body.to_json, {}] }
      ActiveJob::Base.execute(queued)
      assert_equal 'DDM1', JSON.parse(SlackSmokeTransport.requests.last[:body])['channel']

      Rails.cache.clear
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      SlackSmokeTransport.responses = successes.first(stage).map { |body| [200, body.to_json, {}] } + [[503, '{}', {}]]
      RedmineSlack::DeliveryJob.perform_now(envelope)
      queued = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      assert_equal 'slack', queued[:queue]
      assert_in_delta Time.now.to_f + 3, queued[:at], 2
      SlackSmokeTransport.responses = successes.drop(stage).map { |body| [200, body.to_json, {}] }
      ActiveJob::Base.execute(queued)
      assert_equal 'DDM1', JSON.parse(SlackSmokeTransport.requests.last[:body])['channel']
    end
    Rails.cache.clear
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    SlackSmokeTransport.responses = [[429, '{}', {}]]
    RedmineSlack::DeliveryJob.perform_now(envelope)
    queued = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    assert_in_delta Time.now.to_f + 3, queued[:at], 2
  ensure
    SlackSmokeTransport.responses = nil
  end

  def test_transient_attempts_exhaust_and_permanent_errors_do_not_retry
    envelope = {'destination' => {'kind' => 'channel', 'id' => 'CFIXTURE1'}, 'text_parts' => ['fixture']}
    SlackSmokeTransport.status = 503
    RedmineSlack::DeliveryJob.perform_now(envelope)
    4.times do
      queued = ActiveJob::Base.queue_adapter.enqueued_jobs.shift
      assert queued
      ActiveJob::Base.execute(queued)
    end
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
    assert_equal 5, SlackSmokeTransport.requests.length
    SlackSmokeTransport.status = 200
    SlackSmokeTransport.body = '{"ok":false,"error":"invalid_auth"}'
    RedmineSlack::DeliveryJob.perform_now(envelope)
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
    SlackSmokeTransport.error = Timeout::Error.new('fixture accepted but response timed out')
    RedmineSlack::DeliveryJob.perform_now(envelope)
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.length
    SlackSmokeTransport.error = nil
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  def test_existing_edit_transaction_persists_and_rolls_back_jobs
    ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
    listener = SlackListener.new
    listener.define_singleton_method(:channel_for_project) { |_project| 'CFIXTURE1' }
    listener.define_singleton_method(:support_channel_for_project) { |_project| 'CFIXTURE1' }
    listener.define_singleton_method(:is_client) { |_user, _project| false }
    baseline = GoodJob::Job.where(queue_name: 'slack').count
    journal = @issue.init_journal(@user, 'Fixture transaction comment')
    ActiveRecord::Base.transaction(requires_new: true) do
      listener.prepare_issue_update(issue: @issue, journal: journal)
      listener.notify_issue_update(issue: @issue, journal: journal)
      assert_operator GoodJob::Job.where(queue_name: 'slack').count, :>, baseline
      assert_empty SlackSmokeTransport.requests
      raise ActiveRecord::Rollback
    end
    assert_equal baseline, GoodJob::Job.where(queue_name: 'slack').count
    ActiveRecord::Base.transaction(requires_new: true) do
      listener.prepare_issue_update(issue: @issue, journal: journal)
      listener.notify_issue_update(issue: @issue, journal: journal)
    end
    assert_operator GoodJob::Job.where(queue_name: 'slack').count, :>, baseline
    assert_empty SlackSmokeTransport.requests
  end

  def test_private_notes_never_enter_job_or_payload_and_lists_are_snapshotted
    listener = SlackListener.new
    listener.define_singleton_method(:channel_for_project) { |_project| 'CFIXTURE1' }
    listener.define_singleton_method(:support_channel_for_project) { |_project| 'CFIXTURE1' }
    listener.define_singleton_method(:is_client) { |_user, _project| false }
    executor = @executor
    listener.define_singleton_method(:get_executor) { |_issue| executor }
    journal = @issue.init_journal(@user, 'Private fixture secret 513')
    journal.private_notes = true
    journal.details.build(property: 'attr', prop_key: 'subject', old_value: 'old', value: 'new')
    listener.prepare_issue_update(issue: @issue, journal: journal)
    listener.notify_issue_update(issue: @issue, journal: journal)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.dup
    assert jobs.any?
    refute_includes jobs.map { |job| job[:args] }.to_json, 'Private fixture secret 513'
    jobs.each { |job| RedmineSlack::DeliveryJob.perform_now(ActiveJob::Arguments.deserialize(job[:args]).first) }
    refute_includes SlackSmokeTransport.requests.to_json, 'Private fixture secret 513'

    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    SlackSmokeTransport.requests.clear
    listener.define_singleton_method(:can_review_code) { |_user, _project| true }
    listener.define_singleton_method(:build_review_list) { |_user| 'Snapshot review list' }
    listener.define_singleton_method(:build_assigned_list) { |_user| 'Snapshot assigned list' }
    @issue = Issue.find(@issue.id)
    listener.define_singleton_method(:is_story) { |_issue| true }
    journal = @issue.init_journal(@executor, '')
    listener.prepare_issue_update(issue: @issue, journal: journal)
    @issue.status_id = 8
    journal.details.build(property: 'attr', prop_key: 'status_id', old_value: '2', value: '8')
    listener.notify_issue_update(issue: @issue, journal: journal)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.dup
    reminders = jobs.select { |job| job[:args].to_json.include?('Snapshot') }
    assert_equal 2, reminders.length
    assert reminders.all? { |job| ActiveJob::Arguments.deserialize(job[:args]).first.dig('destination', 'user_id') == executor.id }
    @issue.status_id = 9
    original_find = IssueQuery.method(:find)
    IssueQuery.define_singleton_method(:find) { |_id| raise 'job must not query issues' }
    SlackSmokeTransport.body = '{"ok":true,"channel":{"id":"DDM1"}}'
    reminders.each { |job| RedmineSlack::DeliveryJob.perform_now(ActiveJob::Arguments.deserialize(job[:args]).first) }
    assert_includes SlackSmokeTransport.requests.to_json, 'Snapshot review list'
    assert_includes SlackSmokeTransport.requests.to_json, 'Snapshot assigned list'
  ensure
    IssueQuery.define_singleton_method(:find, original_find) if original_find
  end

  def test_manager_return_and_saved_changeset_enqueue_expected_envelopes
    listener = SlackListener.new
    listener.define_singleton_method(:channel_for_project) { |_project| 'CFIXTURE1' }
    listener.define_singleton_method(:support_channel_for_project) { |_project| 'CFIXTURE1' }
    listener.define_singleton_method(:is_client) { |_user, _project| false }
    listener.define_singleton_method(:is_story) { |_issue| true }
    executor = User.active.where.not(id: SlackListener::MANAGER_USER).first!
    listener.define_singleton_method(:get_executor) { |_issue| executor }
    listener.define_singleton_method(:get_reviewer) { |_issue| executor }
    @issue.assigned_to = executor
    @issue.status_id = SlackListener::ISSUE_STATUS_FEEDBACK
    journal = @issue.init_journal(User.find(SlackListener::MANAGER_USER), '')
    journal.details.build(property: 'attr', prop_key: 'assigned_to_id', old_value: '1', value: executor.id.to_s)
    listener.instance_variable_set(:@isReturn, true)
    listener.notify_issue_update(issue: @issue, journal: journal)
    envelopes = ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| ActiveJob::Arguments.deserialize(job[:args]).first }
    reviewer = envelopes.find { |item| item.dig('destination', 'user_id') == executor.id }
    assert reviewer
    assert_includes reviewer['text_parts'].join, 'which you were reviewing'
    assert reviewer['attachments'].first[:fields].is_a?(Array)

    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    issue = Issue.find(@issue.id)
    issue.init_journal(@user, 'Fixture changeset update')
    issue.subject = 'Slack fixture changeset'
    repository = Struct.new(:project, :identifier_param).new(issue.project, 'fixture-repository')
    changeset = Struct.new(:repository, :revision, :comments).new(repository, 'fixture-revision', 'Fixture commit')
    listener.model_changeset_scan_commit_for_issue_ids_pre_issue_update(issue: issue, changeset: changeset)
    envelope = ActiveJob::Arguments.deserialize(ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args]).first
    assert_includes envelope['text_parts'].join, 'Slack fixture changeset'
    assert_includes envelope['attachments'].first[:text], 'fixture-revision'
    refute_includes envelope['attachments'].first[:text], 'translation missing'
    assert_equal 'Fixture changeset update', issue.journals.order(id: :desc).first.notes
  end
end
