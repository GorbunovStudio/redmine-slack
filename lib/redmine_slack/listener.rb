require 'httpclient'

class SlackListener
    include ERB::Util  
    include GravatarHelper::PublicMethods

    ISSUE_STATUS_ASSIGNED = 2
    ISSUE_STATUS_CLOSED   = 5
    ISSUE_STATUS_REVIEW   = 8
    ISSUE_STATUS_TESTING  = 7
    ISSUE_STATUS_FEEDBACK = 4
    ISSUE_STATUS_ACCEPTED = 9

    ISSUE_PRIORITY_NORMAL = 4
    ISSUE_PRIORITY_HIGH   = 5
    ISSUE_PRIORITY_URGENT = 6
    ISSUE_PRIORITY_IMMEDIATELY = 7

    ISSUE_HIGH_PRIORITIES = [
        SlackListener::ISSUE_PRIORITY_HIGH, 
        SlackListener::ISSUE_PRIORITY_URGENT, 
        SlackListener::ISSUE_PRIORITY_IMMEDIATELY
    ]

    MANAGER_USER = 3
    TESTER_USER  = 6

    PROGRESS_EVENT_TASK_CLOSED             = 'task_closed'
    PROGRESS_EVENT_STORY_CLAIMED           = 'story_claimed'
    PROGRESS_EVENT_STORY_READY_FOR_REVIEW  = 'story_ready_for_reivew'
    PROGRESS_EVENT_STORY_PASSED_THE_REVIEW = 'story_passed_the_reivew'
    PROGRESS_EVENT_STORY_PASSED_TESTING    = 'story_passed_testing'
    PROGRESS_EVENT_STORY_ACCEPTED          = 'story_accepted'

    @silent_update        = false
    @isReturn             = false
    @previous_assigned_to = nil
    @previous_status_id   = nil
    @previous_priority_id = nil
    @previous_returns_count = 0    

    def controller_issues_new_after_save(context={})
        issue = context[:issue]

        return unless SlackListener::ISSUE_HIGH_PRIORITIES.include?(issue.priority.id) #No creation notifications for now

        channel = channel_for_project issue.project
        return unless channel

        attachment = prepare_issue_description(issue)
        msg = '<!channel> important issue was created!'
        msg += "\n\n<#{object_url issue}|#{escape issue}>"
        speak msg, channel, [attachment]

        return

        msg = "[#{escape issue.project}] #{escape issue.author} created <#{object_url issue}|#{escape issue}>#{mentions issue.description}"

        attachment = {}
        attachment[:text] = escape issue.description if issue.description
        attachment[:fields] = [{
            :title => I18n.t("field_status"),
            :value => escape(issue.status.to_s),
            :short => true
        }, {
            :title => I18n.t("field_priority"),
            :value => escape(issue.priority.to_s),
            :short => true
        }, {
            :title => I18n.t("field_assigned_to"),
            :value => escape(issue.assigned_to.to_s),
            :short => true
        }]

        attachment[:fields] << {
            :title => I18n.t("field_watcher"),
            :value => escape(issue.watcher_users.join(', ')),
            :short => true
        } if Setting.plugin_redmine_slack[:display_watchers] == 'yes'

        speak msg, channel, [attachment]
    end  

    def prepare_issue_update(context={})
        issue = context[:issue]
        @previous_assigned_to = User.find_by(id: issue.assigned_to_id_was)
        @previous_status_id   = issue.status_id_was
        @previous_priority_id = issue.priority_id_was
        @previous_returns_count = get_returns_count(issue)

        journal = context[:journal]

        isReturnField = get_isReturnField(issue)        

        @isReturn = false
        if !isReturnField.nil? && isReturnField.value.to_i == 1
            @isReturn = true
            isReturnField.value = 0
            incReturnsField(issue)
        end
        
        @silent_update = false
        if journal && !journal.notes.blank? && journal.notes.start_with?("[silent-update]")
            @silent_update = true
            journal.notes.sub!(/^\[silent-update\]/, '')
        end
    end

    def notify_issue_update(context={})
        issue = context[:issue]
        journal = context[:journal]
        return unless journal && journal.user

        if (
            is_client(journal.user, issue.project) || 
            (!issue.assigned_to.nil? && is_client(issue.assigned_to, issue.project)) ||
            (!@previous_assigned_to.nil? && is_client(@previous_assigned_to, issue.project))
        )             
            channel = support_channel_for_project(issue.project)
        else 
            channel = channel_for_project(issue.project)
        end
        
        return unless channel and slack_settings[:post_updates] == '1'

        msg         = ""
        attachments = []
        icon_emoji  = nil

        progress_event = get_progress_event(issue, journal)

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_ACCEPTED 
            channel = channel_for_project(issue.project)
        end

        if progress_event
            msg, attachment, icon_emoji = prepare_progress_message(issue, journal, progress_event)
        end

        if msg == ""
            msg, attachment, icon_emoji, reviewerPM = prepare_return_message(issue, journal)

            if !reviewerPM.blank? 
                speak reviewerPM[:text], reviewerPM[:channel], reviewerPM[:attachments]
            end
        end

        if msg == ""
            msg, attachment, icon_emoji = prepare_assigned_change_message(issue, journal)
        end        

        if !attachment.blank?
            attachments.push(attachment)
        end

        msg, attachment = prepare_details_change_message(issue, journal, msg)
        if !attachment.blank?
            attachments.push(attachment)
        end
        
        if msg != ""
            speak msg, channel, attachments, icon_emoji
        end


        msg, channel, image_ids = prepare_comment_message(issue, journal, channel)
        if msg != ""
            speak msg, channel, [], nil, image_ids
        end
        
        msg, attachment = prepare_priority_change_message(issue, journal)
        if !attachment.blank?
            speak msg, channel, [attachment]
        end


        if progress_event && progress_event == SlackListener::PROGRESS_EVENT_STORY_READY_FOR_REVIEW
            # Rails.logger.warn("Preparing review list")
            executor      = get_executor(issue)

            if !executor.nil?
                executor_mention = executor

                if can_review_code(executor, issue.project)
                    msg = build_review_list(executor)

                    if !msg.blank?
                        speak msg, executor_mention, [{}]
                    end
                end

                msg = build_assigned_list(executor)
                if !msg.blank?
                    speak msg, executor_mention, [{}]
                end
            end
        end
    end

    def model_changeset_scan_commit_for_issue_ids_pre_issue_update(context={})
        issue = context[:issue]
        journal = issue.current_journal
        changeset = context[:changeset]

        channel = channel_for_project issue.project
        return unless channel and issue.save

        repository = changeset.repository

        revision_url = Rails.application.routes.url_for(
            :controller => 'repositories',
            :action => 'revision',
            :id => repository.project,
            :repository_id => repository.identifier_param,
            :rev => changeset.revision,
            :host => Setting.host_name,
            :protocol => Setting.protocol
        )

        attachment = {}
        attachment[:text] = I18n.t(:text_status_changed_by_changeset, locale: Setting.default_language, value: "<#{revision_url}|#{escape changeset.comments}>")
        attachment[:fields] = journal.details.map { |d| detail_to_field d }.compact

        msg = "#{escape journal.user} updated <#{object_url issue}|#{escape issue}>"
        speak msg, channel, [attachment]
    end

    def speak(msg, channel, attachments=[], icon_emoji=nil, image_attachment_ids=[])
        return unless delivery_enabled?
        settings = slack_settings
        return if settings[:bot_token].blank? || channel.blank?
        destination = if channel.is_a?(User)
            {'kind' => 'user', 'user_id' => channel.id}
        elsif channel.to_s.match?(/\A[CG][A-Z0-9]+\z/)
            {'kind' => 'channel', 'id' => channel}
        end
        return unless destination
        envelope = {'destination' => destination, 'text_parts' => msg.is_a?(Array) ? msg : [msg]}
        envelope['username'] = settings[:username] if settings[:username]
        envelope['attachments'] = attachments if !attachments.blank?
        envelope['image_attachment_ids'] = image_attachment_ids if image_attachment_ids.present?
        icon = settings[:icon]
        if icon.present?
            if icon.start_with? ':'
                envelope['icon_emoji'] = icon
            else
                envelope['icon_url'] = icon
            end
        end
        envelope.delete('icon_url') if icon_emoji
        envelope['icon_emoji'] = icon_emoji if icon_emoji
        RedmineSlack::DeliveryJob.perform_later(envelope)
    end

private
    def delivery_enabled?
        slack_settings[:delivery_enabled] == '1'
    end

    def slack_settings
        Setting.plugin_redmine_slack.with_indifferent_access
    end

    def get_avatar_url(email)
        return "https:" + gravatar_url(email, {:size => 150})
    end

    def get_progress_event(issue, journal)
        executor      = get_executor(issue)

        if !is_status_changed?(journal)             
            return false
        end

        if !is_story(issue) #&& issue.status.id != SlackListener::ISSUE_STATUS_CLOSED
            return false
        end      

        #Status changes
        if !is_story(issue) 
            if issue.status.id == SlackListener::ISSUE_STATUS_CLOSED 
                return SlackListener::PROGRESS_EVENT_TASK_CLOSED
            end
        else 
            if (!executor.nil? && executor.id == journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_ASSIGNED)
                return SlackListener::PROGRESS_EVENT_STORY_CLAIMED
            end

            if (!executor.nil? && executor.id == journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_REVIEW)
                return SlackListener::PROGRESS_EVENT_STORY_READY_FOR_REVIEW
            end

            if (!executor.nil? && executor.id != journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_TESTING)
                return SlackListener::PROGRESS_EVENT_STORY_PASSED_THE_REVIEW
            end

            if (!executor.nil? && executor.id != journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_FEEDBACK)
                return SlackListener::PROGRESS_EVENT_STORY_PASSED_TESTING
            end

            if (!executor.nil? && executor.id != journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_ACCEPTED)
                return SlackListener::PROGRESS_EVENT_STORY_ACCEPTED
            end
        end

        return false
    end

    def is_client(user, project)
        roles = user.roles_for_project(project).collect(&:id)

        return roles.include? 6 # Client representative
    end

    def can_review_code(user, project)
        roles = user.roles_for_project(project).collect(&:id)

        return roles.include? 10 # Code review
    end

    def prepare_issue_description(issue)
        attachment = {
            #:title      => escape(issue),
            #:title_link => object_url(issue),
            :text       => issue.description.nil? ? "" : escape(issue.description.delete("\r\n").truncate(230, separator: ' ')),
            :fields     => [],            
        }

        if issue.priority.id != SlackListener::ISSUE_PRIORITY_NORMAL
            attachment[:fields].push({
                :title => 'Priority',
                :value => escape(issue.priority.to_s),
                :short => true
            })
        end

        returns_count = get_returns_count(issue)
        if returns_count > 0
            attachment[:fields].push({
                :title => 'Returns count',
                :value => escape(returns_count.to_s),
                :short => true
            })
        end        

        return attachment
    end

    def prepare_progress_message(issue, journal, progress_event)
        executor      = get_executor(issue)
        executor_mention = executor.nil? ? "" : RedmineSlack::MessageTemplate.mention(executor)
        msg = ""
        attachment = {}
        icon = nil

        #Status changes
        icon_emoji = ':thumbsup_dongler:'
        
        if progress_event == SlackListener::PROGRESS_EVENT_TASK_CLOSED 
            msg = "#{escape journal.user.to_s} has finished the task :sunglasses::sunglasses::sunglasses::"
            icon = get_avatar_url(journal.user.mail)
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_CLAIMED 
            msg = "Hey guys, don't worry, #{escape journal.user.to_s} will take care of "
            icon_emoji = ':you_dongler:'
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_READY_FOR_REVIEW 
            msg = "Hey guys, #{escape journal.user.to_s} claims, that this story is ready for Review! :innocent::innocent::innocent:"
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_PASSED_THE_REVIEW 
            msg = [executor_mention, ", good job! Your story just passed the Review! :thumbsup: Let's test it a little :smirk::smirk::smirk:"]
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_PASSED_TESTING 
            msg = [executor_mention, ", great, looks like you hid your bugs thoroughly! :ok_hand:"]
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_ACCEPTED 
            msg = [executor_mention, ", fantastic!!! Your story was just accepted! :tada::tada::tada: Mission accomplished :sunglasses::sunglasses::sunglasses:"]
            icon_emoji = ':tada_dongler:'
        end

        if msg != ""  && !executor.nil?
            icon = get_avatar_url(executor.mail)
        end                
        

        if msg != "" 
            attachment = prepare_issue_description(issue)
            attachment[:color] = "good"
            
            if (issue.assigned_to != nil && issue.assigned_to.id != journal.user.id) 
                msg = Array(msg) + [' ', RedmineSlack::MessageTemplate.mention(issue.assigned_to), ", it's your turn now!"]
            end

            msg = Array(msg) + ["\n\n<#{object_url issue}|#{escape issue}>"]
        end

        if !icon.nil?
            attachment[:thumb_url] = icon
        end

        return msg, attachment, icon_emoji
    end

    def prepare_return_message(issue, journal)
        executor      = get_executor(issue)
        msg        = ""
        attachment = {}
        icon       = nil
        icon_emoji = nil
        reviewerPM = {}

        if !is_story(issue)
            return msg, attachment, icon_emoji, reviewerPM
        end

        if !is_assigned_user_changed?(journal)
            return msg, attachment, icon_emoji, reviewerPM
        end

        if issue.assigned_to == nil
            return msg, attachment, icon_emoji, reviewerPM
        end

        if executor.nil? || (executor.id != issue.assigned_to.id || issue.assigned_to.id == journal.user.id)
            return msg, attachment, icon_emoji, reviewerPM
        end

        returns_count = get_returns_count(issue)

        if !@isReturn
            return msg, attachment, icon_emoji, reviewerPM
        end
            
        msg = [RedmineSlack::MessageTemplate.mention(issue.assigned_to), " Issue was returned :cry::cry::cry: to you (by #{escape journal.user.to_s})"]
        icon = get_avatar_url(issue.assigned_to.mail)

        attachment = prepare_issue_description(issue)

        if issue.status.id == SlackListener::ISSUE_STATUS_FEEDBACK
            icon_emoji         = ':upset_dongler:'
            attachment[:color] = "danger"
                        
            reviewer    = get_reviewer(issue)

            if journal.user.id != SlackListener::MANAGER_USER
                tester      = get_tester(issue)                
                manager     = get_manager(issue)

                if !reviewer.nil?
                    msg += [' ', RedmineSlack::MessageTemplate.mention(reviewer)]
                end

                if !tester.nil?
                    msg += [' ', RedmineSlack::MessageTemplate.mention(tester)]
                end

                if !manager.nil?
                    msg += [' ', RedmineSlack::MessageTemplate.mention(manager)]
                end
            else 
                if !reviewer.nil?
                    reviewerMsg = "You may want to check comments to the issue, which you were reviewing:"
                    reviewerMsg += "\n\n<#{object_url issue}|#{escape issue}>"
                    reviewerAttachment = prepare_issue_description(issue)

                    reviewerPM = {
                        :text => reviewerMsg,
                        :attachments => [reviewerAttachment],
                        :channel => reviewer
                    }
                end
            end
        else
            icon_emoji         = ':sad_dongler:'
            attachment[:color] = "warning"
        end

        #attachment[:pretext] = msg

        if !icon.nil?
            attachment[:thumb_url] = icon
        end

        msg += ["\n\n<#{object_url issue}|#{escape issue}>"]

        return msg, attachment, icon_emoji, reviewerPM
    end

    def prepare_assigned_change_message(issue, journal)
        executor   = get_executor(issue)
        msg        = ""
        attachment = {}
        icon       = nil
        icon_emoji = nil

        if !is_story(issue)
            return msg, attachment, icon_emoji
        end

        if !is_assigned_user_changed?(journal)
            return msg, attachment, icon_emoji
        end

        if issue.assigned_to == nil
            return msg, attachment, icon_emoji
        end

        previous_owner = []
        if !@previous_assigned_to.nil? && @previous_assigned_to.id != journal.user.id
            previous_owner = [RedmineSlack::MessageTemplate.mention(@previous_assigned_to), ", "]
        end

        if (issue.assigned_to.id == journal.user.id)            
            msg  = previous_owner + ["Story was captured by #{escape issue.assigned_to.to_s}"]
            #icon = get_avatar_url(issue.assigned_to.mail)
        else
            msg  = previous_owner + ["Issue was transferred to ", RedmineSlack::MessageTemplate.mention(issue.assigned_to), " (by #{escape journal.user.to_s})"]
        end

        msg += ["\n\n<#{object_url issue}|#{escape issue}>"]

        attachment = prepare_issue_description(issue)
        #attachment[:pretext] = msg

        if !icon.nil?
            attachment[:thumb_url] = icon
        end

        return msg, attachment, ':you_dongler:'
    end

    def comment_inline_images(issue, notes)
        images = []
        select_image = lambda do |target|
            unless target.match?(/\A[a-z][a-z0-9+.-]*:/i)
                filename = CGI.unescape(target)
                attachment = Attachment.latest_attach(issue.attachments, filename)
                images << attachment if attachment && attachment.image?
            end
        end
        text = case Setting.text_formatting
        when 'common_mark'
            require 'redmine/wiki_formatting/common_mark/formatter'
            document = Commonmarker.parse(notes, options: {extension: Redmine::WikiFormatting::CommonMark::PIPELINE_CONFIG[:commonmarker_extensions]})
            offsets = [0]
            notes.each_line { |line| offsets << offsets.last + line.bytesize }
            spans = []
            document.walk do |node|
                next unless node.type == :image
                select_image.call(node.url)
                position = node.source_position
                start = offsets[position[:start_line] - 1] + position[:start_column] - 1
                finish = offsets[position[:end_line] - 1] + position[:end_column]
                spans << [start, finish]
            end
            result = notes.dup
            merged = []
            spans.sort.each do |start, finish|
                if merged.any? && start <= merged.last[1]
                    merged.last[1] = [merged.last[1], finish].max
                else
                    merged << [start, finish]
                end
            end
            merged.reverse_each do |start, finish|
                result = result.byteslice(0, start) + result.byteslice(finish..-1).to_s
            end
            result
        when 'textile'
            require 'redmine/wiki_formatting/textile/redcloth3'
            protected_or_image = /((?i:<pre\b[^>]*>.*?<\/pre\s*>|<code\b[^>]*>.*?<\/code\s*>)|@[^@\n]*@)|#{RedCloth3::IMAGE_RE}/m
            notes.gsub(protected_or_image) do
                match = Regexp.last_match
                if match[1]
                    match[1]
                else
                    select_image.call(match[5])
                    match[2]
                end
            end
        else
            notes.dup
        end
        [text, images]
    end

    def prepare_comment_message(issue, journal, channel, msg="")
        icon = nil

        if journal.private_notes? || journal.notes.blank? || @silent_update
           return msg, channel
        end


        notes, inline_images = comment_inline_images(issue, journal.notes)
        image_ids = (journal.attachments.select(&:image?) + inline_images).map(&:id).uniq
        comment, redmine_mentions = RedmineSlack::MessageTemplate.tokenize(notes)

        redmine_mentions.each do |user|
            if is_client(user, issue.project)
                channel = support_channel_for_project(issue.project)
                break
            end
        end


        comment_mentions = redmine_mentions.map(&:id)
        mention = []

        if (!issue.assigned_to.nil? && issue.assigned_to.id != journal.user.id)             
            if !comment_mentions.include? issue.assigned_to.id
                mention += [RedmineSlack::MessageTemplate.mention(issue.assigned_to), " "]
            end 
            
        end

        executor = get_executor(issue)

        if (!executor.nil? && executor.id != journal.user.id && (issue.assigned_to.nil? || issue.assigned_to.id != executor.id)) 
            if !comment_mentions.include? executor.id
                mention += [RedmineSlack::MessageTemplate.mention(executor), " "]
            end             
        end
        

        if msg == ""
            msg = "<#{object_url issue}|#{escape issue}>"
        end       

        msg = [msg, "\n\n"] + mention + ["#{escape journal.user.to_s} commented:", "\n>>>\n"] + comment

        return msg, channel, image_ids
    end

    def prepare_details_change_message(issue, journal, msg="")
        attachment = {}
        icon = nil

        if !is_story(issue)
            return msg, attachment
        end

        #Fields & comments changes
        fields = journal.details.map { |d| detail_to_field d }.compact

        if fields.blank?
           return msg, attachment 
        end

        if msg == ""
            msg = "#{escape journal.user.to_s} updated <#{object_url issue}|#{escape issue}>"

            attachment[:thumb_url] = get_avatar_url(journal.user.mail)
        end

       mention = []

        if (!issue.assigned_to.nil? && issue.assigned_to.id != journal.user.id) 
            mention += [RedmineSlack::MessageTemplate.mention(issue.assigned_to), " "]
        end

        executor      = get_executor(issue)

        if (!executor.nil? && executor.id != journal.user.id && (issue.assigned_to.nil? || issue.assigned_to.id != executor.id)) 
            mention += mention + [RedmineSlack::MessageTemplate.mention(executor), " "]
        end

        msg = mention + Array(msg)

        attachment[:fields]   = fields

        return msg, attachment
    end

    def prepare_priority_change_message(issue, journal)
        msg = ''
        attachment = {}

        if (@previous_priority_id == issue.priority_id)
            return msg, attachment
        end        

        issueWasImportant   = SlackListener::ISSUE_HIGH_PRIORITIES.include?(@previous_priority_id)
        issueIsImportantNow = SlackListener::ISSUE_HIGH_PRIORITIES.include?(issue.priority_id)
        
        if !issueWasImportant && issueIsImportantNow
            msg = '<!channel> issue priority has been raised!'
            msg += "\n\n<#{object_url issue}|#{escape issue}>"
            attachment = prepare_issue_description(issue)
        end

        return msg, attachment
    end

    def is_assigned_user_changed?(journal)
        return journal.details.any?{|item| 
            item.prop_key.to_s == "assigned_to_id"
        }
    end

    def is_status_changed?(journal)
        return journal.details.any?{|item| 
            item.prop_key.to_s == "status_id"
        }
    end

    def get_description(journal)
        return journal.details.find{|item| 
            item.prop_key.to_s == "description"
        }
    end

    def get_isReturnField(issue)
        issue.custom_field_values.each do |field|
          if field.custom_field.name == "Is return"
            return field
          end
        end

        return nil
    end

    def incReturnsField(issue)
        issue.custom_field_values.each do |field|
          if field.custom_field.name == "Returns count"
            field.value = field.value.to_i + 1
            return
          end
        end
    end

    def is_story(issue)
        return [1, 3, 4, 5].include?(issue.tracker.id)
    end

    def get_executor(issue)
        field_id = CustomField.where(:name => "Исполнитель").first.id
		value_object = issue.custom_value_for(field_id)
        value = value_object.value if !value_object.nil? 

        if !value.blank?
            value = User.find(value)
        else
            value = nil
        end
        
        return value
    end

    def get_reviewer(issue)
        field_id = CustomField.where(:name => "Ревьюер").first.id

		value_object = issue.custom_value_for(field_id)
        value = value_object.value if !value_object.nil? 

        if !value.blank?
            value = User.find(value)
        else
            value = nil
        end
        
        return value        
    end

    def get_tester(issue)
        value = SlackListener::TESTER_USER
        value = User.find(value)
        
        return value        
    end

    def get_manager(issue)
        value = SlackListener::MANAGER_USER
        value = User.find(value)
        
        return value        
    end


    def get_returns_count(issue)
        field_id = CustomField.where(:name => "Returns count").first.id
        value_object = issue.custom_value_for(field_id)
        value = 0
        value = value_object.value.to_i if !value_object.nil?

        return value        
    end

    def escape(msg)
        ::RedmineSlack::MessageTemplate.escape(msg)
    end

    def object_url(obj)
        Rails.application.routes.url_for(obj.event_url({:host => Setting.host_name, :protocol => Setting.protocol}))
    end

    def channel_for_project(proj)
        return nil if proj.blank?

        cf = ProjectCustomField.find_by_name("Slack Channel")

        val = [
            (proj.custom_field_value(cf.id) if cf),
            (channel_for_project proj.parent),
            slack_settings[:channel],
        ].find{|v| v.present?}

        if val.to_s.match?(/\A[CG][A-Z0-9]+\z/)
            val
        else
            nil
        end
    end

    def support_channel_for_project(proj)
        return nil if proj.blank?

        cf = ProjectCustomField.find_by_name("Slack Support Channel")

        val = [
            (proj.custom_field_value(cf.id) if cf),
            (support_channel_for_project proj.parent),
            (channel_for_project proj),            
        ].find{|v| v.present?}

        if val.to_s.match?(/\A[CG][A-Z0-9]+\z/)
            val
        else
            nil
        end
    end

    def detail_to_field(detail)
        if detail.property == "cf"
            return
        elsif detail.property == "attachment"
            return
        else
            key = detail.prop_key.to_s.sub("_id", "")
            title = I18n.t "field_#{key}"
        end

        short = true
        value = escape detail.value.to_s

        case key
        when "title", "subject"
            short = false
        when "description"
            short = false
            value = value.truncate(230, separator: ' ')
        when "priority"
            priority = IssuePriority.find(detail.value) rescue nil
            value = escape priority.to_s
        else
            return
        end

        value = "-" if value.blank?

        result = { :title => title, :value => value }
        result[:short] = true if short
        result
    end

    #def mentions text
    #    text  = convert_usernames_to_slack text
    #    names = extract_usernames text
    #    names.present? ? "\nTo: @" + names.map(&:downcase).join(', @') : nil
    #end

    def detail_to_field_full(detail)
        if detail.property == "cf"
            key = CustomField.find(detail.prop_key).name rescue nil
            title = key
        elsif detail.property == "attachment"
            key = "attachment"
            title = I18n.t :label_attachment
        else
            key = detail.prop_key.to_s.sub("_id", "")
            title = I18n.t "field_#{key}"
        end

        short = true
        value = escape detail.value.to_s

        case key
        when "title", "subject", "description"
            short = false
        when "tracker"
            tracker = Tracker.find(detail.value) rescue nil
            value = escape tracker.to_s
        when "project"
            project = Project.find(detail.value) rescue nil
            value = escape project.to_s
        when "status"
            status = IssueStatus.find(detail.value) rescue nil
            value = escape status.to_s
        when "priority"
            priority = IssuePriority.find(detail.value) rescue nil
            value = escape priority.to_s
        when "category"
            category = IssueCategory.find(detail.value) rescue nil
            value = escape category.to_s
        when "assigned_to"
            user = User.find(detail.value) rescue nil
            value = escape user.to_s
        when "fixed_version"
            version = Version.find(detail.value) rescue nil
            value = escape version.to_s
        when "attachment"
            attachment = Attachment.find(detail.prop_key) rescue nil
            value = "<#{object_url attachment}|#{escape attachment.filename}>" if attachment
        when "parent"
            issue = Issue.find(detail.value) rescue nil
            value = "<#{object_url issue}|#{escape issue}>" if issue
        end

        value = "-" if value.blank?

        result = { :title => title, :value => value }
        result[:short] = true if short
        result
    end

    def format_issue_for_list(issue)
        return "• #{escape issue.project.name} - <#{object_url issue}|#{escape issue.tracker.name} ##{issue.id}: #{escape issue.subject}> (#{escape issue.status.name}) [#{escape issue.priority.name}]"
    end

    def build_review_list(recipient = User.current)
        reviewList = "*The following tasks are waiting for review:*\r\n"

        issues = get_issues_for_review(recipient)
        if issues.blank? 
            return ''
        end

        issues.collect!{|issue|
            format_issue_for_list(issue)
        }

        reviewList += issues.join("\r\n")

        return reviewList
    end

    def get_issues_for_review(recipient = User.current)
        issues_for_recipient(8, recipient)
    end

    def build_assigned_list(recipient = User.current)
        assignedList = "*The following tasks are waiting for your attention:*\r\n"

        issues = get_assigned_issues(recipient)
        if issues.blank?
            return ''
        end

        issues.collect!{|issue|
            format_issue_for_list(issue)
        }

        assignedList += issues.join("\r\n")

        return assignedList
    end

    def get_assigned_issues(recipient = User.current)
        issues_for_recipient(4, recipient).first(10)
    end

    def issues_for_recipient(query_id, recipient)
        previous_user = User.current
        User.current = recipient
        IssueQuery.find(query_id).issues
    ensure
        User.current = previous_user
    end

end

class SlackHook < Redmine::Hook::Listener
    def controller_issues_new_after_save(context={})
        SlackListener.new.controller_issues_new_after_save(context)
    end

    def controller_issues_edit_before_save(context={})
        listener = SlackListener.new
        context.fetch(:issue).instance_variable_set(:@redmine_slack_listener, listener)
        listener.prepare_issue_update(context)
    end

    def controller_issues_edit_after_save(context={})
        issue = context.fetch(:issue)
        listener = issue.instance_variable_get(:@redmine_slack_listener) || SlackListener.new
        listener.notify_issue_update(context)
    ensure
        issue&.remove_instance_variable(:@redmine_slack_listener) if issue&.instance_variable_defined?(:@redmine_slack_listener)
    end

    def model_changeset_scan_commit_for_issue_ids_pre_issue_update(context={})
        SlackListener.new.model_changeset_scan_commit_for_issue_ids_pre_issue_update(context)
    end
end
