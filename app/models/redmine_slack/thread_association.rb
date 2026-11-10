module RedmineSlack
  class ThreadAssociation < ActiveRecord::Base
    self.table_name = 'redmine_slack_thread_associations'
  end
end
