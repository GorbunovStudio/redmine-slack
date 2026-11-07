require 'uri'

module RedmineSlack
  class AvatarCache
    KEY = :rslack_avatar
    MEMBER_ID = /\A[UW][A-Z0-9]+\z/
    IMAGE_EXTENSIONS = %w[jpg jpeg gif png heic].freeze
    # Same interval as the identity caches in MemberResolver; it is a reuse of
    # that policy, not a Slack-documented avatar lifetime.
    REFRESH_INTERVAL = 24.hours

    class << self
      def member_id(value)
        candidate = value.to_s.strip
        candidate if candidate.match?(MEMBER_ID)
      end

      # Picks the largest compatible numeric image_<size> URL of a users.info response.
      def image_url(response)
        user = response['user'] if response.is_a?(Hash)
        profile = user['profile'] if user.is_a?(Hash)
        return nil unless profile.is_a?(Hash)

        profile.filter_map { |field, value| [$1.to_i, value] if field.to_s =~ /\Aimage_(\d+)\z/ }
          .sort_by { |size, _| -size }
          .lazy.filter_map { |_, value| compatible_url(value) }.first
      end

      # Gravatar accepts a custom default only as a public HTTP(S) image URL on a
      # standard port with a recognizable extension and no query string.
      def compatible_url(value)
        return nil unless value.is_a?(String)

        uri = URI.parse(value)
        extension = File.extname(uri.path.to_s).delete_prefix('.').downcase
        value if uri.is_a?(URI::HTTPS) && uri.host.present? && uri.port == 443 && uri.userinfo.nil? &&
          uri.query.nil? && uri.fragment.nil? && IMAGE_EXTENSIONS.include?(extension)
      rescue URI::InvalidURIError
        nil
      end

      # Returns the cached fallback URL for the user's explicit Slack association and
      # requests a background refresh when one is due. It never calls Slack.
      def url_for(user)
        return nil unless user.is_a?(User) && !user.is_a?(AnonymousUser) && user.persisted?

        others = UserPreference.where(user_id: user.id).pick(:others)
        return nil unless others.is_a?(Hash)

        member = member_id(others[:rslack_username])
        return nil unless member

        state = state_for(others, member)
        request_refresh(user.id, member) if due?(state) && token_configured?
        compatible_url(state[:url])
      end

      def request_refresh(user_id, member)
        ActiveRecord::Base.transaction(requires_new: true) do
          pref = UserPreference.lock.find_by(user_id: user_id)
          next unless pref && member_id(pref[:rslack_username]) == member

          state = state_for(pref.others, member)
          next unless due?(state)
          next if state[:job_id] && GoodJob::Job.unfinished.exists?(active_job_id: state[:job_id])

          job = ::RedmineSlack::AvatarRefreshJob.new(user_id, member)
          pref[KEY] = {member_id: member, url: state[:url], refresh_after: now + REFRESH_INTERVAL.to_i, job_id: job.job_id}
          pref.save!
          job.enqueue
          raise ActiveRecord::Rollback unless job.successfully_enqueued?
        end
        nil
      rescue ActiveJob::EnqueueError
        nil
      end

      def current?(user_id, member, job_id)
        others = UserPreference.where(user_id: user_id).pick(:others)
        others.is_a?(Hash) && member_id(others[:rslack_username]) == member && state_for(others, member)[:job_id] == job_id
      end

      # Saves a refresh outcome only while the association and job still match.
      # Without a :url the existing same-association image is kept.
      def finish(user_id, member, job_id, **result)
        ActiveRecord::Base.transaction(requires_new: true) do
          pref = UserPreference.lock.find_by(user_id: user_id)
          state = state_for(pref.others, member) if pref && member_id(pref[:rslack_username]) == member
          if state && state[:job_id] == job_id
            url = result.key?(:url) ? result[:url] : state[:url]
            pref[KEY] = {member_id: member, url: url, refresh_after: now + REFRESH_INTERVAL.to_i, job_id: job_id}
            pref.save!
            true
          else
            false
          end
        end
      end

      def clear(pref)
        pref.others = (pref.others || {}).except(KEY)
      end

      private

      def state_for(others, member)
        stored = others[KEY]
        return {} unless stored.is_a?(Hash) && stored[:member_id] == member

        url, refresh_after, job_id = stored.values_at(:url, :refresh_after, :job_id)
        # A nil url is a valid negative cache; any other malformed field makes the whole state uncached.
        return {} unless (url.nil? || url.is_a?(String)) && refresh_after.is_a?(Integer) && job_id.is_a?(String)

        {url: url, refresh_after: refresh_after, job_id: job_id}
      end

      def due?(state)
        state[:refresh_after].to_i <= now
      end

      def now
        Time.current.to_i
      end

      def token_configured?
        Setting.plugin_redmine_slack.with_indifferent_access[:bot_token].present?
      end
    end
  end
end
