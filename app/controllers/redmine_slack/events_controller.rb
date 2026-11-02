module RedmineSlack
  class EventsController < ActionController::Base
    skip_forgery_protection

    def create
      secret = Setting.plugin_redmine_slack['signing_secret']
      timestamp = request.headers['X-Slack-Request-Timestamp'].to_s
      signature = request.headers['X-Slack-Signature'].to_s
      body = request.raw_post
      return head :forbidden if secret.blank? || !timestamp.match?(/\A\d+\z/) || (Time.now.to_i - timestamp.to_i).abs > 5.minutes
      expected = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}"
      return head :forbidden unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)

      payload = JSON.parse(body)
      return head :bad_request unless payload.is_a?(Hash)
      case payload['type']
      when 'url_verification'
        render plain: payload['challenge'].to_s
      when 'event_callback'
        ::RedmineSlack::EventJob.perform_later(payload['event'])
        head :ok
      else
        head :ok
      end
    rescue JSON::ParserError
      head :bad_request
    end
  end
end
