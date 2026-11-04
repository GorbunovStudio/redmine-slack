module RedmineSlack
  class RateLimitError < StandardError
    attr_reader :wait

    def initialize(wait)
      @wait = wait
      super('ratelimited')
    end
  end
end
