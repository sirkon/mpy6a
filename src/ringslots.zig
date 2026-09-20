const std = @import("std");
const zigring_mod = @import("zigring");

/// RingTaskContext this is a reference for a logic
const RingTaskContext = union {
    logging: RingTaskLogging,
};

const RingTaskLogging = struct {
    buf: []const u8,
};

const RingSlots = zigring_mod.Slots(RingTaskContext);
