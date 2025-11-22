const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = error { OutOfMemory };

pub fn _Queue(comptime T: type) type { return struct {
    const Queue = @This();
    const pool = @import("./pool.zig").Pool(@sizeOf(T));

    pub const Node = @import("./node.zig")._Node(T);

    head: ?*Node,
    last: ?*Node,

    pub fn deinit(self: *Queue, mem: Allocator) void {
        pool.instances -|= 1;
        if (pool.instances == 0) {
            while (Node.pop(&(self.head), &(self.last))) |node| mem.destroy(node);
            pool.clear(mem);
        } else self.clear();
        self.* = undefined;
    }

    pub fn init() Queue {
        pool.instances += 1;
        return .{ .head = null, .last = null };
    }

    pub fn push(self: *Queue, mem: Allocator, val: T) OOM!void {
        const node: *Node = try pool.acquire(T, mem);
        node.* = .{ .val = val };
        Node.snoc(&(self.head), &(self.last), node);
    }

    pub fn pop(self: *Queue) ?T {
        if (Node.pop(&(self.head), &(self.last))) |prev| {
            const val = prev.val;
            pool.release(T, prev);
            return val;
        } else return null;
    }

    pub fn clear(self: *Queue) void {
        while (Node.pop(&(self.head), &(self.last))) |node| pool.release(T, node);
    }
};}

test "Queue" {
    const mem = std.testing.allocator;
    var queue: _Queue(u8) = .init();
    defer queue.deinit(mem);

    try queue.push(mem, 1);
    try queue.push(mem, 2);
    try queue.push(mem, 3);
    try std.testing.expectEqual(1, queue.pop());
    try std.testing.expectEqual(2, queue.pop());
    try queue.push(mem, 4);
    try queue.push(mem, 5);
    try std.testing.expectEqual(3, queue.pop());
    try std.testing.expectEqual(4, queue.pop());
    try std.testing.expectEqual(5, queue.pop());
    try std.testing.expectEqual(null, queue.pop());
}

