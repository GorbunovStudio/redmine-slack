module RedmineSlack
  module AvatarsHelperPatch
    # With Gravatar disabled, an eligible user's cached Slack picture precedes initials.
    def avatar(user, options = {})
      return super if Setting.gravatar_enabled? || !slack_avatar_user?(user)

      url = ::RedmineSlack::AvatarCache.url_for(user)
      return super unless url

      size = (options[:size] || GravatarHelper::DEFAULT_OPTIONS[:size]).to_i
      classes = ['avatar', *options[:class].to_s.split, "s#{size}"].uniq.join(' ')
      attributes = options.except(:size, :default, :rating, :ssl, :initials)
      # The cached source is the largest Slack image and core has size classes only for common sizes.
      dimensions = {width: size, height: size}
      image_tag url, dimensions.merge(attributes).merge(class: classes, alt: options.fetch(:alt, ''), title: options[:title] || user.name)
    end

    private

    # With Gravatar enabled, the cached Slack picture becomes Gravatar's custom default.
    def gravatar_avatar_tag(user, options)
      email = extract_email_from_user(user) if slack_avatar_user?(user)
      url = ::RedmineSlack::AvatarCache.url_for(user) if email.present?
      return super unless url

      options = options.dup
      options[:default] = url
      options[:class] = [GravatarHelper::DEFAULT_OPTIONS[:class], options[:class]].compact.join(' ')
      options[:title] ||= user.name
      gravatar(email.to_s.downcase, options) rescue nil
    end

    def slack_avatar_user?(user)
      user.is_a?(User) && !user.is_a?(AnonymousUser) && user.persisted?
    end
  end
end
