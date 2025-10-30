const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = error{OutOfMemory};

pub fn SparseArrayList(comptime T: type) type { return struct {
    const Self = @This();

    const is_optional = @typeInfo(T) == .optional;
    const Known = if (is_optional) @typeInfo(T).child else T;

    pub const LookupResult = if (is_optional) T else ?T;

    const Slice = struct {
        offset: usize,
        ptr: [*]Known,
        len: u32,
        cap: u32,

        pub fn deinit(self: *Slice, mem: Allocator) void {
            mem.free(self.ptr[0..self.cap]);
            self.* = undefined;
        }

        const init_cap: comptime_int = @max(1, std.atomic.cache_line / @sizeOf(T));

        pub fn init(mem: Allocator, offset: usize, val: Known) OOM!Self {
            const slice = try mem.alloc(Known, init_cap);
            slice[0] = val;
            return .{
                .offset = offset,
                .ptr = slice.ptr,
                .len = 1,
                .cap = @intCast(slice.len)
            };
        }

        pub fn setCapacity(self: *Slice, mem: Allocator, cap: u32) OOM!void {
            if (mem.remap(self.ptr[0..self.cap], cap)) |mapped| {
                self.ptr = mapped.ptr;
                self.cap = @intCast(mapped.len);
            } else {
                const moved = try mem.alloc(Known, cap);
                @memcpy(moved[0..self.len], self.ptr[0..self.len]);
                mem.free(self.ptr[0..self.cap]);
                self.ptr = moved.ptr;
                self.cap = @intCast(moved.len);
            }
        }

        pub fn ensureCapacity(self: *Slice, mem: Allocator, size: u32, max: u32) OOM!bool {
            if (size > max) return false;
            const cap: usize = @intCast(self.cap);
            if (size < cap) return true;

            var next: usize = cap;
            while (next < size) next +|= next / 2 + init_cap;
            next = @min(next, max);
            if (next <= cap) return if (self.len == self.cap) false else true;

            try self.setCapacity(mem, @intCast(next));
            return true;
        }
    };

    inner: std.ArrayList(Slice),

    pub const empty: Self = .{ .inner = .empty };

    pub fn deinit(self: *Self, mem: Allocator) void {
        for (self.inner.items) |*slice| slice.deinit(mem);
        self.inner.deinit(mem);
        self.* = undefined;
    }

    pub fn initCapacity(mem: Allocator, size: usize) OOM!Self {
        var self: Self = .empty;
        const slice = try mem.alloc(Known, @max(size, Slice.init_cap));
        errdefer mem.free(slice);
        try self.inner.append(mem, .{
            .offset = 0,
            .ptr = slice.ptr,
            .len = 0,
            .cap = @intCast(slice.len)
        });
        return self;
    }
};}

const tst = std.testing;
const test_mem = std.testing.allocator;

const TestUnbounded = SparseArrayList(usize);

test "Slice Capacity" {
    var t: TestUnbounded = try .initCapacity(test_mem, 1);
    defer t.deinit(test_mem);

    try tst.expectEqual(true, try t.inner.items[0].ensureCapacity(test_mem, 52, std.math.maxInt(u32)));
    try tst.expectEqual(0, t.inner.items[0].len);
    try tst.expectEqual(76, t.inner.items[0].cap);

    try tst.expectEqual(true, try t.inner.items[0].ensureCapacity(test_mem, 128, std.math.maxInt(u32)));
    try tst.expectEqual(0, t.inner.items[0].len);
    try tst.expectEqual(130, t.inner.items[0].cap);

    try tst.expectEqual(false, try t.inner.items[0].ensureCapacity(test_mem, 999, 130));
    try tst.expectEqual(0, t.inner.items[0].len);
    try tst.expectEqual(130, t.inner.items[0].cap);

    t.inner.items[0].len = 130;
    try tst.expectEqual(false, try t.inner.items[0].ensureCapacity(test_mem, 130, 130));
    try tst.expectEqual(130, t.inner.items[0].len);
    try tst.expectEqual(130, t.inner.items[0].cap);
}
