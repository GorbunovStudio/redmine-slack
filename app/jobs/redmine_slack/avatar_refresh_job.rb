module RedmineSlack
  class AvatarRefreshJob < ActiveJob::Base
    queue_as :slack
    self.enqueue_after_transaction_commit = false
    self.log_arguments = false

    retry_on ::RedmineSlack::TransientError do |job, error|
      Rails.logger.warn("Slack avatar refresh exhausted (#{error.message})")
      job.record_failure
    end

    rescue_from ::RedmineSlack::RateLimitError do |error|
      retry_job wait: error.wait
    end

    rescue_from ::RedmineSlack::DropError do |error|
      Rails.logger.warn("Slack avatar refresh dropped (#{error.message})")
      record_failure
    end

    def perform(user_id, member_id)
      Setting.check_cache
      token = Setting.plugin_redmine_slack.with_indifferent_access[:bot_token]
      return if token.blank?
      return unless ::RedmineSlack::AvatarCache.current?(user_id, member_id, job_id)

      response = ::RedmineSlack::Client.new(token).user_info(member_id)
      ::RedmineSlack::AvatarCache.finish(user_id, member_id, job_id, url: ::RedmineSlack::AvatarCache.image_url(response))
    end

    def record_failure
      user_id, member_id = arguments
      ::RedmineSlack::AvatarCache.finish(user_id, member_id, job_id)
    end
  end
end
