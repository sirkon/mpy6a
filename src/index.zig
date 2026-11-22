//! Index thread: consensus-side worker and child of one front.
//!
//! An index owns one `IndexInbox` (its LLQ) and one io_uring ring. Phase A
//! (ring, inbox, `INITIALIZED`) is handled by `lifetime.Controller.runThread`;
//! this file owns everything after that: the service loop, routing of accepted
//! sessions and the shutdown choreography from docs/startup-en-reworked.md.

const std = @import("std");
const posix = std.posix;
const zigring = @import("zigring");
const lifetime = @import("lifetime.zig");
const config = @import("config.zig");
const idxinbox = @import("index_inbox.zig");
const messages = @import("messages.zig");
const state = @import("state.zig");
const wal = @import("wal.zig");
const cross_task = @import("cross_task.zig");
const snapshot = @import("snapshot.zig");
const cluster_transport = @import("cluster_transport.zig");

/// A message that a front pushes into an index inbox.
pub const FrontMessage = union(enum) {
    /// Hand a freshly accepted client socket to this index. The index becomes
    /// the only owner of `fd` from that point on.
    create: struct {
        fd: posix.fd_t,
    },
    /// An operation on an already established session.
    session_op: struct {},
    /// The parent front is draining: stop taking new sessions and report to
    /// the parent once this index has no sessions left.
    shutdown_soft: void,
    /// Stop now: close everything and report.
    shutdown_hard: void,
};

/// The inbound queue type shared by fronts and indexes.
pub const Inbox = idxinbox.IndexInbox(FrontMessage);

const LoopConfig = idxinbox.LoopConfig;

/// The index service loop's frame: the state the per-CQE drain, the tick pass
/// and the snapshot dispatch share. It lives in `run`'s frame; tests drive the
/// same functions with synthetic states.
const Frame = struct {
    ctrl: *lifetime.Controller,
    ring: *lifetime.RingStuff,
    front_ring: *zigring.Ring,
    logger: *lifetime.LoggerStuff,
    ring_idx: u16,
    /// The index's own number: the `index_idx` of every pair it hosts.
    index_idx: u16,
    data_sets: []state.IndexState,
    stream_io: wal.FileReadProcess.Io,
    soft_draining: bool = false,
    /// Set once the drain closed every link (§3.7). A hand-over that races the
    /// shutdown is then closed instead of greeted.
    links_closed: bool = false,
    /// The snapshot procedure's policy state.
    snap: snapshot.State = .{},

    fn host(self: *Frame) snapshot.Host {
        return .{
            .ctrl = self.ctrl,
            .ring = self.ring,
            .log = &self.logger.logger,
            .ring_idx = self.ring_idx,
            .index_idx = self.index_idx,
            .data_sets = self.data_sets,
        };
    }
};

/// Runs the index thread to completion. `role` is the role the thread derived
/// from its `ring_idx` before reporting `INITIALIZED`; the service loop ends
/// when a shutdown demand has been satisfied.
pub fn run(ctrl: *lifetime.Controller, role: lifetime.Role, logger: *lifetime.LoggerStuff) void {
    const ring = &ctrl.rings[role.index.ring_idx];
    const inbox = &ctrl.inboxes[role.index.inbox_idx];
    const front_ring = &ctrl.rings[role.index.front_idx].ring;
    const log = &logger.logger;

    log.info("index started", .{ .ring_idx = role.index.ring_idx, .inbox = role.index.inbox_idx });

    // The thread's completion dispatch: its own ring's stream window and slot
    // table, where a WAL read arms its block reads (§6).
    const stream_io = wal.FileReadProcess.Io{
        .stream = &ring.sqstream,
        .slots = &ring.slots,
    };

    // One data set per member of the replication group, indexed by host_idx;
    // the own data set sits at the configured host slot. The group is sized by
    // the WAL config, and the own slot is bounds-checked by config validation
    // (§A1), so the thread takes it as given.
    const data_sets = ctrl.allocator.alloc(state.IndexState, ctrl.cfg.wal.hosts()) catch |err| {
        log.err("index state allocation failed", .{
            .ring_idx = role.index.ring_idx,
            .err = @errorName(err),
        });
        std.process.exit(1);
    };
    defer ctrl.allocator.free(data_sets);

    var initialized: usize = 0;
    while (initialized < data_sets.len) : (initialized += 1) {
        ctrl.initIndexState(&data_sets[initialized]) catch |err| {
            log.err("index state initialization failed", .{
                .ring_idx = role.index.ring_idx,
                .err = @errorName(err),
            });
            std.process.exit(1);
        };
    }
    defer {
        for (data_sets) |*st| ctrl.deinitIndexState(st);
    }

    // The cold per-pair startup sequence (§7.1): adoption rule, registry,
    // snapshot, writer, bring-tail and replay. It runs before the service loop
    // and before any open of a pair; a failed pair is a startup fatality.
    for (0..ctrl.cfg.wal.hosts()) |host| {
        snapshot.recoverPair(ctrl, ring, log, role.index.inbox_idx, @intCast(host), &data_sets[host]) catch |err| {
            log.err("index recovery failed", .{
                .ring_idx = role.index.ring_idx,
                .host_idx = host,
                .err = @errorName(err),
            });
            std.process.exit(1);
        };
    }

    const own_state = &data_sets[ctrl.cfg.host_index];

    const cfg = LoopConfig{};

    var frame = Frame{
        .ctrl = ctrl,
        .ring = ring,
        .front_ring = front_ring,
        .logger = logger,
        .ring_idx = role.index.ring_idx,
        .index_idx = role.index.inbox_idx,
        .data_sets = data_sets,
        .stream_io = stream_io,
    };
    snapshot.armTicker(frame.host());
    dialPeers(&frame);
    frame.ring.ring.streamedSQ(&frame.ring.sqstream);

    while (true) {
        // One pending push per pass: a procedure's pushes are sequential, so a
        // single op suffices (§4).
        frame.snap.retryPending(frame.host());
        pumpRetries(&frame);

        const batch = inbox.batch(cfg.batch_k, cfg.batch_k) orelse {
            // A pending push must not park: the loop keeps passing until the
            // `MSG_RING` lands.
            if (frame.snap.pending_push != null) {
                std.atomic.spinLoopHint();
                continue;
            }
            inbox.hang(cfg);
            continue;
        };

        // The CQ is strictly drained before the inbound queue.
        while (batch.ring.popCQE()) |cqe| stepCQE(&frame, cqe);
        batch.ring.commit() catch |err| {
            log.err("index CQ commit failed", .{ .ring_idx = role.index.ring_idx, .err = @errorName(err) });
            std.process.exit(1);
        };

        // A frame the transport could not dispatch (a full send ring) is
        // retried here, once per pass, never inside the receive completion.
        drainLinks(&frame);

        // A reply armed a continuation: finish it now that the batch cursor is
        // published, and before any front task. The pump's raw `popCQE` must
        // never run inside the batch window (§5, D1).
        if (frame.snap.drainPending()) {
            drainPump(&frame);
            continue;
        }

        var stopping = false;
        while (batch.front.next()) |task| switch (task) {
            .create => |create| {
                // A stopped thread takes no front work at all: the session is
                // refused by closing its descriptor at once, the skeleton's own
                // shape. The refusal's wire form is the consensus design's.
                if (frame.snap.serve != .serving) {
                    log.warn("index refused a session: the WAL stopped this thread", .{
                        .ring_idx = role.index.ring_idx,
                        .fd = create.fd,
                        .wal_serve = @tagName(frame.snap.serve),
                    });
                    _ = std.os.linux.close(create.fd);
                    continue;
                }
                // The skeleton owns no session state yet: take ownership of the
                // descriptor, log it, and close it again.
                log.info("index received session", .{ .ring_idx = role.index.ring_idx, .fd = create.fd });
                _ = std.os.linux.close(create.fd);
            },
            .session_op => {
                // Refused before a WAL is ever reached (§3.5). A frozen window
                // denies the front exactly like a stop; only the front intake
                // is denied.
                if (frame.snap.serve != .serving) continue;
            },
            .shutdown_soft => {
                if (!frame.soft_draining) {
                    frame.soft_draining = true;
                    log.info("index soft shutdown", .{ .ring_idx = role.index.ring_idx });
                }
                if (own_state.sessions.count() == 0) {
                    stopping = true;
                    break;
                }
            },
            .shutdown_hard => {
                log.info("index hard shutdown", .{ .ring_idx = role.index.ring_idx });
                stopping = true;
                break;
            },
        };

        // Every drain path closes the links before it reports (§3.7).
        if (stopping) {
            teardownLinks(&frame);
            reportDrained(ring, front_ring, role.index.ring_idx);
            return;
        }

        // The queue entry itself carries the future due time; checking it
        // against the clock is the loop's outer logic, not the drain's.
        drainReplay(ctrl, own_state, logger, role.index.ring_idx);

        // A soft shutdown may have been requested while the last session was
        // still open; once it closes, the index is done. The replay queue does
        // not gate shutdown: its contents are dump-persistent state that
        // survives the restart.
        if (frame.soft_draining and own_state.sessions.count() == 0) {
            teardownLinks(&frame);
            reportDrained(ring, front_ring, role.index.ring_idx);
            return;
        }
    }
}

/// Steps one completion of the thread's own ring: the reserved control arms,
/// the snapshot tick and the tracked operations. Named so the bounded drain of
/// the swap (§3.4) reuses exactly this dispatch.
fn stepCQE(frame: *Frame, cqe: zigring.CQE) void {
    switch (cqe.taskIdx()) {
        // The launch broadcast is a no-op for an index: it ignores the socket
        // fd and keeps working off its ring and its inbox.
        messages.StartWorkIdx => {},
        // A payload-less wakeup: the inbox drain below delivers.
        messages.IndexWakeupTaskIdx => {},
        // A cross-task slot message, receiver-released on read exactly like the
        // elephant's arm. This is the elephant→index direction: the fd reply,
        // the abandon, the completion and the terminal reply all ride it (§4).
        messages.CrossTaskMessageIdx => {
            const slot_idx: u32 = @intCast(cqe.res);
            const task = frame.ctrl.cross_slots.at(slot_idx).*;
            frame.ctrl.cross_slots.release(slot_idx);
            // The reply's `MSG_RING` was a direct push into this ring from the
            // elephant's thread, so it moved the SQ tail past the stream
            // window's cursors. Re-capture them before the pass (and any WAL
            // flush it triggers) submits through the same window (§4).
            frame.snap.resync(frame.host());
            switch (task) {
                .PeerLink => |link| onPeerLink(frame, link),
                else => frame.snap.onReply(frame.host(), task),
            }
        },
        // The repeating snapshot ticker's own timeout completion (§1.1).
        messages.SnapshotTickIdx => frame.snap.onTick(frame.host()),
        else => {
            // A tracked operation's completion: the slot says what it was and
            // what steps it (§6). Reserved control indices and already-retired
            // slots have no context here.
            const ctx = frame.ring.slots.get(cqe.taskIdx()) orelse return;
            switch (ctx) {
                // A flush in flight: its completion reclaims the buffer and
                // advances the writer's queue — or, on a negative `res`, stops
                // the writer and the thread (§3.5).
                .wal_flush => |flush| {
                    flush.writer.flushResult(cqe);
                    // The window's completions follow both sides' frontiers:
                    // an event is durable only once the last of the two has
                    // covered it (§5).
                    frame.snap.onFlush(frame.host(), flush.writer);
                    frame.snap.onWriterFault(frame.host(), flush.writer);
                },
                // One block of a read walk: its completion delivers the records
                // and arms the next block.
                .file_read => |read| {
                    read.file_process.onCQE(frame.stream_io, cqe) catch |err| {
                        frame.logger.logger.err("wal read failed", .{
                            .ring_idx = frame.ring_idx,
                            .offset = read.offset,
                            .err = @errorName(err),
                        });
                        // A negative `res` on a WAL read is the stop's second
                        // trigger; backpressure or a refused op only stops this
                        // walk.
                        if (err == error.IO) frame.snap.onReadFault();
                    };
                },
                .greeting_send => |greet| {
                    const entry = linkEntry(frame, greet.host_idx) orelse return;
                    onGreetingSend(frame, entry, greet.epoch, cqe);
                },
                .frame_send => |send| {
                    const entry = linkEntry(frame, send.host_idx) orelse return;
                    onFrameSend(frame, entry, send.epoch, cqe);
                },
                .frame_recv => |recv| {
                    const entry = linkEntry(frame, recv.host_idx) orelse return;
                    onFrameRecv(frame, entry, recv.epoch, cqe);
                },
                .peer_close => |close| onPeerClose(frame, close.host_idx, close.epoch, cqe),
                .pulse => |pulse| {
                    const entry = linkEntry(frame, pulse.host_idx) orelse return;
                    onPulse(frame, entry, cqe);
                },
                .predicate_timeout => |deadline| {
                    const entry = linkEntry(frame, deadline.host_idx) orelse return;
                    onPredicateTimeout(frame, entry, deadline.epoch, cqe);
                },
                .keepalive_tick => |tick| {
                    const entry = linkEntry(frame, tick.host_idx) orelse return;
                    onKeepaliveTick(frame, entry, tick.epoch, cqe);
                },
                .connect => |dial| {
                    const entry = linkEntry(frame, dial.host_idx) orelse return;
                    onConnect(frame, entry, dial.epoch, cqe);
                },
                .connect_deadline => |deadline| {
                    const entry = linkEntry(frame, deadline.host_idx) orelse return;
                    onConnectDeadline(frame, entry, deadline.epoch, cqe);
                },
                .greet_send => |send| {
                    const entry = linkEntry(frame, send.host_idx) orelse return;
                    onGreetSend(frame, entry, send.epoch, cqe);
                },
                .verdict_read => |read| {
                    const entry = linkEntry(frame, read.host_idx) orelse return;
                    onVerdictRead(frame, entry, read.epoch, cqe);
                },
                .reply_deadline => |deadline| {
                    const entry = linkEntry(frame, deadline.host_idx) orelse return;
                    onReplyDeadline(frame, entry, deadline.epoch, cqe);
                },
                .retry_timer => |retry| {
                    const entry = linkEntry(frame, retry.host_idx) orelse return;
                    onRetryTimer(frame, entry, retry.epoch, cqe);
                },
                .timeout => frame.ring.slots.del(cqe.taskIdx()),
                else => {},
            }
        },
    }
}

/// The link table of this index thread, or null when the transport is dark.
fn linkTable(frame: *Frame) ?*lifetime.LinkTable {
    if (frame.ctrl.cfg.cluster == null) return null;
    if (frame.index_idx >= frame.ctrl.link_tables.len) return null;
    return &frame.ctrl.link_tables[frame.index_idx];
}

/// The installed entry for `host_idx`, or null when the link was never
/// promoted.
fn linkEntry(frame: *Frame, host_idx: u8) ?*cluster_transport.LinkEntry {
    const table = linkTable(frame) orelse return null;
    return table.get(host_idx);
}

fn closeFd(fd: posix.fd_t) void {
    if (fd >= 0) _ = std.os.linux.close(fd);
}

fn setDeadlineSpec(spec: *std.os.linux.kernel_timespec, ns: i64) void {
    const total = @max(ns, 0);
    spec.* = .{
        .sec = @intCast(@divTrunc(total, std.time.ns_per_s)),
        .nsec = @intCast(@mod(total, std.time.ns_per_s)),
    };
}

fn nextBackoff(current: u64) u64 {
    if (current >= cluster_transport.RETRY_MAX) return cluster_transport.RETRY_MAX;
    return @min(current * 2, cluster_transport.RETRY_MAX);
}

fn peerAddressText(frame: *Frame, host_idx: u8) []const u8 {
    const text = frame.ctrl.cfg.cluster.?.peers[host_idx];
    if (std.mem.eql(u8, text, "localhost")) return "127.0.0.1";
    return text;
}

/// The lower host dials every higher host once recovery is done and before the
/// service loop (§3.1, §3.6).
fn dialPeers(frame: *Frame) void {
    const cfg = frame.ctrl.cfg;
    if (cfg.cluster == null) return;
    const own: u32 = cfg.host_index;
    const hosts = cfg.wal.hosts();
    var host: u32 = own + 1;
    while (host < hosts) : (host += 1) startDial(frame, @intCast(host));
}

fn startDial(frame: *Frame, host_idx: u8) void {
    const cluster = frame.ctrl.cfg.cluster orelse return;
    const table = linkTable(frame) orelse return;
    const entry = table.acquire(host_idx, frame.index_idx) catch |err| {
        frame.logger.logger.err("peer dial entry allocation failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = host_idx,
            .err = @errorName(err),
        });
        return;
    };
    if (entry.state != .none or entry.fd >= 0) return;

    entry.epoch +%= 1;
    entry.retry_pending = false;
    entry.verdict_filled = 0;
    entry.state = .greeting;

    const fd = zigring.createTCPClientSocket(null) catch |err| {
        entry.state = .none;
        frame.logger.logger.warn("peer dial socket failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = host_idx,
            .err = @errorName(err),
        });
        armRetry(frame, entry);
        return;
    };
    entry.fd = fd;

    setDeadlineSpec(&entry.connect_deadline_spec, cluster.handshake_timeout.value());
    const deadline_idx = frame.ring.slots.add(.{ .connect_deadline = .{
        .host_idx = host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        failDial(frame, entry, @errorName(err));
        return;
    };
    entry.connect_deadline_task = deadline_idx;
    frame.ring.ring.pushTicker(deadline_idx, &entry.connect_deadline_spec, 1, .{}) catch |err| {
        frame.ring.slots.del(deadline_idx);
        entry.connect_deadline_task = null;
        failDial(frame, entry, @errorName(err));
        return;
    };

    const connect_idx = frame.ring.slots.add(.{ .connect = .{
        .host_idx = host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        failDial(frame, entry, @errorName(err));
        return;
    };
    entry.connect_task = connect_idx;
    frame.ring.ring.pushConnectIp4(
        fd,
        connect_idx,
        peerAddressText(frame, host_idx),
        cluster.peer_port,
        .{},
    ) catch |err| {
        frame.ring.slots.del(connect_idx);
        entry.connect_task = null;
        failDial(frame, entry, @errorName(err));
    };
}

fn cancelTask(frame: *Frame, task: ?u64) void {
    const target = task orelse return;
    const cancel_idx = frame.ring.slots.add(.{ .timeout = .{} }) catch return;
    frame.ring.ring.pushCancel(cancel_idx, target, .{}) catch {
        frame.ring.slots.del(cancel_idx);
    };
}

fn cancelDial(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    cancelTask(frame, entry.connect_task);
    cancelTask(frame, entry.connect_deadline_task);
    cancelTask(frame, entry.greet_task);
    cancelTask(frame, entry.verdict_task);
    cancelTask(frame, entry.verdict_deadline_task);
    entry.connect_task = null;
    entry.connect_deadline_task = null;
    entry.greet_task = null;
    entry.verdict_task = null;
    entry.verdict_deadline_task = null;
}

fn armRetry(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    if (entry.retry_task != null) return;
    const delay = entry.retry_backoff;
    setDeadlineSpec(&entry.retry_spec, @intCast(delay));

    const task_idx = frame.ring.slots.add(.{ .retry_timer = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } }) catch {
        entry.retry_pending = true;
        return;
    };
    entry.retry_task = task_idx;
    frame.ring.ring.pushTicker(task_idx, &entry.retry_spec, 1, .{}) catch |err| {
        frame.ring.slots.del(task_idx);
        entry.retry_task = null;
        entry.retry_pending = true;
        frame.logger.logger.warn("peer dial retry arm failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = entry.host_idx,
            .err = @errorName(err),
        });
        return;
    };

    entry.retry_pending = false;
    entry.retry_backoff = nextBackoff(delay);
    frame.logger.logger.warn("peer dial retry armed", .{
        .ring_idx = frame.ring_idx,
        .host_idx = entry.host_idx,
        .delay_ms = delay / std.time.ns_per_ms,
    });
}

/// Re-arms every retry whose ticker the ring refused on a previous pass.
fn pumpRetries(frame: *Frame) void {
    const table = linkTable(frame) orelse return;
    for (table.entries) |maybe| {
        const entry = maybe orelse continue;
        if (!entry.retry_pending or entry.retry_task != null) continue;
        armRetry(frame, entry);
    }
}

/// A failed dial: the descriptor is retired, the reorder state returns to zero
/// and the retry timer carries the exponential backoff (§3.6).
fn failDial(frame: *Frame, entry: *cluster_transport.LinkEntry, reason: []const u8) void {
    frame.logger.logger.warn("peer dial failed", .{
        .ring_idx = frame.ring_idx,
        .host_idx = entry.host_idx,
        .reason = reason,
    });
    cancelDial(frame, entry);
    closeEntryFd(frame, entry);
    entry.state = .none;
    entry.resetConnection();
    armRetry(frame, entry);
}

fn onConnect(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.connect_task != cqe.taskIdx()) return;
    entry.connect_task = null;
    if (entry.epoch != epoch) return;
    if (entry.state != .greeting or entry.fd < 0) return;

    cancelTask(frame, entry.connect_deadline_task);
    entry.connect_deadline_task = null;

    if (cqe.res < 0) {
        failDial(frame, entry, "connect failed");
        return;
    }

    cluster_transport.encodeGreet(.{
        .version = cluster_transport.VERSION,
        .host_idx = @intCast(frame.ctrl.cfg.host_index),
        .index_idx = frame.index_idx,
    }, &entry.greet);

    const task_idx = frame.ring.slots.add(.{ .greet_send = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        failDial(frame, entry, @errorName(err));
        return;
    };
    entry.greet_task = task_idx;
    frame.ring.ring.pushSend(entry.fd, task_idx, &entry.greet, cluster_transport.GREET_LEN, .{}) catch |err| {
        frame.ring.slots.del(task_idx);
        entry.greet_task = null;
        failDial(frame, entry, @errorName(err));
    };
}

fn onConnectDeadline(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.connect_deadline_task != cqe.taskIdx()) return;
    entry.connect_deadline_task = null;
    if (entry.epoch != epoch) return;
    if (entry.state != .greeting) return;

    cancelTask(frame, entry.connect_task);
    entry.connect_task = null;
    failDial(frame, entry, "connect deadline");
}

fn onGreetSend(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.greet_task != cqe.taskIdx()) return;
    entry.greet_task = null;
    if (entry.epoch != epoch) return;
    if (entry.state != .greeting or entry.fd < 0) return;

    if (cqe.res != cluster_transport.GREET_LEN) {
        failDial(frame, entry, "greet send failed");
        return;
    }

    const cluster = frame.ctrl.cfg.cluster.?;
    entry.verdict_filled = 0;

    const read_idx = frame.ring.slots.add(.{ .verdict_read = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        failDial(frame, entry, @errorName(err));
        return;
    };
    entry.verdict_task = read_idx;
    frame.ring.ring.pushRecv(entry.fd, read_idx, entry.reply[0..cluster_transport.REPLY_LEN], .{}) catch |err| {
        frame.ring.slots.del(read_idx);
        entry.verdict_task = null;
        failDial(frame, entry, @errorName(err));
        return;
    };

    setDeadlineSpec(&entry.verdict_deadline_spec, cluster.handshake_timeout.value());
    const deadline_idx = frame.ring.slots.add(.{ .reply_deadline = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        failDial(frame, entry, @errorName(err));
        return;
    };
    entry.verdict_deadline_task = deadline_idx;
    frame.ring.ring.pushTicker(deadline_idx, &entry.verdict_deadline_spec, 1, .{}) catch |err| {
        frame.ring.slots.del(deadline_idx);
        entry.verdict_deadline_task = null;
        failDial(frame, entry, @errorName(err));
    };
}

fn onVerdictRead(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.verdict_task != cqe.taskIdx()) return;
    entry.verdict_task = null;
    if (entry.epoch != epoch) return;
    if (entry.state != .greeting or entry.fd < 0) return;

    if (cqe.res < 0) {
        failDial(frame, entry, "verdict read failed");
        return;
    }
    if (cqe.res == 0) {
        failDial(frame, entry, "peer closed before the verdict");
        return;
    }

    entry.verdict_filled += @intCast(cqe.res);
    if (entry.verdict_filled < cluster_transport.REPLY_LEN) {
        const read_idx = frame.ring.slots.add(.{ .verdict_read = .{
            .host_idx = entry.host_idx,
            .epoch = entry.epoch,
        } }) catch |err| {
            failDial(frame, entry, @errorName(err));
            return;
        };
        entry.verdict_task = read_idx;
        frame.ring.ring.pushRecv(entry.fd, read_idx, entry.reply[entry.verdict_filled..], .{}) catch |err| {
            frame.ring.slots.del(read_idx);
            entry.verdict_task = null;
            failDial(frame, entry, @errorName(err));
        };
        return;
    }

    cancelTask(frame, entry.verdict_deadline_task);
    entry.verdict_deadline_task = null;
    onVerdictComplete(frame, entry);
}

fn onVerdictComplete(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    const cluster = frame.ctrl.cfg.cluster.?;
    const reply = cluster_transport.decodeReply(&entry.reply) catch {
        failDial(frame, entry, "verdict decode failed");
        return;
    };

    if (reply.verdict != .ok) {
        frame.logger.logger.warn("peer rejected the link", .{
            .ring_idx = frame.ring_idx,
            .host_idx = entry.host_idx,
            .verdict = @tagName(reply.verdict),
            .address = peerAddressText(frame, entry.host_idx),
            .peer_port = cluster.peer_port,
        });
        failDial(frame, entry, "peer rejected the link");
        return;
    }

    if (reply.version != cluster_transport.VERSION or
        reply.host_idx != entry.host_idx or
        reply.index_idx != frame.index_idx)
    {
        frame.logger.logger.warn("peer verdict identity mismatch", .{
            .ring_idx = frame.ring_idx,
            .host_idx = entry.host_idx,
            .version = reply.version,
            .index_idx = reply.index_idx,
        });
        failDial(frame, entry, "verdict identity mismatch");
        return;
    }

    entry.state = .up;
    entry.retry_backoff = cluster_transport.RETRY_MIN;
    entry.retry_pending = false;
    entry.resetConnection();
    armReceive(frame, entry);
    armKeepalive(frame, entry);
    frame.logger.logger.info("peer link established", .{
        .ring_idx = frame.ring_idx,
        .host_idx = entry.host_idx,
        .index_idx = entry.index_idx,
    });
}

fn onReplyDeadline(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.verdict_deadline_task != cqe.taskIdx()) return;
    entry.verdict_deadline_task = null;
    if (entry.epoch != epoch) return;
    if (entry.state != .greeting) return;

    cancelTask(frame, entry.verdict_task);
    entry.verdict_task = null;
    failDial(frame, entry, "verdict deadline");
}

fn onRetryTimer(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.retry_task != cqe.taskIdx()) return;
    entry.retry_task = null;
    if (entry.epoch != epoch) return;
    if (entry.state != .none or entry.fd >= 0) return;
    startDial(frame, entry.host_idx);
}

/// The front handed a promoted peer socket over (§3.2). The index re-validates
/// what it was told and answers with the seven-byte greeting (§3.3).
fn onPeerLink(frame: *Frame, link: @FieldType(cross_task.CrossTask, "PeerLink")) void {
    // §3.7: a hand-over that raced the drain is closed at once, never greeted,
    // so the final drain cannot install a link after every link was closed.
    if (frame.links_closed) {
        frame.logger.logger.warn("peer link refused: index drained", .{
            .ring_idx = frame.ring_idx,
            .host_idx = link.host_idx,
        });
        closeFd(link.fd);
        return;
    }
    const cfg = frame.ctrl.cfg;
    const table = linkTable(frame) orelse {
        closeFd(link.fd);
        return;
    };
    const own_host: u8 = @intCast(cfg.host_index);
    const hosts = cfg.wal.hosts();
    const host_valid = @as(u32, link.host_idx) < hosts and link.host_idx != own_host;

    if (link.version != cluster_transport.VERSION) {
        frame.logger.logger.warn("peer link version mismatch", .{
            .ring_idx = frame.ring_idx,
            .host_idx = link.host_idx,
            .version = link.version,
        });
        if (host_valid) {
            rejectLink(frame, table, link, .version_mismatch);
        } else {
            closeFd(link.fd);
        }
        return;
    }
    if (!host_valid) {
        frame.logger.logger.warn("peer link invalid host", .{
            .ring_idx = frame.ring_idx,
            .host_idx = link.host_idx,
        });
        closeFd(link.fd);
        return;
    }
    if (!link.source_ok) {
        rejectLink(frame, table, link, .peer_address_mismatch);
        return;
    }
    if (link.index_idx != frame.index_idx) {
        frame.logger.logger.warn("peer link unknown index", .{
            .ring_idx = frame.ring_idx,
            .index_idx = link.index_idx,
        });
        rejectLink(frame, table, link, .unknown_index);
        return;
    }
    if (frame.snap.serve != .serving or frame.soft_draining) {
        frame.logger.logger.warn("peer link refused: index draining", .{
            .ring_idx = frame.ring_idx,
            .host_idx = link.host_idx,
        });
        closeFd(link.fd);
        return;
    }

    acceptLink(frame, table, link);
}

/// A candidate that failed a check is answered with the failing verdict and
/// closed after that send's completion. A bad duplicate is closed the same
/// way: only a candidate that passed every check earns the switch predicate.
fn rejectLink(
    frame: *Frame,
    table: *lifetime.LinkTable,
    link: @FieldType(cross_task.CrossTask, "PeerLink"),
    verdict: cluster_transport.Verdict,
) void {
    const entry = table.acquire(link.host_idx, frame.index_idx) catch |err| {
        frame.logger.logger.err("peer link entry allocation failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = link.host_idx,
            .err = @errorName(err),
        });
        closeFd(link.fd);
        return;
    };
    if (entry.state != .none) {
        frame.logger.logger.warn("duplicate peer link rejected", .{
            .ring_idx = frame.ring_idx,
            .host_idx = link.host_idx,
        });
        closeFd(link.fd);
        return;
    }

    entry.fd = link.fd;
    entry.version = link.version;
    entry.state = .greeting;
    cluster_transport.encodeReply(.{
        .version = cluster_transport.VERSION,
        .host_idx = @intCast(frame.ctrl.cfg.host_index),
        .index_idx = frame.index_idx,
        .verdict = verdict,
    }, &entry.reply);
    armGreetingSend(frame, entry);
}

/// A candidate that passed every check is answered `ok`; the link goes `up` on
/// that send's completion. A candidate for a pair that already holds a link is
/// parked instead and handed to the switch predicate (§3.4).
fn acceptLink(frame: *Frame, table: *lifetime.LinkTable, link: @FieldType(cross_task.CrossTask, "PeerLink")) void {
    const entry = table.acquire(link.host_idx, frame.index_idx) catch |err| {
        frame.logger.logger.err("peer link entry allocation failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = link.host_idx,
            .err = @errorName(err),
        });
        closeFd(link.fd);
        return;
    };
    if (entry.state != .none) {
        parkCandidate(frame, entry, link);
        return;
    }

    entry.fd = link.fd;
    entry.version = link.version;
    entry.state = .greeting;
    cluster_transport.encodeReply(.{
        .version = cluster_transport.VERSION,
        .host_idx = @intCast(frame.ctrl.cfg.host_index),
        .index_idx = frame.index_idx,
        .verdict = .ok,
    }, &entry.reply);
    armGreetingSend(frame, entry);
}

/// Parks a duplicate that passed every check and starts the switch predicate
/// (§3.4). The candidate keeps its socket but gets no receive arm: the dialer
/// sends nothing after its greet until it reads a verdict, so a parked
/// candidate is discarded by a plain close.
fn parkCandidate(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    link: @FieldType(cross_task.CrossTask, "PeerLink"),
) void {
    if (entry.state != .up or entry.candidate_state != .none) {
        frame.logger.logger.warn("duplicate peer link rejected", .{
            .ring_idx = frame.ring_idx,
            .host_idx = link.host_idx,
            .link_state = @tagName(entry.state),
        });
        closeFd(link.fd);
        return;
    }

    entry.candidate_fd = link.fd;
    entry.candidate_version = link.version;
    entry.candidate_state = .parked;
    entry.probe_pending = true;
    // The probe tests liveness now: an acknowledgement that landed before it
    // says nothing about the link the candidate would replace.
    entry.acked = false;

    frame.logger.logger.warn("duplicate peer link parked", .{
        .ring_idx = frame.ring_idx,
        .host_idx = entry.host_idx,
        .index_idx = entry.index_idx,
    });
    probeCandidate(frame, entry);
}

/// Sends the pulse that decides the parked candidate and arms its one-shot
/// deadline (§3.4, §4.8). A push the ring refuses leaves the candidate parked
/// and retried on the next pass, never spinning the loop.
fn probeCandidate(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    if (entry.state != .up or entry.candidate_state != .parked) return;
    if (entry.predicate_task != null) return;

    sendFrame(frame, entry, cluster_transport.OP_PULSE, &.{}, null) catch |err| switch (err) {
        error.Backpressure, error.RingFull, error.NoFreeSlots, error.OutOfMemory => return,
        else => {
            killLink(frame, entry, "pulse could not be submitted");
            return;
        },
    };
    entry.probe_pending = false;

    // The clock starts when the probe is on the wire: a refused push must not
    // spend the candidate's deadline on a pulse that never went out.
    const cluster = frame.ctrl.cfg.cluster.?;
    setDeadlineSpec(&entry.predicate_spec, cluster.pulse_timeout.value());

    const task_idx = frame.ring.slots.add(.{ .predicate_timeout = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        dropCandidate(frame, entry, @errorName(err));
        return;
    };
    entry.predicate_task = task_idx;
    frame.ring.ring.pushTicker(task_idx, &entry.predicate_spec, 1, .{}) catch |err| {
        frame.ring.slots.del(task_idx);
        entry.predicate_task = null;
        dropCandidate(frame, entry, @errorName(err));
    };
}

/// Discards the candidate without a verdict: the probe could not be timed, so
/// nothing decides the switch and the established link keeps serving. The peer
/// retries the dial with the backoff in force.
fn dropCandidate(frame: *Frame, entry: *cluster_transport.LinkEntry, reason: []const u8) void {
    const fd = entry.candidate_fd;
    entry.candidate_fd = -1;
    entry.candidate_state = .none;
    entry.probe_pending = false;
    cancelTask(frame, entry.predicate_task);
    entry.predicate_task = null;

    frame.logger.logger.warn("duplicate peer link dropped", .{
        .ring_idx = frame.ring_idx,
        .host_idx = entry.host_idx,
        .reason = reason,
    });
    closeFd(fd);
}

/// The probe's acknowledgement landed: the established link is alive, so the
/// candidate is the suspicious side. It gets `host_index_squatting` and is
/// closed after that send's completion; the link is untouched (§3.4).
fn resolveProbe(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    // The acknowledgement stays set: it also satisfies the link's keepalive
    // clock, which shares the flag (§4.8).
    entry.probe_pending = false;
    cancelTask(frame, entry.predicate_task);
    entry.predicate_task = null;
    if (entry.candidate_state != .parked) return;

    const fd = entry.candidate_fd;
    entry.candidate_state = .greeting;
    cluster_transport.encodeReply(.{
        .version = cluster_transport.VERSION,
        .host_idx = @intCast(frame.ctrl.cfg.host_index),
        .index_idx = entry.index_idx,
        .verdict = .host_index_squatting,
    }, &entry.candidate_reply);

    const task_idx = frame.ring.slots.add(.{ .pulse = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        entry.candidate_fd = -1;
        entry.candidate_state = .none;
        frame.logger.logger.warn("duplicate peer link rejected", .{
            .ring_idx = frame.ring_idx,
            .host_idx = entry.host_idx,
            .err = @errorName(err),
        });
        closeFd(fd);
        return;
    };
    frame.ring.ring.pushSend(fd, task_idx, &entry.candidate_reply, cluster_transport.REPLY_LEN, .{}) catch |err| {
        frame.ring.slots.del(task_idx);
        entry.candidate_fd = -1;
        entry.candidate_state = .none;
        frame.logger.logger.warn("duplicate peer link rejected", .{
            .ring_idx = frame.ring_idx,
            .host_idx = entry.host_idx,
            .err = @errorName(err),
        });
        closeFd(fd);
        return;
    };
    entry.candidate_reply_task = task_idx;

    frame.logger.logger.warn("duplicate peer link rejected: host_index_squatting", .{
        .ring_idx = frame.ring_idx,
        .host_idx = entry.host_idx,
        .index_idx = entry.index_idx,
    });
}

/// The switch predicate's answer left: the candidate is closed after it, its
/// descriptor no longer owned by the entry.
fn onPulse(frame: *Frame, entry: *cluster_transport.LinkEntry, cqe: zigring.CQE) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.candidate_reply_task != cqe.taskIdx()) return;
    entry.candidate_reply_task = null;

    if (cqe.res != cluster_transport.REPLY_LEN) {
        frame.logger.logger.warn("duplicate peer link verdict did not leave whole", .{
            .ring_idx = frame.ring_idx,
            .host_idx = entry.host_idx,
            .sent = cqe.res,
        });
    }

    const fd = entry.candidate_fd;
    entry.candidate_fd = -1;
    entry.candidate_state = .none;
    closePeerFd(frame, entry.host_idx, entry.epoch, fd);
}

/// The predicate's clock ran out: no acknowledgement means the established
/// link is dead, and the candidate takes its place (§3.4).
fn onPredicateTimeout(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.predicate_task != cqe.taskIdx()) return;
    entry.predicate_task = null;
    if (entry.epoch != epoch) return;
    if (entry.candidate_state != .parked) return;

    // The acknowledgement may have landed in this same drain, before the tick.
    if (entry.acked) {
        resolveProbe(frame, entry);
        return;
    }
    killLink(frame, entry, "pulse not acknowledged");
}

/// Arms the repeating keepalive on a link that just went `up` (§4.8). The
/// handshake itself proved the peer alive, so the first tick has an
/// acknowledgement to spend; from then on a tick sends one pulse and the next
/// tick must find its answer. The ticker keeps its slot across ticks, so only
/// its final (canceled) completion releases it.
fn armKeepalive(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    if (entry.keepalive_task != null) return;
    const cluster = frame.ctrl.cfg.cluster orelse return;

    setDeadlineSpec(&entry.keepalive_spec, cluster.keepalive_interval.value());

    const task_idx = frame.ring.slots.add(.{ .keepalive_tick = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        frame.logger.logger.err("peer keepalive arm failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = entry.host_idx,
            .err = @errorName(err),
        });
        return;
    };
    frame.ring.ring.pushTicker(task_idx, &entry.keepalive_spec, 0, .{}) catch |err| {
        frame.ring.slots.del(task_idx);
        frame.logger.logger.err("peer keepalive arm failed", .{
            .ring_idx = frame.ring_idx,
            .host_idx = entry.host_idx,
            .err = @errorName(err),
        });
        return;
    };

    entry.keepalive_task = task_idx;
    entry.keepalive_pending = false;
    entry.acked = true;
}

/// Stops the keepalive when its link ends. The ticker's own final completion is
/// what releases the slot; clearing the field first makes a late tick
/// attributable.
fn cancelKeepalive(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    entry.keepalive_pending = false;
    const task = entry.keepalive_task orelse return;
    entry.keepalive_task = null;
    cancelTask(frame, task);
}

/// One keepalive tick: a send error or a missing acknowledgement kills the link
/// the same way any other link death does (§3.6, §4.8).
fn onKeepaliveTick(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    const final = !cqe.hasMore();
    if (final) frame.ring.slots.del(cqe.taskIdx());

    const task = entry.keepalive_task orelse return;
    if (task != cqe.taskIdx()) return;
    if (final) {
        entry.keepalive_task = null;
        return;
    }
    if (entry.epoch != epoch) return;
    if (entry.state != .up) return;

    if (!entry.acked) {
        killLink(frame, entry, "keepalive not acknowledged");
        return;
    }
    sendKeepalivePulse(frame, entry);
}

/// Sends the keepalive's pulse. The flag clears only once the frame is on the
/// ring: a refused push is retried on the next pass instead of spending the
/// peer's answer on a pulse that never left.
fn sendKeepalivePulse(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    if (entry.state != .up) return;
    sendFrame(frame, entry, cluster_transport.OP_PULSE, &.{}, null) catch |err| switch (err) {
        error.Backpressure, error.RingFull, error.NoFreeSlots, error.OutOfMemory => {
            entry.keepalive_pending = true;
            return;
        },
        else => {
            killLink(frame, entry, "keepalive pulse could not be submitted");
            return;
        },
    };
    entry.keepalive_pending = false;
    entry.acked = false;
}

/// The probe failed: the candidate replaces the established link. The old
/// socket is retired with its own close, the stream state returns to absolute
/// zero and nothing is replayed, because the old host cannot send anything
/// more (§3.4).
fn promoteCandidate(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    reason: []const u8,
) void {
    const fd = entry.candidate_fd;
    const version = entry.candidate_version;
    entry.candidate_fd = -1;
    entry.candidate_state = .none;
    entry.probe_pending = false;
    cancelTask(frame, entry.predicate_task);
    entry.predicate_task = null;

    closeEntryFd(frame, entry);
    entry.state = .none;
    entry.resetConnection();

    entry.fd = fd;
    entry.version = version;
    entry.state = .greeting;
    cluster_transport.encodeReply(.{
        .version = cluster_transport.VERSION,
        .host_idx = @intCast(frame.ctrl.cfg.host_index),
        .index_idx = entry.index_idx,
        .verdict = .ok,
    }, &entry.reply);

    frame.logger.logger.warn("peer link replaced", .{
        .ring_idx = frame.ring_idx,
        .host_idx = entry.host_idx,
        .index_idx = entry.index_idx,
        .reason = reason,
    });
    armGreetingSend(frame, entry);
}

fn armGreetingSend(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    const task_idx = frame.ring.slots.add(.{ .greeting_send = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        killLink(frame, entry, @errorName(err));
        return;
    };
    frame.ring.ring.pushSend(entry.fd, task_idx, &entry.reply, cluster_transport.REPLY_LEN, .{}) catch |err| {
        frame.ring.slots.del(task_idx);
        killLink(frame, entry, @errorName(err));
        return;
    };
    entry.greeting_task = task_idx;
}

fn onGreetingSend(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.greeting_task != cqe.taskIdx()) return;
    entry.greeting_task = null;
    if (entry.epoch != epoch) return;

    if (cqe.res != cluster_transport.REPLY_LEN) {
        killLink(frame, entry, "greeting send failed");
        return;
    }
    const reply = cluster_transport.decodeReply(&entry.reply) catch {
        killLink(frame, entry, "greeting reply decode failed");
        return;
    };
    if (reply.verdict != .ok) {
        closeEntryFd(frame, entry);
        entry.state = .none;
        entry.resetConnection();
        return;
    }

    entry.state = .up;
    entry.resetConnection();
    armReceive(frame, entry);
    armKeepalive(frame, entry);
    frame.logger.logger.info("peer link up", .{
        .ring_idx = frame.ring_idx,
        .host_idx = entry.host_idx,
        .index_idx = entry.index_idx,
    });
}

/// Arms the next receive: the header remainder, or the body remainder of the
/// one open reservation. The arm is gated by the undelivered backlog (§4.3).
fn armReceive(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    if (entry.state != .up) return;
    if (entry.recv_task != null) return;

    var dst: []u8 = undefined;
    if (entry.open_reservation != null) {
        const frame_len: usize = std.mem.readInt(u16, entry.frame_hdr[2..4], .little);
        dst = entry.frame_slot.?[entry.frame_filled..frame_len];
    } else {
        const window = frame.ctrl.cfg.cluster.?.reorder_window;
        if (entry.pushed_absolute - entry.delivered >= window) return;
        dst = entry.frame_hdr[entry.filled_hdr..4];
    }
    if (dst.len == 0) return;

    const task_idx = frame.ring.slots.add(.{ .frame_recv = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } }) catch |err| {
        killLink(frame, entry, @errorName(err));
        return;
    };
    frame.ring.ring.pushRecv(entry.fd, task_idx, dst, .{}) catch |err| {
        frame.ring.slots.del(task_idx);
        killLink(frame, entry, @errorName(err));
        return;
    };
    entry.recv_task = task_idx;
}

fn onFrameRecv(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.recv_task != cqe.taskIdx()) return;
    entry.recv_task = null;
    if (entry.epoch != epoch) return;

    if (cqe.res < 0) {
        killLink(frame, entry, "receive error");
        return;
    }
    if (cqe.res == 0) {
        killLink(frame, entry, "peer closed");
        return;
    }
    const got: usize = @intCast(cqe.res);

    if (entry.open_reservation == null) {
        entry.filled_hdr += got;
        if (entry.filled_hdr < 4) {
            armReceive(frame, entry);
            return;
        }
        onFrameHeader(frame, entry);
        return;
    }

    entry.frame_filled += got;
    const frame_len: usize = std.mem.readInt(u16, entry.frame_hdr[2..4], .little);
    if (entry.frame_filled < frame_len) {
        armReceive(frame, entry);
        return;
    }

    const abs = entry.open_reservation.?;
    entry.reorder.commit(abs, frame_len);
    entry.filled_hdr = 0;
    entry.open_reservation = null;
    entry.frame_slot = null;
    entry.frame_filled = 0;
    drainFrames(frame, entry);
    armReceive(frame, entry);
}

/// A complete four-byte prefix: validate the length, lift the sequence number
/// and reserve the slot the body lands in (§4.3).
fn onFrameHeader(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    const seq_id = std.mem.readInt(u16, entry.frame_hdr[0..2], .little);
    const frame_len: usize = std.mem.readInt(u16, entry.frame_hdr[2..4], .little);
    if (!cluster_transport.frameLenValid(frame_len)) {
        killLink(frame, entry, "frame length out of range");
        return;
    }

    const window = frame.ctrl.cfg.cluster.?.reorder_window;
    const abs = cluster_transport.lift(entry.reorder.wave, seq_id, window) orelse {
        killLink(frame, entry, "unliftable sequence number");
        return;
    };
    const slot = entry.reorder.reserve(abs) catch |err| {
        killLink(frame, entry, @errorName(err));
        return;
    };
    @memcpy(slot[0..4], entry.frame_hdr[0..]);
    entry.open_reservation = abs;
    entry.frame_slot = slot;
    entry.frame_filled = 4;
    entry.pushed_absolute = @max(entry.pushed_absolute, abs + 1);
    armReceive(frame, entry);
}

const DispatchResult = enum { consumed, retry, death };

/// Delivers every committed frame at the delivery cursor. A frame the control
/// plane cannot hold stays at the head and is retried next pass (§4.3).
fn drainFrames(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    while (true) {
        const bytes = entry.reorder.peekHeadCond(entry.delivered) orelse return;
        switch (dispatchFrame(frame, entry, bytes)) {
            .consumed => {
                entry.reorder.dropHead();
                entry.delivered += 1;
            },
            .retry => return,
            .death => {
                killLink(frame, entry, "unknown op code");
                return;
            },
        }
    }
}

fn dispatchFrame(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    bytes: []const u8,
) DispatchResult {
    const op = bytes[21];
    switch (op) {
        cluster_transport.OP_PULSE => {
            sendFrame(frame, entry, cluster_transport.OP_PULSE_ACK, &.{}, null) catch |err| switch (err) {
                error.Backpressure, error.RingFull => return .retry,
                else => return .death,
            };
            return .consumed;
        },
        cluster_transport.OP_PULSE_ACK => {
            entry.acked = true;
            return .consumed;
        },
        else => {
            if (op >= 0x10 and op <= 0x7F) return .retry;
            return .death;
        },
    }
}

/// Encodes one frame into a free send buffer and submits it. `seq_abs` advances
/// only after a successful submit, so a local `RingFull` leaves no hole (§4.2).
fn sendFrame(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    op: u8,
    payload: []const u8,
    envelope: ?cluster_transport.CommitEnvelope,
) !void {
    const seq = entry.freeSendBuffer() orelse return error.Backpressure;
    const buf = entry.sendBuffer(seq);

    const vc_host = entry.vc_cursor;
    const vc_state = frame.data_sets[vc_host].state;

    const len = try cluster_transport.encodeFrame(buf, .{
        .seq_id = @truncate(entry.seq_abs),
        .vector_clock_frame = .{ .host_idx = vc_host, .state = vc_state },
        .op_code = op,
        .op_payload = payload,
        .commit_envelope = envelope,
    });

    const task_idx = try frame.ring.slots.add(.{ .frame_send = .{
        .host_idx = entry.host_idx,
        .epoch = entry.epoch,
    } });
    frame.ring.ring.pushSend(entry.fd, task_idx, buf.ptr, len, .{}) catch |err| {
        frame.ring.slots.del(task_idx);
        return err;
    };

    entry.setSendBusy(seq, true);
    entry.send_task[seq] = task_idx;
    entry.seq_abs += 1;
    entry.vc_cursor = @intCast((@as(usize, vc_host) + 1) % frame.data_sets.len);
}

fn onFrameSend(
    frame: *Frame,
    entry: *cluster_transport.LinkEntry,
    epoch: u32,
    cqe: zigring.CQE,
) void {
    frame.ring.slots.del(cqe.taskIdx());
    if (entry.epoch != epoch) return;

    const seq = entry.findSendTask(cqe.taskIdx()) orelse return;
    entry.send_task[seq] = null;
    entry.setSendBusy(seq, false);

    const buf = entry.sendBuffer(seq);
    const len: i32 = std.mem.readInt(u16, buf[2..4], .little);
    if (cqe.res != len) {
        killLink(frame, entry, "frame send failed");
    }
}

/// Retries every link's undelivered head once per loop pass.
fn drainLinks(frame: *Frame) void {
    const table = linkTable(frame) orelse return;
    for (table.entries) |maybe| {
        const entry = maybe orelse continue;
        if (entry.state != .up) continue;
        drainFrames(frame, entry);
        if (entry.candidate_state == .parked) {
            // The probe's own progress is stepped here, once per pass, never
            // inside a completion: an acknowledgement that landed in this drain
            // resolves the predicate, and a pulse the ring refused is retried.
            if (entry.acked) {
                resolveProbe(frame, entry);
            } else if (entry.probe_pending) {
                probeCandidate(frame, entry);
            }
        }
        if (entry.keepalive_pending and entry.acked) sendKeepalivePulse(frame, entry);
        armReceive(frame, entry);
    }
}

/// Closes every link before the index reports its drain (§3.7).
///
/// `shutdown_soft` keeps the links alive until the last session is gone, so
/// this runs only once the service loop is leaving; `shutdown_hard` reaches it
/// at once. Each descriptor is retired with its own close, every timer that
/// still guarded it is canceled, and the entry returns to a dead connection.
/// The completion queue is then drained one last time, so a hand-over slot
/// that raced the shutdown is released and its descriptor closed.
fn teardownLinks(frame: *Frame) void {
    closeLinks(frame);
    drainFinalCQ(frame);
}

fn closeLinks(frame: *Frame) void {
    frame.links_closed = true;
    const table = linkTable(frame) orelse return;

    for (table.entries) |maybe| {
        const entry = maybe orelse continue;

        cancelKeepalive(frame, entry);
        cancelTask(frame, entry.predicate_task);
        entry.predicate_task = null;
        entry.probe_pending = false;
        cancelTask(frame, entry.retry_task);
        entry.retry_task = null;
        entry.retry_pending = false;
        cancelDial(frame, entry);
        cancelTask(frame, entry.candidate_reply_task);
        entry.candidate_reply_task = null;

        if (entry.candidate_fd >= 0) {
            const fd = entry.candidate_fd;
            entry.candidate_fd = -1;
            entry.candidate_state = .none;
            closePeerFd(frame, entry.host_idx, entry.epoch, fd);
        }

        closeEntryFd(frame, entry);
        entry.state = .none;
        entry.resetConnection();
    }
}

/// The final full drain (§3.7): a `PeerLink` whose completion arrived after the
/// loop's last pass is released and its descriptor closed, never greeted. A
/// stale completion is attributable by its epoch and ignored.
fn drainFinalCQ(frame: *Frame) void {
    while (frame.ring.ring.popCQE()) |cqe| stepCQE(frame, cqe);
}

/// Tears a link down: the descriptor is retired with a dedicated close, the
/// reorder buffer returns to absolute zero and the epoch advances so a late
/// completion is ignored (§3.6). A parked candidate outlives the link it was
/// probing: a dead link installs it instead (§3.4).
fn killLink(frame: *Frame, entry: *cluster_transport.LinkEntry, reason: []const u8) void {
    frame.logger.logger.warn("peer link died", .{
        .ring_idx = frame.ring_idx,
        .host_idx = entry.host_idx,
        .reason = reason,
    });
    cancelKeepalive(frame, entry);
    if (entry.candidate_state == .parked) {
        promoteCandidate(frame, entry, reason);
        return;
    }
    closeEntryFd(frame, entry);
    entry.state = .none;
    entry.resetConnection();

    // §3.6: a death arms the lower host's retry timer. The higher host never
    // dials, so it closes and waits for the lower host to come back.
    if (frame.ctrl.cfg.host_index < @as(u16, entry.host_idx)) armRetry(frame, entry);
}

fn closeEntryFd(frame: *Frame, entry: *cluster_transport.LinkEntry) void {
    const fd = entry.fd;
    entry.fd = -1;
    closePeerFd(frame, entry.host_idx, entry.epoch, fd);
}

/// Retires one descriptor with a dedicated close, so its completion is
/// attributable and never confused with a reused number.
fn closePeerFd(frame: *Frame, host_idx: u8, epoch: u32, fd: posix.fd_t) void {
    if (fd < 0) return;

    const task_idx = frame.ring.slots.add(.{ .peer_close = .{
        .host_idx = host_idx,
        .epoch = epoch,
    } }) catch {
        _ = std.os.linux.close(fd);
        return;
    };
    frame.ring.ring.pushClose(task_idx, fd, .{}) catch {
        frame.ring.slots.del(task_idx);
        _ = std.os.linux.close(fd);
    };
}

fn onPeerClose(frame: *Frame, host_idx: u8, epoch: u32, cqe: zigring.CQE) void {
    frame.ring.slots.del(cqe.taskIdx());
    frame.logger.logger.debug("peer link closed", .{
        .ring_idx = frame.ring_idx,
        .host_idx = host_idx,
        .epoch = epoch,
    });
}

/// Steps the armed continuation outside the batch window (§5, D1). A reply
/// only records the continuation; the pump is the sole reader that finishes
/// it, and it never runs while `inbox.batch` holds an uncommitted cursor.
fn drainPump(frame: *Frame) void {
    while (frame.snap.drainPending()) {
        if (frame.snap.drainQuiet()) {
            frame.snap.onDrained(frame.host());
            continue;
        }
        if (frame.ring.ring.popCQE()) |cqe| {
            stepCQE(frame, cqe);
            continue;
        }
        frame.ring.ring.park();
    }
}

/// Test helper: drain the window and any continuation a completion arms.
fn pumpWindow(frame: *Frame) void {
    while (true) {
        if (frame.snap.drainPending()) {
            drainPump(frame);
            continue;
        }
        if (frame.snap.drainQuiet()) return;
        if (frame.ring.ring.popCQE()) |cqe| {
            stepCQE(frame, cqe);
            continue;
        }
        frame.ring.ring.park();
    }
}

/// The producer contract of §6: a record handed to an index thread's write path
/// must frame into the pair's `lba`, the buffer size and flush granularity.
///
/// The check belongs at the thread's intake, where every dispatched event
/// passes, window or not; the skeleton's front message does not carry an op
/// payload yet, so the byte length arrives with the consensus channel and its
/// refusal's wire shape is that design's. The 1 MiB structural cap stays the
/// WAL's own (`RecordTooLarge`), and records still legally span `lba`-sized
/// buffers.
fn recordFits(lba: u32, op_len: usize) bool {
    return wal.framedLen(op_len) <= lba;
}

/// Drains every replay-queue head whose recorded retry time is already due.
/// The due-ness check is the caller's job; `popReplayHead` itself does no time
/// math.
fn drainReplay(
    ctrl: *lifetime.Controller,
    st: *state.IndexState,
    logger: *lifetime.LoggerStuff,
    ring_idx: u16,
) void {
    const log = &logger.logger;

    while (true) {
        const retry_time = (st.replay_queue.peekRetryTime() catch |err| {
            log.err("index replay queue peek failed", .{ .ring_idx = ring_idx, .err = @errorName(err) });
            return;
        }) orelse return;

        if (retry_time > lifetime.nowRealtimeNs()) return;

        const reactivated = ctrl.popReplayHead(st) catch |err| {
            log.err("index replay drain failed", .{ .ring_idx = ring_idx, .err = @errorName(err) });
            return;
        };
        const session = reactivated orelse return;

        log.info("session reactivated for replay", .{
            .ring_idx = ring_idx,
            .new_id = @as(u64, @truncate(session.new_id)),
        });
    }
}

/// Tells the parent front that this index has stopped. The front ignores the
/// payload and reads its own per-index bit set instead.
///
/// The only direct push left on an index ring (`designs/wal-impl.md` §6): a
/// shutdown report has no stream state of its own, and `pushMsgRing` leaves the
/// stream window's cursors alone, so the two submission paths cannot diverge
/// here. The WAL never takes this route.
fn reportDrained(ring: *lifetime.RingStuff, front_ring: *zigring.Ring, ring_idx: u16) void {
    while (true) {
        if (ring.ring.pushMsgRing(front_ring, messages.IndexDrainedIdx, ring_idx, .{})) |_| {
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
}

test "front message carries an owned descriptor" {
    const task: FrontMessage = .{ .create = .{ .fd = 5 } };
    try std.testing.expectEqual(@as(posix.fd_t, 5), task.create.fd);
}

/// The records the end-to-end test writes, each one a `create` op's payload.
///
/// One record per buffer: `framedLen(494) == 16 + 2 + 494 == 512`, so every
/// record ends on a buffer boundary and none is left in the live tail, which a
/// plain-mode close does not flush (§2: a record is durable once its buffer's
/// flush completes, and only filled buffers are flushed).
const e2e_records: usize = 6;
const e2e_op_len: usize = 494;
const e2e_tag: u128 = 0x2000;

/// The readout's sink: the record's state goes into the data set first and the
/// op is applied after — `applyIndexOp`'s contract, and the reason the sink
/// receives the state separately.
const Replay = struct {
    ctrl: *lifetime.Controller,
    st: *state.IndexState,
    applied: usize = 0,

    fn apply(ctx: ?*anyopaque, state_idx: u128, op: []const u8) anyerror!void {
        const self: *Replay = @ptrCast(@alignCast(ctx.?));
        self.st.state = state_idx;
        try self.ctrl.applyIndexOp(self.st, .{ .create = .{ .compensator = "marker", .payload = op } });
        self.applied += 1;
    }
};

/// Creates (or empties) the WAL file a snapshot would have handed over.
/// Creation itself is elephant-side (`designs/wal-impl.md` §1.1), so the test
/// stands in for it.
fn createWalFile(path: [:0]const u8) !posix.fd_t {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    return @intCast(fd_raw);
}

test "plain-mode records replay into a fresh data set after a reopen" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path[0..]},
    );
    defer testing.allocator.free(dir);

    var cfg: config.Config = .{
        .fronts = 1,
        .indexes = 1,
        .elephants = 1,
        .queue_depth = 64,
        .cross_task_slots = 8,
        .sqpoll_threads = 1,
        .ring_slots_capacity = 4096,
        .index_inbox_capacity = 8,
        .wal = .{ .plain = .{ .dir = dir, .buffers = 32, .lba = config.kib(1) } },
        .logging = .{
            .method = .{ .json = {} },
            .pool_capacity = 64,
            .pool_frame_size = config.bytes(1024),
        },
    };

    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

    // The index thread's own ring carries both the flushes and the replay's
    // block reads, so the test drives the same two submission paths the
    // service loop does.
    try ctrl.initRing(0, 1);
    defer ctrl.rings[0].deinit();
    const ring = &ctrl.rings[0];
    const stream_io = wal.FileReadProcess.Io{ .stream = &ring.sqstream, .slots = &ring.slots };

    // The elephant creates the file under the index directory the pair lives
    // in; the test stands in for it (designs/SNAPSHOTS.md §2.3).
    try ctrl.ensureIndexDir(0);
    const index_dir = try ctrl.indexDirPath(0);
    defer testing.allocator.free(index_dir);

    const path = try wal.walPath(testing.allocator, index_dir, 0, 0, e2e_tag);
    defer testing.allocator.free(path);
    const created = try createWalFile(path);
    _ = std.os.linux.close(created);

    var written: [e2e_records]u128 = undefined;
    var ops: [e2e_records][e2e_op_len]u8 = undefined;
    for (&ops, 0..) |*op, i| {
        for (op, 0..) |*byte, j| byte.* = @truncate(j *% 31 +% i *% 7 +% 1);
    }
    for (&written, 0..) |*state_idx, i| state_idx.* = e2e_tag + 1 + i;

    {
        const writer = try ctrl.walOpenWrite(0, 0, e2e_tag);
        writer.attachStream(&ring.sqstream, &ring.slots);
        for (written, 0..) |state_idx, i| try writer.write(state_idx, writer.head, &ops[i]);
        // `close` retries a parked submission and awaits the flush in flight,
        // so the file holds every record once it returns.
        try writer.close();
        try testing.expect(!writer.faulted);
    }

    var fresh: state.IndexState = undefined;
    try ctrl.initIndexState(&fresh);
    defer ctrl.deinitIndexState(&fresh);

    var reference: state.IndexState = undefined;
    try ctrl.initIndexState(&reference);
    defer ctrl.deinitIndexState(&reference);

    var replay = Replay{ .ctrl = &ctrl, .st = &fresh };
    {
        const reader = try ctrl.walOpenRead(0, 0, e2e_tag);
        defer ctrl.walCloseRead(reader);
        const process = try reader.beginRead(
            testing.allocator,
            .read_all,
            .{ .ctx = &replay, .apply = Replay.apply },
        );
        defer reader.endRead(testing.allocator, process);
        try process.drive(stream_io);
        try testing.expect(process.done);
    }
    try testing.expectEqual(e2e_records, replay.applied);

    // The reference: the same ops applied live, in the order they were written.
    for (written, 0..) |state_idx, i| {
        reference.state = state_idx;
        try ctrl.applyIndexOp(&reference, .{ .create = .{ .compensator = "marker", .payload = &ops[i] } });
    }

    try testing.expectEqual(reference.state, fresh.state);
    try testing.expectEqual(reference.sessions.count(), fresh.sessions.count());
    for (written) |state_idx| {
        const want = reference.sessions.get(state_idx) orelse return error.MissingReferenceSession;
        const got = fresh.sessions.get(state_idx) orelse return error.MissingReplayedSession;
        try testing.expectEqual(want.data.original_id, got.data.original_id);
        try testing.expectEqual(want.data.retry_count, got.data.retry_count);
        try testing.expectEqualStrings(want.data.compensator, got.data.compensator);
        try testing.expectEqualSlices(
            u8,
            want.data.data.backing[0..want.data.data.len],
            got.data.data.backing[0..got.data.data.len],
        );
    }
}

/// The config every Stage E test starts from: one front, one index, a plain
/// battery, and an explicit elephant count and snapshot block.
fn testConfig(dir: []const u8, hosts: u32, elephants: u16, snapshots: config.Snapshots) config.Config {
    return .{
        .fronts = 1,
        .indexes = 1,
        .elephants = elephants,
        .queue_depth = 64,
        .cross_task_slots = 8,
        .sqpoll_threads = 1,
        .ring_slots_capacity = 4096,
        .index_inbox_capacity = 8,
        .wal = .{ .plain = .{ .dir = dir, .buffers = 8, .lba = config.kib(1), .hosts = hosts } },
        .snapshots = snapshots,
        .logging = .{
            .method = .{ .json = {} },
            .pool_capacity = 64,
            .pool_frame_size = config.bytes(1024),
        },
    };
}

fn testFrame(
    ctrl: *lifetime.Controller,
    ring_idx: u16,
    logger: *lifetime.LoggerStuff,
    data_sets: []state.IndexState,
) Frame {
    return .{
        .ctrl = ctrl,
        .ring = &ctrl.rings[ring_idx],
        .front_ring = &ctrl.rings[0].ring,
        .logger = logger,
        .ring_idx = ring_idx,
        .index_idx = 0,
        .data_sets = data_sets,
        .stream_io = .{
            .stream = &ctrl.rings[ring_idx].sqstream,
            .slots = &ctrl.rings[ring_idx].slots,
        },
    };
}

fn dropTestLogger(ctrl: *lifetime.Controller, logger: *lifetime.LoggerStuff) void {
    logger.deinit(ctrl.allocator);
    ctrl.allocator.destroy(logger);
}

/// Spins until the ring yields one completion or the deadline passes.
fn cqeBefore(ring: *zigring.Ring, deadline_ns: u64) ?zigring.CQE {
    while (zigring.monotonicNs() < deadline_ns) {
        if (ring.popCQE()) |cqe| return cqe;
        std.atomic.spinLoopHint();
    }
    return null;
}

test "the cross-task arm releases the slot it read" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 0, .{});
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();

    // Ring 0 sends, ring 1 is the index's own.
    try ctrl.initRing(0, 1);
    defer ctrl.rings[0].deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var frame = testFrame(&ctrl, 1, logger, &.{});

    // A synthetic in-flight procedure: `SnapshotDone` is its terminal reply.
    var job: lifetime.SnapshotJob = undefined;
    frame.snap.procedure = &job;

    const full = ctrl.cross_slots.freeCount();
    const slot_idx = try ctrl.cross_slots.acquire();
    ctrl.cross_slots.at(slot_idx).* = .{ .SnapshotDone = .{} };

    try ctrl.rings[0].ring.pushMsgRingFd(
        ctrl.rings[1].ring.fd,
        messages.CrossTaskMessageIdx,
        slot_idx,
        .{},
    );

    const cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.CrossTaskCqeTimeout;
    try testing.expectEqual(messages.CrossTaskMessageIdx, cqe.taskIdx());
    try testing.expectEqual(slot_idx, @as(u32, @intCast(cqe.res)));

    stepCQE(&frame, cqe);

    // The arm released the slot on read and the terminal reply cleared the
    // procedure.
    try testing.expectEqual(full, ctrl.cross_slots.freeCount());
    try testing.expect(frame.snap.procedure == null);
}

test "the repeating ticker produces SnapshotTickIdx completions" {
    const testing = std.testing;

    var ring: zigring.Ring = undefined;
    try ring.init(64, null);
    defer ring.deinit();

    var spec = std.os.linux.kernel_timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    try ring.pushTicker(messages.SnapshotTickIdx, &spec, 0, .{});

    var fired: u32 = 0;
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (fired < 2) {
        const cqe = cqeBefore(&ring, deadline) orelse return error.SnapshotTickTimeout;
        if (cqe.taskIdx() != messages.SnapshotTickIdx) continue;
        try testing.expectEqual(std.os.linux.E.TIME, cqe.errno());
        try testing.expect(cqe.hasMore());
        fired += 1;
    }

    const cancel_idx: u64 = 0x1000;
    try ring.pushCancel(cancel_idx, messages.SnapshotTickIdx, .{});

    var saw_cancel = false;
    var saw_end = false;
    const cancel_deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (!saw_cancel or !saw_end) {
        const cqe = cqeBefore(&ring, cancel_deadline) orelse return error.SnapshotCancelTimeout;
        if (cqe.taskIdx() == cancel_idx) {
            if (cqe.res == 0) {
                saw_cancel = true;
            } else {
                // A shot raced the request's re-arm and the cancel matched
                // nothing: ask again. The ticker is unlimited, so it is still
                // there to find.
                try ring.pushCancel(cancel_idx, messages.SnapshotTickIdx, .{});
            }
        } else if (cqe.taskIdx() == messages.SnapshotTickIdx) {
            // The final completion of the canceled ticker.
            try testing.expect(!cqe.hasMore());
            try testing.expectEqual(std.os.linux.E.CANCELED, cqe.errno());
            saw_end = true;
        }
    }
}

test "the drain routes the snapshot tick to the tick pass" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 0, .{});
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var frame = testFrame(&ctrl, 1, logger, &.{});
    // A stopped thread makes the pass end after its skip guard: the counter is
    // the routing spy.
    frame.snap.serve = .stopped;

    stepCQE(&frame, .{ .user_data = messages.SnapshotTickIdx, .res = 0, .flags = 0 });

    try testing.expectEqual(@as(u32, 1), frame.snap.ticks);
    try testing.expect(frame.snap.procedure == null);
}

/// Opens the pair at `host` with the given tag and writes `records` one after
/// another, creating the WAL file the elephant normally creates.
fn testWriter(
    ctrl: *lifetime.Controller,
    host: u8,
    tag: u128,
    records: u32,
    record_len: usize,
) !void {
    const dir = try ctrl.indexDirPath(0);
    defer ctrl.allocator.free(dir);
    const path = try wal.walPath(ctrl.allocator, dir, host, 0, tag);
    defer ctrl.allocator.free(path);

    const created = try createWalFile(path);
    _ = std.os.linux.close(created);

    const writer = try ctrl.walOpenWrite(host, 0, tag);
    const data = try ctrl.allocator.alloc(u8, record_len);
    defer ctrl.allocator.free(data);
    @memset(data, 0x5a);

    var i: u32 = 0;
    while (i < records) : (i += 1) {
        try writer.write(tag + 1 + i, tag + i, data);
    }
}

/// Creates the WAL file the elephant would have created and opens its writer:
/// the window's old side, registered on its pair.
fn openPairWriter(ctrl: *lifetime.Controller, host: u8, index: u16, tag: u128) !*wal.WalWriteFile {
    try ctrl.ensureIndexDir(index);
    const dir = try ctrl.indexDirPath(index);
    defer ctrl.allocator.free(dir);
    const path = try wal.walPath(ctrl.allocator, dir, host, index, tag);
    defer ctrl.allocator.free(path);
    const fd = try createWalFile(path);
    _ = std.os.linux.close(fd);
    return ctrl.walOpenWrite(host, index, tag);
}

/// The window's new side: the file created the elephant's way, then adopted on
/// temp ring `k`, chained from the clone state.
fn adoptWindowWriter(
    ctrl: *lifetime.Controller,
    host: u8,
    index: u16,
    k: u32,
    tag: u128,
    clone_state: u128,
) !*wal.WalWriteFile {
    try ctrl.ensureIndexDir(index);
    const dir = try ctrl.indexDirPath(index);
    defer ctrl.allocator.free(dir);
    const path = try wal.walPath(ctrl.allocator, dir, host, index, tag);
    defer ctrl.allocator.free(path);
    const fd = try createWalFile(path);
    return ctrl.walAdoptWrite(host, index, k, clone_state, fd);
}

/// Tears a synthetic window down without an elephant: the new writer is the
/// caller's, the pair's writer stays registered.
fn dropWindow(frame: *Frame) void {
    if (frame.snap.window) |*window| {
        _ = std.os.linux.close(window.new.fd);
        frame.ctrl.allocator.destroy(window.new);
        window.pending.deinit(frame.ctrl.allocator);
        frame.snap.window = null;
    }
}

/// Releases a test's job the way its terminal elephant would.
fn dropTestJob(ctrl: *lifetime.Controller, job: *lifetime.SnapshotJob) void {
    ctrl.snapshot_slots.at(job.k).status = .idle;
    ctrl.snapshot_slots.release(job.k);
    if (job.fd != -1) _ = std.os.linux.close(job.fd);
    if (job.old_fd != -1) _ = std.os.linux.close(job.old_fd);
    ctrl.releaseSnapshotJob(job);
}

/// The pair's control line, as the restart rule reads it.
fn pairControlLine(ctrl: *lifetime.Controller) *wal.BufferHeader {
    return wal.controlLineOf(
        ctrl.wal_battery.?[0..ctrl.wal_area_stride],
        ctrl.cfg.wal.buffers(),
        ctrl.cfg.wal.lba(),
    );
}

/// The bytes of one file, read back whole.
fn readFileBytes(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);

    const size = try wal.fileSize(fd);
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);

    var got: usize = 0;
    while (got < bytes.len) {
        const res = std.os.linux.pread(fd, bytes[got..].ptr, bytes.len - got, @intCast(got));
        const read_errno = std.os.linux.errno(res);
        if (read_errno != .SUCCESS) return std.posix.unexpectedErrno(read_errno);
        if (res == 0) break;
        got += res;
    }
    return bytes[0..got];
}

test "the bounded drain waits for both writers' in-flight flushes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);
    old.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);
    new.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&frame);
        ctrl.snapshot_slots.release(k);
    }

    var op: [1006]u8 = undefined;
    @memset(&op, 0x22);
    try frame.snap.window.?.write(0x101, &op);
    try testing.expect(!frame.snap.window.?.quiet());
    try testing.expect(old.flush_in_flight and new.flush_in_flight);

    pumpWindow(&frame);

    // Both completions were stepped through the ordinary dispatch; the writers
    // are quiet and the events they carried are complete.
    try testing.expect(frame.snap.window.?.quiet());
    try testing.expect(!old.flush_in_flight and !old.flush_pending);
    try testing.expect(!new.flush_in_flight and !new.flush_pending);
    try testing.expectEqual(@as(u64, 1), old.flushed_upto);
    try testing.expectEqual(@as(u64, 1), new.flushed_upto);
    try testing.expectEqual(@as(usize, 0), frame.snap.window.?.pending.items.len);
}

test "the completion pass drains, copies, rewires, clears, revives and closes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);

    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    defer dropTestJob(&ctrl, job);
    job.fd = -1;
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.procedure = job;
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    // A window event: both sides' synchronous sinks make it durable at once.
    var op: [494]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 13 +% 5);
    try frame.snap.window.?.write(0x101, &op);

    // The pair area's arrays before the copy: what the swap must reproduce.
    const buffers = cfg.wal.buffers();
    const arrays_len = buffers * cfg.wal.lba() + buffers * @sizeOf(wal.BufferHeader);
    const temp_start = wal.tempAreaIdx(k, ctrl.wal_pairs) * ctrl.wal_area_stride;
    const expected = try testing.allocator.dupe(
        u8,
        ctrl.wal_battery.?[temp_start..][0..arrays_len],
    );
    defer testing.allocator.free(expected);

    // An old-side fault had frozen the front before the completion arrived.
    old.faulted = true;
    frame.snap.serve = .frozen;
    const old_fd = old.fd;

    frame.snap.onReply(frame.host(), .{ .SnapshotDumped = .{} });
    pumpWindow(&frame);

    // The pair area is temp ring k's data and header arrays, byte for byte.
    const pair_bytes = ctrl.wal_battery.?[0..ctrl.wal_area_stride];
    try testing.expectEqualSlices(u8, expected, pair_bytes[0..arrays_len]);

    // The new writer is rewired onto the pair area and registered as its
    // writer; a further write lands there.
    const registered = ctrl.wal_writers[0].?;
    try testing.expectEqual(new, registered);
    try testing.expectEqual(@intFromPtr(pair_bytes.ptr), @intFromPtr(registered.data.ptr));
    var small: [10]u8 = undefined;
    @memset(&small, 0x77);
    try registered.write(0x102, 0x101, &small);
    try testing.expect(std.mem.indexOf(u8, pair_bytes, &small) != null);

    // The mark is gone, the old descriptor moved to the job and is still open,
    // and the final close is dispatched.
    const line = pairControlLine(&ctrl);
    try testing.expectEqual(@as(u8, 0), line.snapshot_in_progress);
    try testing.expectEqual(old_fd, job.old_fd);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(
        std.os.linux.fcntl(old_fd, std.os.linux.F.GETFD, 0),
    ));
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);
    try testing.expect(frame.snap.window == null);

    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    try testing.expectEqual(messages.CrossTaskMessageIdx, close_cqe.taskIdx());
    const close_slot: u32 = @intCast(close_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
    ctrl.cross_slots.release(close_slot);

    // The swap revived the frozen front: the old writer is retired from the
    // live set, and the surviving one is healthy.
    try testing.expectEqual(snapshot.Serve.serving, frame.snap.serve);

    // A relapse after the swap finds no window and stops terminally.
    registered.faulted = true;
    frame.snap.onWriterFault(frame.host(), registered);
    try testing.expectEqual(snapshot.Serve.stopped, frame.snap.serve);

    // The terminal reply clears the in-flight flag.
    frame.snap.onReply(frame.host(), .{ .SnapshotDone = .{} });
    try testing.expect(frame.snap.procedure == null);
}

test "recordFits is the pair's lba boundary" {
    const testing = std.testing;

    // 494 op bytes frame to exactly one 512-byte buffer; one more does not.
    try testing.expect(recordFits(512, 494));
    try testing.expect(!recordFits(512, 495));
    try testing.expect(recordFits(512, 0));

    // The 1 MiB structural cap is a separate, unchanged refusal: this record
    // passes the lba check and the WAL itself answers `RecordTooLarge` for it.
    const lba: u32 = 1 << 20;
    const fits_op = lba - 16 - 3;
    try testing.expect(recordFits(lba, fits_op));
    try testing.expect(!recordFits(lba, fits_op + 1));
    try testing.expect(wal.framedLen(fits_op) > wal.BLOCK_CONTENT);
}

/// A sink whose admission pre-check passes once and then refuses once: the
/// write is accepted, its submission parks, and the drain's retry takes it.
const ParkOnceSink = struct {
    var calls: u32 = 0;

    fn reset() void {
        calls = 0;
    }

    fn room(ctx: ?*anyopaque, writer: *wal.WalWriteFile) wal.WalError!void {
        _ = ctx;
        _ = writer;
        calls += 1;
        if (calls == 2) return error.NoFreeSlots;
    }

    fn submit(ctx: ?*anyopaque, writer: *wal.WalWriteFile, ordinal: u64) void {
        _ = ctx;
        writer.flushComplete(ordinal);
    }

    fn install(writer: *wal.WalWriteFile) void {
        writer.sink = .{ .room = room, .submit = submit };
    }
};

test "the drain retries a flush backpressure parked" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    defer {
        dropWindow(&frame);
        ctrl.snapshot_slots.release(k);
    }

    // The old side's admission pre-check passes, its submission is parked.
    ParkOnceSink.reset();
    ParkOnceSink.install(old);

    var op: [1006]u8 = undefined;
    @memset(&op, 0x44);
    try frame.snap.window.?.write(0x101, &op);
    try testing.expect(old.flush_pending);
    try testing.expect(!old.flush_in_flight);
    try testing.expect(!frame.snap.window.?.quiet());

    pumpWindow(&frame);

    // The retry took the parked submission, which completed synchronously: no
    // completion was owed to the drain.
    try testing.expectEqual(@as(u32, 3), ParkOnceSink.calls);
    try testing.expect(!old.flush_pending);
    try testing.expectEqual(@as(u64, 1), old.flushed_upto);
    try testing.expect(frame.snap.window.?.quiet());
}

test "a reply-triggered drain waits for the committed batch cursor" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    // A live window and a procedure, exactly as the completion test builds
    // them, but on the real ring so the batch window is exercised.
    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    old.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);
    new.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    defer dropTestJob(&ctrl, job);
    job.fd = -1;
    job.phase = .dump_sent;
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.procedure = job;
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    // The dump reply lands first: wait for its completion before the window
    // submits anything, so the CQ order is deterministic.
    const slot_idx = try ctrl.cross_slots.acquire();
    ctrl.cross_slots.at(slot_idx).* = .{ .SnapshotDumped = .{} };
    try ctrl.rings[2].ring.pushMsgRingFd(
        ctrl.rings[1].ring.fd,
        messages.CrossTaskMessageIdx,
        slot_idx,
        .{},
    );
    const reply_deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (ctrl.rings[1].ring.cq_tail.* -% ctrl.rings[1].ring.cq_head.* == 0) {
        if (zigring.monotonicNs() >= reply_deadline) return error.SnapshotReplyTimeout;
        std.atomic.spinLoopHint();
    }

    // One event through the window, so the CQ now holds
    // [reply, flush-completion].
    var op: [1006]u8 = undefined;
    @memset(&op, 0x66);
    try frame.snap.window.?.write(0x101, &op);
    try testing.expect(old.flush_in_flight and new.flush_in_flight);
    const flush_deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (ctrl.rings[1].ring.cq_tail.* -% ctrl.rings[1].ring.cq_head.* < 3) {
        if (zigring.monotonicNs() >= flush_deadline) return error.SnapshotFlushTimeout;
        std.atomic.spinLoopHint();
    }

    var inbox: Inbox = undefined;
    try inbox.init(testing.allocator, 8, &ctrl.rings[1].ring);
    defer inbox.deinit();

    // The batch window consumes the reply but does not publish its cursor yet.
    const before = ctrl.rings[1].ring.cq_head.*;
    const batch = inbox.batch(64, 0) orelse return error.MissingBatch;
    const reply = batch.ring.popCQE() orelse return error.MissingCqe;
    try testing.expectEqual(messages.CrossTaskMessageIdx, reply.taskIdx());
    stepCQE(&frame, reply);
    try batch.ring.commit();

    // The reply armed the continuation and was handled once: the head moved
    // exactly one completion forward, and the swap waits for the pump.
    try testing.expectEqual(before + 1, ctrl.rings[1].ring.cq_head.*);
    try testing.expectEqual(snapshot.Drain.swap, frame.snap.drain.?);
    try testing.expectEqual(lifetime.SnapshotPhase.dump_sent, job.phase);
    try testing.expectEqual(cross_task.SnapshotSlotStatus.in_flight, ctrl.snapshot_slots.at(k).status);
    try testing.expect(!ctrl.rings[2].ring.checkCQNotEmpty());

    // A duplicate completion of the same event is ignored, never re-entered.
    frame.snap.onReply(frame.host(), .{ .SnapshotDumped = .{} });
    try testing.expectEqual(snapshot.Drain.swap, frame.snap.drain.?);
    try testing.expectEqual(lifetime.SnapshotPhase.dump_sent, job.phase);

    // The pump finishes the swap outside the batch: each flush is consumed
    // once and exactly one final close is sent.
    drainPump(&frame);
    try testing.expect(frame.snap.drain == null);
    try testing.expect(frame.snap.window == null);
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);
    // The retired old writer is gone; the surviving one carries the event and
    // the single flush the pump consumed.
    try testing.expectEqual(new, ctrl.wal_writers[0].?);
    try testing.expectEqual(@as(u64, 1), new.flushed_upto);
    try testing.expectEqual(@as(u128, 0x101), new.head);

    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const close_slot: u32 = @intCast(close_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
    ctrl.cross_slots.release(close_slot);
    try testing.expect(ctrl.rings[2].ring.popCQE() == null);
}

// ============================================================================
// Startup recovery (§7.1)
// ============================================================================

/// Writes `bytes` into `path`, creating or truncating it.
fn writeFileBytes(path: []const u8, bytes: []const u8) !void {
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);

    const fd_raw = std.os.linux.open(path_z, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    const errno = std.os.linux.errno(fd_raw);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    const fd: posix.fd_t = @intCast(fd_raw);
    defer _ = std.os.linux.close(fd);

    var done: usize = 0;
    while (done < bytes.len) {
        const res = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        const write_errno = std.os.linux.errno(res);
        if (write_errno != .SUCCESS) return std.posix.unexpectedErrno(write_errno);
        done += res;
    }
}

/// A controller over a throwaway WAL root and a plain file standing in for the
/// NVDIMM, for the PMEM-shape startup tests.
const StartupPmem = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    device: []u8,
    cfg: config.Config,
    ctrl: lifetime.Controller,
    live: bool = false,

    fn init(self: *StartupPmem, hosts: u32) !void {
        const allocator = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{self.tmp.sub_path[0..]});
        errdefer allocator.free(self.dir);
        self.device = try std.fmt.allocPrint(allocator, "{s}/pmem0", .{self.dir});
        errdefer allocator.free(self.device);

        self.cfg = testConfig(self.dir, hosts, 1, .{ .registry_keep = 2 });
        self.cfg.wal = .{ .pmem = .{
            .dir = self.dir,
            .device = self.device,
            .buffers = 8,
            .lba = config.kib(1),
            .hosts = hosts,
        } };

        const pairs = @as(usize, self.cfg.indexes) * self.cfg.wal.hosts();
        const areas = pairs + self.cfg.snapshots.slots;
        const stride = wal.areaStride(self.cfg.wal.buffers(), self.cfg.wal.lba(), std.heap.pageSize());
        const needed = areas * stride;

        const path = try allocator.dupeSentinel(u8, self.device, 0);
        defer allocator.free(path);
        const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
        if (std.os.linux.errno(fd_raw) != .SUCCESS) return error.TestUnexpectedResult;
        const fd: posix.fd_t = @intCast(fd_raw);
        defer _ = std.os.linux.close(fd);
        if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(needed))) != .SUCCESS) {
            return error.TestUnexpectedResult;
        }

        try self.openCtrl();
    }

    fn openCtrl(self: *StartupPmem) !void {
        try self.ctrl.init(std.testing.allocator, &self.cfg);
        try self.ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });
        self.live = true;
    }

    fn reopen(self: *StartupPmem) !void {
        self.ctrl.deinit();
        self.live = false;
        try self.openCtrl();
    }

    fn deinit(self: *StartupPmem) void {
        if (self.live) self.ctrl.deinit();
        std.testing.allocator.free(self.dir);
        std.testing.allocator.free(self.device);
        self.tmp.cleanup();
    }
};

// ============================================================================
// Stage J: the end-to-end gate and the PMEM-shape crash matrix
// ============================================================================

/// Steps the thread's own completions until `writer` has no flush in flight and
/// none parked: the standalone pair writer's version of the window drain.
fn drainWriterQuiet(frame: *Frame, writer: *wal.WalWriteFile) void {
    while (writer.flush_in_flight or writer.flush_pending) {
        if (writer.flush_pending and !writer.flush_in_flight) writer.driveFlush();
        if (frame.ring.ring.popCQE()) |cqe| {
            stepCQE(frame, cqe);
            continue;
        }
        frame.ring.ring.park();
    }
}

fn fileExists(path: [:0]const u8) bool {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (std.os.linux.errno(fd_raw) != .SUCCESS) return false;
    _ = std.os.linux.close(@intCast(fd_raw));
    return true;
}

/// Asserts `actual` carries exactly the sessions `expected` does, field by
/// field: the shape the snapshot-equality assertion needs.
fn expectSameSessions(expected: *state.IndexState, actual: *state.IndexState) !void {
    try std.testing.expectEqual(expected.sessions.count(), actual.sessions.count());
    var it = expected.sessions.iterator();
    while (it.next()) |bucket| {
        const want = bucket.val;
        const got = actual.sessions.get(bucket.key) orelse return error.MissingSession;
        try std.testing.expectEqual(want.data.original_id, got.data.original_id);
        try std.testing.expectEqual(want.data.retry_count, got.data.retry_count);
        try std.testing.expectEqualStrings(want.data.compensator, got.data.compensator);
        try std.testing.expectEqualSlices(
            u8,
            want.data.data.backing[0..want.data.data.len],
            got.data.data.backing[0..got.data.data.len],
        );
    }
}

test "the end-to-end plain-mode procedure commits, swaps and replays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir);

    // The barrier is 1 MiB, so the two large records below fire the tick; the
    // interval is irrelevant because the test calls `tickPass` directly.
    var cfg = testConfig(dir, 1, 1, .{ .size_barrier = config.mib(1), .interval = config.seconds(3600), .slots = 2, .registry_keep = 8 });
    cfg.wal = .{ .plain = .{ .dir = dir, .buffers = 2048, .hosts = 1, .lba = config.kib(1) } };
    const states = [_]u128{ 0x101, 0x102, 0x103, 0x104, 0x105 };
    const old_tag: u128 = 0x100;
    const elephant_ring: u16 = cfg.fronts + cfg.indexes;

    // 19 framing bytes plus a 600 KiB payload fills exactly 600 one-KiB
    // buffers, so the record ends on a buffer boundary and is durable at once.
    const big_op_len: usize = 600 * 1024 - 19;
    const op = try allocator.alloc(u8, big_op_len);
    defer allocator.free(op);
    for (op, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 1);

    var saved_wal: ?[:0]u8 = null;
    var saved_snapshot: ?[:0]u8 = null;
    var saved_old: ?[:0]u8 = null;
    defer if (saved_wal) |path| allocator.free(path);
    defer if (saved_snapshot) |path| allocator.free(path);
    defer if (saved_old) |path| allocator.free(path);
    var saved_k: u32 = 0;

    {
        var ctrl: lifetime.Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();
        try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

        try ctrl.initRing(1, 1);
        defer ctrl.rings[1].deinit();
        try ctrl.initRing(elephant_ring, 1);
        defer ctrl.rings[elephant_ring].deinit();

        const logger = try ctrl.getLogger(1);
        defer dropTestLogger(&ctrl, logger);

        var el = snapshot.Elephant{ .ctrl = &ctrl, .log = &logger.logger, .ring_idx = elephant_ring };

        var sets = [_]state.IndexState{undefined};
        try ctrl.initIndexState(&sets[0]);
        defer ctrl.deinitIndexState(&sets[0]);

        // The pre-procedure pair: a WAL under an earlier tag, serving through
        // the index's own ring, exactly as the loop wires it.
        const pair = try openPairWriter(&ctrl, 0, 0, old_tag);
        pair.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

        var frame = testFrame(&ctrl, 1, logger, &sets);
        const slots_full = ctrl.snapshot_slots.freeCount();

        // Two records before the tick; drain each so the next one has buffers.
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            try pair.write(states[i], pair.head, op);
            sets[0].state = states[i];
            try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = op } });
            drainWriterQuiet(&frame, pair);
        }
        try testing.expectEqual(@as(u128, states[1]), sets[0].state);

        // The tick: the pair is over the barrier and its state is the tag X.
        frame.snap.onTick(frame.host());
        const job = frame.snap.procedure orelse return error.SnapshotNotStarted;
        var job_live = true;
        defer if (job_live) dropTestJob(&ctrl, job);
        try testing.expectEqual(@as(u128, states[1]), job.tag);

        // The pair keeps serving between the tick and the create reply: the
        // clone state Y is ahead of the name tag X.
        try pair.write(states[2], pair.head, op);
        sets[0].state = states[2];
        try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = op } });
        drainWriterQuiet(&frame, pair);

        // F1, the real handler: the create request's slot is released on read.
        const create_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        try testing.expectEqual(messages.CrossTaskMessageIdx, create_cqe.taskIdx());
        const create_slot: u32 = @intCast(create_cqe.res);
        try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(create_slot).SnapshotCreate.job);
        ctrl.cross_slots.release(create_slot);
        el.createSnapshot(job);
        saved_wal = try allocator.dupeSentinel(u8, job.wal_path, 0);
        saved_snapshot = try allocator.dupeSentinel(u8, job.snapshot_path, 0);
        saved_k = job.k;

        // The fd reply lands on the index ring; the ordinary dispatch runs the
        // handler pass: mark, clone, adopt, composite, dump dispatch.
        const fd_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, fd_cqe);
        const window = &(frame.snap.window orelse return error.SnapshotWindowMissing);
        try testing.expectEqual(@as(u128, states[2]), job.clone.state);

        // One window event: new first, then old, both through the ring.
        try window.write(states[3], op);
        pumpWindow(&frame);
        try testing.expect(window.quiet());
        try testing.expectEqual(@as(u128, states[3]), window.new.head);
        try testing.expectEqual(@as(u128, states[3]), window.old.head);

        // F2, the real handler: the dump, the registry commit and the reply.
        const dump_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        const dump_slot: u32 = @intCast(dump_cqe.res);
        try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(dump_slot).SnapshotDump.job);
        ctrl.cross_slots.release(dump_slot);
        el.dumpSnapshot(job);

        // The completion: the drain, the copy, the clear, the revival and the
        // close dispatch.
        const dumped_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, dumped_cqe);
        pumpWindow(&frame);
        try testing.expect(frame.snap.window == null);
        try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);

        // F3, the real handler: the old fd's close and the terminal reply.
        const close_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        const close_slot: u32 = @intCast(close_cqe.res);
        try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
        ctrl.cross_slots.release(close_slot);
        el.closeSnapshot(job);
        job_live = false;

        const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, done_cqe);
        try testing.expect(frame.snap.procedure == null);

        // The registry holds exactly one line: the new WAL and snapshot, with
        // the clone state Y.
        const entries = (try ctrl.loadRegistry(0)) orelse return error.RegistryMissing;
        defer ctrl.freeRegistry(entries);
        try testing.expectEqual(@as(usize, 1), entries.len);
        try testing.expectEqual(@as(u128, states[2]), entries[0].state);
        try testing.expectEqualStrings(saved_wal.?, entries[0].wal_path);
        try testing.expectEqualStrings(saved_snapshot.?, entries[0].snapshot_path);

        // The old WAL still exists on disk, but no line names it.
        const index_dir = try ctrl.indexDirPath(0);
        defer allocator.free(index_dir);
        saved_old = try wal.walPath(allocator, index_dir, 0, 0, old_tag);
        try testing.expect(fileExists(saved_old.?));
        try testing.expect(!std.mem.eql(u8, saved_old.?, entries[0].wal_path));

        // The snapshot loads and equals the pair at clone time: the three
        // sessions written before the window's event.
        const snapshot_bytes = try readFileBytes(allocator, saved_snapshot.?);
        defer allocator.free(snapshot_bytes);
        var loaded = try ctrl.loadIndexState(snapshot_bytes);
        defer ctrl.deinitIndexState(&loaded);
        try testing.expectEqual(@as(u128, 0), loaded.state);
        try expectSameSessions(&sets[0], &loaded);

        // The surviving writer is the pair area's, not temp ring k's: the ring
        // is dead to the thread.
        const pair_idx = wal.areaIndex(0, 0, cfg.wal.hosts());
        const pair_bytes = ctrl.wal_battery.?[pair_idx * ctrl.wal_area_stride ..][0..ctrl.wal_area_stride];
        const temp_start = wal.tempAreaIdx(saved_k, ctrl.wal_pairs) * ctrl.wal_area_stride;
        const temp_bytes = ctrl.wal_battery.?[temp_start..][0..ctrl.wal_area_stride];
        const registered = ctrl.wal_writers[pair_idx].?;
        try testing.expectEqual(@intFromPtr(pair_bytes.ptr), @intFromPtr(registered.data.ptr));
        try testing.expect(@intFromPtr(registered.data.ptr) != @intFromPtr(temp_bytes.ptr));

        // The new writer serves further writes: the floor chains from the
        // window's head.
        try registered.write(states[4], registered.head, op);
        drainWriterQuiet(&frame, registered);
        try testing.expectEqual(@as(u128, states[4]), registered.head);

        // The procedure is over to its true end: the flag is clear and the
        // slot is back in the pool.
        try testing.expectEqual(slots_full, ctrl.snapshot_slots.freeCount());
    }

    // The restart: a fresh Controller over the same files replays the WAL over
    // the snapshot and reconstructs every session the procedure wrote.
    {
        var ctrl: lifetime.Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();
        try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

        try ctrl.initRing(1, 1);
        defer ctrl.rings[1].deinit();
        const logger = try ctrl.getLogger(1);
        defer dropTestLogger(&ctrl, logger);

        var st: state.IndexState = undefined;
        try ctrl.initIndexState(&st);
        defer ctrl.deinitIndexState(&st);

        try snapshot.recoverPair(&ctrl, &ctrl.rings[1], &logger.logger, 0, 0, &st);

        try testing.expectEqual(@as(u128, states[4]), st.state);
        try testing.expectEqual(@as(usize, 5), st.sessions.count());
        for (states) |state_idx| {
            try testing.expect(st.sessions.get(state_idx) != null);
        }
    }
}

/// One 494-byte op frames to exactly one 512-byte buffer, so every record the
/// J2 chains write fills and flushes immediately.
const j2_op_len: usize = 494;

fn j2Op(state_idx: u128) [j2_op_len]u8 {
    var op: [j2_op_len]u8 = undefined;
    const seed: usize = @truncate(state_idx);
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 13 +% seed *% 7 +% 3);
    return op;
}

/// A synchronous sink that also writes the buffer into the file, the way a
/// PMEM flush's `RWF.DSYNC` `pwrite` does; `flushComplete` then publishes the
/// resume terminator into the battery.
const J2FileSink = struct {
    fn room(ctx: ?*anyopaque, writer: *wal.WalWriteFile) wal.WalError!void {
        _ = ctx;
        _ = writer;
    }

    fn submit(ctx: ?*anyopaque, writer: *wal.WalWriteFile, ordinal: u64) void {
        _ = ctx;
        const data = writer.bufferData(ordinal);
        const base: posix.off_t = @intCast(ordinal * @as(u64, writer.lba));
        var done: usize = 0;
        while (done < data.len) {
            const res = std.os.linux.pwrite(writer.fd, data[done..].ptr, data.len - done, base + @as(posix.off_t, @intCast(done)));
            const errno = std.os.linux.errno(res);
            if (errno != .SUCCESS) {
                writer.fault(errno);
                return;
            }
            done += res;
        }
        writer.flushComplete(ordinal);
    }

    fn install(writer: *wal.WalWriteFile) void {
        writer.sink = .{ .room = room, .submit = submit };
    }
};

fn j2Area(ctrl: *lifetime.Controller, area_idx: usize) wal.Area {
    const start = area_idx * ctrl.wal_area_stride;
    return wal.Area.init(
        ctrl.wal_battery.?[start..][0..ctrl.wal_area_stride],
        ctrl.cfg.wal.buffers(),
        ctrl.cfg.wal.lba(),
    );
}

/// Writes a chain into battery area `area_idx` and into the WAL file named
/// `file_tag`: records `from..=to`, chained from `start_floor`. The writer is
/// a plain local, never registered on the controller.
fn writeJ2Chain(
    ctrl: *lifetime.Controller,
    host: u8,
    index: u16,
    area_idx: usize,
    file_tag: u128,
    start_floor: u128,
    from: u128,
    to: u128,
) !u128 {
    try ctrl.ensureIndexDir(index);
    const dir = try ctrl.indexDirPath(index);
    defer ctrl.allocator.free(dir);
    const path = try wal.walPath(ctrl.allocator, dir, host, index, file_tag);
    defer ctrl.allocator.free(path);

    const fd = try createWalFile(path);
    var writer = wal.WalWriteFile.init(fd, j2Area(ctrl, area_idx), ctrl.cfg.wal, host, index, start_floor);
    J2FileSink.install(&writer);

    var s = from;
    while (s <= to) : (s += 1) {
        var op = j2Op(s);
        try writer.write(s, writer.head, &op);
    }
    const head = writer.head;
    _ = std.os.linux.close(fd);
    return head;
}

/// Builds a data set by applying one `create` per state, in order.
fn j2State(ctrl: *lifetime.Controller, states: []const u128) !state.IndexState {
    var st: state.IndexState = undefined;
    try ctrl.initIndexState(&st);
    errdefer ctrl.deinitIndexState(&st);
    for (states) |s| {
        st.state = s;
        var op = j2Op(s);
        try ctrl.applyIndexOp(&st, .{ .create = .{ .compensator = "marker", .payload = &op } });
    }
    return st;
}

/// Dumps the sessions of `states` under `snapshot.<host>.<index>.<tag>`.
fn writeJ2Snapshot(
    ctrl: *lifetime.Controller,
    host: u8,
    index: u16,
    tag: u128,
    states: []const u128,
) !void {
    var st = try j2State(ctrl, states);
    defer ctrl.deinitIndexState(&st);

    var dump: std.ArrayList(u8) = .empty;
    defer dump.deinit(ctrl.allocator);
    try ctrl.dumpIndexState(&st, &dump);

    const dir = try ctrl.indexDirPath(index);
    defer ctrl.allocator.free(dir);
    const path = try wal.snapshotPath(ctrl.allocator, dir, host, index, tag);
    defer ctrl.allocator.free(path);
    try writeFileBytes(path, dump.items);
}

const J2Row = enum { create_to_mark, mark_to_commit, commit_to_copy, mid_copy, copy_to_clear, post_swap };

/// One crash-table row, built as files plus battery state and then driven
/// through the **full** startup sequence, not only the adoption rule.
fn runJ2Row(row: J2Row) !void {
    const allocator = std.testing.allocator;

    var f: StartupPmem = undefined;
    try f.init(1);
    defer f.deinit();

    const host: u8 = 0;
    const index: u16 = 0;
    const k: u32 = 0;
    const old_tag: u128 = 0x10;
    const x: u128 = 0x14;
    const all_states = [_]u128{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16 };
    const clone_states = [_]u128{ 0x11, 0x12, 0x13, 0x14 };
    const tail_states = [_]u128{ 0x15, 0x16 };
    const pair_idx = wal.areaIndex(host, index, 1);

    try f.ctrl.ensureIndexDir(index);
    try f.ctrl.acquireWalBattery();

    // The old pair: an empty snapshot at its own tag and a WAL that holds the
    // whole history. The registry state is the snapshot's state, the tag.
    try writeJ2Snapshot(&f.ctrl, host, index, old_tag, &.{});
    _ = try writeJ2Chain(&f.ctrl, host, index, pair_idx, old_tag, old_tag, all_states[0], all_states[all_states.len - 1]);

    if (row == .create_to_mark) {
        // The create reply arrived; the handler pass never did, so there is no
        // temp chain: only the empty new file.
        const dir = try f.ctrl.indexDirPath(index);
        defer allocator.free(dir);
        const path = try wal.walPath(allocator, dir, host, index, x);
        defer allocator.free(path);
        const created = try createWalFile(path);
        _ = std.os.linux.close(created);
    } else {
        // The clone's snapshot and the window's chain on temp ring k.
        try writeJ2Snapshot(&f.ctrl, host, index, x, &clone_states);
        const temp_idx = wal.tempAreaIdx(k, f.ctrl.wal_pairs);
        _ = try writeJ2Chain(&f.ctrl, host, index, temp_idx, x, x, tail_states[0], tail_states[1]);
    }

    // The pair area's state at the crash.
    const pair = j2Area(&f.ctrl, pair_idx);
    const temp = j2Area(&f.ctrl, wal.tempAreaIdx(k, f.ctrl.wal_pairs));
    switch (row) {
        // The old chain is the pair area's from the chain write above.
        .create_to_mark, .mark_to_commit, .commit_to_copy => {},
        .mid_copy => {
            // The copy started and tore: half of the data array and the first
            // two header lines.
            const half = pair.data.len / 2;
            @memcpy(pair.data[0..half], temp.data[0..half]);
            @memcpy(
                std.mem.sliceAsBytes(pair.headers[0..2]),
                std.mem.sliceAsBytes(temp.headers[0..2]),
            );
        },
        .copy_to_clear, .post_swap => {
            @memcpy(pair.data, temp.data);
            @memcpy(std.mem.sliceAsBytes(pair.headers), std.mem.sliceAsBytes(temp.headers));
        },
    }

    // The mark, when the handler pass had published it.
    switch (row) {
        .create_to_mark, .post_swap => {},
        else => try f.ctrl.publishAdoptionMark(host, index, k, x),
    }

    // The registry: the old line wins until the dump's rewrite commits.
    const old_dir = try f.ctrl.indexDirPath(index);
    defer allocator.free(old_dir);
    const old_snapshot = try wal.snapshotPath(allocator, old_dir, host, index, old_tag);
    defer allocator.free(old_snapshot);
    const old_wal = try wal.walPath(allocator, old_dir, host, index, old_tag);
    defer allocator.free(old_wal);
    const new_snapshot = try wal.snapshotPath(allocator, old_dir, host, index, x);
    defer allocator.free(new_snapshot);
    const new_wal = try wal.walPath(allocator, old_dir, host, index, x);
    defer allocator.free(new_wal);
    switch (row) {
        .create_to_mark, .mark_to_commit => try f.ctrl.rewriteRegistry(index, .{
            .host_idx = host,
            .snapshot_path = old_snapshot,
            .wal_path = old_wal,
            .state = old_tag,
        }),
        else => try f.ctrl.rewriteRegistry(index, .{
            .host_idx = host,
            .snapshot_path = new_snapshot,
            .wal_path = new_wal,
            .state = x,
        }),
    }

    // The crash and the full startup sequence: adoption rule, registry,
    // snapshot, writer, (bring-tail) and replay.
    try f.reopen();

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const logger = try f.ctrl.getLogger(ring_idx);
    defer dropTestLogger(&f.ctrl, logger);

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);

    try snapshot.recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], &logger.logger, index, host, &st);

    // Every row converges on the same recovered state: the same sessions and
    // the same walked head, by whichever branch.
    try std.testing.expectEqual(@as(u128, all_states[all_states.len - 1]), st.state);
    try std.testing.expectEqual(all_states.len, st.sessions.count());
    var reference = try j2State(&f.ctrl, &all_states);
    defer f.ctrl.deinitIndexState(&reference);
    try expectSameSessions(&reference, &st);

    // The mark is gone and the pair's writer resumes from the recovered head.
    try std.testing.expectEqual(@as(u8, 0), pairControlLine(&f.ctrl).snapshot_in_progress);
    try std.testing.expectEqual(@as(u128, all_states[all_states.len - 1]), f.ctrl.wal_writers[pair_idx].?.head);

    // The winning line is the old one before the commit and the new one after.
    const entries = (try f.ctrl.loadRegistry(index)).?;
    defer f.ctrl.freeRegistry(entries);
    const winner = lifetime.Controller.lastLineFor(entries, host).?;
    const expected_tag: u128 = switch (row) {
        .create_to_mark, .mark_to_commit => old_tag,
        else => x,
    };
    try std.testing.expectEqual(expected_tag, wal.walTagFromPath(winner.wal_path).?);
    try std.testing.expectEqual(expected_tag, winner.state);
}

test "the six crash-table rows all recover through the full startup sequence" {
    const rows = [_]J2Row{
        .create_to_mark,
        .mark_to_commit,
        .commit_to_copy,
        .mid_copy,
        .copy_to_clear,
        .post_swap,
    };
    for (rows) |row| try runJ2Row(row);
}

test "startup's bring-tail recovers the inter-write cut's surplus record" {
    const allocator = std.testing.allocator;

    var f: StartupPmem = undefined;
    try f.init(1);
    defer f.deinit();

    const host: u8 = 0;
    const index: u16 = 0;
    const k: u32 = 0;
    const old_tag: u128 = 0x10;
    const x: u128 = 0x14;
    const old_states = [_]u128{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16 };
    const clone_states = [_]u128{ 0x11, 0x12, 0x13, 0x14 };
    const pair_idx = wal.areaIndex(host, index, 1);

    try f.ctrl.ensureIndexDir(index);
    try f.ctrl.acquireWalBattery();

    try writeJ2Snapshot(&f.ctrl, host, index, old_tag, &.{});
    _ = try writeJ2Chain(&f.ctrl, host, index, pair_idx, old_tag, old_tag, old_states[0], old_states[old_states.len - 1]);
    try writeJ2Snapshot(&f.ctrl, host, index, x, &clone_states);

    // The cut: the new side holds one record the old side never got.
    const temp_idx = wal.tempAreaIdx(k, f.ctrl.wal_pairs);
    _ = try writeJ2Chain(&f.ctrl, host, index, temp_idx, x, x, 0x15, 0x17);
    try f.ctrl.publishAdoptionMark(host, index, k, x);

    const dir = try f.ctrl.indexDirPath(index);
    defer allocator.free(dir);
    const old_snapshot = try wal.snapshotPath(allocator, dir, host, index, old_tag);
    defer allocator.free(old_snapshot);
    const old_wal = try wal.walPath(allocator, dir, host, index, old_tag);
    defer allocator.free(old_wal);
    try f.ctrl.rewriteRegistry(index, .{
        .host_idx = host,
        .snapshot_path = old_snapshot,
        .wal_path = old_wal,
        .state = old_tag,
    });

    try f.reopen();

    const ring_idx: u16 = f.cfg.fronts;
    try f.ctrl.initRing(ring_idx, 1);
    defer f.ctrl.rings[ring_idx].deinit();
    const logger = try f.ctrl.getLogger(ring_idx);
    defer dropTestLogger(&f.ctrl, logger);

    var st: state.IndexState = undefined;
    try f.ctrl.initIndexState(&st);
    defer f.ctrl.deinitIndexState(&st);

    try snapshot.recoverPair(&f.ctrl, &f.ctrl.rings[ring_idx], &logger.logger, index, host, &st);

    // The surplus is home: the old chain replays it, once, after the abort.
    try std.testing.expectEqual(@as(u128, 0x17), st.state);
    try std.testing.expectEqual(@as(usize, 7), st.sessions.count());
    var reference = try j2State(&f.ctrl, &.{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17 });
    defer f.ctrl.deinitIndexState(&reference);
    try expectSameSessions(&reference, &st);
    try std.testing.expectEqual(@as(u128, 0x17), f.ctrl.wal_writers[pair_idx].?.head);
}

test "the freeze ladder drains the window, revives at the swap and stops on relapse" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    // Both sides flush through the real ring: the drain has real completions
    // to step, not synchronous no-ops.
    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    old.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);
    new.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    var job_live = true;
    defer if (job_live) dropTestJob(&ctrl, job);
    job.fd = -1;
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.procedure = job;
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    var op: [1006]u8 = undefined;
    for (&op, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 1);
    try frame.snap.window.?.write(0x101, &op);
    try testing.expect(old.flush_in_flight and new.flush_in_flight);

    // The old side faults mid-window: the front freezes, the window serves on.
    old.faulted = true;
    frame.snap.onWriterFault(frame.host(), old);
    try testing.expectEqual(snapshot.Serve.frozen, frame.snap.serve);

    // The completion pass's bounded drain steps the real flushes before the
    // copy; the swap retires the faulted writer and revives the front.
    frame.snap.onReply(frame.host(), .{ .SnapshotDumped = .{} });
    pumpWindow(&frame);
    try testing.expect(frame.snap.window == null);
    try testing.expectEqual(snapshot.Serve.serving, frame.snap.serve);
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);

    var el = snapshot.Elephant{ .ctrl = &ctrl, .log = &logger.logger, .ring_idx = 2 };
    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    const close_slot: u32 = @intCast(close_cqe.res);
    try testing.expectEqual(@intFromPtr(job), ctrl.cross_slots.at(close_slot).SnapshotClose.job);
    ctrl.cross_slots.release(close_slot);
    el.closeSnapshot(job);
    job_live = false;

    const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotReplyTimeout;
    stepCQE(&frame, done_cqe);
    try testing.expect(frame.snap.procedure == null);

    // A relapse after the swap finds no window and stops terminally.
    const live = ctrl.wal_writers[0].?;
    live.faulted = true;
    frame.snap.onWriterFault(frame.host(), live);
    try testing.expectEqual(snapshot.Serve.stopped, frame.snap.serve);
}

test "a stop mid-window completes the procedure on the control plane" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .slots = 2 });
    var ctrl: lifetime.Controller = undefined;
    try ctrl.init(testing.allocator, &cfg);
    defer ctrl.deinit();
    try ctrl.initRing(1, 1);
    defer ctrl.rings[1].deinit();
    try ctrl.initRing(2, 1);
    defer ctrl.rings[2].deinit();

    const logger = try ctrl.getLogger(1);
    defer dropTestLogger(&ctrl, logger);

    var sets = [_]state.IndexState{undefined};
    try ctrl.initIndexState(&sets[0]);
    defer ctrl.deinitIndexState(&sets[0]);

    const old = try openPairWriter(&ctrl, 0, 0, 0x100);
    old.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);
    const k = try ctrl.snapshot_slots.acquire();
    const new = try adoptWindowWriter(&ctrl, 0, 0, k, 0x100, 0x100);
    new.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

    const job = try ctrl.mintSnapshotJob(0, 0, 0x100, k, 1);
    var job_live = true;
    defer if (job_live) dropTestJob(&ctrl, job);
    job.fd = -1;
    ctrl.snapshot_slots.at(k).* = .{ .status = .in_flight, .job = @intFromPtr(job) };

    var frame = testFrame(&ctrl, 1, logger, &sets);
    frame.snap.procedure = job;
    frame.snap.window = .{ .new = new, .old = old, .allocator = ctrl.allocator };
    try ctrl.publishAdoptionMark(0, 0, k, 0x100);

    var op = j2Op(0x101);
    try frame.snap.window.?.write(0x101, &op);

    // A new-side flush fault is the ordinary terminal stop; ticks skip the
    // thread, but the procedure still completes on the control plane (rung 10).
    new.faulted = true;
    frame.snap.onWriterFault(frame.host(), new);
    try testing.expectEqual(snapshot.Serve.stopped, frame.snap.serve);

    frame.snap.onReply(frame.host(), .{ .SnapshotDumped = .{} });
    pumpWindow(&frame);
    try testing.expect(frame.snap.window == null);
    try testing.expectEqual(lifetime.SnapshotPhase.close_sent, job.phase);

    // The final close lands and the terminal reply clears the flag. The stop
    // stands: no swap revives a stopped thread.
    var el = snapshot.Elephant{ .ctrl = &ctrl, .log = &logger.logger, .ring_idx = 2 };
    const close_cqe = cqeBefore(&ctrl.rings[2].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotDispatchTimeout;
    ctrl.cross_slots.release(@intCast(close_cqe.res));
    el.closeSnapshot(job);
    job_live = false;

    const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SnapshotReplyTimeout;
    stepCQE(&frame, done_cqe);
    try testing.expect(frame.snap.procedure == null);
    try testing.expectEqual(snapshot.Serve.stopped, frame.snap.serve);
}

test "a failed registry rename leaves the old line winning and recovery-correct" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir);

    var cfg = testConfig(dir, 1, 1, .{ .size_barrier = config.mib(1), .interval = config.seconds(3600), .slots = 2, .registry_keep = 8 });
    cfg.wal = .{ .plain = .{ .dir = dir, .buffers = 2048, .hosts = 1, .lba = config.kib(1) } };
    const old_tag: u128 = 0x100;
    const states = [_]u128{ 0x101, 0x102, 0x103, 0x104 };
    const elephant_ring: u16 = cfg.fronts + cfg.indexes;

    // 19 framing bytes plus a 600 KiB payload fills exactly 600 one-KiB
    // buffers, so the record ends on a buffer boundary and is durable at once.
    const big_op_len: usize = 600 * 1024 - 19;
    const op = try allocator.alloc(u8, big_op_len);
    defer allocator.free(op);
    for (op, 0..) |*byte, i| byte.* = @truncate(i *% 13 +% 3);

    var old_wal_path: ?[:0]u8 = null;
    var fixed_registry: ?[]u8 = null;
    defer if (old_wal_path) |path| allocator.free(path);
    defer if (fixed_registry) |bytes| allocator.free(bytes);

    {
        var ctrl: lifetime.Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();
        try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

        try ctrl.initRing(1, 1);
        defer ctrl.rings[1].deinit();
        try ctrl.initRing(elephant_ring, 1);
        defer ctrl.rings[elephant_ring].deinit();

        const logger = try ctrl.getLogger(1);
        defer dropTestLogger(&ctrl, logger);

        var el = snapshot.Elephant{ .ctrl = &ctrl, .log = &logger.logger, .ring_idx = elephant_ring };

        var sets = [_]state.IndexState{undefined};
        try ctrl.initIndexState(&sets[0]);
        defer ctrl.deinitIndexState(&sets[0]);

        const pair = try openPairWriter(&ctrl, 0, 0, old_tag);
        pair.attachStream(&ctrl.rings[1].sqstream, &ctrl.rings[1].slots);

        // A prior committed line names the old pair.
        const index_dir = try ctrl.indexDirPath(0);
        defer allocator.free(index_dir);
        const old_snapshot = try wal.snapshotPath(allocator, index_dir, 0, 0, old_tag);
        defer allocator.free(old_snapshot);
        old_wal_path = try wal.walPath(allocator, index_dir, 0, 0, old_tag);
        try writeJ2Snapshot(&ctrl, 0, 0, old_tag, &.{});
        try ctrl.rewriteRegistry(0, .{
            .host_idx = 0,
            .snapshot_path = old_snapshot,
            .wal_path = old_wal_path.?,
            .state = old_tag,
        });
        const registry_path = try ctrl.registryPath(0);
        defer allocator.free(registry_path);
        fixed_registry = try readFileBytes(allocator, registry_path);

        var frame = testFrame(&ctrl, 1, logger, &sets);

        var i: usize = 0;
        while (i < 2) : (i += 1) {
            try pair.write(states[i], pair.head, op);
            sets[0].state = states[i];
            try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = op } });
            drainWriterQuiet(&frame, pair);
        }

        frame.snap.onTick(frame.host());
        const job = frame.snap.procedure orelse return error.SnapshotNotStarted;
        var job_live = true;
        defer if (job_live) dropTestJob(&ctrl, job);

        try pair.write(states[2], pair.head, op);
        sets[0].state = states[2];
        try ctrl.applyIndexOp(&sets[0], .{ .create = .{ .compensator = "marker", .payload = op } });
        drainWriterQuiet(&frame, pair);

        const create_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        ctrl.cross_slots.release(@intCast(create_cqe.res));
        el.createSnapshot(job);

        const fd_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, fd_cqe);

        try frame.snap.window.?.write(states[3], op);
        pumpWindow(&frame);

        // The rewrite's pending write succeeds; the rename is where it fails.
        ctrl.test_fail_registry_rename = true;
        const dump_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        ctrl.cross_slots.release(@intCast(dump_cqe.res));
        el.dumpSnapshot(job);
        ctrl.test_fail_registry_rename = false;

        const abandon_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, abandon_cqe);
        pumpWindow(&frame);

        // Unwind B: the window reverts, the new writer closes and cleanup is
        // dispatched. The committed line never changed.
        try testing.expect(frame.snap.window == null);
        try testing.expectEqual(lifetime.SnapshotPhase.cleanup_sent, job.phase);
        try testing.expect(pairControlLine(&ctrl).snapshot_in_progress == 0);

        const cleanup_cqe = cqeBefore(&ctrl.rings[elephant_ring].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotDispatchTimeout;
        ctrl.cross_slots.release(@intCast(cleanup_cqe.res));
        el.cleanupSnapshot(job);
        job_live = false;

        const done_cqe = cqeBefore(&ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
            return error.SnapshotReplyTimeout;
        stepCQE(&frame, done_cqe);
        try testing.expect(frame.snap.procedure == null);

        // The pending staging file is junk; the fixed registry still carries
        // the old line, byte for byte.
        const pending = try ctrl.registryPendingPath(0);
        defer allocator.free(pending);
        try testing.expect(fileExists(pending));
        const after_registry_path = try ctrl.registryPath(0);
        defer allocator.free(after_registry_path);
        const after = try readFileBytes(allocator, after_registry_path);
        defer allocator.free(after);
        try testing.expectEqualSlices(u8, fixed_registry.?, after);
        try testing.expect(fileExists(old_wal_path.?));
    }

    // Recovery is correct on the previous pair: every durable event was
    // written to it too (new first, then old), so nothing is lost.
    {
        var ctrl: lifetime.Controller = undefined;
        try ctrl.init(allocator, &cfg);
        defer ctrl.deinit();
        try ctrl.compensators.put("marker", .{ .bind = "10.0.0.1", .port = 20301 });

        try ctrl.initRing(1, 1);
        defer ctrl.rings[1].deinit();
        const logger = try ctrl.getLogger(1);
        defer dropTestLogger(&ctrl, logger);

        var st: state.IndexState = undefined;
        try ctrl.initIndexState(&st);
        defer ctrl.deinitIndexState(&st);

        try snapshot.recoverPair(&ctrl, &ctrl.rings[1], &logger.logger, 0, 0, &st);

        try testing.expectEqual(@as(u128, states[3]), st.state);
        try testing.expectEqual(states.len, st.sessions.count());
        var reference: state.IndexState = undefined;
        try ctrl.initIndexState(&reference);
        defer ctrl.deinitIndexState(&reference);
        for (states) |s| {
            reference.state = s;
            try ctrl.applyIndexOp(&reference, .{ .create = .{ .compensator = "marker", .payload = op } });
        }
        try expectSameSessions(&reference, &st);
    }
}

/// A two-host cluster config: the transport is live and the own peer slot is
/// empty.
fn clusterTestConfig(dir: []const u8) config.Config {
    var cfg = testConfig(dir, 2, 0, .{});
    cfg.cluster = .{
        .peer_port = 7001,
        .peers = &[_][]const u8{ "", "127.0.0.1" },
    };
    return cfg;
}

/// The Stage F fixture: a live transport, one index ring and one link entry.
const LinkFixture = struct {
    cfg: config.Config = undefined,
    ctrl: lifetime.Controller = undefined,
    logger: *lifetime.LoggerStuff = undefined,
    sets: [2]state.IndexState = undefined,
    frame: Frame = undefined,

    fn init(self: *LinkFixture, dir: []const u8) !void {
        try self.initOnPort(dir, 7001);
    }

    fn initOnPort(self: *LinkFixture, dir: []const u8, peer_port: u16) !void {
        self.cfg = clusterTestConfig(dir);
        self.cfg.cluster.?.peer_port = peer_port;
        try self.ctrl.init(std.testing.allocator, &self.cfg);
        try self.ctrl.initRing(1, 1);
        self.logger = try self.ctrl.getLogger(1);
        for (&self.sets) |*st| try self.ctrl.initIndexState(st);
        self.frame = testFrame(&self.ctrl, 1, self.logger, &self.sets);
    }

    fn deinit(self: *LinkFixture) void {
        for (&self.sets) |*st| self.ctrl.deinitIndexState(st);
        dropTestLogger(&self.ctrl, self.logger);
        self.ctrl.rings[1].deinit();
        self.ctrl.deinit();
    }

    fn entry(self: *LinkFixture) !*cluster_transport.LinkEntry {
        return self.ctrl.link_tables[0].acquire(1, 0);
    }
};

fn socketPair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const res = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (std.os.linux.errno(res) != .SUCCESS) return error.SocketPairFailed;
    return fds;
}

fn listenLoopback() !struct { fd: posix.fd_t, port: u16 } {
    const fd = try zigring.createTCPServerSocket();
    errdefer _ = std.os.linux.close(fd);

    const ip = std.Io.net.Ip4Address.loopback(0);
    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = @bitCast(ip.bytes),
    };

    const bind_res = std.os.linux.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    if (std.os.linux.errno(bind_res) != .SUCCESS) return error.BindFailed;
    const listen_res = std.os.linux.listen(fd, 8);
    if (std.os.linux.errno(listen_res) != .SUCCESS) return error.ListenFailed;

    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const name_res = std.os.linux.getsockname(fd, @ptrCast(&addr), &len);
    if (std.os.linux.errno(name_res) != .SUCCESS) return error.GetSockNameFailed;

    return .{ .fd = fd, .port = std.mem.nativeToBig(u16, addr.port) };
}

fn readExact(fd: posix.fd_t, dst: []u8) !void {
    var got: usize = 0;
    while (got < dst.len) {
        const n = try posix.read(fd, dst[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
}

fn writeExact(fd: posix.fd_t, src: []const u8) !void {
    var written: usize = 0;
    while (written < src.len) {
        const rc = std.os.linux.write(fd, src[written..].ptr, src.len - written);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.WriteFailed;
        written += rc;
    }
}

const DialWait = struct {
    entry: *cluster_transport.LinkEntry,
    step: enum { greeted, up, retry },

    fn ready(self: DialWait) bool {
        return switch (self.step) {
            .greeted => self.entry.greet_task != null,
            .up => self.entry.state == .up,
            .retry => self.entry.retry_task != null,
        };
    }
};

fn pumpDial(frame: *Frame, wait: DialWait, deadline_ns: u64) void {
    while (zigring.monotonicNs() < deadline_ns) {
        if (wait.ready()) return;
        if (frame.ring.ring.popCQE()) |cqe| {
            stepCQE(frame, cqe);
            continue;
        }
        std.atomic.spinLoopHint();
    }
}

test "the dialer greets and installs the link on an ok verdict" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    const listener = try listenLoopback();
    defer _ = std.os.linux.close(listener.fd);

    var f: LinkFixture = undefined;
    try f.initOnPort(dir, listener.port);
    defer f.deinit();

    dialPeers(&f.frame);

    const accepted_raw = std.os.linux.accept(listener.fd, null, null);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(accepted_raw));
    const peer: posix.fd_t = @intCast(accepted_raw);
    defer _ = std.os.linux.close(peer);

    const entry = f.ctrl.link_tables[0].get(1).?;
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;

    pumpDial(&f.frame, .{ .entry = entry, .step = .greeted }, deadline);
    try testing.expect(entry.greet_task != null);

    var greet_bytes: [cluster_transport.GREET_LEN]u8 = undefined;
    try readExact(peer, &greet_bytes);
    const greet = cluster_transport.decodeGreet(&greet_bytes);
    try testing.expectEqual(cluster_transport.VERSION, greet.version);
    try testing.expectEqual(@as(u8, 0), greet.host_idx);
    try testing.expectEqual(@as(u16, 0), greet.index_idx);

    var reply_bytes: [cluster_transport.REPLY_LEN]u8 = undefined;
    cluster_transport.encodeReply(.{
        .version = cluster_transport.VERSION,
        .host_idx = 1,
        .index_idx = 0,
        .verdict = .ok,
    }, &reply_bytes);
    try writeExact(peer, &reply_bytes);

    pumpDial(&f.frame, .{ .entry = entry, .step = .up }, deadline);
    try testing.expectEqual(cluster_transport.LinkState.up, entry.state);
    try testing.expectEqual(cluster_transport.RETRY_MIN, entry.retry_backoff);
    // The handshake proved the peer alive: the dialer's side arms the
    // keepalive on `up` (§4.8).
    try testing.expect(entry.keepalive_task != null);
    cancelKeepalive(&f.frame, entry);
}

test "a non-ok verdict closes the dial and arms the retry" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    const listener = try listenLoopback();
    defer _ = std.os.linux.close(listener.fd);

    var f: LinkFixture = undefined;
    try f.initOnPort(dir, listener.port);
    defer f.deinit();

    dialPeers(&f.frame);

    const accepted_raw = std.os.linux.accept(listener.fd, null, null);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(accepted_raw));
    const peer: posix.fd_t = @intCast(accepted_raw);
    defer _ = std.os.linux.close(peer);

    const entry = f.ctrl.link_tables[0].get(1).?;
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;

    pumpDial(&f.frame, .{ .entry = entry, .step = .greeted }, deadline);
    try testing.expect(entry.greet_task != null);

    var greet_bytes: [cluster_transport.GREET_LEN]u8 = undefined;
    try readExact(peer, &greet_bytes);

    var reply_bytes: [cluster_transport.REPLY_LEN]u8 = undefined;
    cluster_transport.encodeReply(.{
        .version = cluster_transport.VERSION,
        .host_idx = 1,
        .index_idx = 0,
        .verdict = .host_index_squatting,
    }, &reply_bytes);
    try writeExact(peer, &reply_bytes);

    pumpDial(&f.frame, .{ .entry = entry, .step = .retry }, deadline);
    try testing.expectEqual(cluster_transport.LinkState.none, entry.state);
    try testing.expect(entry.retry_task != null);
    try testing.expectEqual(cluster_transport.RETRY_MIN * 2, entry.retry_backoff);
}

test "the dial backoff doubles to the cap" {
    try std.testing.expectEqual(cluster_transport.RETRY_MIN * 2, nextBackoff(cluster_transport.RETRY_MIN));
    try std.testing.expectEqual(cluster_transport.RETRY_MAX, nextBackoff(cluster_transport.RETRY_MAX));
    try std.testing.expectEqual(cluster_transport.RETRY_MAX, nextBackoff(cluster_transport.RETRY_MAX / 2));
}

test "the send path encodes a frame and advances the sequence" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const entry = try f.entry();
    const fds = try socketPair();
    defer _ = std.os.linux.close(fds[1]);
    entry.fd = fds[0];
    entry.state = .up;

    try sendFrame(&f.frame, entry, cluster_transport.OP_PULSE_ACK, &.{}, null);
    try testing.expectEqual(@as(u64, 1), entry.seq_abs);
    try testing.expect(entry.sendBusy(0));

    var buf: [cluster_transport.FRAME_CAP]u8 = undefined;
    const got = try std.posix.read(fds[1], &buf);
    try testing.expectEqual(@as(usize, cluster_transport.FRAME_MIN), got);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[0..2], .little));
    try testing.expectEqual(@as(u16, cluster_transport.FRAME_MIN), std.mem.readInt(u16, buf[2..4], .little));
    try testing.expectEqual(cluster_transport.OP_PULSE_ACK, buf[21]);

    const cqe = cqeBefore(&f.ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.SendCqeTimeout;
    onFrameSend(&f.frame, entry, entry.epoch, cqe);
    try testing.expect(!entry.sendBusy(0));
    try testing.expectEqual(@as(?u64, null), entry.send_task[0]);
}

test "the send path reports backpressure when every buffer is busy" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const entry = try f.entry();
    const fds = try socketPair();
    defer _ = std.os.linux.close(fds[1]);
    entry.fd = fds[0];
    entry.state = .up;

    var seq: u16 = 0;
    while (seq < entry.inflight) : (seq += 1) entry.setSendBusy(seq, true);
    try testing.expectError(
        error.Backpressure,
        sendFrame(&f.frame, entry, cluster_transport.OP_PULSE_ACK, &.{}, null),
    );
}

test "the drain delivers a committed frame and advances the cursor" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const entry = try f.entry();
    entry.state = .up;

    var wire: [cluster_transport.FRAME_CAP]u8 = undefined;
    const len = try cluster_transport.encodeFrame(&wire, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = cluster_transport.OP_PULSE_ACK,
        .op_payload = &.{},
    });
    try entry.reorder.push(0, wire[0..len]);

    drainFrames(&f.frame, entry);
    try testing.expect(entry.acked);
    try testing.expectEqual(@as(u64, 1), entry.delivered);
}

test "an unknown op code is a link death and a consensus op is retried" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const entry = try f.entry();
    entry.state = .up;

    var wire: [cluster_transport.FRAME_CAP]u8 = undefined;
    var len = try cluster_transport.encodeFrame(&wire, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = cluster_transport.OP_PULSE,
        .op_payload = &.{},
    });
    // `0x80..0xFF` has no class, so no encoder emits it; a hostile peer can.
    wire[21] = 0x80;
    try testing.expectEqual(DispatchResult.death, dispatchFrame(&f.frame, entry, wire[0..len]));

    // A consensus op is retried until the class switch lands (§8.1).
    len = try cluster_transport.encodeFrame(&wire, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = cluster_transport.OP_CREATE,
        .op_payload = &.{},
        .state_id = 1,
        .prev_state_id = 0,
    });
    try testing.expectEqual(DispatchResult.retry, dispatchFrame(&f.frame, entry, wire[0..len]));
}

test "a valid peer link is greeted ok and goes up on the send completion" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const fds = try socketPair();
    defer _ = std.os.linux.close(fds[1]);

    onPeerLink(&f.frame, .{
        .fd = fds[0],
        .host_idx = 1,
        .index_idx = 0,
        .version = cluster_transport.VERSION,
        .source_ok = true,
    });

    const entry = f.ctrl.link_tables[0].get(1) orelse return error.MissingLinkEntry;
    try testing.expectEqual(cluster_transport.LinkState.greeting, entry.state);
    const reply = try cluster_transport.decodeReply(&entry.reply);
    try testing.expectEqual(cluster_transport.Verdict.ok, reply.verdict);

    var buf: [cluster_transport.REPLY_LEN]u8 = undefined;
    const got = try std.posix.read(fds[1], &buf);
    try testing.expectEqual(@as(usize, cluster_transport.REPLY_LEN), got);

    const cqe = cqeBefore(&f.ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.GreetingCqeTimeout;
    onGreetingSend(&f.frame, entry, entry.epoch, cqe);
    try testing.expectEqual(cluster_transport.LinkState.up, entry.state);
    try testing.expect(entry.recv_task != null);
    // The acceptor arms its own keepalive on the same transition.
    try testing.expect(entry.keepalive_task != null);
    cancelKeepalive(&f.frame, entry);
}

test "a peer link with a bad source is rejected with peer_address_mismatch" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const fds = try socketPair();
    defer _ = std.os.linux.close(fds[1]);

    onPeerLink(&f.frame, .{
        .fd = fds[0],
        .host_idx = 1,
        .index_idx = 0,
        .version = cluster_transport.VERSION,
        .source_ok = false,
    });

    const entry = f.ctrl.link_tables[0].get(1) orelse return error.MissingLinkEntry;
    try testing.expectEqual(cluster_transport.LinkState.greeting, entry.state);
    const reply = try cluster_transport.decodeReply(&entry.reply);
    try testing.expectEqual(cluster_transport.Verdict.peer_address_mismatch, reply.verdict);

    var buf: [cluster_transport.REPLY_LEN]u8 = undefined;
    const got = try std.posix.read(fds[1], &buf);
    try testing.expectEqual(@as(usize, cluster_transport.REPLY_LEN), got);

    const cqe = cqeBefore(&f.ctrl.rings[1].ring, zigring.monotonicNs() + 5 * std.time.ns_per_s) orelse
        return error.GreetingCqeTimeout;
    onGreetingSend(&f.frame, entry, entry.epoch, cqe);
    try testing.expectEqual(cluster_transport.LinkState.none, entry.state);
    try testing.expectEqual(@as(posix.fd_t, -1), entry.fd);
}

/// Sets up an established link between the entry and a live socket pair: the
/// entry holds one end, the test drives the peer on the other.
fn establishedLink(f: *LinkFixture) !struct { entry: *cluster_transport.LinkEntry, fds: [2]posix.fd_t } {
    const entry = try f.entry();
    const fds = try socketPair();
    entry.fd = fds[0];
    entry.state = .up;
    return .{ .entry = entry, .fds = fds };
}

test "a duplicate candidate parks without a receive arm and probes the link" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const live = try establishedLink(&f);
    defer _ = std.os.linux.close(live.fds[1]);
    const entry = live.entry;

    const cand = try socketPair();
    defer _ = std.os.linux.close(cand[1]);

    onPeerLink(&f.frame, .{
        .fd = cand[0],
        .host_idx = 1,
        .index_idx = 0,
        .version = cluster_transport.VERSION,
        .source_ok = true,
    });

    // The established link is untouched and still `up`; the candidate is
    // parked with its socket and without a receive arm of its own.
    try testing.expectEqual(cluster_transport.LinkState.up, entry.state);
    try testing.expectEqual(cluster_transport.LinkState.parked, entry.candidate_state);
    try testing.expectEqual(cand[0], entry.candidate_fd);
    try testing.expectEqual(@as(?u64, null), entry.recv_task);
    try testing.expect(entry.predicate_task != null);

    // The probe is a pulse on the established link, consuming a `seq_id`.
    try testing.expectEqual(@as(u64, 1), entry.seq_abs);
    var wire: [cluster_transport.FRAME_CAP]u8 = undefined;
    const got = try std.posix.read(live.fds[1], &wire);
    try testing.expectEqual(@as(usize, cluster_transport.FRAME_MIN), got);
    try testing.expectEqual(cluster_transport.OP_PULSE, wire[21]);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, wire[0..2], .little));
}

test "an acknowledged probe rejects the candidate and keeps the link" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const live = try establishedLink(&f);
    defer _ = std.os.linux.close(live.fds[1]);
    const entry = live.entry;

    const cand = try socketPair();
    defer _ = std.os.linux.close(cand[1]);

    onPeerLink(&f.frame, .{
        .fd = cand[0],
        .host_idx = 1,
        .index_idx = 0,
        .version = cluster_transport.VERSION,
        .source_ok = true,
    });
    try testing.expectEqual(cluster_transport.LinkState.parked, entry.candidate_state);

    // The peer answers the pulse: the acknowledgement is any inbound frame,
    // here delivered through the link's own reorder stream.
    var wire: [cluster_transport.FRAME_CAP]u8 = undefined;
    const len = try cluster_transport.encodeFrame(&wire, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = cluster_transport.OP_PULSE_ACK,
        .op_payload = &.{},
    });
    try entry.reorder.push(0, wire[0..len]);
    entry.pushed_absolute = 1;

    drainLinks(&f.frame);

    // The link survives, its clock is cancelled, and the candidate is answered.
    try testing.expectEqual(cluster_transport.LinkState.up, entry.state);
    try testing.expectEqual(cluster_transport.LinkState.greeting, entry.candidate_state);
    try testing.expectEqual(@as(?u64, null), entry.predicate_task);
    // The acknowledgement is shared with the keepalive clock (§4.8): rejecting
    // the candidate must not spend it.
    try testing.expect(entry.acked);

    var reply_bytes: [cluster_transport.REPLY_LEN]u8 = undefined;
    const got = try std.posix.read(cand[1], &reply_bytes);
    try testing.expectEqual(@as(usize, cluster_transport.REPLY_LEN), got);
    const reply = try cluster_transport.decodeReply(&reply_bytes);
    try testing.expectEqual(cluster_transport.Verdict.host_index_squatting, reply.verdict);

    // The candidate is closed only after its verdict left whole.
    const reply_task = entry.candidate_reply_task orelse return error.MissingCandidateReply;
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (entry.candidate_reply_task != null) {
        const cqe = cqeBefore(&f.ctrl.rings[1].ring, deadline) orelse return error.CqeTimeout;
        if (cqe.taskIdx() == reply_task) {
            onPulse(&f.frame, entry, cqe);
        } else {
            stepCQE(&f.frame, cqe);
        }
    }
    try testing.expectEqual(@as(posix.fd_t, -1), entry.candidate_fd);
    try testing.expectEqual(cluster_transport.LinkState.none, entry.candidate_state);
    try testing.expectEqual(cluster_transport.LinkState.up, entry.state);
    try testing.expect(entry.fd >= 0);
}

test "a timed-out probe installs the candidate at absolute zero" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const live = try establishedLink(&f);
    defer _ = std.os.linux.close(live.fds[1]);
    const entry = live.entry;
    const old_fd = live.fds[0];
    const old_epoch = entry.epoch;

    // Frames from the old connection moved both counters off zero.
    entry.seq_abs = 7;
    entry.delivered = 3;
    entry.pushed_absolute = 5;
    const old_wire = try cluster_transport.encodeFrame(entry.sendBuffer(0), .{
        .seq_id = 6,
        .vector_clock_frame = .{ .host_idx = 0, .state = 0 },
        .op_code = cluster_transport.OP_PULSE_ACK,
        .op_payload = &.{},
    });
    try entry.reorder.push(2, entry.sendBuffer(0)[0..old_wire]);
    entry.pushed_absolute = 3;

    const cand = try socketPair();
    defer _ = std.os.linux.close(cand[1]);

    onPeerLink(&f.frame, .{
        .fd = cand[0],
        .host_idx = 1,
        .index_idx = 0,
        .version = cluster_transport.VERSION,
        .source_ok = true,
    });
    const predicate_task = entry.predicate_task orelse return error.MissingPredicateTimer;

    // The deadline fires before any acknowledgement arrives.
    onPredicateTimeout(&f.frame, entry, old_epoch, .{
        .user_data = predicate_task,
        .res = 0,
        .flags = 0,
    });

    // The candidate owns the link now and the old connection is retired.
    try testing.expectEqual(cand[0], entry.fd);
    try testing.expect(entry.fd != old_fd);
    try testing.expectEqual(@as(posix.fd_t, -1), entry.candidate_fd);
    try testing.expectEqual(cluster_transport.LinkState.none, entry.candidate_state);
    try testing.expectEqual(old_epoch +% 1, entry.epoch);
    try testing.expectEqual(cluster_transport.LinkState.greeting, entry.state);
    try testing.expectEqual(@as(u64, 0), entry.seq_abs);
    try testing.expectEqual(@as(u64, 0), entry.delivered);
    try testing.expectEqual(@as(u64, 0), entry.pushed_absolute);
    try testing.expectEqual(@as(u64, 0), entry.reorder.wave);

    const reply = try cluster_transport.decodeReply(&entry.reply);
    try testing.expectEqual(cluster_transport.Verdict.ok, reply.verdict);

    // The greeting goes `up` on its own completion, with a fresh receive.
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (entry.state != .up) {
        const cqe = cqeBefore(&f.ctrl.rings[1].ring, deadline) orelse return error.CqeTimeout;
        stepCQE(&f.frame, cqe);
    }
    try testing.expect(entry.recv_task != null);
}

test "a keepalive tick sends a pulse and clears the acknowledgement" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const live = try establishedLink(&f);
    defer _ = std.os.linux.close(live.fds[1]);
    const entry = live.entry;

    armKeepalive(&f.frame, entry);
    const task = entry.keepalive_task orelse return error.MissingKeepalive;
    // The handshake is the first acknowledgement the clock spends.
    try testing.expect(entry.acked);
    try testing.expectEqual(
        @as(i64, @intCast(@divTrunc(f.cfg.cluster.?.keepalive_interval.value(), std.time.ns_per_s))),
        @as(i64, entry.keepalive_spec.sec),
    );

    // A normal tick: the multishot is still armed, so `hasMore` stays set.
    onKeepaliveTick(&f.frame, entry, entry.epoch, .{
        .user_data = task,
        .res = -@as(i32, @intCast(@backingInt(std.os.linux.E.TIME))),
        .flags = 2,
    });

    try testing.expectEqual(@as(u64, 1), entry.seq_abs);
    try testing.expect(!entry.acked);
    try testing.expect(!entry.keepalive_pending);
    try testing.expectEqual(task, entry.keepalive_task.?);

    var wire: [cluster_transport.FRAME_CAP]u8 = undefined;
    const got = try std.posix.read(live.fds[1], &wire);
    try testing.expectEqual(@as(usize, cluster_transport.FRAME_MIN), got);
    try testing.expectEqual(cluster_transport.OP_PULSE, wire[21]);

    // The peer's acknowledgement re-arms the flag for the next tick.
    const len = try cluster_transport.encodeFrame(&wire, .{
        .seq_id = 0,
        .vector_clock_frame = .{ .host_idx = 1, .state = 0 },
        .op_code = cluster_transport.OP_PULSE_ACK,
        .op_payload = &.{},
    });
    try entry.reorder.push(0, wire[0..len]);
    entry.pushed_absolute = 1;
    drainLinks(&f.frame);
    try testing.expect(entry.acked);

    cancelKeepalive(&f.frame, entry);
    try testing.expectEqual(@as(?u64, null), entry.keepalive_task);
}

test "a keepalive tick without an acknowledgement kills the link" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const live = try establishedLink(&f);
    defer _ = std.os.linux.close(live.fds[1]);
    const entry = live.entry;

    armKeepalive(&f.frame, entry);
    const task = entry.keepalive_task orelse return error.MissingKeepalive;
    entry.acked = false;

    onKeepaliveTick(&f.frame, entry, entry.epoch, .{
        .user_data = task,
        .res = -@as(i32, @intCast(@backingInt(std.os.linux.E.TIME))),
        .flags = 2,
    });

    // §3.6's teardown ran: the descriptor is retired, the stream returns to
    // absolute zero and the ticker is canceled.
    try testing.expectEqual(cluster_transport.LinkState.none, entry.state);
    try testing.expectEqual(@as(posix.fd_t, -1), entry.fd);
    try testing.expectEqual(@as(?u64, null), entry.keepalive_task);
    try testing.expect(!entry.keepalive_pending);
    try testing.expectEqual(@as(u64, 0), entry.seq_abs);
}

test "the canceled keepalive's final completion releases its slot" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const live = try establishedLink(&f);
    defer _ = std.os.linux.close(live.fds[1]);
    const entry = live.entry;

    armKeepalive(&f.frame, entry);
    const task = entry.keepalive_task orelse return error.MissingKeepalive;
    cancelKeepalive(&f.frame, entry);
    try testing.expectEqual(@as(?u64, null), entry.keepalive_task);
    try testing.expect(f.frame.ring.slots.get(task) != null);

    // The kernel's final completion of a canceled unlimited ticker.
    onKeepaliveTick(&f.frame, entry, entry.epoch, .{
        .user_data = task,
        .res = -@as(i32, @intCast(@backingInt(std.os.linux.E.CANCELED))),
        .flags = 0,
    });
    try testing.expect(f.frame.ring.slots.get(task) == null);
    try testing.expectEqual(@as(?u64, null), entry.keepalive_task);
}

test "a backpressured keepalive pulse is retried on the next pass" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const live = try establishedLink(&f);
    defer _ = std.os.linux.close(live.fds[1]);
    const entry = live.entry;

    armKeepalive(&f.frame, entry);
    var seq: u16 = 0;
    while (seq < entry.inflight) : (seq += 1) entry.setSendBusy(seq, true);

    sendKeepalivePulse(&f.frame, entry);
    // Nothing left the ring, so the acknowledgement is not spent yet.
    try testing.expect(entry.keepalive_pending);
    try testing.expect(entry.acked);
    try testing.expectEqual(@as(u64, 0), entry.seq_abs);

    seq = 0;
    while (seq < entry.inflight) : (seq += 1) entry.setSendBusy(seq, false);
    drainLinks(&f.frame);
    try testing.expect(!entry.keepalive_pending);
    try testing.expect(!entry.acked);
    try testing.expectEqual(@as(u64, 1), entry.seq_abs);

    cancelKeepalive(&f.frame, entry);
}
/// Whether the descriptor has already been closed: the kernel answer the
/// teardown tests use to prove a close landed.
fn fdClosed(fd: posix.fd_t) bool {
    return std.os.linux.errno(std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0)) == .BADF;
}

test "the drain closes every link and reaps the close completions" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const live = try establishedLink(&f);
    defer _ = std.os.linux.close(live.fds[1]);
    const entry = live.entry;
    armKeepalive(&f.frame, entry);

    // A duplicate candidate parked by the switch predicate is a descriptor the
    // entry still owns, so the drain must retire it too.
    const cand = try socketPair();
    defer _ = std.os.linux.close(cand[1]);
    onPeerLink(&f.frame, .{
        .fd = cand[0],
        .host_idx = 1,
        .index_idx = 0,
        .version = cluster_transport.VERSION,
        .source_ok = true,
    });
    try testing.expectEqual(cluster_transport.LinkState.parked, entry.candidate_state);

    // One packet the link had queued, so the drain meets a live send too.
    try sendFrame(&f.frame, entry, cluster_transport.OP_PULSE, &.{}, null);

    teardownLinks(&f.frame);

    // §3.7: both descriptors are retired, the link is dead and the stream
    // state returns to absolute zero; the ticker is gone.
    try testing.expect(f.frame.links_closed);
    try testing.expectEqual(cluster_transport.LinkState.none, entry.state);
    try testing.expectEqual(@as(posix.fd_t, -1), entry.fd);
    try testing.expectEqual(@as(posix.fd_t, -1), entry.candidate_fd);
    try testing.expectEqual(cluster_transport.LinkState.none, entry.candidate_state);
    try testing.expectEqual(@as(?u64, null), entry.keepalive_task);
    try testing.expectEqual(@as(u64, 0), entry.seq_abs);
    try testing.expectEqual(@as(u64, 0), entry.reorder.wave);

    // The closes are SQEs of their own: step them until the kernel reports both
    // descriptors gone, which proves the completions were reaped, not leaked.
    const deadline = zigring.monotonicNs() + 5 * std.time.ns_per_s;
    while (zigring.monotonicNs() < deadline) {
        if (f.frame.ring.ring.popCQE()) |cqe| {
            stepCQE(&f.frame, cqe);
            continue;
        }
        if (fdClosed(live.fds[0]) and fdClosed(cand[0])) break;
        std.atomic.spinLoopHint();
    }
    try testing.expect(fdClosed(live.fds[0]));
    try testing.expect(fdClosed(cand[0]));
}

test "a hand-over that raced the drain is closed, never greeted" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(dir);

    var f: LinkFixture = undefined;
    try f.init(dir);
    defer f.deinit();

    const cand = try socketPair();
    defer _ = std.os.linux.close(cand[1]);

    closeLinks(&f.frame);
    onPeerLink(&f.frame, .{
        .fd = cand[0],
        .host_idx = 1,
        .index_idx = 0,
        .version = cluster_transport.VERSION,
        .source_ok = true,
    });

    // The final drain's hand-over is a plain close: no entry, no greeting.
    try testing.expect(fdClosed(cand[0]));
    try testing.expect(f.ctrl.link_tables[0].get(1) == null);
}
