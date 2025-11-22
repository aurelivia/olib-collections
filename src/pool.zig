const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = error { OutOfMemory };
const Node = @import("./node.zig")._Node;

pub fn Pool(comptime bytesize: comptime_int) type { return struct {
    const Bytes = [bytesize]u8;

    const InnerNode = Node(Bytes);

    pub var instances: usize = 0;
    pub var head: ?*InnerNode = null;
    pub var last: ?*InnerNode = null;

    pub fn deinit(mem: Allocator) void {
        clear(mem);
    }

    pub fn clear(mem: Allocator) void {
        while (InnerNode.pop(&head, &last)) |node| mem.destroy(node);
    }

    pub fn acquire(comptime T: type, mem: Allocator) OOM!*Node(T) {
        if (@sizeOf(T) != bytesize) @compileError(std.fmt.comptimePrint("Size {d} of type {s} is not equivalent to pool size {d}.", .{ @sizeOf(T), @typeName(T), bytesize }));
        if (InnerNode.pop(&head, &last)) |node| return @as(*Node(T), @ptrCast(node));

        const node = try mem.create(InnerNode);
        node.* = .{ .val = undefined };
        return @as(*Node(T), @ptrCast(node));
    }

    pub fn release(comptime T: type, node: *Node(T)) void {
        if (@sizeOf(T) != bytesize) @compileError(std.fmt.comptimePrint("Size {d} of type {s} is not equivalent to pool size {d}.", .{ @sizeOf(T), @typeName(T), bytesize }));
        InnerNode.cons(&head, &last, @as(*InnerNode, @ptrCast(node)));
    }
};}
