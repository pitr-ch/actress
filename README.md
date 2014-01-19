## Actress

**Actor model library.**

Provides Future and Actors. Actors are sharing Thread pool so
as many actors as you need can be spawned.
_(AFAIK This is not possible with other gems like Celluloid)._

```ruby
require 'actress'

Message = Algebrick.type do
  variants Plus     = type { fields a: Numeric, b: Numeric },
           Subtract = type { fields a: Numeric, b: Numeric }
end

class Counter < Actress::Abstract

  def on_message(message)
    Type! message, Message
    match message,
          (on ~Plus do |(a, b)|
            a + b
          end),
          (on Subtract.(~any, ~any) do |a, b|
            a - b
          end)
  end
end

world   = Actress::World.new
counter = world.spawn Counter, 'conter'

operations = [Plus[1, 2],
              Subtract[2, 1]]
results    = operations.map { |o| counter.ask o } # futures
p results.map(&:value) # => [3,1]

world.terminate
```

This is still only version 0.0.x please keep that in mind when something breaks ;)
