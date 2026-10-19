//! Elephant thread: heavy background work, reached only through
//! `CrossTaskSlots`.
//!
//! An elephant has no inbox and no session state. It waits in its own ring for
//! two things: a `CrossTaskMessageIdx` completion carrying a slot index, or a
//! `ShutdownDemandIdx`. Its startup broadcast is a no-op: it ignores the
//! listening socket.

const std = @import("std");
const zigring = @import("zigring");
const lifetime = @import("lifetime.zig");
const messages = @import("messages.zig");
const logging = @import("logging.zig");

/// Runs the elephant thread to completion.
pub fn run(ctrl: *lifetime.Controller, role: lifetime.Role, logger: *lifetime.LoggerStuff) void {
    const ring = &ctrl.rings[role.elephant.ring_idx];
    const log = &logger.logger;

    log.info("elephant started", .{ .ring_idx = role.elephant.ring_idx });

    while (true) {
        while (ring.ring.popCQE()) |cqe| {
            switch (cqe.taskIdx()) {
                // Launch broadcast: an elephant never touches the socket.
                messages.StartWorkIdx => {},
                messages.CrossTaskMessageIdx => {
                    const slot_idx: u32 = @intCast(cqe.res);
                    const task = ctrl.cross_slots.at(slot_idx).*;
                    ctrl.cross_slots.release(slot_idx);
                    handleTask(task, log, role.elephant.ring_idx);
                },
                messages.ShutdownDemandIdx => {
                    // There is no multi-step operation in the skeleton, so the
                    // current unit of work is already finished by the time the
                    // demand is observed. A real elephant would drain its
                    // in-flight operation before this report.
                    log.info("elephant stopping", .{ .ring_idx = role.elephant.ring_idx });
                    reportDone(ring, ctrl, role.elephant.ring_idx);
                    return;
                },
                else => {},
            }
        }
        ring.ring.park();
    }
}

fn handleTask(task: @import("cross_task.zig").CrossTask, log: *logging.Logger, ring_idx: u16) void {
    switch (task) {
        // Shutdown demands are delivered as a reserved taskIdx, not through a
        // slot; this variant is only reachable from a direct sender.
        .ShutdownDemand => |demand| {
            log.warn("elephant got a slot-borne shutdown demand", .{ .ring_idx = ring_idx, .hard = demand.hard });
        },
        .SoftShutdown => {},
        .ServerSocket => |socket| {
            // The socket is broadcast to fronts only; an elephant that sees it
            // closes its copy rather than leaking the descriptor.
            _ = std.os.linux.close(socket.fd);
        },
        .IndexDrained => {},
    }
}

fn reportDone(ring: *lifetime.RingStuff, ctrl: *lifetime.Controller, thread_idx: u16) void {
    while (true) {
        if (ring.ring.pushMsgRingFd(ctrl.init_ring.ring.fd, messages.ShutdownDoneIdx, thread_idx, .{})) |_| {
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
}
