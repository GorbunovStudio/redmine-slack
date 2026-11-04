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
