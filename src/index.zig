const std = @import("std");

/// Definition of messages that may come through IndexInbox from its parent front.
pub const FrontMessage = union(enum) {
    create: struct {
        // TODO: fill this.
    },
    session_op: struct {},
    shutdown_soft: void,
    shutdown_hard: void,
};
