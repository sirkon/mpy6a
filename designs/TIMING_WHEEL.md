# Wheel Description.

The wheel is implemented as a comptime factory for the block shape: `N` and `L` are parameters, not hardcoded constants,
and the factory returns a type specialized to them. The slot count `M` (the ticks) is runtime state, passed to `init`.

```zig
pub fn TimingWheel(comptime blockSize: comptime_int, comptime readyBlocks: comptime_int) type {
    // parameter validation via @compileError
    return struct {
        const Self = @This();
        pub const N = blockSize;
        pub const L = readyBlocks;
        pub const MAX_TICKS: u32 = 0x10_0000;
        // structures below, sized by Self.N and Self.L
    };
}
```

(Parameters are lower-case so the re-exported `N`/`L` declarations do not shadow them.)

Usage: `const W = TimingWheel(4, 8); const w = try W.init(allocator, 16);` where the second argument is `M`, validated
by `init` as a power of two in `1..MAX_TICKS` (`error.InvalidTicks` otherwise).

## Slot Ring.

This is an array with a ring cursor and a length that never changes. The length is set at `init` by the runtime value M,
which must be a power of two. Each slot contains "stripes" (see below)

```zig
slots: []*Stripe,
ticks: u32,
cursor: u32,
```

## Stripe.

It has the following structure

```zig
const Stripe = struct {
    blocks: []*Block, // Array of pointers to blocks.
    len: u32 ,        // Current length of the array.

    last: i32,      // Last inserted index.
};
```

## Block.

This is a linked list with peculiarities. It is parameterized by the number N, which must be a power of two and must not
exceed 2^20 (in practice, we will not use anything above 16384 = 2^14).

```zig
const Block = struct {
    ids: [Self.N]u64,
    prevs: [Self.N]i32, // These are CROSS-BLOCK indices. They may point not only to elements inside the block, but also to other blocks.
    nexts: [Self.N]i32,
    len: i32,
    index: i32, // Index in the block pool (see below). -1 for blocks from the allocator.
};
```

## Block Pools.

We need a new structure that stores an array of `Block`, an array `nexts` where the i-th position holds the index of the next free
slot, and an index `first` pointing to the first free `Block` (it equals -1 if no blocks are left).

It is parameterized by the number `L`, which must be a positive i32 number that is a power of two.

```zig
const BlocksPool = struct {
    blocks: [Self.L]Block,
    nexts:  [Self.L]i32, // initially filled with [1, 2, ..., L-1, -1]
    free: i32,
};
```

### Operations:

- Take a block from the pool. If `free < 0`, return failure/apply the allocator. Otherwise, return a pointer to the block
  corresponding to the element with index `free`. Before handing it out, the value of `free` must be changed to `nexts[free]`.
- Return a block to the pool. For blocks with a negative `index`, of course, registering the return is not needed. We add
  the returned block to the BEGINNING of the list. I.e. we set `nexts[block.index] = free` and `free = block.index`.

I suggest implementing the work with the allocator inside BlocksPool itself, so that it falls back to allocation via the
allocator and to freeing via allocator.free inside these two methods.

### Take a block.

If

# Operations on the Wheel.

All operations are performed on an instantiated `TimingWheel`; `Stripe` and `Block` are private to the returned type.

## Add a new value to the front of the wheel.

Goal: insert a value into one of the blocks of the current slot. Return the position of the value using the following encoding:

1. The value of cursor truncated modulo M (i.e. `&(M-1)`).
2. The block index in the slot.
3. The index within the slot.

It is best to encode this into a u64. For 2-3 the lower part is enough; for 1 we reserve the entire upper part.
2-3 are encoded naturally when we always keep the block index in mind when inserting an element.

This is done on the `TimingWheel` itself:

1. Take the current stripe (by the cursor).
2. Take the last block in the stripe (index `Stripe.len - 1`).
3. If `Block.len` of the block has reached `N`, then we increase `Stripe.len` by 1.
    1. If `Stripe.len` has reached `Stripe.blocks.len`, then we REALLOCATE this slice, taking the new length one greater. This
       is justified, since in steady-state operation this item will be hit very rarely.
    2. Request a new block from the block pool and insert a pointer to it into the `Stripe.blocks` array.
4. Otherwise, add the new value to the block at the current block length. Do not forget to add the nexts and prevs indices,
   using `Stripe.last`.

## Delete a value by its index.

To the form described above, add a "number of occupied elements" to the block.

1. We find the slot index, the block index and the index within the block.
2. We remove the pointers to the deleted element from the previous and next elements, as is done in linked lists.
3. We decrease the number of occupied by 1. If it reaches zero, we immediately return the block to the pool. In parallel, we
   replace the reference in blocks with null.

## Wheel Shift.

I suggest performing the wheel shift with a method having a signature similar to this one:

```zig
pub fn shift(self: *Self, placeholder: []u64) error{OutOfMemory}!ShiftResult
```

What is required of it:

- Find all non-deleted elements in the linked list and write them into the provided `items_placeholder`.
- The block has a count of elements. If the provided `placeholder` is not enough, we do a realloc taking into account
  the volume required for this block. There is no need to check all blocks in advance, since in steady-state operation the size
  stabilizes and will change very rarely.
- This "placeholder" is suggested to be reused for these shifts. The response returns the old or reallocated
  buffer + the number of elements.
- After the non-deleted elements are collected, all current blocks of the stripe are returned to the buffer pool. Possibly, except
  for the very first one. We need to analyze which strategy will be more convenient for encoding.