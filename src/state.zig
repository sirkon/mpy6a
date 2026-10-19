const Buffer = struct {
    backing: []u8,
    len: usize,
};

const Session = struct {
    const Self = @This();

    const State = enum(u32) {
        ExpectOp,
        ExpectConsensus,
        ExpectAcceptedFlush,
    };
    const ConsensusProgress = struct {
        accepted: u16 = 0,
        rejected: u16 = 0,
    };

    id: u128,
    index_idx: u128,
    upgrade_idx: u128, // Identifier that will become an index_idx once the last op will be successfully passed.
    wheel_idx: u64, // Current identifier in the timing wheel. Must be changed after successful mutation or pulse.
    state: State,
    consensus_progress: ConsensusProgress,

    data: Buffer,

    pub fn prepareForNewConsensus(self: *Self) void {
        self.consensus_progress = .{};
    }
};

const WALOperation = struct {
    op: union {
        create: struct {
            replayer: u64,
            data: Buffer,
        },
        append: struct {
            data: Buffer,
        },
        ovewrite: struct {
            data: Buffer,
        },
        close: struct {},
        repeat: struct {
            delay: u32,
        },
    },
};
