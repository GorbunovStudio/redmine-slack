module RedmineSlack
  class InboundMessage
    MARKER = /#(\d+)\+=/

    def initialize(text, blocks = nil)
      @text = text.to_s
      @blocks = Array(blocks)
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
      rich = @blocks.select { |block| block['type'] == 'rich_text' }
      return RichTextRenderer.new(@text, resolver).render(rich) if rich.any?

      text = without_marker.gsub(/<@([UW][A-Z0-9]+)(?:\|[^>]*)?>/) do
        member = Regexp.last_match(1)
        user = resolver.user(member)
        user ? "@#{user.login}" : resolver.display_name(member)
      end
      text = text.gsub(/<#C[A-Z0-9]+\|([^>]*)>/) { "##{Regexp.last_match(1).presence || 'channel'}" }
      text = text.gsub(/<!subteam\^[^>|]+(?:\|([^>]*))?>/) { Regexp.last_match(1).presence || '@group' }
      text = text.gsub(/<!date\^[^>|]*(?:\|([^>]*))?>/) { Regexp.last_match(1).to_s }
      text = text.gsub(/<!(here|channel|everyone)>/, '@\\1')
      text = text.gsub(%r{<([a-z][a-z0-9+.-]*:[^>|]+)\|([^>]+)>}i, '[\\2](\\1)')
      text = text.gsub(%r{<(https?://[^>]+)>}, '\\1')
      text = text.gsub(/^&gt;/, '>')
      text = text.gsub('&amp;', '&')
      text.gsub(/(^>[^\n]*\n)(?=[^>\n])/, "\\1\n")
    end

    class RichTextRenderer
      def initialize(text, resolver)
        @text = text
        @resolver = resolver
        @marker = text[MARKER]
      end

      def render(blocks)
        previous = nil
        blocks.flat_map { |block| Array(block['elements']) }.map do |element|
          type = element['type']
          separator = previous == 'rich_text_list' && type == previous ? "\n" : "\n\n"
          separator = '' unless previous
          previous = type
          separator + structure(element)
        end.join
      end

      private

      def literal(text)
        text.to_s.gsub(/[\\`*_~\[\]<>|]/) { |char| "\\#{char}" }
          .gsub(/&(?=(?:#\d+|#x[\da-f]+|[a-z][a-z\d]+);)/i) { '\\&' }
          .gsub(/^( {0,3})(\#{1,6}(?=\s|$)|[-+=](?=\s|$)|[-=]{3,}(?=\s*$))/, '\\1\\\\\\2')
          .gsub(/^( {0,3}\d+)([.)])(?=\s)/, '\\1\\\\\\2')
      end

      def styled(text, style)
        style ||= {}
        return literal(text) if text.match?(/\A\s*\z/)
        if style['code']
          fence = '`' * [text.scan(/`+/).map(&:length).max.to_i + 1, 1].max
          padding = text.start_with?('`', ' ') || text.end_with?('`', ' ') ? ' ' : ''
          return "#{fence}#{padding}#{text}#{padding}#{fence}"
        end
        leading = text[/\A\s*/]
        trailing = text[/\s*\z/]
        body = text[leading.length, text.length - leading.length - trailing.length].to_s
        body = literal(body)
        body = "**#{body}**" if style['bold'] && !body.empty?
        body = "*#{body}*" if style['italic'] && !body.empty?
        body = "~~#{body}~~" if style['strike'] && !body.empty?
        leading + body + trailing
      end

      def inline(element)
        type = element['type']
        case type
        when 'text'
          styled(consume_marker(element['text'].to_s), element['style'])
        when 'link'
          url = element['url'].to_s
          if element['text'].to_s.empty?
            return url.match?(/[ <>]/) ? "[#{literal(url)}](<#{url}>)" : "<#{url}>"
          end
          destination = url.match?(/[ ()]/) ? "<#{url}>" : url
          "[#{styled(element['text'], element['style'])}](#{destination})"
        when 'user'
          user = @resolver.user(element['user_id'])
          literal(user ? "@#{user.login}" : @resolver.display_name(element['user_id']))
        when 'channel', 'usergroup'
          id = Regexp.escape(element[type == 'channel' ? 'channel_id' : 'usergroup_id'].to_s)
          token = type == 'channel' ? /<#(#{id})\|([^>]*)>/ : /<!subteam\^(#{id})\|([^>]*)>/
          name = @text.match(token)&.[](2).to_s
          literal(name.empty? ? (type == 'channel' ? '#channel' : '@group') : (type == 'channel' ? "##{name}" : name))
        when 'broadcast'
          literal("@#{element['range']}")
        when 'emoji'
          literal(element['unicode'].present? ? element['unicode'].split('-').map { |code| code.to_i(16) }.pack('U*') : ":#{element['name']}:")
        when 'date'
          literal(element['fallback'])
        else
          literal(element['text'] || element['url'])
        end
      end

      def consume_marker(text)
        if @marker && text.include?(@marker)
          text = text.sub(@marker, '')
          @marker = nil
        end
        text
      end

      def structure(element)
        elements = Array(element['elements'])
        case element['type']
        when 'rich_text_section'
          elements.map { |item| inline(item) }.join.sub(/\n\z/, '')
        when 'rich_text_preformatted'
          content = elements.map { |item| item['type'] == 'text' ? consume_marker(item['text'].to_s) : (item['text'] || item['url']).to_s }.join
          fence = '`' * [content.scan(/`+/).map(&:length).max.to_i + 1, 3].max
          "#{fence}\n#{content.sub(/\n\z/, '')}\n#{fence}"
        when 'rich_text_quote'
          elements.map { |item| inline(item) }.join.sub(/\n\z/, '').split("\n", -1).map { |line| "> #{line}" }.join("\n")
        when 'rich_text_list'
          elements.each_with_index.map do |item, index|
            prefix = element['style'] == 'ordered' ? "#{element.fetch('offset', 0).to_i + index + 1}. " : '- '
            (' ' * (element.fetch('indent', 0).to_i * 4)) + prefix + structure(item)
          end.join("\n")
        else
          ''
        end
      end
    end
  end
end
