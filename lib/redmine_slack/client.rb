require 'httpclient'
require 'json'
require 'socket'
require 'timeout'
require 'openssl'

module RedmineSlack
  class TransientError < StandardError; end
  class DropError < StandardError; end
  class IdentityMiss < StandardError; end
  class RateLimitError < StandardError
    attr_reader :wait

    def initialize(wait)
      @wait = wait
      super('ratelimited')
    end
  end

  class Client
    def initialize(token)
      @token = token
      @http = HTTPClient.new
      @http.ssl_config.cert_store.set_default_paths
      @http.connect_timeout = 5
      @http.send_timeout = 5
      @http.receive_timeout = 5
    end

    def lookup_by_email(email)
      request(:get, 'users.lookupByEmail', email: email)
    end

    def open_conversation(member_id)
      request(:post, 'conversations.open', users: member_id)
    end

    def post_message(payload)
      request(:post, 'chat.postMessage', payload)
    end

    def list_conversations(cursor = nil)
      query = {types: 'private_channel', limit: 100}
      query[:cursor] = cursor if cursor.present?
      request(:get, 'conversations.list', query)
    end

    private

    def request(method, name, data)
      headers = {'Authorization' => "Bearer #{@token}"}
      url = "https://slack.com/api/#{name}"
      response = if method == :get
        @http.get(url, data, headers)
      else
        @http.post(url, JSON.generate(data), headers.merge('Content-Type' => 'application/json'))
      end
      status = response.status.to_i
      if status == 429
        rate_limit!(response)
      end
      raise TransientError, "http_#{status}" if (500..599).cover?(status)
      raise DropError, "http_#{status}" unless (200..299).cover?(status)
      begin
        payload = JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise DropError, 'invalid_response', cause: nil
      end
      raise DropError, 'invalid_response' unless payload.is_a?(Hash)
      return payload if payload['ok'] == true
      code = payload['error'].to_s
      rate_limit!(response) if code == 'ratelimited'
      raise TransientError, code if %w[internal_error service_unavailable].include?(code)
      raise IdentityMiss, 'users_not_found' if name == 'users.lookupByEmail' && code == 'users_not_found'
      code = 'unknown_error' unless code.match?(/\A[a-z_]+\z/)
      raise DropError, code
    rescue HTTPClient::BadResponseError
      raise DropError, 'invalid_response', cause: nil
    rescue HTTPClient::TimeoutError, IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError
      raise TransientError, 'transport_error', cause: nil
    end

    def rate_limit!(response)
      headers = response.headers
      entry = headers.find { |key, _| key.to_s.downcase == 'retry-after' }
      value = Array(entry && entry.last).first.to_s
      raise TransientError, 'ratelimited' unless value.match?(/\A\d+\z/)
      raise RateLimitError, value.to_i
    end
  end
end
