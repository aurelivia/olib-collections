const std = @import("std");
const expect = std.testing.expect;

pub fn Range(comptime T: type) type {
    const isEnum = switch (@typeInfo(T)) {
        .int => false,
        .@"enum" => true,
        else => @compileError("Ranges can only be constructed for enums and integer types.")
    };

    return struct {
        pub const UPPER: comptime_int = if (isEnum) blk: {
                var m: comptime_int = 0;
                for (@typeInfo(T).@"enum".fields) |f| {
                    m = @max(m, f.value);
                }
                break :blk m;
            } else std.math.maxInt(T);

        pub const LOWER: comptime_int = if (isEnum) blk: {
                var m: comptime_int = 0;
                for (@typeInfo(T).@"enum".fields) |f| {
                    m = @min(m, f.value);
                }
                break :blk m;
            } else std.math.minInt(T);

        const Self = @This();

        pub const Iter = struct {
            start: *const Self = undefined,
            span: *const Self = undefined,
            cur: ?T = undefined,

            pub fn next(self: *Iter) ?T {
                const c = self.cur;
                if (self.cur) |cur| {
                    if (cur == self.span.upper) {
                        if (self.span.next) |n| {
                            self.cur = n.lower;
                            self.span = n;
                        } else self.cur = null;
                    } else self.cur = succ(cur);
                }
                return c;
            }

            pub inline fn done(self: *const Iter) bool {
                return self.cur == null;
            }

            pub inline fn reset(self: *Iter) void {
                self.span = self.start;
                self.cur = self.start.lower;
            }

            pub inline fn random(self: *const Iter, rng: std.Random) T {
                return self.start.random(rng);
            }

            pub inline fn randomOrNull(self: *const Iter, rng: std.Random) ?T {
                return self.start.randomOrNull(rng);
            }
        };

        lower: T,
        upper: T,
        len: usize,
        total: usize,
        next: ?*const Self = null,

        inline fn succ(x: T) T { return if (isEnum) blk: {
                const i = @intFromEnum(x);
                break :blk if (i < UPPER) @enumFromInt(i +| 1) else @enumFromInt(UPPER);
            } else x +| 1;
        }
        inline fn pred(x: T) T { return if (isEnum) blk: {
                const i = @intFromEnum(x);
                break :blk if (i > LOWER) @enumFromInt(i -| 1) else @enumFromInt(LOWER);
            } else x -| 1;
        }
        inline fn lt(a: T, b: T) bool { return if (isEnum) @intFromEnum(a) < @intFromEnum(b) else a < b; }
        inline fn le(a: T, b: T) bool { return a == b or Self.lt(a, b); }
        inline fn gt(a: T, b: T) bool { return !Self.le(a, b); }
        inline fn ge(a: T, b: T) bool { return !Self.lt(a, b); }
        inline fn min(a: T, b: T) T { return if (isEnum) @enumFromInt(@min(@intFromEnum(a), @intFromEnum(b))) else @min(a, b); }
        inline fn max(a: T, b: T) T { return if (isEnum) @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b))) else @max(a, b); }

        fn calcLen(self: *Self) void {
            std.debug.assert(Self.le(self.lower, self.upper));
            self.len = (if (isEnum) @intFromEnum(self.upper) -| @intFromEnum(self.lower) else self.upper -| self.lower) +| 1;
            self.total = self.len;
            if (self.next) |next| self.total += next.total;
        }

        pub fn new(lower: T, upper: T) Self {
            var r: Self = .{ .lower = lower, .upper = upper, .len = 0, .total = 0 };
            r.calcLen();
            return r;
        }

        pub fn single(x: T) Self {
            return Self.new(x, x);
        }

        pub fn chain(lower: T, upper: T, next: Self) Self {
            var r: Self = new(lower, upper);
            r.total += next.total;
            r.next = &next;
            return r;
        }

        pub fn chainSingle(x: T, next: Self) Self {
            return Self.chain(x, x, next);
        }

        pub const chainS = Self.chainSingle;

        pub fn show(self: *const Self, writer: anytype) !void {
            try writer.writeAll("(");
            var span = self;
            while (true) {
                if (span.lower == span.upper) {
                    try writer.print("{}", .{ span.lower });
                } else try writer.print("{}..{}", .{ span.lower, span.upper });
                if (span.next) |n| {
                    try writer.writeAll(", ");
                    span = n;
                } else break;
            }
            try writer.writeAll(")");
        }

        pub fn contains(self: *const Self, x: anytype) bool {
            return switch (@TypeOf(x)) {
                ?T   => if (x) |_x| self.contains(_x) else false,
                T    => if (Self.le(x, self.upper) and Self.ge(x, self.lower)) true
                        else if (self.next) |next| next.contains(x)
                        else false,
                Self => blk: {
                    break :blk false;
                },
                else => @compileError("Range.contains does not accept '" ++ @TypeOf(x) ++ "'")
            };
        }

        pub fn getNth(self: *const Self, nth: usize) T {
            std.debug.assert(nth < self.total);
            var n = nth;
            var s = self;
            while (n >= s.len) {
                n -= s.len;
                s = s.next.?;
            }
            return if (isEnum) @enumFromInt(@intFromEnum(s.lower) + n) else s.lower + n;
        }

        pub fn random(self: *const Self, rng: std.Random) T {
            return self.getNth(rng.uintLessThan(usize, self.total));
        }

        pub fn randomOrNull(self: *const Self, rng: std.Random) ?T {
            const n = rng.uintAtMost(usize, self.total);
            if (n == self.total) return null;
            return self.getNth(n);
        }

        pub fn iter(self: *const Self) Iter {
            return .{ .start = self, .span = self, .cur = self.lower };
        }
    };
}

// pub fn Range(comptime T: type) type {
//     const isEnum = switch (@typeInfo(T)) {
//         .int => false,
//         .@"enum" => true,
//         else => @compileError("Ranges can only be constructed for enums and integer types.")
//     };
//
//     return struct {
//         pub const UPPER: usize = if (isEnum) blk: {
//                 var max: comptime_int = 0;
//                 for (@typeInfo(T).@"enum".fields) |f| {
//                     max = @max(max, f.value);
//                 }
//                 break :blk max;
//             } else std.math.maxInt(T);
//
//         pub const LOWER: usize = if (isEnum) blk: {
//                 var min: comptime_int = 0;
//                 for (@typeInfo(T).@"enum".fields) |f| {
//                     min = @min(min, f.value);
//                 }
//                 break :blk min;
//             } else std.math.minInt(T);
//
//         pub const Span = struct {
//             lower: T,
//             upper: T,
//             len: usize = 0,
//
//             inline fn succ(x: T) T { return if (isEnum) blk: {
//                     const i = @intFromEnum(x);
//                     break :blk if (i < UPPER) @enumFromInt(i +| 1) else @enumFromInt(UPPER);
//                 } else x +| 1;
//             }
//             inline fn pred(x: T) T { return if (isEnum) blk: {
//                     const i = @intFromEnum(x);
//                     break :blk if (i > LOWER) @enumFromInt(i -| 1) else @enumFromInt(LOWER);
//                 } else x -| 1;
//             }
//             inline fn lt(a: T, b: T) bool { return if (isEnum) @intFromEnum(a) < @intFromEnum(b) else a < b; }
//             inline fn le(a: T, b: T) bool { return a == b or Span.lt(a, b); }
//             inline fn gt(a: T, b: T) bool { return !Span.le(a, b); }
//             inline fn ge(a: T, b: T) bool { return !Span.lt(a, b); }
//             inline fn min(a: T, b: T) T { return if (isEnum) @enumFromInt(@min(@intFromEnum(a), @intFromEnum(b))) else @min(a, b); }
//             inline fn max(a: T, b: T) T { return if (isEnum) @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b))) else @max(a, b); }
//
//             pub inline fn clone(self: *const Span) Span {
//                 return .{ .lower = self.lower, .upper = self.upper, .len = self.len };
//             }
//
//             pub inline fn reLen(self: *Span) void {
//                 std.debug.assert(Span.ge(self.upper, self.lower));
//                 self.len = (if (isEnum) @intFromEnum(self.upper) -| @intFromEnum(self.lower) else self.upper -| self.lower) +| 1;
//             }
//
//             pub inline fn elem(self: *const Span, x: T) bool {
//                 return Span.ge(x, self.lower) and Span.le(x, self.upper);
//             }
//
//             pub inline fn contains(self: *const Span, other: Span) bool {
//                 return self.elem(other.lower) and self.elem(other.upper);
//             }
//
//             pub inline fn overlaps(self: *const Span, other: Span) bool {
//                 return self.elem(other.lower) or self.elem(other.upper);
//             }
//
//             pub inline fn _union(self: *Span, other: Span) void {
//                 std.debug.assert(self.overlaps(other));
//                 self.lower = Span.min(self.lower, other.lower);
//                 self.upper = Span.max(self.upper, other.upper);
//                 self.reLen();
//             }
//
//             pub inline fn getNthOfSpan(self: *const Span, n: usize) T {
//                 std.debug.assert(n < self.len);
//                 return if (isEnum) @enumFromInt(@intFromEnum(self.lower) + n) else self.lower + n;
//             }
//         };
//
//         mem: std.mem.Allocator = undefined,
//         spans: List(Span, null) = undefined,
//         lower: T = undefined,
//         upper: T = undefined,
//         total: usize = 0,
//
//         const Self = @This();
//
//         pub fn new(mem: std.mem.Allocator, lower: T, upper: T) !Self {
//             std.debug.assert(Span.le(lower, upper));
//             var range: Self = .{ .mem = mem };
//             range.spans = try List(Span, null).initCapacity(mem, 1);
//             range.spans.appendAssumeCapacity(.{
//                 .lower = lower,
//                 .upper = upper
//             });
//             range.spans.items[0].reLen();
//             range.lower = lower;
//             range.upper = upper;
//             range.total = range.spans.items[0].len;
//             return range;
//         }
//
//         pub fn clone(self: *const Self) !Self {
//             return .{
//                 .mem = self.mem,
//                 .spans = try self.spans.clone(self.mem),
//                 .lower = self.lower,
//                 .upper = self.upper,
//                 .total = self.total
//             };
//         }
//
//         pub fn deinit(self: *Self) void {
//             self.spans.deinit(self.mem);
//         }
//
//         pub fn show(self: *Self, writer: anytype) !void {
//             try writer.writeAll("(");
//             for (self.spans.items, 0..) |span, i| {
//                 try writer.print("{}..{}", .{ span.lower, span.upper });
//                 if (i < self.spans.items.len - 1) {
//                     try writer.writeAll(", ");
//                 }
//             }
//             try writer.writeAll(")");
//         }
//
//         fn bump(self: *Self) !void {
//             try self.spans.ensureTotalCapacityPrecise(self.mem, self.spans.items.len + 1);
//         }
//
//         fn shrink(self: *Self) void {
//             if (self.spans.items.len != self.spans.capacity)
//                 self.spans.shrinkAndFree(self.mem, self.spans.items.len);
//         }
//
//         pub fn elem(self: *const Self, x: T) bool {
//             for (self.spans.items) |span| if (span.elem(x)) return true;
//             return false;
//         }
//
//         pub fn elemMaybe(self: *const Self, x: ?T) bool {
//             return if (x) |_x| self.elem(_x) else false;
//         }
//
//         pub fn contains(self: *const Self, other: Self) bool {
//             for (other.spans.items) |theirs| {
//                 const pass = for (self.spans.items) |ours| {
//                     if (ours.contains(theirs)) break true;
//                 } else false;
//                 if (!pass) return false;
//             }
//             return true;
//         }
//
//         pub fn getNth(self: *const Self, n: usize) T {
//             var _n = n;
//             std.debug.assert(n < self.total);
//             var span = self.spans.items[0];
//             for (0..self.spans.items.len) |i| {
//                 span = self.spans.items[i];
//                 if (_n < span.len) break;
//                 _n -= span.len;
//             }
//             return span.getNthOfSpan(_n);
//         }
//
//         pub fn randomIn(self: *const Self, rng: std.Random) T {
//             const n = rng.uintLessThan(usize, self.total);
//             return self.getNth(n);
//         }
//
//         pub fn insert(self: *Self, x: T) !void {
//             if (self.spans.items.len != 0) {
//                 for (self.spans.items, 0..) |*span, i| {
//                     if (span.elem(x)) {
//                         return; // Already within bounds of a span
//                     } else if (x == Span.pred(span.lower)) {
//                         if (span.lower == Span.pred(self.lower)) return; // At min bound
//                         span.lower = x;
//                         self.extend(i);
//                         self.shrink();
//                         self.total += 1;
//                         break;
//                     } else if (x == Span.succ(span.upper)) {
//                         if (span.upper == Span.succ(span.upper)) return; // At max bound
//                         span.upper = x;
//                         self.extend(i);
//                         self.shrink();
//                         self.total += 1;
//                         break;
//                     } else if (Span.lt(x, span.lower)) {
//                         try self.bump();
//                         self.spans.insertAssumeCapacity(i, .{
//                             .lower = x,
//                             .upper = x,
//                             .len = 1
//                         });
//                         self.total += 1;
//                         break;
//                     }
//                 } else {
//                     try self.bump();
//                     self.spans.appendAssumeCapacity(.{
//                         .lower = x,
//                         .upper = x,
//                         .len = 1
//                     });
//                     self.total += 1;
//                 }
//                 if (Span.lt(x, self.lower)) self.lower = x;
//                 if (Span.gt(x, self.upper)) self.upper = x;
//             } else {
//                 try self.bump();
//                 self.spans.appendAssumeCapacity(.{
//                     .lower = x,
//                     .upper = x,
//                     .len = 1
//                 });
//                 self.lower = x;
//                 self.upper = x;
//                 self.total = 1;
//             }
//         }
//
//         fn extend(self: *Self, i: usize) void {
//             var span = self.spans.items[i];
//             if (i != self.spans.items.len - 1) {
//                 const next = self.spans.items[i + 1];
//                 if (span.overlaps(next)) {
//                     span.upper = next.upper;
//                     span.reLen();
//                     _ =self.spans.orderedRemove(i + 1);
//                 }
//             }
//             if (i != 0) {
//                 var prev = self.spans.items[i - 1];
//                 if (span.overlaps(prev)) {
//                     prev.upper = span.upper;
//                     prev.reLen();
//                     _ = self.spans.orderedRemove(i);
//                 }
//             }
//         }
//
//         fn unionInternal(self: *Self, other: Self) !void {
//             for (other.spans.items) |theirs| {
//                 try self.unionSpan(theirs.lower, theirs.upper);
//             }
//         }
//
//         pub fn _union(self: *Self, other: Self) !void {
//             try self.unionInternal(other);
//             self.shrink();
//         }
//
//         pub fn unions(self: *Self, others: []Self) !void {
//             for (others) |other| try self.unionInternal(other);
//             self.shrink();
//         }
//
//         pub fn unionSpan(self: *Self, lower: T, upper: T) !void {
//             var span: Span = .{ .lower = lower, .upper = upper };
//             span.reLen();
//             var pos: usize = 0;
//             for (self.spans.items, 0..) |*ours, i| {
//                 if (ours.contains(span)) return;
//                 if (ours.overlaps(span)) {
//                     const oldLen = ours.len;
//                     ours._union(span);
//                     self.total += (ours.len -| oldLen);
//                     self.extend(i);
//                     return;
//                 }
//                 if (Span.gt(span.lower, ours.upper)) pos = i;
//             }
//             try self.bump();
//             self.spans.insertAssumeCapacity(pos, span);
//             self.total += span.len;
//         }
//     };
// }
//
// const tmem = std.testing.allocator;
// const RInt = Range(usize);
// const TestEnum = enum {
//     a, b, c, d, e, f, g, h, i, j
// };
// const REnum = Range(TestEnum);
//
// test "elem" {
//     var i: RInt = try RInt.new(tmem, 3, 7);
//     defer i.deinit();
//     try expect(!i.elem(1));
//     try expect(i.elem(5));
//     try expect(!i.elem(9));
//     var e: REnum = try REnum.new(tmem, .c, .h);
//     defer e.deinit();
//     try expect(!e.elem(.a));
//     try expect(e.elem(.e));
//     try expect(!e.elem(.j));
// }
//
// test "contains" {
//     var a: RInt = try RInt.new(tmem, 3, 7);
//     defer a.deinit();
//     var b: RInt = try RInt.new(tmem, 3, 5);
//     defer b.deinit();
//     try expect(a.contains(b));
//     var c: RInt = try RInt.new(tmem, 5, 7);
//     defer c.deinit();
//     try expect(a.contains(c));
//     var d: RInt = try RInt.new(tmem, 1, 2);
//     defer d.deinit();
//     try expect(!a.contains(d));
//     var e: RInt = try RInt.new(tmem, 8, 9);
//     defer e.deinit();
//     try expect(!a.contains(e));
// }

