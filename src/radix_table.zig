const std = @import("std");
const log = std.log.scoped(.@"olib-collections");
const Allocator = std.mem.Allocator;

const RadixTable = @This();

pub const Node = struct {
    bytes: []const u8,
    managed: bool,
    bit_len: usize,
    start_bit: u8,
    start_byte: usize = 0,
    parent: ?usize = null,
    zero: ?usize = null,
    one: ?usize = null,

    pub fn deinit(self: *Node, mem: Allocator) void {
        if (self.managed) mem.free(self.bytes);
    }
};

rw: @import("./mutability_lock.zig") = .{},
nodes: std.ArrayList(Node) = .empty,
root: usize = 0,

pub fn deinit(self: *@This(), mem: Allocator) void {
    self.rw.lockMut();
    defer self.rw.unlockMut();
    for (self.nodes.items) |*node| node.deinit(mem);
    self.nodes.deinit(mem);
}

pub fn getOrPut(self: *RadixTable, mem: Allocator, slice: anytype) Allocator.Error!usize {
    const input: []const u8 = switch (@typeInfo(@TypeOf(slice))) {
        .pointer => |p| switch (p.size) {
            .one, .slice => std.mem.sliceAsBytes(slice),
            .many, .c => std.mem.sliceAsBytes(std.mem.span(slice))
        },
        .array => std.mem.sliceAsBytes(&slice),
        else => @compileError(@typeName(@TypeOf(slice)) ++ " is not a slice.")
    };

    self.rw.lock();
    if (self.nodes.items.len == 0) {
        if (self.rw.toMut()) {
            defer self.rw.unlockMut();
            const bytes = try mem.alloc(u8, input.len);
            errdefer mem.free(bytes);
            @memcpy(bytes, input);
            try self.nodes.append(mem, .{
                .bytes = bytes,
                .bit_len = bytes.len * 8,
                .start_bit = 0x80,
                .managed = true
            });
            return self.root;
        }
    }

    var root_pos: usize = self.root;
    var parent_pos: ?usize = null;
    var parent_leaf_one: bool = false;
    var input_start_byte: usize = 0;
    const input_bit_len = input.len * 8;
    outer: while (true) {
        const root: Node = self.nodes.items[root_pos];
        const input_len: usize = input_bit_len - (input_start_byte * 8);
        var bit_len: usize = @min(root.bit_len, input_len);
        var byte: usize = 0;
        var bit: u8 = root.start_bit;

        const order: std.math.Order = inner: while (bit_len != 0) {
            const root_byte = root.bytes[root.start_byte + byte];
            const input_byte = input[input_start_byte + byte];
            if (bit == 0x80 and bit_len >= 8 and root_byte == input_byte) { bit_len -= 8; byte += 1; continue :inner; }
            while (bit_len != 0) {
                const cmp = std.math.order(root_byte & bit, input_byte & bit);
                if (cmp != .eq) break :inner cmp;
                bit >>= 1; bit_len -= 1;
                if (bit == 0) { bit = 0x80; byte += 1; continue :inner; }
            }
        } else if (input_len > root.bit_len) { // Root is prefix of input
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
                if (!self.rw.toMut()) {
                    self.rw.lock();
                    root_pos = self.root; parent_pos = null; input_start_byte = 0;
                    continue :outer;
                }
                defer self.rw.unlockMut();

                const byte_len = input.len - byte;
                const bytes = try mem.alloc(u8, byte_len);
                errdefer mem.free(bytes);
                @memcpy(bytes, input[(input_start_byte + byte)..]);
                const node = try self.nodes.addOne(mem);
                node.* = .{
                    .bytes = bytes,
                    .managed = true,
                    .bit_len = (bytes.len * 8) - @clz(bit),
                    .start_bit = bit
                };
                const new = self.nodes.items.len - 1;
                node.parent = root_pos;
                if (dir) self.nodes.items[root_pos].one = new else self.nodes.items[root_pos].zero = new;
                return new;
            }
        } else if (input_len < root.bit_len) { // Input is prefix of root
            // Test: Adding Prefix
            if (!self.rw.toMut()) {
                self.rw.lock();
                root_pos = self.root; parent_pos = null; input_start_byte = 0;
                continue :outer;
            }
            defer self.rw.unlockMut();

            const dir = (root.bytes[root.start_byte + byte] & bit) != 0;
            const bytes = root.bytes[root.start_byte..byte];
            const node = try self.nodes.addOne(mem);
            node.* = .{
                .bytes = bytes,
                .managed = false,
                .bit_len = (bytes.len * 8) - @clz(root.start_bit) + @clz(bit),
                .start_bit = root.start_bit,
                .start_byte = root.start_byte,
                .zero = if (!dir) root_pos else null,
                .one = if (dir) root_pos else null
            };
            const new = self.nodes.items.len - 1;

            self.nodes.items[root_pos].parent = new;
            self.nodes.items[root_pos].start_byte = byte;
            self.nodes.items[root_pos].start_bit = bit;
            self.nodes.items[root_pos].bit_len -= node.bit_len;

            if (parent_pos) |p| {
                node.parent = p;
                if (parent_leaf_one) self.nodes.items[p].one = new else self.nodes.items[p].zero = new;
            } else self.root = new;
            return new;
        } else { // Exact match
            self.rw.unlock();
            return root_pos;
        };

        // Test: Common Prefix
        // Common prefix between root and input
        if (!self.rw.toMut()) {
            self.rw.lock();
            root_pos = self.root; parent_pos = null; input_start_byte = 0;
            continue :outer;
        }
        defer self.rw.unlockMut();

        std.debug.assert(bit != 0);

        const remaining_bytes = input.len - input_start_byte - byte;
        const bytes = try mem.alloc(u8, remaining_bytes);
        errdefer mem.free(bytes);
        @memcpy(bytes, input[(input_start_byte + byte)..]);

        const node = try self.nodes.addOne(mem);
        node.* = .{
            .bytes = bytes,
            .managed = true,
            .bit_len = (remaining_bytes * 8) - @clz(bit),
            .start_bit = bit
        };
        const pos = self.nodes.items.len - 1;

        const prefix = root.bytes[root.start_byte..];
        const pivot = try self.nodes.addOne(mem);
        pivot.* = .{
            .bytes = prefix,
            .managed = false,
            .bit_len = ((byte * 8) + @clz(bit)) - @clz(root.start_bit),
            .start_bit = root.start_bit,
            .zero = if (order == .lt) root_pos else pos,
            .one = if (order == .gt) root_pos else pos
        };
        const piv_pos = self.nodes.items.len - 1;

        self.nodes.items[pos].parent = piv_pos;
        self.nodes.items[root_pos].parent = piv_pos;
        self.nodes.items[root_pos].start_byte += pivot.bit_len / 8;
        self.nodes.items[root_pos].start_bit = bit;
        self.nodes.items[root_pos].bit_len -= pivot.bit_len;

        if (parent_pos) |p| {
            pivot.parent = p;
            if (parent_leaf_one) self.nodes.items[p].one = piv_pos else self.nodes.items[p].zero = piv_pos;
        } else self.root = piv_pos;
        return pos;
    }
}

const test_mem = std.testing.allocator;

test "RadixTable: Empty" {
    var table: RadixTable = .{};
    defer table.deinit(test_mem);

    try std.testing.expectEqual(0, try table.getOrPut(test_mem, "a"));
    try std.testing.expectEqual(1, table.nodes.items.len);
    try std.testing.expectEqual(0, table.root);
    try std.testing.expectEqualDeep(Node{
        .bytes = "a",
        .managed = true,
        .bit_len = 8,
        .start_bit = 0x80,
        .start_byte = 0,
        .parent = null,
        .zero = null,
        .one = null
    }, table.nodes.items[table.root]);
}

test "RadixTable: Common Prefix" {
    var table: RadixTable = .{};
    defer table.deinit(test_mem);

    _ = try table.getOrPut(test_mem, "abc");
    try std.testing.expectEqual(1, try table.getOrPut(test_mem, "a"));
    try std.testing.expectEqual(2, table.nodes.items.len);
    try std.testing.expectEqual(1, table.root);
    try std.testing.expectEqual(2, try table.getOrPut(test_mem, "be"));
    try std.testing.expectEqual(4, table.nodes.items.len);
    try std.testing.expectEqual(3, table.root);
    try std.testing.expectEqual(4, try table.getOrPut(test_mem, "abd"));
    try std.testing.expectEqual(6, table.nodes.items.len);
    try std.testing.expectEqual(3, table.root);

    try std.testing.expectEqualDeep(Node{
        .bytes = "abc",
        .managed = true,
        .bit_len = 3,
        .start_bit = 0b00000100,
        .start_byte = 2,
        .parent = 5,
        .zero = null,
        .one = null
    }, table.nodes.items[0]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "a",
        .managed = false,
        .bit_len = 2,
        .start_bit = 0b00000010,
        .start_byte = 0,
        .parent = 3,
        .zero = 5,
        .one = null
    }, table.nodes.items[1]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "be",
        .managed = true,
        .bit_len = 10,
        .start_bit = 0b00000010,
        .start_byte = 0,
        .parent = 3,
        .zero = null,
        .one = null
    }, table.nodes.items[2]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "a",
        .managed = false,
        .bit_len = 6,
        .start_bit = 0x80,
        .start_byte = 0,
        .parent = null,
        .zero = 1,
        .one = 2
    }, table.nodes.items[3]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "d",
        .managed = true,
        .bit_len = 3,
        .start_bit = 0b00000100,
        .start_byte = 0,
        .parent = 5,
        .zero = null,
        .one = null
    }, table.nodes.items[4]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "bc",
        .managed = false,
        .bit_len = 13,
        .start_bit = 0x80,
        .start_byte = 0,
        .parent = 1,
        .zero = 0,
        .one = 4
    }, table.nodes.items[5]);
}

test "RadixTable: Adding Branch" {
    var table: RadixTable = .{};
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
        .start_bit = 0x80,
        .start_byte = 0,
        .parent = null,
        .zero = 1,
        .one = 2
    }, table.nodes.items[0]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "b",
        .managed = true,
        .bit_len = 8,
        .start_bit = 0x80,
        .start_byte = 0,
        .parent = 0,
        .zero = null,
        .one = null
    }, table.nodes.items[1]);
    try std.testing.expectEqualDeep(Node{
        .bytes = &[1]u8{ 0x80 },
        .managed = true,
        .bit_len = 8,
        .start_bit = 0x80,
        .start_byte = 0,
        .parent = 0,
        .zero = null,
        .one = null
    }, table.nodes.items[2]);
}

test "RadixTable: Adding Prefix" {
    var table: RadixTable = .{};
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
        .start_bit = 0x80,
        .start_byte = 2,
        .parent = 1,
        .zero = null,
        .one = null
    }, table.nodes.items[0]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "ab",
        .managed = false,
        .bit_len = 8,
        .start_bit = 0x80,
        .start_byte = 1,
        .parent = 2,
        .zero = 0,
        .one = null
    }, table.nodes.items[1]);
    try std.testing.expectEqualDeep(Node{
        .bytes = "a",
        .managed = false,
        .bit_len = 8,
        .start_bit = 0x80,
        .start_byte = 0,
        .parent = null,
        .zero = 1,
        .one = null
    }, table.nodes.items[2]);
}
