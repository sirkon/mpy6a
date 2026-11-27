//! Elephant thread: heavy background work, reached only through
//! `CrossTaskSlots`.
//!
//! An elephant has no inbox and no session state. It waits in its own ring for
//! two things: a `CrossTaskMessageIdx` completion carrying a slot index, or a
//! `ShutdownDemandIdx`. Its startup broadcast is a no-op: it ignores the
//! listening socket.
//!
//! The snapshot procedure's file work lives in `snapshot.Elephant`; this file
//! keeps the loop and the four non-snapshot variants.

const std = @import("std");
const resources = @import("resources.zig");
const messages = @import("messages.zig");
const logging = @import("logging.zig");
const cross_task = @import("cross_task.zig");
const snapshot = @import("snapshot.zig");

/// Runs the elephant thread to completion. `role` is the role the thread derived
/// from its `ring_idx` before reporting `INITIALIZED`.
pub fn run(ctrl: *resources.Controller, role: resources.Role, logger: *resources.LoggerStuff) void {
    const ring = &ctrl.rings[role.elephant.ring_idx];
    const log = &logger.logger;

    log.info("elephant started", .{ .ring_idx = role.elephant.ring_idx });

    var self = snapshot.Elephant{
        .ctrl = ctrl,
        .log = log,
        .ring_idx = role.elephant.ring_idx,
    };

    while (true) {
        while (ring.ring.popCQE()) |cqe| {
            switch (cqe.taskIdx()) {
                // Launch broadcast: an elephant never touches the socket.
                messages.StartWorkIdx => {},
                messages.CrossTaskMessageIdx => {
                    const slot_idx: u32 = @intCast(cqe.res);
                    const task = ctrl.cross_slots.at(slot_idx).*;
                    ctrl.cross_slots.release(slot_idx);
                    if (self.handle(task)) continue;
                    handleOther(task, log, role.elephant.ring_idx);
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

/// The cross-task variants the snapshot actor declines: shutdown demands, the
/// socket broadcast and the index drain notice.
fn handleOther(
    task: cross_task.CrossTask,
    log: *logging.Logger,
    own_ring_idx: u16,
) void {
    switch (task) {
        // Shutdown demands are delivered as a reserved taskIdx, not through a
        // slot; this variant is only reachable from a direct sender.
        .ShutdownDemand => |demand| {
            log.warn("elephant got a slot-borne shutdown demand", .{ .ring_idx = own_ring_idx, .hard = demand.hard });
        },
        .SoftShutdown => {},
        .ServerSocket => |socket| {
            // The listener is broadcast to fronts only and ownership stays with
            // `runShard`; every thread shares one descriptor table, so there is
            // no copy an elephant could close. No production sender emits this
            // variant.
            log.warn("elephant got a server socket it does not own", .{
                .ring_idx = own_ring_idx,
                .fd = socket.fd,
            });
        },
        .IndexDrained => {},
        else => log.warn("elephant read a cross-task message it does not handle", .{ .ring_idx = own_ring_idx }),
    }
}

fn reportDone(ring: *resources.RingStuff, ctrl: *resources.Controller, ring_idx: u16) void {
    while (true) {
        if (ring.ring.pushMsgRingFd(ctrl.init_ring.ring.fd, messages.ShutdownDoneIdx, ring_idx, .{})) |_| {
            return;
        } else |err| switch (err) {
            error.RingFull => std.atomic.spinLoopHint(),
        }
    }
}
