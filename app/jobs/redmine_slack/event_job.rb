module RedmineSlack
  class EventJob < ActiveJob::Base
    queue_as :slack
    self.enqueue_after_transaction_commit = false
    self.log_arguments = false

    retry_on ActiveRecord::StaleObjectError

    retry_on ::RedmineSlack::TransientError do |_job, error|
      Rails.logger.warn("Slack event exhausted (#{error.message})")
    end

    rescue_from ::RedmineSlack::RateLimitError do |error|
      retry_job wait: error.wait
    end

    rescue_from ::RedmineSlack::DropError do |error|
      Rails.logger.warn("Slack event dropped (#{error.message})")
    end

    def perform(event)
      Setting.check_cache
      settings = Setting.plugin_redmine_slack.with_indifferent_access
      return unless settings[:import_enabled] == '1' && settings[:signing_secret].present? && settings[:bot_token].present?
      import_user = User.active.find_by(id: settings[:import_user_id])
      return unless import_user
      return unless event.is_a?(Hash) && event['type'] == 'message' && %w[group im].include?(event['channel_type'])
      return if event['bot_id'].present? || event.dig('message', 'bot_id').present? || event.dig('previous_message', 'bot_id').present?
      return if [event.dig('message', 'subtype'), event.dig('previous_message', 'subtype')].include?('bot_message')
      if %w[message_changed message_deleted].include?(event['subtype'])
        importer = ::RedmineSlack::CommentImporter.new(::RedmineSlack::Client.new(settings[:bot_token]), import_user)
        event['subtype'] == 'message_changed' ? importer.edit(event) : importer.delete(event)
        return
      end
      return unless [nil, 'file_share', 'thread_broadcast'].include?(event['subtype'])
      return if event['user'].blank?

      client = ::RedmineSlack::Client.new(settings[:bot_token])
      message = ::RedmineSlack::InboundMessage.new(event['text'])
      target = message.marker
      if !target && event['thread_ts'].present?
        parent = client.conversation_parent(event['channel'], event['thread_ts'])
        if parent
          fields = [parent['text']] + Array(parent['attachments']).flat_map { |attachment| [attachment['title'], attachment['text']] }
          target = fields.lazy.map { |text| ::RedmineSlack::InboundMessage.new(text).references.first }.find(&:itself)
        end
      end
      ::RedmineSlack::CommentImporter.new(client, import_user).create(event, target) if target

      references = message.preview_references
      attachments = references.filter_map do |id|
        issue = Issue.find_by(id: id)
        next unless issue && issue.visible?(import_user)
        escape = ::RedmineSlack::MessageTemplate.method(:escape)
        url = "#{Setting.protocol}://#{Setting.host_name}/issues/#{issue.id}"
        {text: "<#{url}|#{escape.call(issue.tracker)} ##{issue.id}: #{escape.call(issue.subject)}>\n#{escape.call(issue.project)} — #{escape.call(issue.status)} — #{escape.call(issue.priority)}\n#{escape.call(issue.description)}"}
      end
      unless attachments.empty?
        payload = {channel: event['channel'], text: '', attachments: attachments, unfurl_links: false, unfurl_media: false}
        payload[:thread_ts] = event['thread_ts'] if event['thread_ts'].present?
        payload[:username] = settings[:username] if settings[:username]
        if settings[:icon].present?
          payload[settings[:icon].start_with?(':') ? :icon_emoji : :icon_url] = settings[:icon]
        end
        client.post_message(payload)
      end
    end
  end
end
