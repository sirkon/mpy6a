pub const CrossTaskPlaceholder = struct {};

// CrossTask descriptor for tasks that travel between different OS threads.
pub const CrossTask = union {
    Placeholder: CrossTaskPlaceholder,
};
