require 'timeout'
require 'securerandom'

module RedmineSlack
  class InteractionsController < ActionController::Base
    skip_forgery_protection

    def create
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return head :forbidden unless ::RedmineSlack::RequestSignature.valid?(request)
      raw_payload = params.require(:payload)
      return head :bad_request unless raw_payload.is_a?(String)
      payload = JSON.parse(raw_payload)
      return head :bad_request unless payload.is_a?(Hash)

      if payload['type'] == 'message_action' && payload['callback_id'] == 'redmine_slack_manage_thread'
        message = payload['message'] || {}
        metadata = {channel: payload.dig('channel', 'id'), root: message['thread_ts'].presence || message['ts'], actor: payload.dig('user', 'id')}
        settings = Setting.plugin_redmine_slack.with_indifferent_access
        remaining = 2.5 - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        return head :ok unless remaining.positive? && settings[:bot_token].present?
        Timeout.timeout(remaining) do
          ::RedmineSlack::Client.new(settings[:bot_token]).open_view(payload['trigger_id'], ::RedmineSlack::AssociationModal.input(metadata))
        end
        head :ok
      elsif payload['type'] == 'view_submission'
        submit(payload)
      else
        head :ok
      end
    rescue JSON::ParserError, ActionController::ParameterMissing
      head :bad_request
    rescue ::RedmineSlack::DropError, ::RedmineSlack::TransientError, ::RedmineSlack::RateLimitError, Timeout::Error
      head :ok
    end

    private

    def submit(payload)
      view = payload['view'] || {}
      raw_metadata = view.fetch('private_metadata', '{}')
      return head :bad_request unless raw_metadata.is_a?(String)
      metadata = JSON.parse(raw_metadata)
      return head :bad_request unless metadata.is_a?(Hash) && metadata['actor'] == payload.dig('user', 'id')
      destination = SecureRandom.uuid
      case view['callback_id']
      when 'redmine_slack_association_input'
        values = view.dig('state', 'values') || {}
        issue = values.dig('issue', 'number', 'value').to_s.strip
        metadata['issue_id'] = issue.presence
        metadata['import_existing'] = Array(values.dig('history', 'import', 'selected_options')).any? { |item| item['value'] == 'yes' }
        ::RedmineSlack::InteractionJob.perform_later('prepare', destination, metadata)
      when 'redmine_slack_association_confirm'
        ::RedmineSlack::InteractionJob.perform_later('apply', destination, metadata)
      else
        return head :ok
      end
      render json: {response_action: 'push', view: ::RedmineSlack::AssociationModal.message(metadata, 'Working…', external_id: destination)}
    end
  end
end
