require 'celluloid'
require 'actress'
require 'benchmark'

# MRI
#Rehearsal ----------------------------------------------
#actress     14.860000   4.020000  18.880000 ( 17.415216)
#celluloid   42.420000   5.310000  47.730000 ( 47.235505)
#------------------------------------ total: 66.610000sec
#
#user     system      total        real
#actress     18.410000   6.070000  24.480000 ( 21.775153)
#celluloid   70.920000  10.640000  81.560000 ( 80.603684)

# JRuby
#Rehearsal ----------------------------------------------
#actress     34.780000   1.590000  36.370000 ( 11.176000)
#celluloid   30.970000  36.200000  67.170000 ( 36.841000)
#----------------------------------- total: 103.540000sec
#
#user     system      total        real
#actress     13.860000   8.030000  21.890000 (  8.145000)
#celluloid  E, [2014-01-18T21:25:48.989000 #43033] ERROR -- : Counter crashed!
#Java::JavaLang::OutOfMemoryError: unable to create new native thread

COUNT_TO      = 50
COUNTS_SIZE   = 1000
COUNTERS_SIZE = 1000

world = Actress::World.new logging:   Actress::Logging.new(
                                          Actress::Logging::StandardLogger.new(
                                              Logger.new($stderr), 2)),
                           pool_size: 10

require 'celluloid/autostart'

class Counter
  include Celluloid

  def initialize(counters, i)
    @counters = counters
    @i        = i
  end

  def counting(count, future)
    if count < COUNT_TO
      @counters[(@i+1) % @counters.size].counting count+1, future
    else
      future.resolve count
    end
  end
end

Benchmark.bmbm(10) do |b|
  b.report('actress') do
    counts = Array.new(COUNTS_SIZE) { [0, Actress::Future.new] }

    counters = Array.new(COUNTERS_SIZE) do |i|
      world.spawn(Actress::BlockActress, "counter#{i}") do |count, future|
        if count < COUNT_TO
          counters[(i+1) % COUNTERS_SIZE].tell [count+1, future]
        else
          future.resolve count
        end
      end
    end

    counts.each_with_index do |count, i|
      counters[i % COUNTERS_SIZE].tell count
    end

    counts.each do |count, future|
      raise unless future.value >= COUNT_TO
    end
  end
  b.report('celluloid') do
    counts = []
    COUNTS_SIZE.times { counts << [0, Actress::Future.new] }

    counters = []
    COUNTERS_SIZE.times do |i|
      counters << Counter.new(counters, i)
    end

    counts.each_with_index do |count, i|
      counters[i % COUNTERS_SIZE].counting *count
    end

    counts.each do |count, future|
      raise unless future.value >= COUNT_TO
    end
  end
end

