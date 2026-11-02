module RedmineSlack
  module SettingsPatch
    def plugin
      if request.post? && params[:id] == 'redmine_slack'
        params[:settings] ||= ActionController::Parameters.new
        %w[bot_token signing_secret].each do |key|
          params[:settings][key] = Setting.plugin_redmine_slack[key] if params[:settings][key].blank?
        end
      end
      super
    end
  end
end
