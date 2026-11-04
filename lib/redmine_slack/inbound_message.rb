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

    def unsupported_types
      @unsupported_types || []
    end

    def convert(resolver)
      rich = @blocks.select { |block| %w[rich_text table].include?(block['type']) }
      if rich.any?
        renderer = RichTextRenderer.new(@text, resolver)
        rendered = renderer.render(rich)
        @unsupported_types = (@blocks - rich).map { |block| block['type'] }.concat(renderer.unsupported).map { |type| safe_type(type) }.uniq.sort
        return rendered
      end

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

    def safe_type(type)
      type.to_s.match?(/\A[a-z0-9_]{1,40}\z/) ? type.to_s : 'unknown'
    end
    private :safe_type

    class RichTextRenderer
      attr_reader :unsupported

      def initialize(text, resolver)
        @text = text
        @resolver = resolver
        @marker = text[MARKER]
        @unsupported = []
      end

      def render(blocks)
        previous = nil
        blocks.flat_map { |block| block['type'] == 'table' ? [block] : Array(block['elements']) }.map do |element|
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

      def inline(element, remove_marker = true)
        type = element['type']
        case type
        when 'text'
          text = element['text'].to_s
          styled(remove_marker ? consume_marker(text) : text, element['style'])
        when 'link'
          url = element['url'].to_s
          destination = url.gsub('&', '&amp;').gsub('\\') { '\\\\' }
          if element['text'].to_s.empty?
            return url.match?(/[ <>\\]/) ? "[#{literal(url)}](<#{destination}>)" : "<#{destination}>"
          end
          destination = "<#{destination}>" if url.match?(/[ ()]/)
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
          @unsupported << type
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
          merged = []
          elements.each do |item|
            if item['type'] == 'text'
              item = item.merge('text' => consume_marker(item['text'].to_s))
              style = item['style'] || {}
              previous = merged.last
              previous_style = previous && (previous['style'] || {})
              same_style = previous && previous['type'] == 'text' &&
                (style['code'] && previous_style['code'] ||
                  !style['code'] && !previous_style['code'] && %w[bold italic strike].all? { |key| !!style[key] == !!previous_style[key] })
              if same_style
                previous['text'] += item['text']
                next
              end
            end
            merged << item
          end
          parts = merged.map { |item| inline(item, false) }
          parts.each_index do |index|
            if merged[index]['type'] == 'text' && parts[index].end_with?('!') && merged[index + 1]&.[]('type') == 'link' && parts[index + 1].start_with?('[')
              parts[index] = parts[index].sub(/!\z/, '\\!')
            end
          end
          parts.join.sub(/\n\z/, '')
        when 'rich_text_preformatted'
          content = elements.map { |item| item['type'] == 'text' ? consume_marker(item['text'].to_s) : (item['text'] || item['url']).to_s }.join
          fence = '`' * [content.scan(/`+/).map(&:length).max.to_i + 1, 3].max
          "#{fence}\n#{content.sub(/\n\z/, '')}\n#{fence}"
        when 'rich_text_quote'
          elements.map { |item| inline(item) }.join.sub(/\n\z/, '').split("\n", -1).map { |line| "> #{line}" }.join("\n")
        when 'rich_text_list'
          elements.each_with_index.map do |item, index|
            prefix = element['style'] == 'ordered' ? "#{element.fetch('offset', 0).to_i + index + 1}. " : '- '
            indentation = ' ' * (element.fetch('indent', 0).to_i * 4)
            lines = structure(item).split("\n", -1)
            indentation + prefix + lines.first.to_s + lines.drop(1).map { |line| line.empty? ? "\n" : "\n#{indentation}#{' ' * prefix.length}#{line}" }.join
          end.join("\n")
        when 'table'
          table(element)
        else
          @unsupported << element['type']
          ''
        end
      end

      def table(block)
        rows = Array(block['rows']).map { |row| Array(row).map { |cell| table_cell(cell) } }
        width = rows.map(&:length).max.to_i
        return '' if width.zero?

        settings = Array(block['column_settings'])
        alignments = Array.new(width) do |index|
          align = settings[index].is_a?(Hash) ? settings[index]['align'] : nil
          {'center' => ':---:', 'right' => '---:'}.fetch(align, '---')
        end
        lines = rows.map { |row| "| #{(row + [''] * (width - row.length)).join(' | ')} |" }
        lines.insert(1, "| #{alignments.join(' | ')} |")
        lines.join("\n")
      end

      def table_cell(cell)
        cell = {} unless cell.is_a?(Hash)
        text = if cell['type'] == 'rich_text'
          Array(cell['elements']).map { |element| structure(element) }.join("\n")
        else
          @unsupported << cell['type'] unless %w[raw_text raw_number].include?(cell['type']) || cell.empty?
          literal(consume_marker((cell['text'] || cell['value']).to_s))
        end
        text.strip.gsub(/\s*\n\s*/, '<br>').gsub(/(?<!\\)\|/) { '\\|' }
      end
    end
  end
end
