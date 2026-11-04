require 'minitest/autorun'
require 'action_controller/test_case'
require 'rake'
require 'tempfile'

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
    allowed = {'GET' => %w[users.lookupByEmail users.info conversations.list conversations.history files.info], 'POST' => %w[conversations.open chat.postMessage files.getUploadURLExternal files.completeUploadExternal]}
    endpoint = url.to_s.split('?').first
    synthetic_upload = method == 'POST' && url.to_s == 'https://upload.example.invalid/synthetic'
    synthetic_file = method == 'GET' && url.to_s == 'https://files.slack.com/synthetic-file'
    raise 'Unexpected HTTP request' unless synthetic_upload || synthetic_file || allowed.fetch(method).any? { |name| endpoint == "https://slack.com/api/#{name}" }
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
    assert_raises(RuntimeError) { client.post('https://upload.example.invalid/other', 'bytes') }
    assert_raises(RuntimeError) { client.post('https://slack.com/api/files.other', '{}') }
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

  def test_external_upload_requests
    bytes = "\x00\xFFabc".b
    SlackSmokeTransport.responses = [[200, '{"ok":true,"upload_url":"https://upload.example.invalid/synthetic","file_id":"F1"}', {}], [200, 'OK', {}], [200, '{"ok":true}', {}]]
    upload = @client.upload_url('fixture.png', bytes.bytesize)
    assert @client.upload_file(upload.fetch('upload_url'), bytes)
    assert @client.complete_upload(files: [{id: upload.fetch('file_id')}, {id: 'F2'}], channel_id: 'C1')['ok']
    form, raw, complete = SlackSmokeTransport.requests
    assert_equal({filename: 'fixture.png', length: 5}, form[:body])
    assert_equal 'Bearer xoxb-synthetic-secret', form[:headers]['Authorization']
    assert_equal bytes, raw[:body]
    refute raw[:headers].key?('Authorization')
    assert_equal 'application/json', complete[:headers]['Content-Type']
    assert_equal 'Bearer xoxb-synthetic-secret', complete[:headers]['Authorization']
    assert_equal [{'id' => 'F1'}, {'id' => 'F2'}], JSON.parse(complete[:body])['files']
  ensure
    SlackSmokeTransport.responses = nil
  end

  def test_upload_failure_classification
    url = 'https://upload.example.invalid/synthetic'
    SlackSmokeTransport.body = 'not json'
    assert @client.upload_file(url, 'bytes')
    SlackSmokeTransport.status = 429
    SlackSmokeTransport.headers = {'Retry-After' => '7'}
    assert_equal 7, assert_raises(RedmineSlack::RateLimitError) { @client.upload_file(url, 'bytes') }.wait
    SlackSmokeTransport.headers = {'Retry-After' => 'invalid'}
    assert_raises(RedmineSlack::TransientError) { @client.upload_file(url, 'bytes') }
    SlackSmokeTransport.status = 503
    assert_raises(RedmineSlack::TransientError) { @client.upload_file(url, 'bytes') }
    SlackSmokeTransport.status = 403
    assert_equal 'http_403', assert_raises(RedmineSlack::DropError) { @client.upload_file(url, 'bytes') }.message
    SlackSmokeTransport.error = IOError.new('secret')
    error = assert_raises(RedmineSlack::TransientError) { @client.upload_file(url, 'bytes') }
    assert_equal 'transport_error', error.message
    assert_nil error.cause
    SlackSmokeTransport.error = nil
    SlackSmokeTransport.status = 200
    SlackSmokeTransport.body = '{"ok":false,"error":"invalid_auth"}'
    assert_raises(RedmineSlack::DropError) { @client.upload_url('fixture.png', 5) }
    SlackSmokeTransport.body = '{"ok":false,"error":"internal_error"}'
    assert_raises(RedmineSlack::TransientError) { @client.complete_upload(files: []) }
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
    assert_nil error.cause
    SlackSmokeTransport.error = HTTPClient::ReceiveTimeoutError.new('xoxb-synthetic-secret fixture@example.invalid')
    error = assert_raises(RedmineSlack::TransientError) { @client.post_message({}) }
    assert_equal 'transport_error', error.message
    assert_nil error.cause
    SlackSmokeTransport.error = HTTPClient::BadResponseError.new('xoxb-synthetic-secret fixture@example.invalid')
    assert_nil assert_raises(RedmineSlack::DropError) { @client.post_message({}) }.cause
    SlackSmokeTransport.error = nil
    SlackSmokeTransport.body = 'xoxb-synthetic-secret fixture@example.invalid'
    assert_nil assert_raises(RedmineSlack::DropError) { @client.post_message({}) }.cause
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

  def html(text)
    assert Redmine::WikiFormatting::CommonMark::PIPELINE_CONFIG[:commonmarker_render_options][:hardbreaks]
    Redmine::WikiFormatting::CommonMark::Formatter.new(text).to_html
  end

  def rich_section(*elements)
    {'type' => 'rich_text_section', 'elements' => elements}
  end

  def rich_text(text, style = nil)
    {'type' => 'text', 'text' => text, 'style' => style}
  end

  def rich_blocks(*elements)
    [{'type' => 'rich_text', 'elements' => elements}]
  end

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
    @listener.define_singleton_method(:speak) do |message, channel, attachments = [], icon = nil, image_ids = []|
      if message.is_a?(Array)
        resolver = Object.new
        resolver.define_singleton_method(:member) { |id| User.find_by(id: id)&.rslack_preference&.[](:username) }
        message = RedmineSlack::MessageTemplate.render(message, resolver)
      end
      messages << {text: message, channel: channel, attachments: attachments, icon: icon, image_ids: image_ids}
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

  def test_reverse_identity_prefers_preference_and_caches_successful_email_matches
    resolver = RedmineSlack::MemberResolver.new(RedmineSlack::Client.new('fixture-token'))
    @executor.rslack_preference[:username] = 'UPREFERRED'
    @executor.preference.save!
    assert_equal @executor.id, resolver.user('UPREFERRED').id
    assert_empty SlackSmokeTransport.requests
    locked = User.active.where.not(id: @user.id).first!
    original_preference = locked.rslack_preference[:username]
    locked.rslack_preference[:username] = 'ULOCKEDPREF'
    locked.update_columns(status: User::STATUS_LOCKED)
    SlackSmokeTransport.body = {ok: true, user: {profile: {email: @user.mail}}}.to_json
    assert_equal @user.id, resolver.user('ULOCKEDPREF').id
    locked.update_columns(status: User::STATUS_ACTIVE)
    locked.rslack_preference[:username] = original_preference
    SlackSmokeTransport.requests.clear
    SlackSmokeTransport.body = {ok: true, user: {profile: {email: @user.mail.upcase, display_name: 'Fixture Name'}}}.to_json
    assert_equal @user.id, resolver.user('UEMAIL').id
    assert_equal @user.id, resolver.user('UEMAIL').id
    assert_equal 1, SlackSmokeTransport.requests.size
    assert_equal 'Fixture Name', resolver.display_name('UEMAIL')
    assert_equal 1, SlackSmokeTransport.requests.size
    SlackSmokeTransport.body = '{"ok":true,"user":{"profile":{}}}'
    2.times { assert_nil resolver.user('UNMATCHED') }
    assert_equal 2, SlackSmokeTransport.requests.size
    assert_nil RedmineSlack::MemberResolver.new(RedmineSlack::Client.new('fixture-token')).user('UNMATCHED')
    assert_equal 3, SlackSmokeTransport.requests.size
    SlackSmokeTransport.body = '{"ok":false,"error":"invalid_auth"}'
    2.times { assert_raises(RedmineSlack::DropError) { resolver.user('UFAILURE') } }
    assert_nil Rails.cache.read(['redmine_slack', 'reverse_member', 'UFAILURE'])
    travel 24.hours + 1.second do
      SlackSmokeTransport.body = {ok: true, user: {profile: {email: @user.mail}}}.to_json
      assert_equal @user.id, resolver.user('UEMAIL').id
      assert_equal 5, SlackSmokeTransport.requests.size
    end
    @user.update_columns(status: User::STATUS_LOCKED)
    SlackSmokeTransport.body = {ok: true, user: {profile: {email: @user.mail}}}.to_json
    assert_nil resolver.user('ULOCKEDEMAIL')
    assert_nil Rails.cache.read(['redmine_slack', 'reverse_member', 'ULOCKEDEMAIL'])
    assert_equal 'UPREFERRED', @executor.reload.rslack_preference[:username]
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

class SlackInboundMessageSmokeTest < SlackWorkflowSmokeTest
  def test_rich_text_uses_blocks_but_references_use_text
    section = ->(text) { {'type' => 'rich_text_section', 'elements' => [{'type' => 'text', 'text' => text}]} }
    blocks = [{'type' => 'header', 'text' => 'ignored'}, {'type' => 'rich_text', 'elements' => [section.call('first')]},
      {'type' => 'rich_text', 'elements' => [section.call('second')]}]
    message = RedmineSlack::InboundMessage.new('#12+= #34', blocks)
    assert_equal 12, message.marker
    assert_equal [12, 34], message.references
    assert_equal [34], message.preview_references
    assert_equal "<p>first</p>\n<p>second</p>", html(message.convert(Object.new))
  end

  def test_rich_text_literal_and_styles
    elements = [
      {'type' => 'text', 'text' => ' bold ', 'style' => {'bold' => true}},
      {'type' => 'text', 'text' => 'italic', 'style' => {'italic' => true}},
      {'type' => 'text', 'text' => 'strike', 'style' => {'strike' => true}},
      {'type' => 'text', 'text' => 'a`b', 'style' => {'code' => true}},
      {'type' => 'text', 'text' => "\n# TODO later\ntext\n---\n__init__ 2*3*4 <div> &amp;\n- item\n1. item\na | b\n#123 @login /path file.txt"}
    ]
    blocks = [{'type' => 'rich_text', 'elements' => [{'type' => 'rich_text_section', 'elements' => elements}]}]
    source = RedmineSlack::InboundMessage.new('', blocks).convert(Object.new)
    assert_includes source, '#123 @login /path file.txt'
    result = html(source)
    ['<strong>bold</strong>', '<em>italic</em>', '<del>strike</del>', '<code>a`b</code>'].each { |value| assert_includes result, value }
    text = Nokogiri::HTML.fragment(result).text
    ['# TODO later', '__init__ 2*3*4 <div> &amp;', '- item', '1. item', 'a | b', '#123 @login /path file.txt'].each { |value| assert_includes text, value }
    refute_match(/<h[12]>|<ul>|<ol>|<table>|<div>/, result)
    assert_match(/<strong>bold<\/strong> <em>italic<\/em>/, result)
    assert_includes Nokogiri::HTML.fragment(result).text, "text\n---"
  end

  def test_rich_text_inline_mappings
    resolver = Object.new
    linked = @user
    resolver.define_singleton_method(:user) { |id| id == 'ULINKED' ? linked : nil }
    resolver.define_singleton_method(:display_name) { |_| 'Slack *Name*' }
    elements = [
      {'type' => 'link', 'url' => 'mailto:a@b.com', 'text' => 'mail [me]', 'style' => {'bold' => true}},
      rich_text(' '), {'type' => 'link', 'url' => 'https://github.com/a_b/c_d*e'}, rich_text(' '),
      {'type' => 'link', 'url' => 'https://example.invalid/space here'}, rich_text(' '),
      {'type' => 'link', 'url' => 'https://example.invalid/a (b)', 'text' => 'spaced'}, rich_text(' '),
      {'type' => 'user', 'user_id' => 'ULINKED'}, rich_text(' '), {'type' => 'user', 'user_id' => 'UOTHER'}, rich_text(' '),
      *%w[C1 C2 C3].flat_map { |id| [{'type' => 'channel', 'channel_id' => id}, rich_text(' ')] },
      *%w[S1 S2 S3].flat_map { |id| [{'type' => 'usergroup', 'usergroup_id' => id}, rich_text(' ')] },
      *%w[here channel everyone].flat_map { |range| [{'type' => 'broadcast', 'range' => range}, rich_text(' ')] },
      {'type' => 'emoji', 'name' => 'tada', 'unicode' => '1f389'}, rich_text(' '),
      {'type' => 'emoji', 'name' => 'custom'}, rich_text(' '), {'type' => 'date', 'fallback' => 'Nov 14'}, rich_text(' '),
      {'type' => 'unknown', 'text' => '<literal>'}, rich_text(' '), {'type' => 'unknown', 'url' => 'https://example.invalid/other'}, {'type' => 'unknown'}
    ]
    message = RedmineSlack::InboundMessage.new('<#C1|general> <#C2|> <!subteam^S1|@devs> <!subteam^S2|>', rich_blocks(rich_section(*elements)))
    fragment = Nokogiri::HTML.fragment(html(message.convert(resolver)))
    assert_equal 'mail [me]', fragment.at_css('a[href="mailto:a@b.com"] strong').text
    assert_equal 'https://github.com/a_b/c_d*e', fragment.at_css('a[href="https://github.com/a_b/c_d*e"]').text
    assert_equal 'https://example.invalid/space here', fragment.at_css('a[href="https://example.invalid/space%20here"]').text
    assert fragment.at_css('a[href="https://example.invalid/a%20(b)"]')
    ["@#{@user.login}", 'Slack *Name*', '#general #channel #channel', '@devs @group @group', '@here @channel @everyone', '🎉 :custom: Nov 14', '<literal>', 'https://example.invalid/other'].each { |value| assert_includes fragment.text, value }
    assert_empty SlackSmokeTransport.requests
  end

  def test_rich_text_link_boundaries_destinations_and_adjacent_styles
    url = 'https://example.invalid/?x=&copy;'
    backslash_url = 'https://example.invalid/a\\_b'
    elements = [rich_text('!'), {'type' => 'link', 'url' => url, 'text' => 'label'}, rich_text(' '),
      {'type' => 'link', 'url' => url}, rich_text(' '), {'type' => 'link', 'url' => backslash_url, 'text' => 'backslash'}, rich_text(' '),
      {'type' => 'link', 'url' => backslash_url}, rich_text(' '), rich_text('abc', {'bold' => true}), rich_text('def', {'bold' => true}), rich_text(' '),
      rich_text('one`two', {'code' => true}), rich_text('three', {'code' => true, 'bold' => true})]
    fragment = Nokogiri::HTML.fragment(html(RedmineSlack::InboundMessage.new('', rich_blocks(rich_section(*elements))).convert(Object.new)))
    assert_equal [url, url, 'https://example.invalid/a%5C_b', 'https://example.invalid/a%5C_b'], fragment.css('a').map { |link| link['href'] }
    assert_includes fragment.text, '!label'
    refute fragment.at_css('img')
    assert_equal 'abcdef', fragment.at_css('strong').text
    assert_equal 'one`twothree', fragment.at_css('code').text
  end

  def test_rich_text_list_item_continuation_paragraphs
    list = {'type' => 'rich_text_list', 'style' => 'bullet', 'elements' => [rich_section(rich_text("first\n\nsecond")), rich_section(rich_text('third'))]}
    fragment = Nokogiri::HTML.fragment(html(RedmineSlack::InboundMessage.new('', rich_blocks(list)).convert(Object.new)))
    assert_equal 1, fragment.css('ul').size
    assert_equal 2, fragment.css('ul > li').size
    assert_equal %w[first second], fragment.css('ul > li').first.css('p').map(&:text)
    assert_equal 'third', fragment.css('ul > li').last.text.strip
  end

  def test_rich_text_structures_and_marker
    section = ->(text) { rich_section(rich_text(text)) }
    list = ->(style, indent, texts, offset = 0) { {'type' => 'rich_text_list', 'style' => style, 'indent' => indent, 'offset' => offset, 'elements' => texts.map { |text| section.call(text) }} }
    blocks = rich_blocks(section.call("before\n"), {'type' => 'rich_text_preformatted', 'elements' => [rich_text("first\n```\n"), {'type' => 'link', 'url' => 'https://example.invalid/code'}, rich_text("\nlast")]},
      {'type' => 'rich_text_quote', 'elements' => [rich_text("quote\nsecond")]}, section.call('after'),
      list.call('bullet', 0, ['bullet parent']), list.call('ordered', 1, ['ordered child']),
      list.call('ordered', 0, ['ordered parent']), list.call('bullet', 1, ['bullet child']))
    source = RedmineSlack::InboundMessage.new('', blocks).convert(Object.new)
    assert_match(/\Abefore\n\n`/, source)
    fragment = Nokogiri::HTML.fragment(html(source))
    assert_equal "first\n```\nhttps://example.invalid/code\nlast\n", fragment.at_css('pre code').text
    assert_includes fragment.at_css('blockquote').text, 'quote'
    assert_equal 'after', fragment.css('p').find { |p| p.text == 'after' }.text
    assert fragment.at_css('ul > li > ol'), fragment.to_html
    assert_equal 'ordered child', fragment.at_css('ul > li > ol > li').text
    assert_equal 'bullet child', fragment.at_css('ol > li > ul > li').text
    offset = Nokogiri::HTML.fragment(html(RedmineSlack::InboundMessage.new('', rich_blocks(list.call('ordered', 0, ['third', 'fourth'], 2))).convert(Object.new)))
    assert_equal '3', offset.at_css('ol')['start']
    assert_equal %w[third fourth], offset.css('li').map(&:text)
    message = RedmineSlack::InboundMessage.new('#12+= #34', rich_blocks(rich_section(rich_text('#12+= first #12+=', {'bold' => true}), rich_text(' #12+='))))
    result = Nokogiri::HTML.fragment(html(message.convert(Object.new)))
    assert_equal 'first #12+=', result.at_css('strong').text
    assert_equal 2, result.text.scan('#12+=').size
    assert_equal 12, message.marker
    assert_equal [34], message.preview_references
  end

  def slack_table(rows, column_settings = nil)
    block = {'type' => 'table', 'rows' => rows}
    block['column_settings'] = column_settings if column_settings
    block
  end

  def rich_cell(*elements)
    {'type' => 'rich_text', 'elements' => [rich_section(*elements)]}
  end

  def raw_cell(text)
    {'type' => 'raw_text', 'text' => text}
  end

  def test_table_block_renders_between_rich_text_blocks
    table = slack_table([
      [rich_cell(rich_text('Hospital', {'bold' => true})), rich_cell(rich_text('Contact Email', {'bold' => true})), raw_cell('Visits')],
      [raw_cell('Kids | Art'), rich_cell({'type' => 'link', 'url' => 'mailto:rachel@kidsandart.org', 'text' => 'rachel@kidsandart.org'}), {'type' => 'raw_number', 'value' => 12, 'text' => '12'}],
      [rich_cell(rich_text("Dana-Farber\n(at Harvard)")), rich_cell(rich_text('a|b', {'code' => true}))],
      [raw_cell('# not a heading'), raw_cell('')]
    ], [nil, {'align' => 'center'}, {'align' => 'right'}])
    blocks = [{'type' => 'rich_text', 'elements' => [rich_section(rich_text("ok these should be them.\n"))]}, table,
      {'type' => 'rich_text', 'elements' => [rich_section(rich_text('after'))]}]
    source = RedmineSlack::InboundMessage.new('#12+= ok', blocks).convert(Object.new)
    fragment = Nokogiri::HTML.fragment(html(source))
    assert_equal %w[p table p], fragment.element_children.map(&:name), source
    assert_equal 'ok these should be them.', fragment.element_children.first.text
    assert_equal 'after', fragment.element_children.last.text
    assert_equal %w[Hospital] + ['Contact Email', 'Visits'], fragment.css('thead th').map(&:text)
    assert_equal 'Hospital', fragment.at_css('thead th strong').text
    rows = fragment.css('tbody tr')
    assert_equal 3, rows.size
    assert rows.all? { |row| row.css('td').size == 3 }, fragment.to_html
    assert_equal ['Kids | Art', 'rachel@kidsandart.org', '12'], rows[0].css('td').map(&:text)
    assert_equal 'mailto:rachel@kidsandart.org', rows[0].at_css('a')['href']
    assert_equal ['Dana-Farber(at Harvard)', 'a|b', ''], rows[1].css('td').map { |cell| cell.text.strip }
    assert rows[1].at_css('td br'), fragment.to_html
    assert_equal 'a|b', rows[1].at_css('td code').text
    assert_equal ['# not a heading', '', ''], rows[2].css('td').map(&:text)
    refute fragment.at_css('h1')
    assert_match(/text-align:\s*center|align="center"/, fragment.at_css('thead th:nth-child(2)').to_html)
    assert_match(/text-align:\s*right|align="right"/, fragment.at_css('thead th:nth-child(3)').to_html)
    refute_match(/text-align|align=/, fragment.at_css('thead th:nth-child(1)').to_html)
  end

  def test_table_only_message_does_not_fall_back_to_text
    table = slack_table([[raw_cell('A'), raw_cell('B')], [raw_cell('1'), raw_cell('2')]])
    message = RedmineSlack::InboundMessage.new('#12+= fallback text', [{'type' => 'section'}, table])
    fragment = Nokogiri::HTML.fragment(html(message.convert(Object.new)))
    assert_equal %w[A B], fragment.css('th').map(&:text)
    assert_equal %w[1 2], fragment.css('td').map(&:text)
    refute_includes fragment.text, 'fallback text'
  end

  def test_empty_table_block_adds_nothing
    blocks = [{'type' => 'rich_text', 'elements' => [rich_section(rich_text('only text'))]}, slack_table([]), slack_table([[]])]
    assert_equal 'only text', RedmineSlack::InboundMessage.new('', blocks).convert(Object.new).strip
  end

  def test_table_cell_code_with_line_breaks_keeps_the_breaks_outside_the_code
    table = slack_table([[raw_cell('H')], [rich_cell(rich_text("first\n\n`second`", {'code' => true}), rich_text(' tail'))]])
    cell = Nokogiri::HTML.fragment(html(RedmineSlack::InboundMessage.new('x', [table]).convert(Object.new))).at_css('tbody td')
    assert_equal %w[first `second`], cell.css('code').map(&:text)
    assert cell.at_css('br')
    refute_includes cell.text, '<br>'
    assert_includes cell.text, 'tail'
    plain = Nokogiri::HTML.fragment(html(RedmineSlack::InboundMessage.new('x', rich_blocks(rich_section(rich_text("one\ntwo", {'code' => true})))).convert(Object.new)))
    assert_equal ['one two'], plain.css('code').map(&:text)
  end

  def test_unsupported_types_inside_preformatted_blocks_are_reported
    pre = {'type' => 'rich_text_preformatted', 'elements' => [rich_text('code '), {'type' => 'link', 'url' => 'https://example.invalid'},
      {'type' => 'color', 'value' => '#ff0000'}, {'type' => 'emoji', 'name' => 'tada'}]}
    message = RedmineSlack::InboundMessage.new('x', rich_blocks(pre))
    assert_includes message.convert(Object.new), "code https://example.invalid\n"
    assert_equal %w[color emoji], message.unsupported_types
  end

  def test_unsupported_types_are_reported_by_name_only
    blocks = [{'type' => 'header', 'text' => 'secret title'},
      {'type' => 'rich_text', 'elements' => [rich_section(rich_text('secret body'), {'type' => 'color', 'value' => '#ff0000'}, {'type' => 'Bad Type!'}), {'type' => 'rich_text_extra'}]},
      slack_table([[{'type' => 'action_cell'}]])]
    message = RedmineSlack::InboundMessage.new('x', blocks)
    assert_empty message.unsupported_types
    message.convert(Object.new)
    assert_equal %w[action_cell color header rich_text_extra unknown], message.unsupported_types
    supported = RedmineSlack::InboundMessage.new('x', rich_blocks(rich_section(rich_text('a')), {'type' => 'rich_text_quote', 'elements' => []}))
    supported.convert(Object.new)
    assert_empty supported.unsupported_types
    fallback = RedmineSlack::InboundMessage.new('x', [{'type' => 'section'}])
    fallback.convert(Object.new)
    assert_empty fallback.unsupported_types
  end

  def test_parent_lookup_and_binary_download_restrictions
    client = RedmineSlack::Client.new('fixture-token')
    SlackSmokeTransport.body = '{"ok":true,"messages":[{"ts":"123.456","text":"fixture"}]}'
    assert_equal 'fixture', client.conversation_parent('CFIXTURE', '123.456')['text']
    request = SlackSmokeTransport.requests.last
    assert_equal({channel: 'CFIXTURE', latest: '123.456', inclusive: true, limit: 1}, request[:body])
    assert_nil client.conversation_parent('CFIXTURE', '999.000')
    SlackSmokeTransport.requests.clear
    Setting.attachment_max_size = '1'
    file = {'url_private_download' => 'https://files.slack.com/synthetic-file', 'url_private' => 'https://example.invalid/file', 'size' => 1025}
    assert_nil client.download_file(file)
    assert_empty SlackSmokeTransport.requests
    file['size'] = 1024
    SlackSmokeTransport.body = "\x00\xff".b
    bytes = client.download_file(file)
    assert_equal "\x00\xff".b, bytes
    assert_equal Encoding::BINARY, bytes.encoding
    assert_equal 'Bearer fixture-token', SlackSmokeTransport.requests.last[:headers]['Authorization']
    file.delete('url_private_download')
    assert_nil client.download_file(file)
    file['url_private'] = 'https://files.slack.com/synthetic-file'
    assert_equal bytes, client.download_file(file)
    file['url_private'] = 'http://files.slack.com/synthetic-file'
    assert_nil client.download_file(file)
    assert_raises(RuntimeError) { HTTPClient.new.get('https://files.slack.com/not-allowed') }
  end

  def test_slack_text_conversion_and_quote_separation
    resolver = Object.new
    linked = @user
    resolver.define_singleton_method(:user) { |id| id == 'ULINKED' ? linked : nil }
    resolver.define_singleton_method(:display_name) { |_id| 'Slack Person' }
    text = "#123+= &amp; &lt;div&gt; x &gt; y <@ULINKED> <@UOTHER> <https://example.invalid|label> <https://example.invalid> <#C123|general> <!here> <!channel> <!everyone> *unchanged* `code`\n\n&gt; quoted\nnext\n\n&gt;another\n\nseparated"
    converted = RedmineSlack::InboundMessage.new(text).convert(resolver)
    assert_includes converted, ">another\n\nseparated"
    assert_includes converted, 'x &gt; y'
    fragment = Nokogiri::HTML.fragment(html(converted))
    assert_includes fragment.text, "& <div> x > y @#{@user.login} Slack Person"
    assert_includes fragment.text, '#general @here @channel @everyone'
    assert_equal 'unchanged', fragment.at_css('em').text
    assert_equal 'code', fragment.at_css('code').text
    assert_equal 2, fragment.css('a[href="https://example.invalid"]').size
    assert_equal %w[quoted another], fragment.css('blockquote').map { |q| q.text.strip }
    assert fragment.css('p').any? { |p| p.text == 'next' && !p.ancestors('blockquote').any? }
    assert fragment.css('p').any? { |p| p.text == 'separated' && !p.ancestors('blockquote').any? }
    refute_includes fragment.text, '#123+='
    refute fragment.at_css('div')
  end

  def test_text_fallback_measured_tokens_with_no_rich_blocks
    resolver = Object.new
    linked = @user
    resolver.define_singleton_method(:user) { |_| linked }
    text = '<mailto:a@b.com|a@b.com> <custom:abc|custom> <!date^123^format|Nov 14> <!subteam^S1|@devs> <!subteam^S2|> <!subteam^S3> <@U333|old> <#C456|> &lt;div&gt;'
    [nil, [{'type' => 'section'}]].each do |blocks|
      fragment = Nokogiri::HTML.fragment(html(RedmineSlack::InboundMessage.new(text, blocks).convert(resolver)))
      assert_equal 'a@b.com', fragment.at_css('a[href="mailto:a@b.com"]').text
      assert_equal 'custom', fragment.at_css('a[href="custom:abc"]').text
      ['Nov 14', '@devs @group @group', "@#{@user.login}", '#channel', '<div>'].each { |value| assert_includes fragment.text, value }
      refute fragment.at_css('div')
    end
  end

  def test_message_link_allows_a_journalless_tombstone
    link = RedmineSlack::MessageLink.create!(channel_id: 'CFIXTURE', message_ts: '123.456', deleted_at: Time.current)
    assert_nil link.reload.journal_id
    assert_not_nil link.deleted_at
    assert_raises(ActiveRecord::RecordNotUnique) do
      RedmineSlack::MessageLink.create!(channel_id: 'CFIXTURE', message_ts: '123.456')
    end
  end

  def test_references_and_markers
    origin = "#{Setting.protocol}://#{Setting.host_name}"
    message = RedmineSlack::InboundMessage.new("#12 <#{origin}/issues/12?x=1|label> <#{origin}/issues/23#note> #{origin}/issues/45 #23 #12+= #67+=")
    assert_equal [12, 23, 45, 67], message.references
    assert_equal 12, message.marker
    assert_equal [23, 45], message.preview_references
    assert_includes message.without_marker, '#67+='
    refute_includes message.without_marker, '#12+='
    unrelated = RedmineSlack::InboundMessage.new('https://elsewhere.invalid/issues/9#123 http://elsewhere.invalid/issues/11')
    assert_empty unrelated.references
    opposite = Setting.protocol == 'https' ? 'http' : 'https'
    assert_empty RedmineSlack::InboundMessage.new("#{opposite}://#{Setting.host_name}/issues/42").references
  end
end

class SlackEventJobSmokeTest < SlackWorkflowSmokeTest
  setup do
    @initial_attachment_id = Attachment.maximum(:id).to_i
    @event_settings = {'import_enabled' => '1', 'delivery_enabled' => '0', 'signing_secret' => 'fixture-secret',
      'bot_token' => 'fixture-token', 'import_user_id' => @user.id.to_s, 'username' => 'fixture-bot', 'icon' => ':robot_face:'}
    Setting.plugin_redmine_slack = @event_settings
    @event = {'type' => 'message', 'channel_type' => 'group', 'channel' => 'CFIXTURE', 'user' => 'UFIXTURE', 'text' => "##{@issue.id}"}
  end

  def cleanup_import_fixture_files
    Attachment.where('id > ?', @initial_attachment_id).where(container_type: 'Issue', container_id: @issue.id, author_id: @user.id).find_each do |attachment|
      next unless attachment.filename.start_with?('slack-import-fixture-')
      File.delete(attachment.diskfile) if File.file?(attachment.diskfile)
    end
  end

  def with_issue_lookup(issue)
    Issue.define_singleton_method(:find_by) { |**_args| issue }
    yield
  ensure
    Issue.singleton_class.remove_method(:find_by)
  end

  def test_stale_issue_is_retried_and_imported_once
    ActiveJob::Base.queue_adapter = :test
    @user.rslack_preference[:username] = 'ULINKED01'
    event = @event.merge('ts' => '189.001', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+= retry")
    Issue.where(id: @issue.id).update_all(lock_version: @issue.lock_version + 1)
    assert_no_difference ['Journal.count', 'RedmineSlack::MessageLink.count'] do
      with_issue_lookup(@issue) { RedmineSlack::EventJob.perform_now(event) }
    end
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == RedmineSlack::EventJob }
    assert_equal 1, jobs.size
    assert_difference ['Journal.count', 'RedmineSlack::MessageLink.count'], 1 do
      ActiveJob::Base.execute(jobs.first)
      RedmineSlack::EventJob.perform_now(event)
    end
    assert_equal 'retry', Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: event['ts']).journal_id).notes
  end

  def test_deleted_rich_history_remains_visible_in_quote
    @user.rslack_preference[:username] = 'ULINKED01'
    body = "~~struck history~~\n\n```\ncode first\ncode second\n```\n\n- list one\n- list two"
    event = @event.merge('ts' => '188.001', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+= #{body}")
    RedmineSlack::EventJob.perform_now(event)
    journal = Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: event['ts']).journal_id)
    RedmineSlack::EventJob.perform_now(@event.merge('subtype' => 'message_deleted', 'deleted_ts' => event['ts'], 'event_ts' => '188.002'))
    fragment = Nokogiri::HTML.fragment(html(journal.reload.notes))
    assert_match(/Deleted in Slack on/, fragment.at_css('p > em').text)
    quote = fragment.at_css('blockquote')
    ['struck history', 'code first', 'code second', 'list one', 'list two'].each { |text| assert_includes quote.text, text }
    assert_equal 'struck history', quote.at_css('del').text
    assert quote.at_css('pre code')
    assert_equal 2, quote.css('li').size
  end

  def test_unsupported_block_types_are_logged_without_content
    @user.rslack_preference[:username] = 'ULINKED01'
    blocks = [{'type' => 'header', 'text' => 'secret title'}] +
      rich_blocks(rich_section(rich_text("##{@issue.id}+= secret body"), {'type' => 'color', 'value' => '#ff0000'}))
    event = @event.merge('ts' => '190.001', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+= secret body", 'blocks' => blocks)
    output = StringIO.new
    previous = Rails.logger
    Rails.logger = Logger.new(output)
    begin
      assert_difference 'Journal.count', 1 do
        RedmineSlack::EventJob.perform_now(event)
      end
    ensure
      Rails.logger = previous
    end
    assert_includes output.string, 'Slack import rendered unsupported types (color, header)'
    refute_includes output.string, 'secret'
    assert_includes Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: event['ts']).journal_id).notes, 'secret body'
  end

  def test_fallback_author_offset_list_on_create_and_edit
    @user.define_singleton_method(:member_of?) { |_project| true }
    SlackSmokeTransport.body = '{"ok":true,"user":{"profile":{"display_name":"Outside Person"}}}'
    list = {'type' => 'rich_text_list', 'style' => 'ordered', 'offset' => 2, 'elements' => [rich_section(rich_text('third')), rich_section(rich_text('fourth'))]}
    event = @event.merge('ts' => '187.001', 'user' => 'UOUTSIDE', 'text' => "##{@issue.id}+= list", 'blocks' => rich_blocks(list))
    RedmineSlack::EventJob.perform_now(event)
    journal = Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: event['ts']).journal_id)
    assert_equal '3', Nokogiri::HTML.fragment(html(journal.notes)).at_css('ol')['start']
    change = @event.merge('subtype' => 'message_changed', 'message' => {'ts' => event['ts'], 'text' => 'edited', 'blocks' => rich_blocks(list), 'edited' => {'ts' => '187.002'}})
    RedmineSlack::EventJob.perform_now(change)
    fragment = Nokogiri::HTML.fragment(html(journal.reload.notes))
    assert_equal 'Outside Person', fragment.at_css('strong').text
    assert_equal '3', fragment.at_css('ol')['start']
  end

  def test_rich_text_create_edit_attribution_routing_and_previews
    @user.define_singleton_method(:member_of?) { |_project| true }
    other = Issue.where.not(id: @issue.id).first!
    SlackSmokeTransport.body = '{"ok":true,"user":{"profile":{"display_name":"Outside Person"}}}'
    created = rich_blocks(rich_section(rich_text("##{@issue.id}+= create "), rich_text('bold', {'bold' => true})))
    event = @event.merge('ts' => '181.001', 'user' => 'UOUTSIDE', 'text' => "##{@issue.id}+= text only ##{other.id}", 'blocks' => created)
    RedmineSlack::EventJob.perform_now(event)
    link = RedmineSlack::MessageLink.find_by!(message_ts: '181.001')
    journal = Journal.find(link.journal_id)
    assert_equal @issue.id, journal.journalized_id
    assert_equal @user.id, journal.user_id
    fragment = Nokogiri::HTML.fragment(html(journal.notes))
    assert_equal 'Outside Person', fragment.css('strong').first.text
    assert_equal 'bold', fragment.css('strong').last.text
    assert_includes fragment.text, 'create bold'
    refute_includes fragment.text, 'text only'
    preview = SlackSmokeTransport.requests.find { |r| r[:url].end_with?('/chat.postMessage') }
    assert_includes JSON.parse(preview[:body])['attachments'].first['text'], "/issues/#{other.id}"
    edit_blocks = rich_blocks(rich_section(rich_text('edit '), rich_text('italic', {'italic' => true})))
    changed = @event.merge('subtype' => 'message_changed', 'blocks' => rich_blocks(rich_section(rich_text('wrong top-level'))),
      'message' => {'ts' => event['ts'], 'text' => '#999999+= wrong text', 'blocks' => edit_blocks, 'edited' => {'ts' => '181.002'}})
    RedmineSlack::EventJob.perform_now(changed)
    fragment = Nokogiri::HTML.fragment(html(journal.reload.notes))
    assert_equal 'Outside Person', fragment.at_css('strong').text
    assert_equal 'italic', fragment.at_css('em').text
    assert_includes fragment.text, 'edit italic'
    refute_includes fragment.text, 'wrong'
    assert_equal [@issue.id, @user.id, '181.002'], [journal.journalized_id, journal.user_id, link.reload.last_edited_ts]
  end

  def test_previews_run_independently_of_outbound_delivery
    @issue.update!(subject: 'Subject <tag>', description: 'Description & details')
    RedmineSlack::EventJob.perform_now(@event)
    payload = JSON.parse(SlackSmokeTransport.requests.last[:body])
    assert_equal 'CFIXTURE', payload['channel']
    assert_equal false, payload['unfurl_links']
    assert_equal false, payload['unfurl_media']
    assert_equal 'fixture-bot', payload['username']
    assert_equal ':robot_face:', payload['icon_emoji']
    refute payload.key?('thread_ts')
    text = payload['attachments'].first['text']
    [@issue.tracker.name, @issue.project.name, @issue.status.name, @issue.priority.name, 'Subject &lt;tag&gt;', 'Description &amp; details', "/issues/#{@issue.id}"].each { |value| assert_includes text, value }
    %w[file_share thread_broadcast].each do |subtype|
      SlackSmokeTransport.requests.clear
      RedmineSlack::EventJob.perform_now(@event.merge('subtype' => subtype, 'thread_ts' => '123.456'))
      preview = SlackSmokeTransport.requests.find { |request| request[:url].end_with?('/chat.postMessage') }
      assert_equal '123.456', JSON.parse(preview[:body])['thread_ts']
    end
  end

  def test_permanent_preview_failure_does_not_prevent_import
    other = Issue.where.not(id: @issue.id).first!
    @user.rslack_preference[:username] = 'ULINKED01'
    SlackSmokeTransport.body = '{"ok":false,"error":"msg_too_long"}'
    event = @event.merge('ts' => '190.001', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+= imported ##{other.id}")
    RedmineSlack::EventJob.perform_now(event)
    link = RedmineSlack::MessageLink.find_by!(channel_id: event['channel'], message_ts: event['ts'])
    assert_equal "imported ##{other.id}", Journal.find(link.journal_id).notes
    assert_equal 1, SlackSmokeTransport.requests.count { |request| request[:url].end_with?('/chat.postMessage') }
  end

  def test_combined_preview_excludes_markers_missing_and_invisible_issues
    other = Issue.where.not(id: @issue.id).first!
    RedmineSlack::EventJob.perform_now(@event.merge('channel_type' => 'im', 'text' => "##{@issue.id} ##{other.id} ##{@issue.id} #999999999"))
    payload = JSON.parse(SlackSmokeTransport.requests.last[:body])
    assert_equal 2, payload['attachments'].size
    assert_includes payload['attachments'][0]['text'], "/issues/#{@issue.id}"
    assert_includes payload['attachments'][1]['text'], "/issues/#{other.id}"
    SlackSmokeTransport.requests.clear
    @user.rslack_preference[:username] = 'ULINKED01'
    RedmineSlack::EventJob.perform_now(@event.merge('ts' => '123.456', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+= ##{other.id}"))
    payload = JSON.parse(SlackSmokeTransport.requests.find { |r| r[:url].end_with?('/chat.postMessage') }[:body])
    assert_equal 1, payload['attachments'].size
    assert_includes payload['attachments'][0]['text'], "/issues/#{other.id}"
    outsider = User.create!(login: 'slack_preview_outsider', firstname: 'Slack', lastname: 'Outsider', mail: 'slack-preview@example.invalid', password: 'FixturePassword_104!', password_confirmation: 'FixturePassword_104!')
    @issue.project.update_column(:is_public, false)
    refute @issue.reload.visible?(outsider)
    Setting.plugin_redmine_slack = @event_settings.merge('import_user_id' => outsider.id.to_s)
    SlackSmokeTransport.requests.clear
    RedmineSlack::EventJob.perform_now(@event)
    assert_empty SlackSmokeTransport.requests
  end

  def test_ineligible_events_and_configuration_do_no_work
    [@event.merge('bot_id' => 'B1'), @event.merge('subtype' => 'bot_message'),
      @event.merge('subtype' => 'message_changed'), @event.merge('subtype' => 'message_deleted'),
      @event.merge('subtype' => 'unsupported'), @event.merge('channel_type' => 'channel'),
      @event.merge('channel_type' => 'mpim'), @event.merge('text' => '#999999999')].each do |event|
      RedmineSlack::EventJob.perform_now(event)
    end
    %w[import_enabled signing_secret bot_token import_user_id].each do |key|
      Setting.plugin_redmine_slack = @event_settings.merge(key => '')
      RedmineSlack::EventJob.perform_now(@event)
    end
    assert_empty SlackSmokeTransport.requests
    assert_equal 'slack', RedmineSlack::EventJob.queue_name
    refute RedmineSlack::EventJob.log_arguments
  end

  def test_marker_import_uses_linked_author_and_deduplicates
    @user.rslack_preference[:username] = 'ULINKED01'
    event = @event.merge('text' => "##{@issue.id}+= imported fixture", 'ts' => '123.456', 'user' => 'ULINKED01')
    assert_difference 'Journal.count', 1 do
      RedmineSlack::EventJob.perform_now(event)
      RedmineSlack::EventJob.perform_now(event)
    end
    link = RedmineSlack::MessageLink.find_by!(channel_id: 'CFIXTURE', message_ts: '123.456')
    journal = Journal.find(link.journal_id)
    assert_equal @user.id, journal.user_id
    assert_equal 'imported fixture', journal.notes
    refute_includes journal.notes, '[silent-update]'
    changed = @event.merge('subtype' => 'message_changed', 'message' => {'ts' => '123.456', 'text' => "##{@issue.id}+= edited\n\nnext", 'edited' => {'ts' => '123.457'}})
    RedmineSlack::EventJob.perform_now(changed)
    assert_equal "edited\n\nnext", journal.reload.notes
    assert_equal '123.457', link.reload.last_edited_ts
    changed['message']['text'] = 'stale'
    RedmineSlack::EventJob.perform_now(changed)
    assert_equal "edited\n\nnext", journal.reload.notes
    deletion = @event.merge('subtype' => 'message_deleted', 'deleted_ts' => '123.456', 'event_ts' => '123.458')
    RedmineSlack::EventJob.perform_now(deletion)
    assert_match(/\A_Deleted in Slack on .*_\n\n> edited\n>\n> next\z/, journal.reload.notes)
    deleted_notes = journal.notes
    RedmineSlack::EventJob.perform_now(deletion)
    changed['message']['edited']['ts'] = '123.459'
    RedmineSlack::EventJob.perform_now(changed)
    assert_equal deleted_notes, journal.reload.notes
  end

  def test_thread_parent_routing_uses_text_then_attachments_and_marker_precedes_lookup
    @user.rslack_preference[:username] = 'ULINKED01'
    parent = {ok: true, messages: [{ts: 'parent.1', text: "##{@issue.id}", bot_id: 'B1', attachments: [{title: '#999999999'}]}]}
    SlackSmokeTransport.body = parent.to_json
    event = @event.merge('subtype' => 'thread_broadcast', 'text' => 'reply', 'thread_ts' => 'parent.1', 'ts' => 'reply.1', 'user' => 'ULINKED01')
    RedmineSlack::EventJob.perform_now(event)
    assert_equal 'reply', Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: 'reply.1').journal_id).notes
    parent[:messages][0][:text] = ''
    parent[:messages][0][:attachments] = [{title: "##{@issue.id}", text: '#999999999'}]
    SlackSmokeTransport.body = parent.to_json
    RedmineSlack::EventJob.perform_now(event.merge('ts' => 'reply.2'))
    assert RedmineSlack::MessageLink.exists?(message_ts: 'reply.2')
    SlackSmokeTransport.requests.clear
    RedmineSlack::EventJob.perform_now(event.merge('ts' => 'reply.3', 'text' => "##{@issue.id}+= explicit"))
    assert RedmineSlack::MessageLink.exists?(message_ts: 'reply.3')
    refute SlackSmokeTransport.requests.any? { |request| request[:url].end_with?('/conversations.history') }
    parent[:messages][0][:text] = 'no issue'
    parent[:messages][0][:attachments] = []
    SlackSmokeTransport.body = parent.to_json
    RedmineSlack::EventJob.perform_now(event.merge('ts' => 'reply.4'))
    refute RedmineSlack::MessageLink.exists?(message_ts: 'reply.4')
  end

  def test_deletion_before_import_suppresses_late_message
    @user.rslack_preference[:username] = 'ULINKED01'
    deletion = @event.merge('subtype' => 'message_deleted', 'deleted_ts' => 'late.1', 'event_ts' => '123.458')
    RedmineSlack::EventJob.perform_now(deletion)
    link = RedmineSlack::MessageLink.find_by!(message_ts: 'late.1')
    assert_nil link.journal_id
    assert_not_nil link.deleted_at
    assert_no_difference 'Journal.count' do
      RedmineSlack::EventJob.perform_now(@event.merge('ts' => 'late.1', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+= late"))
    end
  end

  def test_edit_watermarks_missing_journals_and_unchanged_attribution
    @user.define_singleton_method(:member_of?) { |_project| true }
    importer = RedmineSlack::CommentImporter.new(RedmineSlack::Client.new('fixture-token'), @user)
    SlackSmokeTransport.body = '{"ok":true,"user":{"profile":{"display_name":"Outside Person"}}}'
    event = @event.merge('ts' => '180.000000000000000001', 'user' => 'UOUTSIDE', 'text' => "##{@issue.id}+= original")
    importer.create(event, @issue.id)
    link = RedmineSlack::MessageLink.find_by!(message_ts: event['ts'])
    journal = Journal.find(link.journal_id)
    original_issue_id, original_user_id = journal.journalized_id, journal.user_id
    change = @event.merge('subtype' => 'message_changed', 'message' => {'ts' => event['ts'], 'text' => '#999999999+= changed', 'edited' => {'ts' => '180.000000000000000002'}})
    SlackSmokeTransport.requests.clear
    RedmineSlack::EventJob.perform_now(change)
    assert_equal "**Outside Person** (Slack):\n\nchanged", journal.reload.notes
    assert_equal [original_issue_id, original_user_id], [journal.journalized_id, journal.user_id]
    assert_equal '180.000000000000000002', link.reload.last_edited_ts
    assert_empty SlackSmokeTransport.requests
    %w[180.000000000000000001 180.000000000000000002].each do |ts|
      change['message']['edited']['ts'] = ts
      change['message']['text'] = 'stale'
      RedmineSlack::EventJob.perform_now(change)
    end
    assert_equal "**Outside Person** (Slack):\n\nchanged", journal.reload.notes
    change['message']['ts'] = 'missing'
    change['message']['edited']['ts'] = '181.0'
    assert_no_difference ['Journal.count', 'RedmineSlack::MessageLink.count'] do
      RedmineSlack::EventJob.perform_now(change)
    end
    change['message']['ts'] = event['ts']
    Journal.where(id: journal.id).delete_all
    RedmineSlack::EventJob.perform_now(change)
    assert_equal '180.000000000000000002', link.reload.last_edited_ts
    RedmineSlack::EventJob.perform_now(@event.merge('subtype' => 'message_deleted', 'deleted_ts' => event['ts'], 'event_ts' => '182.0'))
    assert_not_nil link.reload.deleted_at
    assert_nil Journal.find_by(id: journal.id)
  end

  def test_fallback_requires_membership_and_attributes_slack_author
    importer = RedmineSlack::CommentImporter.new(RedmineSlack::Client.new('fixture-token'), @user)
    SlackSmokeTransport.body = '{"ok":true,"user":{"profile":{"display_name":"Outside Person"}}}'
    event = @event.merge('ts' => 'fallback.1', 'user' => 'UUNLINKED', 'text' => "##{@issue.id}+= fixture")
    @user.define_singleton_method(:member_of?) { |_project| false }
    assert_no_difference 'Journal.count' do
      importer.create(event, @issue.id)
    end
    refute RedmineSlack::MessageLink.exists?(message_ts: 'fallback.1')
    @user.define_singleton_method(:member_of?) { |_project| true }
    importer.create(event, @issue.id)
    link = RedmineSlack::MessageLink.find_by!(message_ts: 'fallback.1')
    assert_equal "**Outside Person** (Slack):\n\nfixture", Journal.find(link.journal_id).notes
    assert_equal 'Outside Person', link.author_name
  end

  def test_denied_linked_author_falls_back_and_denied_import_user_skips
    linked = User.active.where.not(id: @user.id).first!
    linked.rslack_preference[:username] = 'UDENIED'
    @user.define_singleton_method(:member_of?) { |_project| true }
    linked_id = linked.id
    @issue.define_singleton_method(:visible?) { |user| user.id != linked_id }
    importer = RedmineSlack::CommentImporter.new(RedmineSlack::Client.new('fixture-token'), @user)
    SlackSmokeTransport.body = '{"ok":true,"user":{"profile":{"display_name":"Denied Author"}}}'
    event = @event.merge('ts' => '160.001', 'user' => 'UDENIED', 'text' => "##{@issue.id}+= body")
    with_issue_lookup(@issue) { importer.create(event, @issue.id) }
    journal = Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: '160.001').journal_id)
    assert_equal @user.id, journal.user_id
    assert_equal "**Denied Author** (Slack):\n\nbody", journal.notes
    [[:visible?, false], [:notes_addable?, false]].each_with_index do |(method, _), index|
      @issue.define_singleton_method(:visible?) { |_user| false } if method == :visible?
      if method == :notes_addable?
        @issue.define_singleton_method(:visible?) { |user| user.id != linked_id }
        @issue.define_singleton_method(:notes_addable?) { |_user| false }
      end
      SlackSmokeTransport.requests.clear
      assert_no_difference 'Journal.count' do
        with_issue_lookup(@issue) { importer.create(event.merge('ts' => "160.00#{index + 2}"), @issue.id) }
      end
      assert_empty SlackSmokeTransport.requests
    end
  end

  def test_failed_save_and_unique_collision_leave_no_duplicate_import
    @user.rslack_preference[:username] = 'ULINKED01'
    event = @event.merge('ts' => '170.001', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+= body")
    importer = RedmineSlack::CommentImporter.new(RedmineSlack::Client.new('fixture-token'), @user)
    @issue.define_singleton_method(:save!) { raise ActiveRecord::RecordInvalid.new(self) }
    assert_no_difference ['Journal.count', 'RedmineSlack::MessageLink.count'] do
      assert_raises(ActiveRecord::RecordInvalid) { with_issue_lookup(@issue) { importer.create(event, @issue.id) } }
    end
    refute RedmineSlack::MessageLink.exists?(message_ts: '170.001')
    RedmineSlack::MessageLink.create!(channel_id: event['channel'], message_ts: event['ts'])
    RedmineSlack::MessageLink.define_singleton_method(:exists?) { |*_args| false }
    assert_no_difference 'Journal.count' do
      importer.create(event, @issue.id)
    end
  ensure
    RedmineSlack::MessageLink.singleton_class.remove_method(:exists?) if RedmineSlack::MessageLink.singleton_class.instance_methods(false).include?(:exists?)
  end

  def test_file_imports_validate_and_keep_note_and_journal_details
    ActiveJob::Base.queue_adapter = :test
    @user.rslack_preference[:username] = 'ULINKED01'
    Setting.attachment_max_size = '1'
    Setting.attachment_extensions_denied = 'exe'
    files = %w[slack-import-fixture-image.png slack-import-fixture-text.txt slack-import-fixture-oversized.txt slack-import-fixture-blocked.exe slack-import-fixture-failed.txt].map do |name|
      {'name' => name, 'size' => 1, 'url_private_download' => 'https://files.slack.com/synthetic-file'}
    end
    SlackSmokeTransport.responses = [[200, "\x00\xff".b, {}], [200, 'text bytes'.b, {}],
      [200, 'x'.b * 1025, {}], [200, 'blocked'.b, {}], [503, '', {}]]
    event = @event.merge('ts' => '150.001', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+= note", 'files' => files)
    previous_user = User.current
    RedmineSlack::EventJob.perform_now(event)
    assert_equal previous_user, User.current
    journal = Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: '150.001').journal_id)
    assert_equal 'note', journal.notes
    assert journal.notify?
    refute_includes journal.notes, '[silent-update]'
    details = journal.details.where(property: 'attachment').order(:id).to_a
    assert_equal %w[slack-import-fixture-image.png slack-import-fixture-text.txt], details.map(&:value)
    attachments = details.map { |detail| Attachment.find(detail.prop_key) }
    assert_equal ["\x00\xff".b, 'text bytes'.b], attachments.map { |attachment| File.binread(attachment.diskfile) }
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == RedmineSlack::DeliveryJob }
    changed = @event.merge('subtype' => 'message_changed', 'message' => {'ts' => '150.001', 'text' => 'edited', 'edited' => {'ts' => '150.002'}, 'files' => []})
    SlackSmokeTransport.requests.clear
    RedmineSlack::EventJob.perform_now(changed)
    assert_empty SlackSmokeTransport.requests
    assert_equal 2, journal.reload.details.where(property: 'attachment').count
    RedmineSlack::EventJob.perform_now(@event.merge('subtype' => 'message_deleted', 'deleted_ts' => '150.001', 'event_ts' => '150.003'))
    assert_equal 2, journal.reload.details.where(property: 'attachment').count
    assert attachments.all? { |attachment| File.exist?(attachment.diskfile) }
  ensure
    cleanup_import_fixture_files
  end

  def test_file_only_linked_and_fallback_comments
    ActiveJob::Base.queue_adapter = :test
    @user.rslack_preference[:username] = 'ULINKED01'
    file = {'name' => 'slack-import-fixture-only.txt', 'size' => 2, 'url_private_download' => 'https://files.slack.com/synthetic-file'}
    SlackSmokeTransport.body = 'ok'.b
    event = @event.merge('ts' => '151.001', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+=", 'files' => [file])
    RedmineSlack::EventJob.perform_now(event)
    journal = Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: '151.001').journal_id)
    assert_equal '', journal.notes.to_s
    assert_equal 1, journal.details.where(property: 'attachment').count
    assert journal.notify?
    @user.define_singleton_method(:member_of?) { |_project| true }
    importer = RedmineSlack::CommentImporter.new(RedmineSlack::Client.new('fixture-token'), @user)
    info = '{"ok":true,"user":{"profile":{"display_name":"Outside Person"}}}'
    SlackSmokeTransport.responses = [[200, info, {}], [200, 'ok'.b, {}]]
    importer.create(event.merge('ts' => '151.002', 'user' => 'UOUTSIDE'), @issue.id)
    fallback = Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: '151.002').journal_id)
    assert_equal '**Outside Person** (Slack):', fallback.notes
    assert_equal 1, fallback.details.where(property: 'attachment').count
    assert fallback.notify?
    refute_includes fallback.notes, '[silent-update]'
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == RedmineSlack::DeliveryJob }
  ensure
    cleanup_import_fixture_files
  end

  def test_file_placeholders_are_resolved_with_files_info
    @user.rslack_preference[:username] = 'ULINKED01'
    placeholders = %w[F0RESOLVED F0MISSING].map { |id| {'id' => id, 'file_access' => 'check_file_info', 'created' => 0, 'user' => ''} }
    info = {'ok' => true, 'file' => {'id' => 'F0RESOLVED', 'name' => 'slack-import-fixture-placeholder.png', 'mimetype' => 'image/png', 'size' => 2, 'url_private_download' => 'https://files.slack.com/synthetic-file'}}
    SlackSmokeTransport.responses = [[200, JSON.generate(info), {}], [200, "\x89P".b, {}], [200, '{"ok":false,"error":"file_not_found"}', {}]]
    event = @event.merge('subtype' => 'file_share', 'ts' => '152.001', 'user' => 'ULINKED01', 'text' => "##{@issue.id}+= see image", 'files' => placeholders)
    RedmineSlack::EventJob.perform_now(event)
    lookups = SlackSmokeTransport.requests.select { |request| request[:url] == 'https://slack.com/api/files.info' }
    assert_equal [{file: 'F0RESOLVED'}, {file: 'F0MISSING'}], lookups.map { |request| request[:body] }
    journal = Journal.find(RedmineSlack::MessageLink.find_by!(message_ts: '152.001').journal_id)
    assert_equal 'see image', journal.notes
    attachment = Attachment.find(journal.details.find_by!(property: 'attachment').prop_key)
    assert_equal ['slack-import-fixture-placeholder.png', "\x89P".b], [attachment.filename, File.binread(attachment.diskfile)]
  ensure
    cleanup_import_fixture_files
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

  def test_sensitive_transport_error_has_no_unsafe_cause_or_writes
    original_settings = Setting.plugin_redmine_slack.deep_dup
    original_values = @values.map { |value| value.reload.value }
    ENV['APPLY'] = '1'
    SlackSmokeTransport.error = IOError.new('xoxb-synthetic-secret fixture@example.invalid')
    task = Rake::Task['redmine_slack:convert_channels']
    task.reenable
    error = assert_raises(RuntimeError) { task.invoke }
    assert_equal 'Slack conversion: transport_error', error.message
    while error
      refute_includes error.message, 'xoxb-synthetic-secret'
      refute_includes error.message, 'fixture@example.invalid'
      error = error.cause
    end
    assert_equal original_settings, Setting.plugin_redmine_slack
    assert_equal original_values, @values.map { |value| value.reload.value }
  end
end

class SlackWorkflowBehaviorSmokeTest < SlackWorkflowSmokeTest
  tests IssuesController

  def test_inline_image_selection_follows_formatter_and_redmine_filename_order
    image = Struct.new(:id, :filename, :created_on, :image?)
    old = image.new(1, 'Screen Shot.png', Time.at(1), true)
    latest = image.new(2, 'SCREEN SHOT.PNG', Time.at(2), true)
    other = image.new(3, 'document.pdf', Time.at(3), false)
    issue = Struct.new(:attachments).new([old, latest, other])
    notes = 'before ![alt](screen%20shot.png) ![x](https://example.invalid/a.png) ![x](missing.png) ![x](document.pdf) !textile.png! after'
    Setting.text_formatting = 'common_mark'
    text, selected = @listener.send(:comment_inline_images, issue, notes)
    assert_equal [latest], selected
    assert_equal 'before     !textile.png! after', text
    assert_includes notes, '![alt]'
    Setting.text_formatting = 'textile'
    text, selected = @listener.send(:comment_inline_images, issue, '![alt](screen%20shot.png) !screen%20shot.png! !https://example.invalid/a.png!')
    assert_equal [latest], selected
    assert_equal '![alt](screen%20shot.png)  ', text
    Setting.text_formatting = 'none'
    assert_equal [notes, []], @listener.send(:comment_inline_images, issue, notes)
    assert_empty SlackSmokeTransport.requests
  end

  def test_commonmark_images_use_parsed_destinations_and_byte_positions
    image = Struct.new(:id, :filename, :created_on, :image?)
    screen = image.new(1, 'screen.png', Time.at(1), true)
    spaced = image.new(2, 'screen shot.png', Time.at(1), true)
    parens = image.new(3, 'plot(v2).png', Time.at(1), true)
    issue = Struct.new(:attachments).new([screen, spaced, parens])
    Setting.text_formatting = 'common_mark'
    notes = "привет ![s](screen.png \"caption\")\r\n![s](<screen shot.png>) ![s](plot(v2).png) end"
    text, selected = @listener.send(:comment_inline_images, issue, notes)
    assert_equal [screen, spaced, parens], selected
    assert_equal "привет \r\n  end", text
    assert_equal "привет ![s](screen.png \"caption\")\r\n![s](<screen shot.png>) ![s](plot(v2).png) end", notes
  end

  def test_commonmark_literal_image_syntax_is_not_selected_or_stripped
    Setting.text_formatting = 'common_mark'
    notes = "`![s](screen.png)`\n\n```\n![s](screen.png)\n```\n\n    ![s](screen.png)\n\n\\![s](screen.png)"
    issue = Struct.new(:attachments).new([])
    assert_equal [notes, []], @listener.send(:comment_inline_images, issue, notes)
  end

  def test_textile_images_use_redcloth_modifiers_and_leave_code_untouched
    image = Struct.new(:id, :filename, :created_on, :image?)
    screen = image.new(1, 'screen.png', Time.at(1), true)
    issue = Struct.new(:attachments).new([screen])
    Setting.text_formatting = 'textile'
    notes = "before !screen.png(Caption)! and !>screen.png! after\n@!screen.png!@\n<pre>!screen.png!</pre>\n<code>!screen.png!</code>"
    text, selected = @listener.send(:comment_inline_images, issue, notes)
    assert_equal [screen, screen], selected
    assert_equal "before  and  after\n@!screen.png!@\n<pre>!screen.png!</pre>\n<code>!screen.png!</code>", text
  end

  def test_comment_combines_journal_images_and_inline_images_without_mutating_notes
    Setting.text_formatting = 'common_mark'
    image = Struct.new(:id, :filename, :created_on, :image?)
    added = image.new(1, 'added.png', Time.at(1), true)
    reused = image.new(2, 'reused.png', Time.at(1), true)
    unrelated = image.new(3, 'unrelated.png', Time.at(1), true)
    nonimage = image.new(4, 'document.pdf', Time.at(1), false)
    @issue.define_singleton_method(:attachments) { [added, reused, unrelated, nonimage] }
    notes = "Before ![a](added.png) ![b](added.png) ![c](reused.png) ![d](document.pdf) ![e](missing.png) ![f](https://example.invalid/a.png) @#{@executor.login} after"
    journal = @issue.init_journal(@user, notes)
    journal.define_singleton_method(:attachments) { [added, nonimage] }
    parts, _channel, ids = @listener.send(:prepare_comment_message, @issue, journal, '#fixture-main')
    assert_equal [1, 2], ids
    assert_equal notes, journal.notes
    assert_includes parts.grep(String).join, 'Before'
    assert_includes parts.grep(String).join, 'after'
    refute_includes parts.grep(String).join, '!['
    assert_includes parts, RedmineSlack::MessageTemplate.mention(@executor)
    assert_empty SlackSmokeTransport.requests
    journal.notes = '![a](added.png)'
    parts, _, ids = @listener.send(:prepare_comment_message, @issue, journal, '#fixture-main')
    assert_includes parts.grep(String).join, 'commented:'
    assert_equal [1], ids
  end

  def test_journal_attachment_additions_exclude_removals
    now = Time.current
    attachments = %w[added.png removed.png document.pdf].map do |name|
      Attachment.create!(container: @issue, author: @user, filename: name, disk_filename: "fixture-#{name}", filesize: 1,
        content_type: name.end_with?('.png') ? 'image/png' : 'application/pdf', digest: 'fixture', created_on: now)
    end
    journal = @issue.init_journal(@user, 'Fixture')
    journal.details.build(property: 'attachment', prop_key: attachments[0].id.to_s, value: 'added.png')
    journal.details.build(property: 'attachment', prop_key: attachments[1].id.to_s, old_value: 'removed.png', value: nil)
    journal.details.build(property: 'attachment', prop_key: attachments[2].id.to_s, value: 'document.pdf')
    _, _, ids = @listener.send(:prepare_comment_message, @issue, journal, '#fixture-main')
    assert_equal [attachments[0].id], ids
    assert_empty SlackSmokeTransport.requests
  end

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

class SlackEventsSmokeTest < ActionDispatch::IntegrationTest
  setup do
    raise 'Run only against the upgraded local db service' unless ActiveRecord::Base.connection_db_config.host == 'db'
    raise 'Local Slack delivery must start disabled in plugin settings' if Setting.plugin_redmine_slack.with_indifferent_access[:delivery_enabled] == '1'
    @connection = ActiveRecord::Base.connection
    @connection.begin_transaction(joinable: false)
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    SlackSmokeTransport.requests.clear
    Setting.plugin_redmine_slack = {'signing_secret' => 'fixture-secret', 'import_enabled' => '0'}
  end

  teardown do
    @connection.rollback_transaction if @connection
    ActiveJob::Base.queue_adapter = @previous_adapter if @previous_adapter
    Setting.clear_cache
  end

  def signed_post(body, timestamp: Time.now.to_i.to_s, secret: 'fixture-secret', signature: nil)
    signature ||= "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}"
    post '/redmine_slack/events', params: body, headers: {'CONTENT_TYPE' => 'application/json',
      'X-Slack-Request-Timestamp' => timestamp, 'X-Slack-Signature' => signature}
  end

  def test_signed_challenge_and_callbacks_without_login_or_csrf
    signed_post('{ "type": "url_verification", "challenge": "fixture-challenge" }')
    assert_response :success
    assert_equal 'fixture-challenge', response.body
    assert_empty enqueued_jobs
    body = '{ "type": "event_callback", "event": {"type":"message"} }'
    issue_reads = []
    subscriber = ->(*args) { issue_reads << args.last[:sql] if args.last[:sql].match?(/\bFROM\s+[`"]?issues\b/i) }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      2.times do
        signed_post(body)
        assert_response :success
      end
    end
    assert_empty issue_reads
    assert_equal 2, enqueued_jobs.size
    assert_empty SlackSmokeTransport.requests
  end

  def test_signed_callback_through_import_edit_and_delete
    user = User.active.where(admin: true).first!
    issue = Issue.joins(:custom_values).where(custom_values: {custom_field_id: 8}).where.not(custom_values: {value: [nil, '']}).first!
    user.rslack_preference[:username] = 'UE2ETEST'
    Setting.plugin_redmine_slack = {'signing_secret' => 'fixture-secret', 'import_enabled' => '1', 'delivery_enabled' => '0', 'bot_token' => 'fixture-token', 'import_user_id' => user.id.to_s}
    base = {'type' => 'message', 'channel_type' => 'group', 'channel' => 'CE2E', 'user' => 'UE2ETEST'}
    events = [base.merge('ts' => '200.001', 'text' => "##{issue.id}+= original"),
      base.merge('subtype' => 'message_changed', 'message' => {'ts' => '200.001', 'text' => 'edited', 'edited' => {'ts' => '200.002'}}),
      base.merge('subtype' => 'message_deleted', 'deleted_ts' => '200.001', 'event_ts' => '200.003')]
    events.each_with_index do |event, index|
      signed_post({type: 'event_callback', event: event}.to_json)
      assert_response :success
      queued = enqueued_jobs.find { |job| job[:job] == RedmineSlack::EventJob }
      assert_not_nil queued
      enqueued_jobs.delete(queued)
      queued[:job].perform_now(*queued[:args])
      journal = Journal.find(RedmineSlack::MessageLink.find_by!(channel_id: 'CE2E', message_ts: '200.001').journal_id)
      case index
      when 0 then assert_equal 'original', journal.notes
      when 1 then assert_equal 'edited', journal.notes
      when 2 then assert_match(/\A_Deleted in Slack on .*_\n\n> edited\z/, journal.notes)
      end
    end
    assert_empty SlackSmokeTransport.requests
  end

  def test_rejects_invalid_missing_and_replayed_signatures
    body = '{"type":"event_callback","event":{}}'
    signed_post(body, signature: 'v0=invalid')
    assert_response :forbidden
    [-301, 301].each do |offset|
      signed_post(body, timestamp: (Time.now.to_i + offset).to_s)
      assert_response :forbidden
    end
    post '/redmine_slack/events', params: body, headers: {'CONTENT_TYPE' => 'application/json'}
    assert_response :forbidden
    post '/redmine_slack/events', params: body, headers: {'CONTENT_TYPE' => 'application/json', 'X-Slack-Request-Timestamp' => Time.now.to_i.to_s}
    assert_response :forbidden
    post '/redmine_slack/events', params: body, headers: {'CONTENT_TYPE' => 'application/json', 'X-Slack-Signature' => 'v0=invalid'}
    assert_response :forbidden
    Setting.plugin_redmine_slack = {'signing_secret' => ''}
    signed_post(body)
    assert_response :forbidden
    assert_empty enqueued_jobs
  end
end

class SlackSettingsSmokeTest < SlackWorkflowSmokeTest
  tests SettingsController

  def test_inbound_settings_preserve_and_filter_signing_secret
    assert_equal '0', Redmine::Plugin.find(:redmine_slack).settings[:default]['import_enabled']
    inactive = User.where(status: User::STATUS_LOCKED).first
    get :plugin, params: {id: 'redmine_slack'}
    assert_select '#settings_import_enabled:not([checked])'
    assert_select '#settings_import_user_id option[value=?]', @user.id.to_s
    assert_select '#settings_import_user_id option[value=?]', inactive.id.to_s, count: 0 if inactive
    assert_select '#slack-signing-secret-status', text: 'Not configured'
    assert_select 'input[type=password][name="settings[signing_secret]"][value=""]'
    csrf_token = css_select('meta[name="csrf-token"]').first['content']
    post :plugin, params: {id: 'redmine_slack', authenticity_token: csrf_token,
      settings: {signing_secret: 'fixture-signing-secret', bot_token: 'fixture-token', import_enabled: '1', import_user_id: @user.id, delivery_enabled: '0', post_updates: '1'}}
    assert_equal '[FILTERED]', @request.filtered_parameters['settings']['signing_secret']
    assert_equal 'fixture-signing-secret', Setting.plugin_redmine_slack['signing_secret']
    assert_equal @user.id.to_s, Setting.plugin_redmine_slack['import_user_id'].to_s
    assert_equal '1', Setting.plugin_redmine_slack['import_enabled']
    get :plugin, params: {id: 'redmine_slack'}
    assert_select '#slack-signing-secret-status', text: 'Configured'
    assert_select 'input[type=password][name="settings[signing_secret]"][value=""]'
    refute_includes response.body, 'fixture-signing-secret'
    ['', nil].each do |value|
      submitted = {delivery_enabled: '0', post_updates: '1'}
      submitted[:signing_secret] = value unless value.nil?
      post :plugin, params: {id: 'redmine_slack', authenticity_token: csrf_token, settings: submitted}
      assert_equal 'fixture-signing-secret', Setting.plugin_redmine_slack['signing_secret']
      assert_equal 'fixture-token', Setting.plugin_redmine_slack['bot_token']
      assert_equal '1', Setting.plugin_redmine_slack['post_updates']
      assert_equal '0', Setting.plugin_redmine_slack['delivery_enabled']
    end
    post :plugin, params: {id: 'redmine_slack', authenticity_token: csrf_token, settings: {signing_secret: 'replacement-secret'}}
    assert_equal 'replacement-secret', Setting.plugin_redmine_slack['signing_secret']
  end

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

  def with_image_fixtures(images)
    original = Attachment.method(:find_by)
    Attachment.define_singleton_method(:find_by) { |id:| images[id] }
    yield
  ensure
    Attachment.define_singleton_method(:find_by, original) if original
  end

  def test_image_delivery_skips_unavailable_and_falls_back_to_customized_text
    image = Struct.new(:filename, :diskfile, :image?)
    Tempfile.create('slack-image') do |file|
      file.binmode
      file.write("\x00\xFFabc".b)
      file.flush
      fixtures = {1 => image.new('fixture.png', file.path, true), 2 => image.new('missing.png', file.path + '.missing', true), 3 => image.new('document.pdf', file.path, false)}
      with_image_fixtures(fixtures) do
        envelope = {'destination' => {'kind' => 'channel', 'id' => 'CFIXTURE1'}, 'text_parts' => ['<https://issue.invalid|Issue>\n>>>\n<@U123>'], 'username' => 'fixture-bot', 'icon_emoji' => ':event:', 'image_attachment_ids' => [1, 2, 3, 4]}
        SlackSmokeTransport.responses = [[200, '{"ok":true,"upload_url":"https://upload.example.invalid/synthetic","file_id":"F1"}', {}], [200, 'OK', {}], [200, '{"ok":true}', {}]]
        RedmineSlack::DeliveryJob.perform_now(envelope)
        requests = SlackSmokeTransport.requests
        assert_equal 3, requests.length
        assert_equal({filename: 'fixture.png', length: 5}, requests[0][:body])
        assert_equal "\x00\xFFabc".b, requests[1][:body]
        payload = JSON.parse(requests[2][:body])
        assert_equal [{'id' => 'F1'}], payload['files']
        assert_equal envelope['text_parts'].first, payload['initial_comment']
        assert_equal 'CFIXTURE1', payload['channel_id']
        assert_equal 'fixture-bot', payload['username']
        assert_equal ':event:', payload['icon_emoji']
        %w[unfurl_links unfurl_media attachments link_names blocks].each { |key| refute payload.key?(key) }
        SlackSmokeTransport.requests.clear
        SlackSmokeTransport.responses = nil
        envelope['image_attachment_ids'] = [2, 3, 4]
        RedmineSlack::DeliveryJob.perform_now(envelope)
        fallback = JSON.parse(SlackSmokeTransport.requests.last[:body])
        assert SlackSmokeTransport.requests.last[:url].end_with?('/chat.postMessage')
        assert_equal false, fallback['unfurl_links']
        assert_equal false, fallback['unfurl_media']
        assert_equal ':event:', fallback['icon_emoji']
        assert_equal 'fixture-bot', fallback['username']
        assert_equal envelope['text_parts'].first, fallback['text']
        SlackSmokeTransport.requests.clear
        envelope.delete('image_attachment_ids')
        RedmineSlack::DeliveryJob.perform_now(envelope)
        assert_equal 1, SlackSmokeTransport.requests.length
        SlackSmokeTransport.requests.clear
        envelope['image_attachment_ids'] = []
        RedmineSlack::DeliveryJob.perform_now(envelope)
        assert_equal 1, SlackSmokeTransport.requests.length
        SlackSmokeTransport.requests.clear
        envelope['image_attachment_ids'] = [1]
        SlackSmokeTransport.error = IOError.new('fixture transport error')
        RedmineSlack::DeliveryJob.perform_now(envelope)
        assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.length
        assert_empty SlackSmokeTransport.requests
      end
    end
  ensure
    SlackSmokeTransport.responses = nil
  end

  def test_combined_upload_renders_mentions_and_completes_all_files_once
    image = Struct.new(:filename, :diskfile, :image?)
    Tempfile.create('slack-image') do |file|
      file.write('fixture bytes')
      file.flush
      with_image_fixtures(1 => image.new('one.png', file.path, true), 2 => image.new('two.png', file.path, true)) do
        @executor.rslack_preference[:username] = 'UFIXTURE01'
        envelope = {'destination' => {'kind' => 'channel', 'id' => 'CFIXTURE1'}, 'text_parts' => ['<https://issue.invalid|Issue>', "\n>>>\n", RedmineSlack::MessageTemplate.mention(@executor)], 'username' => 'bot', 'icon_url' => 'https://example.invalid/icon', 'image_attachment_ids' => [1, 2]}
        SlackSmokeTransport.responses = [
          [200, '{"ok":true,"upload_url":"https://upload.example.invalid/synthetic","file_id":"F1"}', {}], [200, 'OK', {}],
          [200, '{"ok":true,"upload_url":"https://upload.example.invalid/synthetic","file_id":"F2"}', {}], [200, 'OK', {}],
          [200, '{"ok":true,"files":[]}', {}]
        ]
        RedmineSlack::DeliveryJob.perform_now(envelope)
        assert_equal 5, SlackSmokeTransport.requests.length
        payload = JSON.parse(SlackSmokeTransport.requests.last[:body])
        assert_equal [{'id' => 'F1'}, {'id' => 'F2'}], payload['files']
        assert_equal "<https://issue.invalid|Issue>\n>>>\n<@UFIXTURE01>", payload['initial_comment']
        assert_equal 'https://example.invalid/icon', payload['icon_url']
        refute SlackSmokeTransport.requests.any? { |request| request[:url].end_with?('/chat.postMessage') }
      end
    end
  ensure
    SlackSmokeTransport.responses = nil
  end

  def test_upload_retry_restarts_after_partial_progress_without_text_substitute
    image = Struct.new(:filename, :diskfile, :image?)
    Tempfile.create('slack-image') do |file|
      file.write('bytes')
      file.flush
      with_image_fixtures(1 => image.new('one.png', file.path, true), 2 => image.new('two.png', file.path, true)) do
        envelope = {'destination' => {'kind' => 'channel', 'id' => 'CFIXTURE1'}, 'text_parts' => ['fixture'], 'image_attachment_ids' => [1, 2]}
        acquisition = [200, '{"ok":true,"upload_url":"https://upload.example.invalid/synthetic","file_id":"F1"}', {}]
        raw = [200, 'OK', {}]
        SlackSmokeTransport.responses = [acquisition, raw, [429, '{}', {'Retry-After' => '7'}]]
        RedmineSlack::DeliveryJob.perform_now(envelope)
        queued = ActiveJob::Base.queue_adapter.enqueued_jobs.last
        assert_in_delta Time.now.to_f + 7, queued[:at], 2
        assert_equal envelope, ActiveJob::Arguments.deserialize(queued[:args]).first
        SlackSmokeTransport.requests.clear
        SlackSmokeTransport.responses = [acquisition, raw, acquisition, raw, [200, '{"ok":true}', {}]]
        ActiveJob::Base.execute(queued)
        assert_equal 2, SlackSmokeTransport.requests.count { |r| r[:url].end_with?('/files.getUploadURLExternal') }
        assert_equal 2, SlackSmokeTransport.requests.count { |r| r[:url] == 'https://upload.example.invalid/synthetic' }
        refute SlackSmokeTransport.requests.any? { |r| r[:url].end_with?('/chat.postMessage') }
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear
        SlackSmokeTransport.requests.clear
        SlackSmokeTransport.responses = [[200, '{"ok":false,"error":"invalid_auth"}', {}]]
        RedmineSlack::DeliveryJob.perform_now(envelope)
        assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
        refute SlackSmokeTransport.requests.any? { |r| r[:url].end_with?('/chat.postMessage') }
        SlackSmokeTransport.requests.clear
        SlackSmokeTransport.responses = [acquisition, raw, acquisition, raw, [503, '{}', {}]]
        RedmineSlack::DeliveryJob.perform_now(envelope)
        assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.length
        refute SlackSmokeTransport.requests.any? { |r| r[:url].end_with?('/chat.postMessage') }
      end
    end
  ensure
    SlackSmokeTransport.responses = nil
  end

  def test_comment_producer_queues_only_image_ids_and_preserves_original_note
    Setting.text_formatting = 'common_mark'
    image = Struct.new(:id, :filename, :created_on, :image?) do
      def diskfile; raise 'producer must not read files'; end
    end.new(123456, 'fixture.png', Time.at(1), true)
    @issue.define_singleton_method(:attachments) { [image] }
    journal = @issue.init_journal(@user, 'Before ![fixture](fixture.png) after')
    journal.define_singleton_method(:attachments) { [image] }
    @producer.define_singleton_method(:channel_for_project) { |_project| 'CFIXTURE1' }
    @producer.define_singleton_method(:is_client) { |_user, _project| false }
    @producer.notify_issue_update(issue: @issue, journal: journal)
    envelopes = ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| ActiveJob::Arguments.deserialize(job[:args]).first }
    envelope = envelopes.find { |item| item['image_attachment_ids'] }
    assert envelope
    assert_equal [123456], envelope['image_attachment_ids']
    assert_equal 'Before ![fixture](fixture.png) after', journal.notes
    assert_includes envelope['text_parts'].grep(String).join, 'Before  after'
    refute_includes envelope.to_json, 'fixture.png'
    refute_includes envelope.to_json, 'fixture-token'
    assert_equal ['image_attachment_ids'], envelope.keys.grep(/image|upload/)
    assert_empty SlackSmokeTransport.requests
  end

  def test_private_and_blank_notes_never_queue_comment_images
    Setting.text_formatting = 'common_mark'
    image = Struct.new(:id, :filename, :created_on, :image?) do
      def diskfile; raise 'producer must not read files'; end
    end.new(123456, 'fixture.png', Time.at(1), true)
    @issue.define_singleton_method(:attachments) { [image] }
    @producer.define_singleton_method(:channel_for_project) { |_project| 'CFIXTURE1' }
    @producer.define_singleton_method(:prepare_details_change_message) { |_issue, _journal, _msg| ['Fixture update', {}] }
    journal = @issue.init_journal(@user, 'Private ![fixture](fixture.png)')
    journal.private_notes = true
    journal.define_singleton_method(:attachments) { [image] }
    @producer.notify_issue_update(issue: @issue, journal: journal)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    assert jobs.any?
    refute_includes jobs.map { |job| job[:args] }.to_json, 'Private'
    refute_includes jobs.map { |job| job[:args] }.to_json, 'image_attachment_ids'
    assert_empty SlackSmokeTransport.requests
    jobs.clear
    @producer.define_singleton_method(:prepare_details_change_message) { |_issue, _journal, msg| [msg, {}] }
    journal.private_notes = false
    journal.notes = ''
    @producer.notify_issue_update(issue: @issue, journal: journal)
    assert_empty jobs
    assert_empty SlackSmokeTransport.requests
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
    assert_equal false, payload['unfurl_links']
    assert_equal false, payload['unfurl_media']
  end

  def test_comment_payload_escapes_literal_controls_but_resolves_login
    @executor.update_columns(login: 'fixture.comment-user')
    @executor.rslack_preference[:username] = 'UFIXTURE01'
    @producer.define_singleton_method(:is_client) { |_user, _project| false }
    executor = @executor
    @producer.define_singleton_method(:get_executor) { |_issue| executor }
    journal = @issue.init_journal(@user, "<!channel> <@U012AB3CD> a < b & c @#{@executor.login}")
    parts, = @producer.send(:prepare_comment_message, @issue, journal, 'CFIXTURE1')
    @producer.speak(parts, 'CFIXTURE1')
    envelope = ActiveJob::Arguments.deserialize(ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args]).first
    RedmineSlack::DeliveryJob.perform_now(envelope)
    text = JSON.parse(SlackSmokeTransport.requests.last[:body])['text']
    assert_includes text, '&lt;!channel&gt;'
    assert_includes text, '&lt;@U012AB3CD&gt;'
    assert_includes text, 'a &lt; b &amp; c'
    assert_includes text, '<@UFIXTURE01>'
    refute_includes text, '<!channel>'
    refute_includes text, '<@U012AB3CD>'
  end

  def test_reminder_payload_keeps_issue_link_and_escapes_display_values
    @issue.project.name = 'Project & <control>'
    @issue.tracker.name = 'Tracker & <control>'
    @issue.subject = 'ordinary> <!here>'
    @issue.status.name = 'Status & <control>'
    @issue.priority.name = 'Priority & <control>'
    entry = @producer.send(:format_issue_for_list, @issue)
    @producer.speak(entry, 'CFIXTURE1')
    envelope = ActiveJob::Arguments.deserialize(ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args]).first
    RedmineSlack::DeliveryJob.perform_now(envelope)
    text = JSON.parse(SlackSmokeTransport.requests.last[:body])['text']
    assert_includes text, 'Project &amp; &lt;control&gt;'
    assert_includes text, "<#{@producer.send(:object_url, @issue)}|Tracker &amp; &lt;control&gt; ##{@issue.id}: ordinary&gt; &lt;!here&gt;>"
    assert_includes text, '(Status &amp; &lt;control&gt;)'
    assert_includes text, '[Priority &amp; &lt;control&gt;]'
    assert_equal 1, text.scan(/<[^>]*>/).length
    refute_includes text, '<!here>'
  end

  def test_captured_assignee_is_escaped_and_generated_broadcast_remains_active
    @user.firstname = 'Name & <control>'
    @issue.assigned_to = @user
    journal = @issue.init_journal(@user, '')
    journal.details.build(property: 'attr', prop_key: 'assigned_to_id', old_value: '1', value: @user.id.to_s)
    @producer.define_singleton_method(:is_story) { |_issue| true }
    parts, = @producer.send(:prepare_assigned_change_message, @issue, journal)
    @producer.speak(parts, 'CFIXTURE1')
    envelope = ActiveJob::Arguments.deserialize(ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args]).first
    RedmineSlack::DeliveryJob.perform_now(envelope)
    text = JSON.parse(SlackSmokeTransport.requests.last[:body])['text']
    assert_includes text, 'Story was captured by Name &amp; &lt;control&gt;'
    refute_includes text, '<control>'

    @producer.define_singleton_method(:channel_for_project) { |_project| 'CFIXTURE1' }
    @issue.priority_id = 5
    @producer.controller_issues_new_after_save(issue: @issue)
    envelope = ActiveJob::Arguments.deserialize(ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args]).first
    RedmineSlack::DeliveryJob.perform_now(envelope)
    assert JSON.parse(SlackSmokeTransport.requests.last[:body])['text'].start_with?('<!channel>')
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
