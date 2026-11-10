module RedmineSlack
  class MessageTarget
    def initialize(client)
      @client = client
    end

    def eligible?(message)
      message['bot_id'].blank? &&
        [nil, 'file_share', 'thread_broadcast'].include?(message['subtype']) && message['user'].present?
    end

    def for_event(event)
      marker = InboundMessage.new(event['text']).marker
      return marker if marker
      return unless event['thread_ts'].present?

      association = ThreadAssociation.find_by(channel_id: event['channel'], root_message_ts: event['thread_ts'])
      return association.issue_id if association

      parent = @client.conversation_parent(event['channel'], event['thread_ts'])
      return unless parent

      fields = [parent['text']] + Array(parent['attachments']).flat_map { |attachment| [attachment['title'], attachment['text']] }
      fields.lazy.map { |text| InboundMessage.new(text).references.first }.find(&:itself)
    end

    def for_history(message, issue_id)
      InboundMessage.new(message['text']).marker || issue_id
    end
  end
end
