const std = @import("std");
const Mem = std.mem.Allocator;

pub fn Queue(comptime T: type) type { return struct {
    pub const Node = struct {
        val: T = undefined,
        next: ?*Node = null
    };

    fn pushNode(head: *(?*Node), last: *(?*Node), node: *Node) void {
        var prev: ?*Node = null;
        while (true) {
            prev = @atomicLoad(?*Node, last, .acquire);
            if (@cmpxchgWeak(?*Node, last, prev, node, .acq_rel, .acquire) == null) {
                if (prev) |p| @atomicStore(?*Node, &(p.next), node, .release);
                break;
            }
        }
        _ = @cmpxchgWeak(?*Node, head, null, prev, .acq_rel, .acquire);
    }

    fn popNode(head: *(?*Node), last: *(?*Node)) ?*Node {
        var prev: ?*Node = null;
        while (true) {
            prev = @atomicLoad(?*Node, head, .acquire);
            if (prev == null) break;
            if (@cmpxchgWeak(?*Node, head, prev, prev.?.next, .acq_rel, .acquire) == null) break;
        }

        _ = @cmpxchgWeak(?*Node, last, prev, null, .acq_rel, .acquire);

        return prev;
    }

    pub const Pool = struct {
        managed: bool = false,
        instances: usize = 0,
        head: ?*Node = null,
        last: ?*Node = null,

        pub fn deinit(self: *@This(), mem: Mem) void {
            self.clear(mem);
            self.managed = false;
        }

        pub fn clear(self: *@This(), mem: Mem) void {
            var last: ?*Node = popNode(&(self.head), &(self.last));
            while (last) |l| {
                mem.destroy(l);
                last = popNode(&(self.head), &(self.last));
            }
        }
    };

    pub var pool: Pool = .{};

    head: ?*Node = null,
    last: ?*Node = null,

    pub fn deinit(self: *@This(), mem: Mem) void {
        self.clear();
        pool.instances -= 1;
        if (!pool.managed and pool.instances == 0) pool.clear(mem);
    }

    pub fn init() @This() {
        pool.instances += 1;
        return .{};
    }

    pub fn push(self: *@This(), mem: Mem, val: T) Mem.Error!void {
        const node: *Node = if (popNode(&(pool.head), &(pool.last))) |n| b: {
            n.val = val;
            break :b n;
        } else b: {
            const n: *Node = try mem.create(Node);
            n.* = .{ .val = val };
            break :b n;
        };

        pushNode(&(self.head), &(self.last), node);
    }

    pub fn pop(self: *@This()) ?T {
        if (popNode(&(self.head), &(self.last))) |prev| {
            const val = prev.val;
            pushNode(&(pool.head), &(pool.last), prev);
            return val;
        } else return null;
    }

    pub fn clear(self: *@This()) void {
        var last: ?T = self.pop();
        while (last != null) last = self.pop();
    }
};}

const expect = std.testing.expect;

test "Queue" {
    const mem = std.testing.allocator;
    var queue: Queue(u8) = .init();
    defer queue.deinit(mem);

    try queue.push(mem, 1);
    try queue.push(mem, 2);
    try queue.push(mem, 3);
    try queue.push(mem, 4);
    try queue.push(mem, 5);
    try expect(queue.pop() == 1);
    try expect(queue.pop() == 2);
    try expect(queue.pop() == 3);
    try expect(queue.pop() == 4);
    try expect(queue.pop() == 5);
    try expect(queue.pop() == null);
}

