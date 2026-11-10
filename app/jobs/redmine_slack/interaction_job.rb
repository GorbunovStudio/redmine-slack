module RedmineSlack
  class InteractionJob < ActiveJob::Base
    queue_as :slack
    self.log_arguments = false
    self.enqueue_after_transaction_commit = false

    retry_on ::RedmineSlack::TransientError do |job, error|
      Rails.logger.warn("Slack interaction exhausted (#{error.message})")
      destination = job.arguments[1]
      InteractionViewJob.perform_later(destination, AssociationModal.message({}, 'Association unavailable.', external_id: destination))
    end
    rescue_from ::RedmineSlack::RateLimitError do |error|
      retry_job wait: error.wait
    end
    def perform(stage, destination, metadata)
      Setting.check_cache
      settings = Setting.plugin_redmine_slack.with_indifferent_access
      unless InboundReadiness.import_user(settings)
        InteractionViewJob.perform_later(destination, AssociationModal.message({}, 'Association unavailable.', external_id: destination))
        return
      end
      client = Client.new(settings[:bot_token])
      actor = MemberResolver.new(client).user(metadata['actor'])
      manager = AssociationManager.new(actor)
      channel = metadata['channel']
      root = metadata['root']
      issue_id = metadata['issue_id']
      raise AssociationManager::NotFound if issue_id && !issue_id.match?(/\A\d+\z/)
      if stage == 'prepare'
        issue = manager.confirm(channel, root, issue_id)
        text = issue_id ? "Link to ##{issue.id}: #{issue.subject}?" : "Remove link to ##{issue.id}: #{issue.subject}?"
        text += "\n\nExisting messages will be imported." if issue_id && metadata['import_existing']
        view = AssociationModal.message(metadata, text, confirm: true, external_id: destination)
      else
        if issue_id
          manager.upsert(channel, root, issue_id, import_existing: metadata['import_existing'])
        else
          manager.remove(channel, root)
        end
        view = AssociationModal.message({}, 'Association updated.', external_id: destination)
      end
      InteractionViewJob.perform_later(destination, view)
    rescue AssociationManager::NotFound, AssociationManager::NotAuthorized, AssociationManager::InvalidSource, AssociationManager::ImportNotReady, ::RedmineSlack::DropError => error
      Rails.logger.warn("Slack interaction dropped (#{error.message})") if error.is_a?(::RedmineSlack::DropError)
      InteractionViewJob.perform_later(destination, AssociationModal.message({}, 'Association unavailable.', external_id: destination))
    end
  end
end
