module RedmineSlack
  class AssociationIndicationJob < ActiveJob::Base
    queue_as :slack
    self.enqueue_after_transaction_commit = true
    self.log_arguments = false

    retry_on ::RedmineSlack::TransientError do |_job, error|
      Rails.logger.warn("Slack indication exhausted (#{error.message})")
    end
    rescue_from ::RedmineSlack::RateLimitError do |error|
      retry_job wait: error.wait
    end
    rescue_from ::RedmineSlack::DropError do |error|
      Rails.logger.warn("Slack indication dropped (#{error.message})")
    end

    def perform(operation, channel, root_message_ts, issue_id = nil)
      Setting.check_cache
      settings = Setting.plugin_redmine_slack.with_indifferent_access
      import_user = ::RedmineSlack::InboundReadiness.import_user(settings)
      return unless import_user

      client = ::RedmineSlack::Client.new(settings[:bot_token])
      if operation == 'remove'
        client.remove_reaction(channel, root_message_ts)
      else
        client.add_reaction(channel, root_message_ts)
        payload = ::RedmineSlack::IssuePreview.new(settings, import_user).payload(channel, [issue_id], root_message_ts)
        client.post_message(payload) if payload
      end
    end
  end
end
