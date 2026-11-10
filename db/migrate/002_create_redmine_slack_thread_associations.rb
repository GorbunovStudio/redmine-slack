class CreateRedmineSlackThreadAssociations < ActiveRecord::Migration[8.1]
  def change
    create_table :redmine_slack_thread_associations do |t|
      t.string :channel_id, :root_message_ts, null: false
      t.integer :issue_id, null: false
    end
    add_index :redmine_slack_thread_associations, [:channel_id, :root_message_ts], unique: true, name: :slack_thread_identity
    add_index :redmine_slack_thread_associations, :issue_id
  end
end
