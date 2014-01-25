module Actress

  # `#future` will become resolved to `true` when ``#countdown!`` is called `count` times
  class CountDownLatch
    attr_reader :future

    def initialize(count, future)
      raise ArgumentError if count < 0
      @count  = Atomic.new count
      @future = Type! future, Future
    end

    def countdown!
      count_value = @count.update { |v| v < 0 ? v : v - 1 }
      @future.resolve true if count_value == 0
    end

    def count
      [@count.get, 0].max
    end
  end
end
