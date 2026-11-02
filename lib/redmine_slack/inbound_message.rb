module RedmineSlack
  class InboundMessage
    MARKER = /#(\d+)\+=/

    def initialize(text)
      @text = text.to_s
    end

    def marker
      match = @text.match(MARKER)
      match && match[1].to_i
    end

    def without_marker
      @text.sub(MARKER, '')
    end

    def references
      origin = "#{Setting.protocol}://#{Setting.host_name}"
      ids = []
      @text.scan(%r{https?://[^\s<>|]+|#\d+}) do |token|
        if token.start_with?('#')
          ids << token[1..].to_i
        elsif (match = token.match(%r{\A#{Regexp.escape(origin)}/issues/(\d+)(?:[?#].*)?\z}))
          ids << match[1].to_i
        end
      end
      ids.uniq
    end

    def preview_references
      excluded = @text.scan(MARKER).flatten.map(&:to_i)
      references - excluded
    end

    def convert(resolver)
      text = without_marker.gsub(/<@([UW][A-Z0-9]+)>/) do
        member = Regexp.last_match(1)
        user = resolver.user(member)
        user ? "@#{user.login}" : resolver.display_name(member)
      end
      text = text.gsub(/<#C[A-Z0-9]+\|([^>]+)>/, '#\\1')
      text = text.gsub(/<!(here|channel|everyone)>/, '@\\1')
      text = text.gsub(%r{<(https?://[^>|]+)\|([^>]+)>}, '[\\2](\\1)')
      text = text.gsub(%r{<(https?://[^>]+)>}, '\\1')
      text = text.gsub('&lt;', '<').gsub('&gt;', '>').gsub('&amp;', '&')
      text.gsub(/(^>[^\n]*\n)(?=[^>\n])/, "\\1\n")
    end
  end
end
