namespace :redmine_slack do
  desc 'Report or convert stored Slack channel names (set APPLY=1 to write)'
  task convert_channels: :environment do
    settings = Setting.plugin_redmine_slack.to_h
    token = settings['bot_token'].to_s
    raise 'Slack conversion: missing_token' if token.blank?
    client = RedmineSlack::Client.new(token)
    channels = {}
    cursor = nil
    begin
      loop do
        page = client.list_conversations(cursor)
        Array(page['channels']).each { |channel| channels[channel['name']] = channel['id'] }
        cursor = page.dig('response_metadata', 'next_cursor').to_s
        break if cursor.blank?
      end
    rescue RedmineSlack::RateLimitError => error
      raise "Slack conversion: ratelimited retry_after=#{error.wait}"
    rescue RedmineSlack::TransientError, RedmineSlack::DropError => error
      raise "Slack conversion: #{error.message}"
    end

    fields = ProjectCustomField.where(name: ['Slack Channel', 'Slack Support Channel']).index_by(&:id)
    locations = [{label: 'setting channel', value: settings['channel'], setting: true}]
    CustomValue.where(customized_type: 'Project', custom_field_id: fields.keys).includes(:customized).find_each do |value|
      project = value.customized
      next unless project
      locations << {label: "project #{project.id}/#{project.identifier} #{fields[value.custom_field_id].name}", value: value.value, record: value}
    end
    counts = Hash.new(0)
    changes = []
    report = []
    apply = ENV['APPLY'] == '1'
    locations.each do |location|
      value = location[:value].to_s
      if value.blank? || value == '-' || value.match?(/\A[CG][A-Z0-9]+\z/)
        counts[:unchanged] += 1
        report << "#{location[:label]}: #{value.inspect} => unchanged"
      elsif value.start_with?('#')
        id = channels[value[1..-1]]
        if id
          counts[:matched] += 1
          counts[:applied] += 1 if apply
          changes << [location, id]
          report << "#{location[:label]}: #{value.inspect} => #{id} #{apply ? 'applied' : 'planned'}"
        else
          counts[:unresolved] += 1
          report << "#{location[:label]}: #{value.inspect} => unresolved (not invited or renamed) unchanged"
        end
      else
        counts[:invalid] += 1
        report << "#{location[:label]}: #{value.inspect} => invalid unchanged"
      end
    end
    if apply
      ActiveRecord::Base.transaction do
        changes.each do |location, id|
          if location[:setting]
            Setting.plugin_redmine_slack = settings.merge('channel' => id)
          else
            location[:record].update!(value: id)
          end
        end
      end
    end
    report.each { |line| puts line }
    puts "Summary: matched=#{counts[:matched]} unresolved=#{counts[:unresolved]} invalid=#{counts[:invalid]} unchanged=#{counts[:unchanged]} applied=#{counts[:applied]}"
    raise 'Slack conversion: unresolved_or_invalid' if counts[:unresolved] > 0 || counts[:invalid] > 0
  end
end
