# Startup and operation process description.

For understanding, familiarize yourself with shard-arch-hld.md.

## Terminology.

- Elephants are threads for heavy processing. They get tasks via their CrossTaskSlots only.
- Fronts are threads for dispatching connections and incoming data flowing through said connections.
- Indices are "children" threads of fronts. They process incoming data and reply to clients through their rings.
- Any thread can take tasks through CrossTaskSlots, but this is very rare for indices and rare for fronts.
- Indices get events through their rings (io_uring) and through their IndexInbox, which are fed by their parent
  fronts.

## Process startup.

1. Read the config, which specifies the host index, the number of fronts, the number of indexes.
2. Create an array of rings of the given length for all threads. Values are `undefined`.
3. Create an array of [IndexInbox](../src/index_inbox.zig) of the given length. Values are `undefined`.
4. Create [CrossTaskSlots](../src/cross_task_slots.zig) for carrying heavy tasks across threads.
5. Start the init-ring in this thread.
6. Create a logging file in this thread.
7. Start the threads of the fronts and the elephants. They receive the just-created ring and the logger as arguments.
8. After finishing initialization, each thread sends a certain message into this ring. When the number of such messages
   reaches fronts + elephants + indexes (yes, we expect the indexes too).
9. Bring up the server socket.
10. Distribute the socket to the fronts.

## Elephant initialization.

Initializes its machinery, writes its ring into the array of rings, pushes a message into the init-ring.

## Front initialization.

1. Initializes its machinery.
2. Writes its ring into the array of rings.
3. Initializes the IndexInbox of its indexes.
4. Starts all the threads of its indexes.
5. Replies to the init-ring on its behalf.
6. Waits in its own ring for a message with the descriptor of the input socket.
7. Receives it. Sets up multishot accept and recv tasks.
8. Writes "ready" into the init-ring.
9. Enters the input-processing loop.

## Index initialization.

1. Initializes its machinery.
2. Writes its ring into the array of rings.
3. Initializes state - this is the user data.
4. Replies to the init-ring.
5. Blocks on reads from its ring and its IndexInbox.

# Shutdown description.

## Process shutdown.

The process realizes that the application needs to be stopped.

1. It sends a shutdown demand message to the rings of the fronts and the elephants.
2. Waits for responses from ALL fronts and counts ticks once every half-second to a second. Also counts the number of
   stopped elephants.
3. If not all elephants have stopped, then wait up to N seconds (counted from the start of the shutdown, we have the
   tick counter). Report which elephants have not stopped.
3. Terminate the process.

## Elephant shutdown.

ATTENTION: The elephant logic MUST NOT corrupt data if the process was stopped forcibly.

Upon receiving a signal, we try to finish the current operation as soon as possible and, after finishing it, signal
into the init-ring.

## Front shutdown.

Upon receiving a shutdown demand we

1. Cancel the multishot-accepts.
2. Stop passing through the "create session" operations that were previously distributed in some way across the
   indexes. Only pulses and operations are passed through.
3. Send a "soft" shutdown signal into the index inboxes.
3. Start counting ticks. If the boundary of N seconds is exceeded:
    1. Cancel the multishot-recvs.
    2. Fully close all client sockets. Cooperation is needed here. Let every front close only "its own" sockets, which
       it determines by the remainder of division.
    3. Send an immediate shutdown order to the indexes that have not stopped.
    4. Wait for a response from these indexes.
4. Signal completion through the init-ring.

## Index shutdown.

Upon receiving a soft shutdown demand we keep working almost as before - the number of our own sessions does not grow,
since the fronts simply do not pass these operations to us. But once the number of our own sessions reaches zero we
send a message to the parent index and terminate the thread, after closing all "our" sockets to the mirrors first.

When an immediate/hard shutdown signal is received we close all sockets of the mirror indexes, send a shutdown
message, and close the thread.
