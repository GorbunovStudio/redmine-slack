module RedmineSlack
  class InteractionViewJob < ActiveJob::Base
    queue_as :slack
    self.log_arguments = false
    self.enqueue_after_transaction_commit = false

    retry_on ::RedmineSlack::TransientError do |_job, error|
      Rails.logger.warn("Slack interaction view exhausted (#{error.message})")
    end

    rescue_from ::RedmineSlack::RateLimitError do |error|
      retry_job wait: error.wait
    end

    rescue_from ::RedmineSlack::DropError do |error|
      Rails.logger.warn("Slack interaction view dropped (#{error.message})")
    end

    def perform(destination, view)
      Setting.check_cache
      settings = Setting.plugin_redmine_slack.with_indifferent_access
      return if settings[:bot_token].blank?

      Client.new(settings[:bot_token]).update_view(destination, view)
    rescue ::RedmineSlack::DropError => error
      raise ::RedmineSlack::TransientError, 'view_not_found', cause: nil if error.message == 'not_found'
      raise
    end
  end
end
