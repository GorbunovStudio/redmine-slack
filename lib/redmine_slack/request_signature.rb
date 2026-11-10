module RedmineSlack
  class RequestSignature
    def self.valid?(request)
      secret = Setting.plugin_redmine_slack['signing_secret']
      timestamp = request.headers['X-Slack-Request-Timestamp'].to_s
      signature = request.headers['X-Slack-Signature'].to_s
      return false if secret.blank? || !timestamp.match?(/\A\d+\z/) || (Time.now.to_i - timestamp.to_i).abs > 5.minutes

      expected = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{request.raw_post}")}"
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end
  end
end
