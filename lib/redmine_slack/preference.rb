module RedmineSlack
  class Preference
    def initialize(user)
      @user = user
    end

    def []=(attribute, value)
      raise "Unsupported attribute '#{attribute}'" unless attribute == :username

      username = value.to_s.strip
      return @user.pref[:rslack_username] = username unless @user.persisted?

      # Merge into the current persisted preferences; the User row serializes
      # creation of a first preference row.
      User.transaction do
        User.lock.where(id: @user.id).pick(:id)
        held = @user.association(:preference).target
        pref = UserPreference.lock.find_by(user_id: @user.id)
        if pref
          carry_unsaved_changes(held, pref) if held&.persisted? && held.changed?
        else
          pref = @user.pref
        end
        previous = AvatarCache.member_id(pref[:rslack_username])
        pref[:rslack_username] = username
        AvatarCache.clear(pref) unless previous == AvatarCache.member_id(username)
        pref.save!
        if held&.persisted? && !held.equal?(pref)
          held.reload
        elsif !held&.equal?(pref)
          @user.association(:preference).target = pref
        end
      end
    end

    def [](attribute)
      raise "Unsupported attribute '#{attribute}'" unless attribute == :username

      @user.pref[:rslack_username].to_s.strip
    end

    private

    # Applies only what the caller changed locally onto the freshly locked record,
    # so newer persisted values are not overwritten by the caller's older copy.
    def carry_unsaved_changes(held, pref)
      held.changes_to_save.each do |name, (old, current)|
        if name == 'others'
          old ||= {}
          current ||= {}
          merged = (pref.others || {}).dup
          old.each_key { |key| merged.delete(key) unless current.key?(key) }
          current.each { |key, value| merged[key] = value unless old.key?(key) && old[key] == value }
          pref.others = merged
        else
          pref[name] = current
        end
      end
    end
  end
end
