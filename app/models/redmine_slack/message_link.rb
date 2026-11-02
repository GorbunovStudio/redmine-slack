module RedmineSlack
  class MessageLink < ActiveRecord::Base
    self.table_name = 'redmine_slack_message_links'
  end
end
