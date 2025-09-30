const std = @import("std");
const log = std.log.scoped(.@"olib-collections");
const Allocator = std.mem.Allocator;

const byte_align: std.mem.Alignment = std.mem.Alignment.fromByteUnits(@alignOf(u8));

pub const Node = struct {
    bytes: []const u8,
    managed: bool,
    bit_len: usize,
    start_bit: u8 = 0,
    start_byte: usize = 0,
    zero: ?usize = null,
    one: ?usize = null,

    pub fn deinit(self: *Node, mem: Allocator) void {
        if (self.managed) mem.free(self.bytes);
    }
};

mut: std.Thread.RwLock = .{},
snapshot: u16 = 0,
nodes: std.ArrayList(Node) = .empty,
root: usize = 0,

pub fn deinit(self: *@This(), mem: Allocator) void {
    self.mut.lock();
    defer self.mut.unlock();
    for (self.nodes.items) |*node| node.deinit(mem);
    self.nodes.deinit(mem);
}

pub fn getOrPut(self: *@This(), mem: Allocator, input: []const u8) Allocator.Error!usize {
    self.mut.lockShared();
    if (self.nodes.items.len == 0) {
        const snap = self.snapshot;
        self.mut.unlockShared(); self.mut.lock();
        if (snap == self.snapshot) {
            defer self.mut.unlock();
            const bytes = try mem.alloc(u8, input.len);
            errdefer mem.free(bytes);
            @memcpy(bytes, input);
            try self.nodes.append(mem, .{
                .bytes = bytes,
                .bit_len = bytes.len * 8,
                .managed = true
            });
            self.snapshot +%= 1;
            return self.root;
        } else { self.mut.unlock(); self.mut.lockShared(); }
    }

    var root_pos: usize = self.root;
    var parent_pos: ?usize = null;
    var parent_leaf_one: bool = false;
    var input_start_byte: usize = 0;
    const input_bit_len = input.len * 8;
    outer: while (true) {
        const root: Node = self.nodes.items[root_pos];
        const root_len: usize = root.bit_len - root.start_bit;
        const input_len: usize = input_bit_len - (input_start_byte * 8);
        const min: usize = @min(root_len, input_len);
        var byte: usize = 0;
        var bit_len: usize = 0;
        var bit: u8 = 0x80;

        const order: std.math.Order = inner: while (bit_len < min) {
            const root_byte = root.bytes[root.start_byte + byte];
            const input_byte = input[input_start_byte + byte];
            if (root_byte == input_byte) { bit_len += 8; byte += 1; continue :inner; }
            while (bit != 0) {
                const cmp = std.math.order(root_byte & bit, input_byte & bit);
                if (cmp != .eq) break :inner cmp;
                bit >>= 1; bit_len += 1;
            }
            bit = 0x80; byte += 1;
        } else if (input_len > root_len) { // Root is prefix of input
            const dir = (input[input_start_byte + byte] & bit) != 0;
            const branch = if (dir) root.one else root.zero;
            if (branch) |b| {
                // Test: Branching
                input_start_byte += byte;
                parent_pos = root_pos;
                parent_leaf_one = dir;
                root_pos = b;
                continue :outer;
            } else {
                // Test: Adding Branch
                const snap = self.snapshot;
                self.mut.unlockShared();
                self.mut.lock();
                errdefer self.mut.unlock();
                if (self.snapshot != snap) {
                    self.mut.unlock(); self.mut.lockShared();
                    root_pos = self.root; parent_pos = null; input_start_byte = 0;
                    continue :outer;
                }

                const byte_len = input.len - byte;
                const bytes = try mem.alloc(u8, byte_len);
                errdefer mem.free(bytes);
                @memcpy(bytes, input[(input_start_byte + byte)..]);
                const node = try self.nodes.addOne(mem);
                node.* = .{
                    .bytes = bytes,
                    .managed = true,
                    .bit_len = (bytes.len * 8) - @clz(bit),
                    .start_bit = @clz(bit)
                };

                const new = self.nodes.items.len - 1;
                if (dir) self.nodes.items[root_pos].one = new else self.nodes.items[root_pos].zero = new;

                self.snapshot +%= 1;
                self.mut.unlock();
                return new;
            }
        } else if (input_len < root_len) { // Input is prefix of root
            // Test: Adding Prefix
            const snap = self.snapshot;
            self.mut.unlockShared();
            self.mut.lock();
            errdefer self.mut.unlock();
            if (self.snapshot != snap) {
                self.mut.unlock(); self.mut.lockShared();
                root_pos = self.root; parent_pos = null; input_start_byte = 0;
                continue :outer;
            }

            const dir = (root.bytes[root.start_byte + byte] & bit) != 0;
            const bytes = root.bytes[root.start_byte..byte];
            const node = try self.nodes.addOne(mem);
            node.* = .{
                .bytes = bytes,
                .managed = false,
                .bit_len = (bytes.len * 8) - root.start_bit + @clz(bit),
                .start_bit = root.start_bit,
                .start_byte = root.start_byte,
                .zero = if (!dir) root_pos else null,
                .one = if (dir) root_pos else null
            };
            const new = self.nodes.items.len - 1;

            self.nodes.items[root_pos].start_byte = byte;
            self.nodes.items[root_pos].start_bit = @clz(bit);
            self.nodes.items[root_pos].bit_len -= node.bit_len;

            if (parent_pos) |p| {
                if (parent_leaf_one) self.nodes.items[p].one = new else self.nodes.items[p].zero = new;
            } else self.root = new;

            self.snapshot +%= 1;
            self.mut.unlock();
            return new;
        } else { // Exact match
            self.mut.unlockShared();
            return root_pos;
        };

        // Test: Common Prefix
        // Common prefix between root and input
        const snap = self.snapshot;
        self.mut.unlockShared();
        self.mut.lock();
        errdefer self.mut.unlock();
        if (self.snapshot != snap) {
            self.mut.unlock(); self.mut.lockShared();
            root_pos = self.root; parent_pos = null; input_start_byte = 0;
            continue :outer;
        }

        const byte_len = input.len - byte;
        const bytes = try mem.alloc(u8, byte_len);
        errdefer mem.free(bytes);
        @memcpy(bytes, input[(input_start_byte + byte)..]);

        const node = try self.nodes.addOne(mem);
        node.* = .{
            .bytes = bytes,
            .managed = true,
            .bit_len = (bytes.len * 8) - @clz(bit),
            .start_bit = @clz(bit)
        };
        const pos = self.nodes.items.len - 1;

        const prefix = root.bytes[root.start_byte..(byte + 1)];
        const pivot = try self.nodes.addOne(mem);
        pivot.* = .{
            .bytes = prefix,
            .managed = false,
            .bit_len = (byte * 8) + @clz(bit) - root.start_bit,
            .start_bit = root.start_bit,
            .start_byte = root.start_byte,
            .zero = if (order == .lt) root_pos else pos,
            .one = if (order == .gt) root_pos else pos
        };
        const new = self.nodes.items.len - 1;

        self.nodes.items[root_pos].start_byte = byte;
        self.nodes.items[root_pos].start_bit = @clz(bit);
        self.nodes.items[root_pos].bit_len -= pivot.bit_len;

        if (parent_pos) |p| {
            if (parent_leaf_one) self.nodes.items[p].one = new else self.nodes.items[p].zero = new;
        } else self.root = new;

        self.snapshot +%= 1;
        self.mut.unlock();
        return pos;
    }
}

const test_mem = std.testing.allocator;

test "RadixTable: Empty" {
    var table: @This() = .{};
    defer table.deinit(test_mem);

    try std.testing.expectEqual(0, try table.getOrPut(test_mem, "a"));
    try std.testing.expectEqual(1, table.nodes.items.len);
    try std.testing.expectEqual(0, table.root);
    try std.testing.expectEqualDeep(Node{
        .bytes = "a",
        .managed = true,
        .bit_len = 8,
        .start_bit = 0,
        .start_byte = 0,
        .zero = null,
        .one = null
    }, table.nodes.items[table.root]);
}

test "RadixTable: Common Prefix" {
    var table: @This() = .{};
    defer table.deinit(test_mem);

    _ = try table.getOrPut(test_mem, "a");
    try std.testing.expectEqual(1, try table.getOrPut(test_mem, "b"));
    try std.testing.expectEqual(3, table.nodes.items.len);
    try std.testing.expectEqual(2, table.root);
    try std.testing.expectEqualDeep(Node{
        .bytes = "a",
        .managed = true,
        .bit_len = 2,
        .start_bit = 6,
        .start_byte = 0,
        .zero = null,
        .one = null
    }, table.nodes.items[0]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "b",
        .managed = true,
        .bit_len = 2,
        .start_bit = 6,
        .start_byte = 0,
        .zero = null,
        .one = null
    }, table.nodes.items[1]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "a",
        .managed = false,
        .bit_len = 6,
        .start_bit = 0,
        .start_byte = 0,
        .zero = 0,
        .one = 1
    }, table.nodes.items[2]);
}

test "RadixTable: Adding Branch" {
    var table: @This() = .{};
    defer table.deinit(test_mem);

    try std.testing.expectEqual(0, try table.getOrPut(test_mem, "a"));
    try std.testing.expectEqual(1, try table.getOrPut(test_mem, "ab"));
    try std.testing.expectEqual(2, table.nodes.items.len);
    try std.testing.expectEqual(0, table.root);
    try std.testing.expectEqual(2, try table.getOrPut(test_mem, &[2]u8{ 0x61, 0x80 }));
    try std.testing.expectEqual(3, table.nodes.items.len);
    try std.testing.expectEqual(0, table.root);
    try std.testing.expectEqualDeep(Node{
        .bytes = "a",
        .managed = true,
        .bit_len = 8,
        .start_bit = 0,
        .start_byte = 0,
        .zero = 1,
        .one = 2
    }, table.nodes.items[0]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "b",
        .managed = true,
        .bit_len = 8,
        .start_bit = 0,
        .start_byte = 0,
        .zero = null,
        .one = null
    }, table.nodes.items[1]);
    try std.testing.expectEqualDeep(Node{
        .bytes = &[1]u8{ 0x80 },
        .managed = true,
        .bit_len = 8,
        .start_bit = 0,
        .start_byte = 0,
        .zero = null,
        .one = null
    }, table.nodes.items[2]);
}

test "RadixTable: Adding Prefix" {
    var table: @This() = .{};
    defer table.deinit(test_mem);

    try std.testing.expectEqual(0, try table.getOrPut(test_mem, "abc"));
    try std.testing.expectEqual(1, try table.getOrPut(test_mem, "ab"));
    try std.testing.expectEqual(2, table.nodes.items.len);
    try std.testing.expectEqual(1, table.root);
    try std.testing.expectEqual(2, try table.getOrPut(test_mem, "a"));
    try std.testing.expectEqual(3, table.nodes.items.len);
    try std.testing.expectEqual(2, table.root);
    try std.testing.expectEqualDeep(Node{
        .bytes = "abc",
        .managed = true,
        .bit_len = 8,
        .start_bit = 0,
        .start_byte = 2,
        .zero = null,
        .one = null
    }, table.nodes.items[0]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "ab",
        .managed = false,
        .bit_len = 8,
        .start_bit = 0,
        .start_byte = 1,
        .zero = 0,
        .one = null
    }, table.nodes.items[1]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "a",
        .managed = false,
        .bit_len = 8,
        .start_bit = 0,
        .start_byte = 0,
        .zero = 1,
        .one = null
    }, table.nodes.items[2]);
}
