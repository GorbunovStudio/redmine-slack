module RedmineSlack
  module MyControllerPatch
    def self.included(base)
      base.after_action :save_slack_preferences, only: :account
    end

    def save_slack_preferences
      if request.put? && @user&.persisted? && @user.errors.empty? && params[:redmine_slack]
        @user.rslack_preference[:username] = params[:redmine_slack][:username].to_s
      end
    end
  end
end
