module RedmineSlack
  module MessageTemplate
    def self.mention(user)
      {'redmine_user_id' => user.id, 'fallback' => user.name}
    end

    def self.tokenize(text)
      parts = []
      users = []
      offset = 0
      text.to_s.to_enum(:scan, /(?<!\w)@([a-zA-Z0-9][a-zA-Z0-9_.-]*)/).each do
        match = Regexp.last_match
        user = User.find_by_login(match[1])
        next unless user
        parts << text[offset...match.begin(0)]
        parts << mention(user)
        users << user
        offset = match.end(0)
      end
      parts << text.to_s[offset..-1]
      [parts, users.uniq(&:id)]
    end

    def self.render(parts, resolver)
      Array(parts).map do |part|
        if part.is_a?(Hash) && part.key?('redmine_user_id')
          member = resolver.member(part['redmine_user_id'])
          member ? "<@#{member}>" : part['fallback'].to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        else
          part.to_s
        end
      end.join
    end
  end
end
