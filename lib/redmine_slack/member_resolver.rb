module RedmineSlack
  class MemberResolver
    def initialize(client)
      @client = client
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
  end
end
