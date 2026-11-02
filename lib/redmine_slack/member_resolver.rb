module RedmineSlack
  class MemberResolver
    def initialize(client)
      @client = client
      @user_info = {}
    end

    def member(user_id)
      user = User.find_by(id: user_id)
      return nil unless user
      preferred = user.rslack_preference[:username].to_s.strip
      return preferred if preferred.match?(/\A[UW][A-Z0-9]+\z/)
      key = ['redmine_slack', 'member', user.id]
      cached = Rails.cache.read(key)
      return cached if cached
      return nil if user.mail.blank?
      result = @client.lookup_by_email(user.mail).dig('user', 'id')
      Rails.cache.write(key, result, expires_in: 24.hours) if result
      result
    rescue IdentityMiss
      nil
    end

    def dm(member_id)
      key = ['redmine_slack', 'dm', member_id]
      cached = Rails.cache.read(key)
      return cached if cached
      result = @client.open_conversation(member_id).dig('channel', 'id')
      Rails.cache.write(key, result, expires_in: 24.hours) if result
      result
    end

    def user(member_id)
      preferred = User.active.includes(:preference).find { |user| user.rslack_preference[:username].to_s.strip == member_id }
      return preferred if preferred
      key = ['redmine_slack', 'reverse_member', member_id]
      cached = Rails.cache.read(key)
      if cached
        user = User.active.find_by(id: cached)
        return user if user
        Rails.cache.delete(key)
      end
      email = user_info(member_id).dig('user', 'profile', 'email')
      return nil if email.blank?
      user = User.active.having_mail(email).first
      Rails.cache.write(key, user.id, expires_in: 24.hours) if user
      user
    end

    def display_name(member_id)
      profile = user_info(member_id)['user'] || {}
      profile.dig('profile', 'display_name').presence || profile.dig('profile', 'real_name').presence || profile['name'].presence || member_id
    end

    private

    def user_info(member_id)
      @user_info[member_id] ||= @client.user_info(member_id)
    end
  end
end
