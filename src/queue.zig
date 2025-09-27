const std = @import("std");
const Mem = std.mem.Allocator;

pub fn UQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            val: T = undefined,
            next: ?*Node = null
        };

        head: ?*Node = null,
        last: ?*Node = null,

        pub fn deinit(self: *Self, mem: Mem) void {
            self.clear(mem);
        }

        pub fn push(self: *Self, mem: Mem, val: T) !void {
            const n: *Node = try mem.create(Node);
            n.* = .{ .val = val };

            var prev: ?*Node = null;
            while (true) {
                prev = @atomicLoad(?*Node, &self.last, .acquire);
                if (@cmpxchgWeak(?*Node, &self.last, prev, n, .acq_rel, .acquire) == null) {
                    if (prev) |p| @atomicStore(?*Node, &(p.next), n, .release);
                    break;
                }
            }

            _ = @cmpxchgWeak(?*Node, &self.head, null, prev, .acq_rel, .acquire);
        }

        pub fn pop(self: *Self, mem: Mem) ?T {
            var prev: ?*Node = null;
            while (true) {
                prev = @atomicLoad(?*Node, &self.head, .acquire);
                if (prev == null) break;
                if (@cmpxchgWeak(?*Node, &self.head, prev, prev.?.next, .acq_rel, .acquire) == null) break;
            }

            _ = @cmpxchgWeak(?*Node, &self.last, prev, null, .acq_rel, .acquire);

            if (prev) |p| {
                const val = p.val;
                mem.destroy(p);
                return val;
            } return null;
        }

        pub fn clear(self: *Self, mem: Mem) void {
            var last: ?T = self.pop(mem);
            while (last != null) last = self.pop(mem);
        }
    };
}

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        inner: UQueue(T) = .{},
        mem: Mem = undefined,

        pub fn init(self: *Self, mem: Mem) void {
            self.mem = mem;
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit(self.mem);
        }

        pub fn push(self: *Self, val: T) !void {
            try self.inner.push(self.mem, val);
        }

        pub fn pop(self: *Self) ?T {
            return self.inner.pop(self.mem);
        }

        pub fn clear(self: *Self) void {
            self.inner.clear(self.mem);
        }
    };
}

const expect = std.testing.expect;

test "Queue" {
    var queue: Queue(u8) = .{ .mem = std.testing.allocator };

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);
    try queue.push(4);
    try queue.push(5);
    try expect(queue.pop() == 1);
    try expect(queue.pop() == 2);
    try expect(queue.pop() == 3);
    try expect(queue.pop() == 4);
    try expect(queue.pop() == 5);
    try expect(queue.pop() == null);
}

