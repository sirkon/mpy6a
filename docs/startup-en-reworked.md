# Startup and operation process description.

For understanding, familiarize yourself with shard-arch-hld.md.

## Terminology.

- Elephants are threads for heavy processing. They get tasks via their CrossTaskSlots only.
- Fronts are threads for dispatching connections and incoming data flowing through said connections.
- Indices are "children" threads of fronts. They process incoming data and reply to clients through their rings.
- Any thread can take tasks through CrossTaskSlots, but this is very rare for indices and rare for fronts.
- Indices get events through their rings (io_uring) and through their IndexInbox, which are fed by their parent
  fronts.

## Design principles.

Startup is a linear two-phase process:

- **Phase A — initialization.** Every thread starts, sets up its own machinery, publishes what needs to be published,
  and reports "initialized" to the main ring. No thread waits for any other thread during this phase.
- **Phase B — launch.** Once the main thread has collected all "initialized" reports, it creates the server socket and
  broadcasts a single `START_WORK(socket_fd)` message into every thread's ring. Each thread reacts to it in its own
  ring's service loop, according to its role.

There is no separate "ready" step, no per-thread handshakes, no init-ring distinct from the main ring. The main ring is
the single point of synchronization. Ordering within a thread's ring is guaranteed by io_uring, which is what makes the
single-message launch safe.

## Thread identification.

Threads are identified by a role derived from an atomic counter incremented at thread start. The counter value is the
thread's `ring_idx`: its slot in every per-thread shared array (rings and the payloads of cross-thread reports). There is no separate "thread index" term. The mapping from `ring_idx` to role is fixed by the config:

- `[0, F)` — fronts.
- `[F, F + I)` — indices.
- `[F + I, F + I + E)` — elephants.

Each thread takes its `ring_idx` from the counter with `getRingIdx` before doing anything else, and keeps the role
derived from that value on its own stack. The role is never stored in shared memory: every decision of the thread uses
its local role, and every process-side decision about a thread derives the role from its `ring_idx` with `roleOf`. The
launch order is the formula in practice, so a thread whose counter value differs from the slot it was spawned into
exits fatally.

The formula is the contract. If the formula and the actual launch order ever diverge, that is a fatal bug and the
process exits.

## Process startup.

1. Read the config, which specifies the host index, the number of fronts `F`, the number of indices `I`, and the
   number of elephants `E`.
2. Create the main ring in the main thread.
3. Create the shared array of rings (length `F + I + E`). Values are `undefined`.
4. Create the shared array of [IndexInbox](../src/index_inbox.zig) (length `I`). Values are `undefined`.
5. Create [CrossTaskSlots](../src/cross_task_slots.zig) for carrying heavy tasks across threads.
6. Create the the logger for the init thread.
7. Start all threads — fronts, indices, elephants. Each receives the init ring and the logger as arguments.
8. Each thread runs its own initialization (see below), then sends `INITIALIZED` into the main ring, then enters its
   own ring's service loop and blocks.
9. The init thread blocks on the init ring, waiting for `F + I + E` messages of type `INITIALIZED`. A timeout applies;
   if it expires, the process exits fatally and reports which roles have not reported.
10. The init thread creates the server socket.
11. The init thread broadcasts `START_WORK(socket_fd)` into every thread's ring.
12. The init thread blocks on signal handling, waiting for a shutdown demand.

## Thread initialization.

Each thread, regardless of role:

1. Creates its own ring.
2. Creates its own logger (may depend on the ring).
3. Increments the atomic counter, takes its `ring_idx` from the value and derives its role from it.
4. Writes its ring into the shared array of rings at its own slot.
5. If the thread is an index: creates its LLQ and writes it into the shared LLQ array at its own slot.
6. Sends `INITIALIZED` into the main ring.
7. Enters its own ring's service loop.

A failure at any of steps 1–6 is fatal: immediate exit with the diagnostic that is available. There is no graceful
degradation during startup.

Fronts do **not** touch the LLQ array during initialization. Elephants do not touch it either. Only fronts write to
it, and only indices read from it, and only after `START_WORK`.

## Reaction to START_WORK.

`START_WORK(socket_fd)` is delivered into each thread's ring after the init thread has collected all `INITIALIZED`
reports. The message is processed inside each thread's ring service loop.

**Front.** Takes its indices' LLQs from the shared array (the barrier guarantees they are all present), then installs
multishot accepts on `socket_fd`, then enters the input-processing loop.

**Elephant.** Ignores `socket_fd`. Enters the working loop: waiting for tasks in its CrossTaskSlots.

**Index.** Ignores `socket_fd`. Continues to block on reads from its ring and its IndexInbox. Its LLQ already exists.

A front that receives `START_WORK` more than once must not install accepts more than once. Either the main thread
guarantees single delivery, or the handler is idempotent. The design assumes the former and treats the latter as a
defensive check.

A front that finds an `undefined` LLQ slot for one of its indices exits fatally. The barrier excludes this case.
Do not write check code, do not rely on []?IndexInbox, it is an initialization sequence that establishes the
"All LLQs are valid" invariant. This is the same for rings.

# Shutdown description.

## Process shutdown.

The process realizes that the application needs to be stopped.

1. It sends a shutdown demand message to the rings of the fronts and the elephants.
2. Waits for responses from ALL fronts and counts ticks once every half-second to a second. Also counts the number of
   stopped elephants.
3. If not all elephants have stopped, then wait up to N seconds (counted from the start of the shutdown, we have the
   tick counter). Report which elephants have not stopped.
4. Terminate the process.

## Elephant shutdown.

ATTENTION: the elephant logic MUST NOT corrupt data if the process was stopped forcibly.

Upon receiving a signal, we try to finish the current operation as soon as possible and, after finishing it, signal
into the main ring.

## Front shutdown.

Upon receiving a shutdown demand we

1. Cancel the multishot-accepts.
2. Stop passing through the "create session" operations that were previously distributed in some way across the
   indices. Only pulses and operations are passed through.
3. Send a "soft" shutdown signal into the index inboxes.
4. Start counting ticks. If the boundary of N seconds is exceeded:
   1. Cancel the multishot-recvs.
   2. Fully close all client sockets. Cooperation is needed here. Let every front close only "its own" sockets, which
      it determines by the remainder of division.
   3. Send an immediate shutdown order to the indexes that have not stopped.
   4. Wait for a response from these indexes.
5. Signal completion through the main ring.

## Index shutdown.

Upon receiving a soft shutdown demand we keep working almost as before - the number of our own sessions does not grow,
since the fronts simply do not pass these operations to us. But once the number of our own sessions reaches zero we
send a message to the parent front and terminate the thread, after closing all "our" sockets to the mirrors first.

When an immediate/hard shutdown signal is received we close all sockets of the mirror indexes, send a shutdown
message, and close the thread.

# Appendix

## On the `task_idx` aka `user_data`.

`task_idx` is a name for what is called `user_data` in vanilla io_uring.
Before pushing a task into a ring's SQ we either pushes a task that requires a context into a slotter and it gives
us `task_idx` which we uses upon completion. Or we use a `task_idx` value starting from 2^63, which is guaranteed
to be above any value a slotter can return - for any case where we don't have any execution context.

Feel free to take any of these $[2^63, 2^64)$. The only convention - constants holding these task indices are defined
in ./src/task_idx_consts.zig (which may not exist at the time).

## On the resources needed for functioning.

Every non-trivial resource needed by any thread must be created within `lifetime.Controller` defined in ./src/lifetime.zig.
Working threads (i.e. any thread that is not init thread) start from a method defined in ./src/lifetime.zig, which
further calls front/index/elephant logic defined in front.zig/elephant.zig/index.zig files after a retrieved role dispatch.
