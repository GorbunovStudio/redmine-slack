require 'bigdecimal'

module RedmineSlack
  class CommentImporter
    def initialize(client, import_user)
      @client = client
      @import_user = import_user
      @resolver = MemberResolver.new(client)
    end

    def create(event, issue_id)
      return if MessageLink.exists?(channel_id: event['channel'], message_ts: event['ts'])
      issue = Issue.find_by(id: issue_id)
      return unless issue
      linked = @resolver.user(event['user'])
      author = linked if linked && issue.visible?(linked) && issue.notes_addable?(linked)
      unless author
        unless @import_user.member_of?(issue.project) && issue.visible?(@import_user) && issue.notes_addable?(@import_user)
          Rails.logger.warn('Slack import skipped (not_authorized)')
          return
        end
        author = @import_user
        author_name = @resolver.display_name(event['user'])
      end
      text = InboundMessage.new(event['text'], event['blocks']).convert(@resolver).strip
      notes = author_name ? ["**#{author_name}** (Slack):", text.presence].compact.join("\n") : text
      previous_user = User.current
      User.current = author
      MessageLink.transaction do
        link = MessageLink.create!(channel_id: event['channel'], message_ts: event['ts'], slack_user_id: event['user'],
          author_name: author_name, last_edited_ts: event.dig('edited', 'ts') || event['ts'])
        journal = issue.init_journal(author, notes)
        if issue.attachments_addable?(author)
          Array(event['files']).each do |file|
            bytes = @client.download_file(file)
            next unless bytes
            attachment = Attachment.new(author: author, filename: file['name'], content_type: file['mimetype'])
            attachment.file = bytes
            issue.attachments << attachment if attachment.save
          end
        end
        issue.save!
        raise ActiveRecord::Rollback unless journal.persisted?
        link.update!(journal_id: journal.id)
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    ensure
      User.current = previous_user if previous_user
    end

    def edit(event)
      message = event['message'] || {}
      timestamp = message.dig('edited', 'ts').to_s
      return unless timestamp.match?(/\A\d+(?:\.\d+)?\z/)
      MessageLink.transaction do
        link = MessageLink.lock.find_by(channel_id: event['channel'], message_ts: message['ts'])
        next unless link && !link.deleted_at && link.journal_id
        next unless BigDecimal(timestamp) > BigDecimal(link.last_edited_ts.to_s)
        journal = Journal.find_by(id: link.journal_id)
        next unless journal
        text = InboundMessage.new(message['text'], message['blocks']).convert(@resolver).strip
        notes = link.author_name.present? ? ["**#{link.author_name}** (Slack):", text.presence].compact.join("\n") : text
        journal.update!(notes: notes)
        link.update!(last_edited_ts: timestamp)
      end
    end

    def delete(event)
      timestamp = event['deleted_ts']
      return if timestamp.blank?
      deleted_at = event['event_ts'].present? ? Time.at(BigDecimal(event['event_ts'])).in_time_zone : Time.current
      MessageLink.transaction do
        link = MessageLink.lock.find_or_initialize_by(channel_id: event['channel'], message_ts: timestamp)
        next if link.deleted_at
        journal = Journal.find_by(id: link.journal_id) if link.journal_id
        if journal
          old_notes = journal.notes.to_s.lines.map { |line| line.chomp.blank? ? line : "~~#{line.chomp}~~#{line.end_with?("\n") ? "\n" : ''}" }.join
          heading = "_Deleted in Slack on #{ApplicationController.helpers.format_time(deleted_at)}_"
          journal.update!(notes: "#{heading}\n\n#{old_notes}")
        end
        link.update!(deleted_at: deleted_at)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
