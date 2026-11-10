module RedmineSlack
  class EventsController < ActionController::Base
    skip_forgery_protection

    def create
      return head :forbidden unless ::RedmineSlack::RequestSignature.valid?(request)

      payload = JSON.parse(request.raw_post)
      return head :bad_request unless payload.is_a?(Hash)
      case payload['type']
      when 'url_verification'
        render plain: payload['challenge'].to_s
      when 'event_callback'
        ::RedmineSlack::EventJob.perform_later(payload['event'])
        head :ok
      else
        head :ok
      end
    rescue JSON::ParserError
      head :bad_request
    end
  end
end
