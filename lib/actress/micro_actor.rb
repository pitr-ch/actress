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
  class MicroActor
    include Algebrick::TypeCheck
    include Algebrick::Matching

    Terminate = Algebrick.type { fields! future: Future }

    def initialize(logger, *args)
      initialized = Future.new

      @thread = Thread.new do
        Thread.current.abort_on_exception = true

        @logger     = logger
        @terminated = nil
        @mailbox    = Queue.new

        delayed_initialize(*args)
        initialized.resolve true

        catch(Terminate) { loop { receive } }
      end

      initialized.wait
    end

    def <<(message)
      @mailbox << message
      self
    end

    private

    # for overriding
    def delayed_initialize
    end

    # for overriding
    def on_message(message)
      raise NotImplementedError
    end

    # for overriding
    def on_terminate
      terminate!
    end

    def receive
      message = @mailbox.pop
      if Terminate === message
        if @terminated
          @terminated.tangle message.future
        else
          @terminated = message.future
          on_terminate
        end
      else
        on_message message
      end
    rescue Exception => error
      @logger.fatal "#{error.message} (#{error.class})\n#{error.backtrace * "\n"}"
    end

    def terminate!
      @terminated.resolve true
      throw Terminate
    end

    def terminated?
      @terminated && @terminated.ready?
    end
  end
end
