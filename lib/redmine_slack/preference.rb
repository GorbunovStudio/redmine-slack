module RedmineSlack
  class Preference
    def initialize(user)
      @user = user
    end

    def []=(attribute, value)
      raise "Unsupported attribute '#{attribute}'" unless attribute == :username

      @user.pref[:rslack_username] = value.to_s.strip
      @user.pref.save! if @user.persisted?
    end

    def [](attribute)
      raise "Unsupported attribute '#{attribute}'" unless attribute == :username

      @user.pref[:rslack_username].to_s.strip
    end
  end
end
