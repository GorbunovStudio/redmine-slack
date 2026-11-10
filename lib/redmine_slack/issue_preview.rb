module RedmineSlack
  class IssuePreview
    def initialize(settings, import_user)
      @settings = settings
      @import_user = import_user
    end

    def payload(channel, references, thread_ts = nil)
      attachments = references.filter_map do |id|
        issue = Issue.find_by(id: id)
        next unless issue && issue.visible?(@import_user)
        escape = MessageTemplate.method(:escape)
        url = "#{Setting.protocol}://#{Setting.host_name}/issues/#{issue.id}"
        {text: "<#{url}|#{escape.call(issue.tracker)} ##{issue.id}: #{escape.call(issue.subject)}>\n#{escape.call(issue.project)} — #{escape.call(issue.status)} — #{escape.call(issue.priority)}\n#{escape.call(issue.description)}"}
      end
      return if attachments.empty?

      payload = {channel: channel, text: '', attachments: attachments, unfurl_links: false, unfurl_media: false}
      payload[:thread_ts] = thread_ts if thread_ts.present?
      payload[:username] = @settings[:username] if @settings[:username]
      if @settings[:icon].present?
        payload[@settings[:icon].start_with?(':') ? :icon_emoji : :icon_url] = @settings[:icon]
      end
      payload
    end
  end
end
