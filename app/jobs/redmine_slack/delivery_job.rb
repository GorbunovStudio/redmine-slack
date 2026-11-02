module RedmineSlack
  class DeliveryJob < ActiveJob::Base
    queue_as :slack
    self.enqueue_after_transaction_commit = false
    self.log_arguments = false

    retry_on ::RedmineSlack::TransientError do |_job, error|
      Rails.logger.warn("Slack delivery exhausted (#{error.message})")
    end

    rescue_from ::RedmineSlack::RateLimitError do |error|
      retry_job wait: error.wait
    end

    rescue_from ::RedmineSlack::DropError do |error|
      Rails.logger.warn("Slack delivery dropped (#{error.message})")
    end

    def perform(envelope)
      Setting.check_cache
      settings = Setting.plugin_redmine_slack.with_indifferent_access
      return unless settings[:delivery_enabled] == '1' && settings[:bot_token].present?

      client = ::RedmineSlack::Client.new(settings[:bot_token])
      resolver = ::RedmineSlack::MemberResolver.new(client)
      destination = envelope.fetch('destination')
      channel = if destination['kind'] == 'user'
        member = resolver.member(destination['user_id'])
        unless member
          Rails.logger.warn('Slack delivery skipped (unresolved_recipient)')
          return
        end
        resolver.dm(member)
      else
        destination['id']
      end
      return if channel.blank?
      payload = {'channel' => channel, 'text' => ::RedmineSlack::MessageTemplate.render(envelope['text_parts'], resolver), 'unfurl_links' => false, 'unfurl_media' => false}
      %w[attachments username icon_url icon_emoji].each do |key|
        payload[key] = envelope[key] if envelope.key?(key)
      end
      files = []
      Array(envelope['image_attachment_ids']).each do |id|
        attachment = Attachment.find_by(id: id)
        next unless attachment && attachment.image?
        begin
          bytes = File.binread(attachment.diskfile)
        rescue IOError, SystemCallError
          next
        end
        upload = client.upload_url(attachment.filename, bytes.bytesize)
        client.upload_file(upload.fetch('upload_url'), bytes)
        bytes = nil
        files << {id: upload.fetch('file_id')}
      end
      if files.empty?
        client.post_message(payload)
      else
        completion = {files: files, channel_id: channel, initial_comment: payload['text']}
        %w[username icon_url icon_emoji].each { |key| completion[key] = payload[key] if payload.key?(key) }
        client.complete_upload(completion)
      end
    end
  end
end
