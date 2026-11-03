const std = @import("std");

fn NodeType(comptime K: type, comptime V: type, comptime DEGREE: usize) type {
    return struct {
        is_leaf: bool,
        keys: [2 * DEGREE - 1]K,
        children: [2 * DEGREE]*NodeType(K, V, DEGREE),
        values: [2 * DEGREE - 1]?V,
        n: usize,
        next: ?*NodeType(K, V, DEGREE),
    };
}

/// Returns a robust, generic B+ tree type for the given key/value type and degree.
/// Usage:
///   var tree = BPlusTree(i32, i32, 4).init(allocator);       // uses MemoryPool (faster)
///   var tree = BPlusTree(i32, i32, 4).initAlloc(allocator);  // uses allocator directly
pub fn BPlusTree(comptime K: type, comptime V: type, comptime DEGREE: usize) type {
    return struct {
        pub const Error = error{
            OutOfMemory,
            NotFound,
            DuplicateKey,
        };

        pub const Node = NodeType(K, V, DEGREE);
        const NodePtr = *Node;
        const Self = @This();

        pub const Strategy = enum {
            pool,
            direct,
        };

        root: ?NodePtr,
        mode: Strategy,
        pool: std.heap.MemoryPool(Node),
        allocator: std.mem.Allocator,

        /// Returns an iterator for in-order traversal.
        pub fn iter(self: *Self) Iterator {
            var node = self.root;
            while (node != null and !node.?.is_leaf) {
                node = node.?.children[0];
            }
            return Iterator{
                .current = node,
                .idx = 0,
            };
        }

        /// Initialize a new B+ tree with the given allocator, using a MemoryPool for node allocation (faster).
        pub fn init(gpa: std.mem.Allocator) Self {
            return Self{
                .root = null,
                .mode = .pool,
                .pool = .empty,
                .allocator = gpa,
            };
        }

        /// Initialize a new B+ tree using the allocator directly (no MemoryPool overhead).
        pub fn initAlloc(gpa: std.mem.Allocator) Self {
            return Self{
                .root = null,
                .mode = .direct,
                .pool = .empty,
                .allocator = gpa,
            };
        }

        /// Free all memory used by the tree and its nodes.
        pub fn deinit(self: *Self) void {
            switch (self.mode) {
                .pool => self.pool.deinit(self.allocator),
                .direct => if (self.root) |r| self.freeNode(r),
            }
            self.* = undefined;
        }

        /// Recursively free a node and its children.
        fn freeNode(self: *Self, node: NodePtr) void {
            if (!node.is_leaf) {
                for (node.children[0 .. node.n + 1]) |child| {
                    self.freeNode(child);
                }
            }
            switch (self.mode) {
                .pool => self.pool.destroy(node),
                .direct => self.allocator.destroy(node),
            }
        }

        /// Search for a key in the tree. Returns the value if found, else null.
        pub fn search(self: *Self, key: K) ?V {
            if (self.root) |r| {
                return self.searchNode(r, key);
            }
            return null;
        }

        /// Internal recursive search helper.
        fn searchNode(self: *Self, node: NodePtr, key: K) ?V {
            var i: usize = 0;
            while (i < node.n and key > node.keys[i]) : (i += 1) {}
            if (node.is_leaf) {
                if (i < node.n and node.keys[i] == key) {
                    return node.values[i];
                }
                return null;
            } else {
                if (i < node.n and key == node.keys[i]) {
                    return self.searchNode(node.children[i + 1], key);
                } else {
                    return self.searchNode(node.children[i], key);
                }
            }
        }

        /// Insert a key-value pair into the tree. Returns error on duplicate key or OOM.
        pub fn insert(self: *Self, key: K, value: V) Error!void {
            if (self.root == null) {
                self.root = try self.createNode(true);
                self.root.?.keys[0] = key;
                self.root.?.values[0] = value;
                self.root.?.n = 1;
                return;
            }
            if (self.root.?.n == 2 * DEGREE - 1) {
                var s = try self.createNode(false);
                s.children[0] = self.root.?;
                try self.splitChild(s, 0, self.root.?);
                self.root = s;
            }
            try self.insertNonFull(self.root.?, key, value);
        }

        /// Insert a key-value pair into a node that is not full.
        fn insertNonFull(self: *Self, node: NodePtr, key: K, value: V) Error!void {
            var i = node.n;
            if (node.is_leaf) {
                while (i > 0 and key < node.keys[i - 1]) : (i -= 1) {
                    node.keys[i] = node.keys[i - 1];
                    node.values[i] = node.values[i - 1];
                }
                if (i > 0 and node.keys[i - 1] == key) return Error.DuplicateKey;
                node.keys[i] = key;
                node.values[i] = value;
                node.n += 1;
            } else {
                while (i > 0 and key < node.keys[i - 1]) : (i -= 1) {}
                if (node.children[i].n == 2 * DEGREE - 1) {
                    try self.splitChild(node, i, node.children[i]);
                    if (key >= node.keys[i]) i += 1;
                }
                try self.insertNonFull(node.children[i], key, value);
            }
        }

        /// Split a full child node and update the parent.
        /// Parent must never be a leaf in a B+ tree.
        fn splitChild(self: *Self, parent: NodePtr, i: usize, y: NodePtr) Error!void {
            std.debug.assert(!parent.is_leaf);
            var z = try self.createNode(y.is_leaf);
            var j: usize = 0;
            if (y.is_leaf) {
                z.n = DEGREE;
                while (j < DEGREE) : (j += 1) {
                    z.keys[j] = y.keys[j + DEGREE - 1];
                    z.values[j] = y.values[j + DEGREE - 1];
                }
                y.n = DEGREE - 1;
                j = parent.n;
                while (j > i) : (j -= 1) {
                    parent.children[j + 1] = parent.children[j];
                    parent.keys[j] = parent.keys[j - 1];
                }
                parent.children[i + 1] = z;
                parent.keys[i] = z.keys[0];
                parent.n += 1;
                z.next = y.next;
                y.next = z;
            } else {
                z.n = DEGREE - 1;
                while (j < DEGREE - 1) : (j += 1) {
                    z.keys[j] = y.keys[j + DEGREE];
                }
                j = 0;
                while (j < DEGREE) : (j += 1) {
                    z.children[j] = y.children[j + DEGREE];
                }
                y.n = DEGREE - 1;
                j = parent.n;
                while (j > i) : (j -= 1) {
                    parent.children[j + 1] = parent.children[j];
                    parent.keys[j] = parent.keys[j - 1];
                }
                parent.children[i + 1] = z;
                parent.keys[i] = y.keys[DEGREE - 1];
                parent.n += 1;
            }
        }

        /// Allocate and initialize a new node (leaf or internal).
        fn createNode(self: *Self, is_leaf: bool) !NodePtr {
            const node = switch (self.mode) {
                .pool => try self.pool.create(self.allocator),
                .direct => try self.allocator.create(Node),
            };
            node.* = Node{
                .is_leaf = is_leaf,
                .keys = undefined,
                .children = undefined,
                .values = undefined,
                .n = 0,
                .next = null,
            };
            return node;
        }

        /// Remove a key from the tree. Returns error if not found.
        pub fn remove(self: *Self, key: K) Error!void {
            if (self.root == null) return Error.NotFound;
            try self.removeNode(self.root.?, key);
            if (self.root.?.n == 0 and !self.root.?.is_leaf) {
                self.root = self.root.?.children[0];
            }
            if (self.root.?.n == 0 and self.root.?.is_leaf) {
                self.freeNode(self.root.?);
                self.root = null;
            }
        }

        /// Internal recursive remove helper.
        fn removeNode(self: *Self, node: NodePtr, key: K) Error!void {
            var i: usize = 0;
            while (i < node.n and key > node.keys[i]) : (i += 1) {}
            if (node.is_leaf) {
                if (i < node.n and node.keys[i] == key) {
                    var j = i;
                    while (j + 1 < node.n) : (j += 1) {
                        node.keys[j] = node.keys[j + 1];
                        node.values[j] = node.values[j + 1];
                    }
                    node.n -= 1;
                    return;
                } else {
                    return Error.NotFound;
                }
            } else {
                var child = node.children[i];
                if (child.n == DEGREE - 1) {
                    if (i > 0 and node.children[i - 1].n >= DEGREE) {
                        self.borrowFromPrev(i, node);
                    } else if (i < node.n and node.children[i + 1].n >= DEGREE) {
                        self.borrowFromNext(i, node);
                    } else {
                        if (i < node.n) {
                            self.merge(node, i);
                            child = node.children[i];
                        } else {
                            self.merge(node, i - 1);
                            child = node.children[i - 1];
                        }
                    }
                }
                return self.removeNode(child, key);
            }
        }

        fn borrowFromPrev(self: *Self, idx: usize, _parent: NodePtr) void {
            _ = self;
            const child = _parent.children[idx];
            const sibling = _parent.children[idx - 1];
            var j = child.n;
            while (j > 0) : (j -= 1) {
                child.keys[j] = child.keys[j - 1];
                child.values[j] = child.values[j - 1];
            }
            if (!child.is_leaf) {
                var k = child.n + 1;
                while (k > 0) : (k -= 1) {
                    child.children[k] = child.children[k - 1];
                }
                child.children[0] = sibling.children[sibling.n];
            }
            child.keys[0] = _parent.keys[idx - 1];
            if (child.is_leaf) child.values[0] = sibling.values[sibling.n - 1];
            _parent.keys[idx - 1] = sibling.keys[sibling.n - 1];
            child.n += 1;
            sibling.n -= 1;
        }

        fn borrowFromNext(self: *Self, idx: usize, _parent: NodePtr) void {
            _ = self;
            const child = _parent.children[idx];
            const sibling = _parent.children[idx + 1];
            child.keys[child.n] = _parent.keys[idx];
            if (child.is_leaf) child.values[child.n] = sibling.values[0];
            if (!child.is_leaf) {
                child.children[child.n + 1] = sibling.children[0];
            }
            _parent.keys[idx] = sibling.keys[0];
            var j: usize = 0;
            while (j + 1 < sibling.n) : (j += 1) {
                sibling.keys[j] = sibling.keys[j + 1];
                sibling.values[j] = sibling.values[j + 1];
            }
            if (!sibling.is_leaf) {
                var k: usize = 0;
                while (k + 1 <= sibling.n) : (k += 1) {
                    sibling.children[k] = sibling.children[k + 1];
                }
            }
            child.n += 1;
            sibling.n -= 1;
        }

        /// Merge child at idx with its right sibling
        fn merge(self: *Self, node: NodePtr, idx: usize) void {
            const child = node.children[idx];
            const sibling = node.children[idx + 1];
            if (!child.is_leaf) {
                child.keys[DEGREE - 1] = node.keys[idx];
            }
            var j: usize = 0;
            while (j < sibling.n) : (j += 1) {
                child.keys[child.n + j] = sibling.keys[j];
                if (child.is_leaf) child.values[child.n + j] = sibling.values[j];
            }
            if (!child.is_leaf) {
                var k: usize = 0;
                while (k <= sibling.n) : (k += 1) {
                    child.children[child.n + k] = sibling.children[k];
                }
            }
            if (child.is_leaf) {
                child.next = sibling.next;
            }
            child.n += sibling.n;
            var k = idx;
            while (k + 1 < node.n) : (k += 1) {
                node.keys[k] = node.keys[k + 1];
                node.children[k + 1] = node.children[k + 2];
            }
            node.n -= 1;
            self.freeNode(sibling);
        }

        /// Iterator for in-order traversal of the B+ tree.
        pub const Iterator = struct {
            pub const KV = struct { key: K, value: V };

            current: ?NodePtr,
            idx: usize,

            /// Returns the next key-value pair, or null if done.
            pub fn next(self: *Iterator) ?KV {
                if (self.current) |node| {
                    if (self.idx < node.n) {
                        defer self.idx += 1;
                        return .{
                            .key = node.keys[self.idx],
                            .value = node.values[self.idx].?,
                        };
                    } else if (node.next) |next_node| {
                        self.current = next_node;
                        self.idx = 0;
                        return self.next();
                    }
                }
                return null;
            }
        };
    };
}
