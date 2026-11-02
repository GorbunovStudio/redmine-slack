module RedmineSlack
  module SettingsPatch
    def plugin
      if request.post? && params[:id] == 'redmine_slack'
        params[:settings] ||= ActionController::Parameters.new
        if params[:settings]['bot_token'].blank?
          params[:settings]['bot_token'] = Setting.plugin_redmine_slack['bot_token']
        end
      end
      super
    end
  end
end
