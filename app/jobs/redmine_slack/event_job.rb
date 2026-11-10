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
      import_user = ::RedmineSlack::InboundReadiness.import_user(settings)
      return unless import_user
      return unless event.is_a?(Hash) && event['type'] == 'message' && %w[group im].include?(event['channel_type'])
      return if event['bot_id'].present? || event.dig('message', 'bot_id').present? || event.dig('previous_message', 'bot_id').present?
      return if [event.dig('message', 'subtype'), event.dig('previous_message', 'subtype')].include?('bot_message')
      if %w[message_changed message_deleted].include?(event['subtype'])
        importer = ::RedmineSlack::CommentImporter.new(::RedmineSlack::Client.new(settings[:bot_token]), import_user)
        event['subtype'] == 'message_changed' ? importer.edit(event) : importer.delete(event)
        return
      end
      client = ::RedmineSlack::Client.new(settings[:bot_token])
      resolver = ::RedmineSlack::MessageTarget.new(client)
      return unless resolver.eligible?(event)
      message = ::RedmineSlack::InboundMessage.new(event['text'])
      target = resolver.for_event(event)
      ::RedmineSlack::CommentImporter.new(client, import_user).create(event, target) if target

      payload = ::RedmineSlack::IssuePreview.new(settings, import_user).payload(event['channel'], message.preview_references, event['thread_ts'])
      client.post_message(payload) if payload
    end
  end
end
