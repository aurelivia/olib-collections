const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = error { OutOfMemory };

pub fn _Node(comptime T: type) type { return extern struct {
    const Node = @This();
    val: T,
    next: ?*Node = null,

    pub fn cons(head: *(?*Node), last: *(?*Node), node: *Node) void {
        while (true) {
            node.next = @atomicLoad(?*Node, head, .acquire);
            if (@cmpxchgWeak(?*Node, head, node.next, node, .acq_rel, .acquire) == null) break;
        }

        _ = @cmpxchgWeak(?*Node, last, null, node, .acq_rel, .acquire);
    }

    pub fn snoc(head: *(?*Node), last: *(?*Node), node: *Node) void {
        var prev: ?*Node = null;
        while (true) {
            prev = @atomicLoad(?*Node, last, .acquire);
            if (@cmpxchgWeak(?*Node, last, prev, node, .acq_rel, .acquire) == null) {
                if (prev) |p| @atomicStore(?*Node, &(p.next), node, .release);
                break;
            }
        }
        _ = @cmpxchgWeak(?*Node, head, null, node, .acq_rel, .acquire);
    }

    pub fn pop(head: *(?*Node), last: *(?*Node)) ?*Node {
        var prev: ?*Node = null;
        while (true) {
            prev = @atomicLoad(?*Node, head, .acquire);
            if (prev == null) break;
            if (@cmpxchgWeak(?*Node, head, prev, prev.?.next, .acq_rel, .acquire) == null) break;
        }

        _ = @cmpxchgWeak(?*Node, last, prev, null, .acq_rel, .acquire);

        return prev;
    }
};}

