module RedmineSlack
  class ThreadImportJob < ActiveJob::Base
    queue_as :slack
    self.enqueue_after_transaction_commit = true
    self.log_arguments = false

    retry_on ActiveRecord::StaleObjectError
    retry_on ::RedmineSlack::TransientError do |_job, error|
      Rails.logger.warn("Slack history exhausted (#{error.message})")
    end
    rescue_from ::RedmineSlack::RateLimitError do |error|
      retry_job wait: error.wait
    end
    rescue_from ::RedmineSlack::DropError do |error|
      Rails.logger.warn("Slack history dropped (#{error.message})")
    end

    def perform(channel, root_message_ts, issue_id)
      Setting.check_cache
      settings = Setting.plugin_redmine_slack.with_indifferent_access
      import_user = ::RedmineSlack::InboundReadiness.import_user(settings)
      return unless import_user

      client = ::RedmineSlack::Client.new(settings[:bot_token])
      resolver = ::RedmineSlack::MessageTarget.new(client)
      importer = ::RedmineSlack::CommentImporter.new(client, import_user)
      cursor = nil
      loop do
        page = client.conversation_replies(channel, root_message_ts, cursor)
        Array(page['messages']).each do |message|
          next unless resolver.eligible?(message)

          importer.create(message.merge('channel' => channel), resolver.for_history(message, issue_id))
        end
        cursor = page.dig('response_metadata', 'next_cursor')
        break if cursor.blank?
      end
    end
  end
end
