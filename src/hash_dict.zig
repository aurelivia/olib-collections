const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn HashDict(comptime BackingInt: type) type { return struct {
    const HashDictImpl = @This();

    comptime {
        switch (@typeInfo(BackingInt)) {
            .int => |int| if (int.signedness == .signed) @compileError("Backing integers may not be signed.")
                else if (int.bits < 16) @compileError("Backing integers must be at least u16.")
                else if (int.bits > @import("builtin").target.ptrBitWidth()) @compileError("Backing integers cannot be larger than pointers."),
            else => @compileError(@typeName(BackingInt) ++ " is not a valid backing integer type (only unsigned integers are allowed).")
        }
    }

    pub const Slice = packed struct (BackingInt) {
        pub const index_bits = @divFloor(@typeInfo(BackingInt).int.bits, 2);
        pub const length_bits = @typeInfo(BackingInt).int.bits - index_bits;
        pub const Index = @Type(std.builtin.Type{ .int = .{ .signedness = .unsigned, .bits = index_bits }});
        pub const Length = @Type(std.builtin.Type{ .int = .{ .signedness = .unsigned, .bits = length_bits }});

        index: Index,
        len: Length
    };

    const Chunk = struct {
        start: [*]const u8,
        len: Slice.Length,
        next: ?Slice.Index = null,

        pub fn eql(self: Chunk, rhs: Chunk) bool {
            return if (std.mem.eql(u8, self.start[0..self.len], rhs.start[0..rhs.len])) self.next == rhs.next else false;
        }
    };

    const Map = std.ArrayHashMapUnmanaged(Chunk, void, struct {
        inner: *Map,

        pub fn eql(_: @This(), a: Chunk, b: Chunk, _: usize) bool {
            return a.eql(b);
        }

        pub fn hash(self: @This(), start: Chunk) u32 {
            var wyhash = std.hash.Wyhash.init(0);
            const chunks = self.inner.keys();
            var chunk: ?Chunk = start;
            while (chunk) |c| {
                wyhash.update(c.start[0..c.len]);
                chunk = if (c.next) |n| chunks[n] else null;
            }
            return @truncate(wyhash.final());
        }
    }, true);

    inner: Map,

    pub fn deinit(self: *HashDictImpl, mem: Allocator) void {
        for (self.inner.keys()) |chunk| mem.free(chunk.start[0..chunk.len]);
        self.inner.deinit(mem);
    }

    pub const empty: HashDictImpl = .{ .inner = .empty };

    pub fn getOrPut(self: *HashDictImpl, mem: Allocator, slice: anytype) Allocator.Error!Slice {
        std.debug.assert(self.inner.entries.len < std.math.maxInt(Slice.Index));
        const bytes: []const u8 = switch (@typeInfo(@TypeOf(slice))) {
            .pointer => |p| switch (p.size) {
                .one, .slice => std.mem.sliceAsBytes(slice),
                .many, .c => std.mem.sliceAsBytes(std.mem.span(slice))
            },
            .array => std.mem.sliceAsBytes(&slice),
            else => @compileError(@typeName(@TypeOf(slice)) ++ " is not a slice.")
        };

        std.debug.assert(bytes.len <= std.math.maxInt(Slice.Length));

        const input: Chunk = .{
            .start = bytes.ptr,
            .len = @truncate(bytes.len)
        };

        const entry = try self.inner.getOrPutContext(mem, input, .{ .inner = &self.inner });
        if (!entry.found_existing) {
            // TODO: Make this smart
            const copy = try mem.alloc(u8, bytes.len);
            @memcpy(copy, bytes);
            entry.key_ptr.* = .{
                .start = copy.ptr,
                .len = @truncate(copy.len)
            };
        }

        return .{
            .index = @truncate(entry.index),
            .len = @truncate(bytes.len)
        };
    }

    pub const Iter = struct {
        source: *HashDictImpl,
        current: Chunk,
        remaining: Slice.Length,
        offset: Slice.Length = 0,
        peeked: ?u8 = null,

        pub fn peek(self: *@This()) ?u8 {
            if (self.peeked) |p| return p;
            self.peeked = self.next();
            return self.peeked;
        }

        pub fn toss(self: *@This()) void {
            if (self.peeked != null) {
                self.peeked = null;
            } else _ = self.next();
        }

        pub fn next(self: *@This()) ?u8 {
            if (self.remaining == 0) return null;
            if (self.offset == self.current.len) {
                if (self.current.next == null) unreachable;
                self.current = self.source.inner.keys()[self.current.next.?];
                self.offset = 0;
            }

            self.remaining -= 1;
            const byte = self.current.start[self.offset];
            self.offset += 1;
            return byte;
        }
    };

    pub fn iter(self: *HashDictImpl, slice: Slice) Iter {
        return .{
            .source = self,
            .current = self.inner.keys()[slice.index],
            .remaining = slice.len
        };
    }
};}
