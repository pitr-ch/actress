require 'actress'

Actress.logger.level = :info
require 'benchmark'

actors_count = 10
bounce_times = 10
messages     = 10
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
  [Actress::Core::Threaded, Actress::Core::Shared].each do |type|
    b.report("#{type} #{messages*bounce_times}") do
      done   = Queue.new
      actors = Array.new(actors_count) do |i|
        world.run(name: i.to_s, type: type) do
          Actress::BlockActor.new do |count|
            if count < bounce_times
              actors[(i+1) % actors_count].tell count + 1
            else
              done.push true
            end
          end
        end
      end

      messages.times { |i| actors[i % actors_count].tell 0 }
      messages.times { done.pop }
    end
  end

end
