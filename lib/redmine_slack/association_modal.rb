module RedmineSlack
  class AssociationModal
    def self.input(metadata)
      {
        type: 'modal', callback_id: 'redmine_slack_association_input', private_metadata: metadata.to_json,
        title: {type: 'plain_text', text: 'Link thread'}, submit: {type: 'plain_text', text: 'Continue'},
        close: {type: 'plain_text', text: 'Cancel'},
        blocks: [
          {type: 'input', block_id: 'issue', optional: true, label: {type: 'plain_text', text: 'Issue number (leave blank to unlink)'}, element: {type: 'plain_text_input', action_id: 'number'}},
          {type: 'actions', block_id: 'history', elements: [{type: 'checkboxes', action_id: 'import', options: [{text: {type: 'plain_text', text: 'Import existing messages'}, value: 'yes'}]}]}
        ]
      }
    end

    def self.message(metadata, text, confirm: false, external_id:)
      view = {type: 'modal', callback_id: confirm ? 'redmine_slack_association_confirm' : 'redmine_slack_association_working',
        private_metadata: metadata.to_json, title: {type: 'plain_text', text: 'Link thread'},
        external_id: external_id, clear_on_close: true,
        close: {type: 'plain_text', text: 'Close'}, blocks: [{type: 'section', text: {type: 'plain_text', text: text}}]}
      view[:submit] = {type: 'plain_text', text: 'Confirm'} if confirm
      view
    end
  end
end
