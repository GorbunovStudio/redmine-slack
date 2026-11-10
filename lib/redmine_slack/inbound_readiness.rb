module RedmineSlack
  class InboundReadiness
    def self.import_user(settings)
      return unless settings[:import_enabled] == '1' && settings[:signing_secret].present? && settings[:bot_token].present?

      User.active.find_by(id: settings[:import_user_id])
    end
  end
end
