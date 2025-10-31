const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = error{OutOfMemory};

pub fn SparseArrayList(comptime T: type) type { return struct {
    const Self = @This();

    const is_optional = @typeInfo(T) == .optional;
    const Known = if (is_optional) @typeInfo(T).optional.child else T;

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

        pub fn init(mem: Allocator, offset: usize, val: Known) OOM!Slice {
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
    trailing_nulls: if (is_optional) usize else void,

    pub const empty: Self = .{ .inner = .empty, .trailing_nulls = if (is_optional) 0 else {} };

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

    inline fn knownLen(self: *const Self) usize {
        if (self.inner.items.len == 0) return 0;
        const last = self.inner.items[self.inner.items.len - 1];
        return last.offset + last.len;
    }

    pub inline fn len(self: *const Self) usize {
        if (!is_optional) @compileError("len() cannot be used with sparse arrays of non-optional types (" ++ @typeName(T) ++ ") as they are unbounded.");
        return self.knownLen() + self.trailing_nulls;
    }

    inline fn assertBounds(self: *const Self, index: usize) void {
        if (is_optional) {
            if (index >= self.len()) {
                std.debug.print("Index {d} greater than maximum bound {d} of sparse array.\n", .{ index, self.len() });
                unreachable;
            }
        }
    }

    fn getPositionContaining(self: *const Self, index: usize) ?usize {
        self.assertBounds(index);
        if (self.inner.items.len == 0) return null;
        var range = self.inner.items;
        var shift: usize = 0;
        while (true) {
            const midpos: usize = range.len / 2;
            const mid = range[midpos];
            if (mid.offset <= index) {
                if (index < (mid.offset + mid.len)) return shift + midpos;
                if ((midpos + 1) == range.len) return null;
                range = range[(midpos + 1)..];
                shift += midpos + 1;
            } else {
                if (range.len == 1) return null;
                range = range[0..midpos];
            }
        }
    }

    pub fn get(self: *const Self, index: usize) LookupResult {
        if (self.getPositionContaining(index)) |pos| {
            const slice = self.inner.items[pos];
            return slice.ptr[index - slice.offset];
        } else return null;
    }

    pub fn append(self: *Self, mem: Allocator, val: T) Allocator.Error!void {
        const known: Known = if (is_optional) (if (val) |v| v else {
            self.trailing_nulls += 1;
            return;
        }) else val;

        if (self.inner.items.len == 0) {
            var slice: Slice = try .init(mem, 0, known);
            errdefer slice.deinit(mem);
            return try self.inner.append(mem, slice);
        }

        if (is_optional) {
            if (self.trailing_nulls != 0) {
                var slice: Slice = try .init(mem, self.len(), known);
                errdefer slice.deinit(mem);
                try self.inner.append(mem, slice);
                self.trailing_nulls = 0;
                return;
            }
        }

        var last = &(self.inner.items[self.inner.items.len - 1]);
        if (!(try last.ensureCapacity(mem, last.len + 1, std.math.maxInt(u32)))) return error.OutOfMemory;
        last.ptr[last.len] = known;
        last.len += 1;
    }
};}

const tst = std.testing;
const test_mem = std.testing.allocator;

const TestUnbounded = SparseArrayList(usize);
const TestBounded = SparseArrayList(?usize);

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

fn appendTestSlice(comptime T: type, t: *T, off: usize, len: u32) OOM!void {
    const slice = try test_mem.alloc(usize, len);
    for (0..slice.len) |i| slice[i] = i + off;
    errdefer test_mem.free(slice);
    try t.inner.append(test_mem, .{
        .offset = off,
        .ptr = slice.ptr,
        .len = len,
        .cap = @intCast(slice.len)
    });
}

fn makeTestList(comptime T: type) OOM!T {
    var t: T = .empty;
    errdefer t.deinit(test_mem);

    try appendTestSlice(T, &t, 0, 1);
    try appendTestSlice(T, &t, 4, 2);
    try appendTestSlice(T, &t, 8, 4);
    try appendTestSlice(T, &t, 16, 8);
    try appendTestSlice(T, &t, 32, 16);

    return t;
}

test "Get" {
    var t: TestUnbounded = try makeTestList(TestUnbounded);
    defer t.deinit(test_mem);

    try tst.expectEqual(0, t.get(0));
    var s: usize = 4;
    while (s <= 16): (s <<= 1) {
        const l: usize = s / 2;
        for (0..l) |i| try tst.expectEqual(s + i, t.get(s + i));
        for (l..s) |i| try tst.expectEqual(null, t.get(s + i));
    }
}

test "Append" {
    var u: TestUnbounded = try makeTestList(TestUnbounded);
    defer u.deinit(test_mem);

    try tst.expectEqual(null, u.get(32 + 16));
    try u.append(test_mem, 999);
    try tst.expectEqual(999, u.get(32 + 16));

    var b: TestBounded = try makeTestList(TestBounded);
    defer b.deinit(test_mem);

    try tst.expectEqual(32 + 16, b.len());
    try b.append(test_mem, null);
    try tst.expectEqual(32 + 17, b.len());
    try tst.expectEqual(null, b.get(32 + 16));
    try b.append(test_mem, null);
    try b.append(test_mem, null);
    try b.append(test_mem, null);
    try b.append(test_mem, null);
    try tst.expectEqual(5, b.trailing_nulls);
    try b.append(test_mem, 999);
    try tst.expectEqual(0, b.trailing_nulls);
    try tst.expectEqual(32 + 22, b.len());
    try tst.expectEqual(999, b.get(32 + 21));
}
