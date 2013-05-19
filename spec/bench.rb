require 'actress'

Actress.logger.level = :info
require 'benchmark'
require 'timeout'


def timeout(timeout = 10, should_fail = false)
  ret = Timeout::timeout(timeout) do
    yield
  end
  flunk 'it should timout' if should_fail
  ret
rescue Timeout::Error => error
  raise error unless should_fail
end
actors_count = 1000
bounce_times = 100
messages     = 100
Benchmark.bmbm(20) do |b|
  #b.report("#{messages*bounce_times} rand") do
  #  done   = Queue.new
  #  actors = Array.new(actors_count) do |i|
  #    Actor::SimpleShared.new do |count|
  #      if count < bounce_times
  #        actors[rand(actors_count)] << count + 1
  #      else
  #        done << true
  #      end
  #    end
  #  end
  #
  #  messages.times { |i| actors[i] << 0 }
  #  messages.times { |i| done.pop }
  #end
  world = Actress::World.new pool_size: 10
  [Actress::Core::Threaded,
   Actress::Core::Shared2,
   Actress::Core::Shared,
  ].each do |type|
    b.report("#{type} #{messages*bounce_times}") do
      begin
        Timeout::timeout(10) do
          done   = Queue.new
          actors = Array.new(actors_count) do |i|
            world.run(name: i.to_s, type: type) do
              Actress::BlockActor.new do |count|
                #print '(%2d:%2d)' % [i, count]
                if count < bounce_times
                  actors[(i+1) % actors_count].tell count + 1
                else
                  done.push true
                end
              end
            end
          end

          messages.times { |i| actors[i % actors_count].tell 0 }
          messages.times do
            done.pop
            #print '.'
          end
          actors.each { |a| a.terminate }
        end
      rescue Timeout::Error => error
        error
      end
    end
  end

end
