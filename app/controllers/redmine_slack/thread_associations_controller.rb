module RedmineSlack
  class ThreadAssociationsController < ::ApplicationController
    accept_api_auth :show, :update, :destroy
    before_action :require_login

    def show
      association = manager.show(params[:channel_id], params[:root_message_ts])
      render json: representation(association)
    end

    def update
      input = params.require(:thread_association)
      raise ActionController::ParameterMissing, :thread_association unless input.is_a?(ActionController::Parameters)
      association, created = manager.upsert(input[:channel_id], input[:root_message_ts], input[:issue_id], import_existing: input[:import_existing] == true)
      render json: representation(association), status: created ? :created : :ok
    end

    def destroy
      manager.remove(params[:channel_id], params[:root_message_ts])
      head :no_content
    end

    rescue_from AssociationManager::NotFound do
      render json: {error: 'not_found'}, status: :not_found
    end
    rescue_from AssociationManager::NotAuthorized do
      render json: {error: 'not_authorized'}, status: :forbidden
    end
    rescue_from AssociationManager::InvalidSource, ActionController::ParameterMissing do
      render json: {error: 'invalid_source'}, status: :unprocessable_entity
    end
    rescue_from AssociationManager::ImportNotReady do
      render json: {error: 'import_not_ready'}, status: :conflict
    end
    rescue_from ::RedmineSlack::DropError do
      render json: {error: 'invalid_source'}, status: :unprocessable_entity
    end
    rescue_from ::RedmineSlack::TransientError, ::RedmineSlack::RateLimitError do
      render json: {error: 'provider_unavailable'}, status: :service_unavailable
    end

    private

    def manager
      AssociationManager.new(User.current, api: true)
    end

    def representation(association)
      {thread_association: {channel_id: association.channel_id, root_message_ts: association.root_message_ts, issue_id: association.issue_id}}
    end
  end
end
