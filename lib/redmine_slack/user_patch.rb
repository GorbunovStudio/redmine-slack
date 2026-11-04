module RedmineSlack
  module UserPatch
    def rslack_preference
      @rslack_preference ||= Preference.new(self)
    end
  end
end
