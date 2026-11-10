module RedmineSlack
  class AssociationManager
    class NotFound < StandardError; end
    class NotAuthorized < StandardError; end
    class InvalidSource < StandardError; end
    class ImportNotReady < StandardError; end

    def initialize(actor, api: false)
      @actor = actor
      @api = api
    end

    def show(channel, root)
      source!(channel, root)
      association = ThreadAssociation.find_by(channel_id: channel, root_message_ts: root)
      raise NotFound unless association
      authorize!(Issue.find_by(id: association.issue_id), read: true)
      association
    end

    def confirm(channel, root, issue_id = nil)
      source!(channel, root)
      association = ThreadAssociation.find_by(channel_id: channel, root_message_ts: root)
      authorize!(Issue.find_by(id: association.issue_id)) if association
      if issue_id
        issue = Issue.find_by(id: issue_id)
        authorize!(issue)
        issue
      else
        raise NotFound unless association
        Issue.find_by(id: association.issue_id)
      end
    end

    def upsert(channel, root, issue_id, import_existing: false)
      source!(channel, root)
      Setting.check_cache
      settings = Setting.plugin_redmine_slack.with_indifferent_access
      raise ImportNotReady unless InboundReadiness.import_user(settings)
      raise NotFound unless issue_id.is_a?(Integer) || (issue_id.is_a?(String) && issue_id.match?(/\A\d+\z/))
      issue = Issue.find_by(id: issue_id)
      authorize!(issue)
      client = Client.new(settings[:bot_token])
      conversation = client.conversation_info(channel)
      supported = conversation && ((conversation['is_private'] && (conversation['is_channel'] || conversation['is_group']) && !conversation['is_mpim']) || conversation['is_im'])
      parent = client.conversation_parent(channel, root) if supported
      raise InvalidSource unless parent && (parent['thread_ts'].blank? || parent['thread_ts'] == root)

      begin
        ThreadAssociation.transaction(requires_new: true) do
          association = ThreadAssociation.lock.find_by(channel_id: channel, root_message_ts: root)
          created = association.nil?
          authorize!(Issue.find_by(id: association.issue_id)) if association
          association ||= ThreadAssociation.new(channel_id: channel, root_message_ts: root)
          association.issue_id = issue.id
          association.save!
          ThreadImportJob.perform_later(channel, root, issue.id) if import_existing
          AssociationIndicationJob.perform_later('upsert', channel, root, issue.id)
          [association, created]
        end
      rescue ActiveRecord::RecordNotUnique
        retry
      end
    end

    def remove(channel, root)
      source!(channel, root)
      ThreadAssociation.transaction do
        association = ThreadAssociation.lock.find_by(channel_id: channel, root_message_ts: root)
        raise NotFound unless association
        authorize!(Issue.find_by(id: association.issue_id))
        association.destroy!
        Setting.check_cache
        settings = Setting.plugin_redmine_slack.with_indifferent_access
        AssociationIndicationJob.perform_later('remove', channel, root) if InboundReadiness.import_user(settings)
      end
    end

    private

    def source!(channel, root)
      raise InvalidSource unless channel.is_a?(String) && channel.present? && root.is_a?(String) && root.present?
    end

    def authorize!(issue, read: false)
      raise NotFound unless issue && @actor && issue.visible?(@actor)
      raise NotAuthorized if @api && !@actor.allowed_to?(:manage_slack_associations_via_api, issue.project)
      raise NotAuthorized if !read && !issue.notes_addable?(@actor)
    end
  end
end
