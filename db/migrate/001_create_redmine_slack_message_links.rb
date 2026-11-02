class CreateRedmineSlackMessageLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :redmine_slack_message_links do |t|
      t.string :channel_id, :message_ts, null: false
      t.integer :journal_id
      t.string :slack_user_id, :author_name, :last_edited_ts
      t.datetime :deleted_at
    end
    add_index :redmine_slack_message_links, [:channel_id, :message_ts], unique: true, name: :slack_message_identity
  end
end
