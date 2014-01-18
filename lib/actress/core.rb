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
      execute { @actress = actress_class.new self, *args, &block }
    end

    def on_envelope(envelope)
      execute do
        @mailbox.push envelope
        process?
      end
    end

    private

    def process?
      unless @mailbox.empty? || @receive_envelope_scheduled
        @receive_envelope_scheduled = true
        execute { receive_envelope }
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

    def execute(future = nil, &block)
      @executor.execute reference do
        with_current_actress do
          result = block.call
          future.resolve result if future
        end
      end
      future
    end

    def with_current_actress
      Thread.current[:__current_actress__] = reference
      yield
    ensure
      Thread.current[:__current_actress__] = nil
    end
  end
end
