#  Copyright 2013 Petr Chalupa <git+actress@pitr.ch>
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

module Actress
  class Core
    include Algebrick::TypeCheck

    attr_reader :reference, :name, :world, :path, :logger

    def initialize(world, executor, parent, name, actress_class, *args, &block)
      @mailbox    = Array.new
      @processing = false
      @world      = Type! world, World
      @executor   = Type! executor, Executor
      @parent     = Type! parent, Reference, NilClass
      @name       = Type! name, String
      # Todo children
      @path       = @parent ? "#{@parent.path}.#{name}" : name
      @logger     = world.logging[path]
      @reference  = Reference.new self

      @actress_class = Child! actress_class, Abstract
      schedule_execution :create_and_set_actor, actress_class, block, *args
    end


    def __on_envelope(envelope)
      schedule_execution :execute_on_envelope, envelope
    end

    def __execute(method, *args)
      begin
        Thread.current[:__current_actress__] = reference
        send method, *args
      ensure
        Thread.current[:__current_actress__] = nil
      end
    end

    private

    def process?
      unless @mailbox.empty? || @receive_envelope_scheduled
        @receive_envelope_scheduled = true
        schedule_execution :receive_envelope
      end
    end

    def receive_envelope
      envelope = @mailbox.shift
      logger.debug "received #{envelope.message} from #{envelope.sender_path}"

      result = @actress.on_envelope envelope
      envelope.future.maybe { |f| f.resolve result }
    rescue => error
      logger.error error
      envelope.future.maybe { |f| f.fail error }
    ensure
      @receive_envelope_scheduled = false
      process?
    end

    def schedule_execution(method, *args)
      @executor.execute self, method, *args
    end

    def execute_on_envelope(envelope)
      @mailbox.push envelope
      process?
    end

    def create_and_set_actor(actress_class, block, *args)
      @actress = actress_class.new self, *args, &block
    end
  end
end
