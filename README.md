## Actress

_still only a gem prototype_

Actress is a library providing Actors. Behaviour is similar to Akka.

### Why?

This lib implements both actors tied to threads and actors running on thread pool. A developer can easily spawn 100_000 actors
with actress. This is not possible with Celluloid or Rubinius actors. A machine would run out of memory because those libs are 
spawning thread for each actor.

