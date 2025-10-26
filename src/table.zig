const std = @import("std");
const log = std.log.scoped(.@"olib-collections");
const Allocator = std.mem.Allocator;
const Queue = @import("./queue.zig").Queue;

pub fn Table(comptime T: type, comptime BackingInt: type) type { return struct {
    const Self = @This();

    comptime {
        switch (@typeInfo(BackingInt)) {
            .int => |int| if (int.signedness == .signed) @compileError("Backing integers may not be signed.")
                else if (int.bits < 16) @compileError("Backing integers must be at least u16."),
            else => @compileError(@typeName(BackingInt) ++ " is not a valid backing integer type (only unsigned integers are allowed).")
        }
    }

    pub const Key = packed struct (BackingInt) {
        pub const generation_bits = @min(@divFloor(@typeInfo(BackingInt).int.bits, 3), 16);
        pub const index_bits = @typeInfo(BackingInt).int.bits - generation_bits;
        pub const Generation = @Type(std.builtin.Type{ .int = .{ .signedness = .unsigned, .bits = generation_bits }});
        pub const Index = @Type(std.builtin.Type{ .int = .{ .signedness = .unsigned, .bits = index_bits }});

        generation: Generation,
        index: Index
    };

    const is_multi = @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".layout != .@"packed";
    const Items = if (is_multi) std.MultiArrayList(T) else std.ArrayList(T);

    rw: @import("./mutability_lock.zig"),
    items: Items,
    generation: std.ArrayList(Key.Generation),
    recycle: ?Queue(Key),

    pub const empty: Self = .{
        .rw = .{},
        .items = .empty,
        .generation = .empty,
        .recycle = null
    };

    pub fn deinit(self: *Self, mem: Allocator) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.items.deinit(mem);
        self.generation.deinit(mem);
        if (self.recycle) |*rec| rec.deinit(mem);
    }

    pub fn initCapacity(mem: Allocator, size: Key.Index) Allocator.Error!Self {
        var table = .{
            .rw = .{},
            .items = .empty,
            .generation = .empty,
            .recycle = .init()
        };
        try table.items.ensureTotalCapacity(mem, size);
        errdefer table.items.deinit(mem);
        table.generation = try .initCapacity(mem, size);
        return table;
    }

    pub inline fn len(self: *const Self) Key.Index {
        return @truncate(if (is_multi) self.items.len else self.items.items.len);
    }

    inline fn modItemsLen(self: *Self, mod: isize) void {
        if (is_multi) self.items.len += mod else self.items.items.len += mod;
    }

    fn awaitNewLocked(self: *Self, mem: Allocator) Allocator.Error!Key {
        if (self.recycle) |*rec| {
            while (rec.pop()) |r| {
                if (r.index < self.items.len and self.generations.items[r.index] == 0) {
                    var gen = r.generation +% 1;
                    if (gen == 0) gen = 1;
                    self.generation.items[r.index] = gen;
                    return .{ .index = r.index, .generation = gen };
                }
            }
        }

        if (self.len() == self.items.capacity) {
            std.debug.assert(self.items.len < std.math.maxInt(Key.Index));
            try self.items.ensureUnusedCapacity(mem, 1);
            try self.generation.ensureTotalCapacityPrecise(mem, self.items.capacity);
            @memset(self.generation.items.ptr[self.generation.items.len..self.generation.items.capacity], 0);
        }

        self.modItemsLen(1);
        const newlen = self.len();
        self.generation.items.len = newlen;
        self.generation.items[newlen - 1] = 1;
        return .{ .index = @as(Key.Index, @intCast(newlen - 1)), .generation = 1 };
    }

    pub fn awaitNew(self: *Self, mem: Allocator) Allocator.Error!Key {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        return try self.awaitNewLocked(mem);
    }

    fn createLocked(self: *Self, mem: Allocator, val: T) Allocator.Error!Key {
        const key = try self.awaitNewLocked(mem);
        self.setLocked(key, val);
        return key;
    }

    pub fn create(self: *Self, mem: Allocator, val: T) Allocator.Error!Key {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        return try self.createLocked(mem, val);
    }

    fn existsLocked(self: *const Self, key: Key) bool {
        return self.generation.items[key.index] == key.generation;
    }

    pub fn exists(self: *const Self, key: Key) bool {
        self.rw.lock();
        defer self.rw.unlock();
        return self.existsLocked(key);
    }

    fn getLocked(self: *const Self, key: Key) ?T {
        if (self.existsLocked(key)) return if (is_multi) self.items.get(key.index) else self.items.items[key.index];
        return null;
    }

    pub fn get(self: *const Self, key: Key) ?T {
        self.rw.lock();
        defer self.rw.unlock();
        return self.getLocked(key);
    }

    fn setLocked(self: *Self, key: Key, val: T) void {
        std.debug.assert(self.existsLocked(key));
        if (is_multi) self.items.set(key.index, val) else self.items.items[key.index] = val;
    }

    pub fn set(self: *Self, key: Key, val: T) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.setLocked(key, val);
    }

    fn destroyLocked(self: *Self, mem: Allocator, key: Key) void {
        if (self.recycle == null) self.recycle = .init();
        self.recycle.?.push(mem, key) catch {};
        self.generation.items[key.index] = 0;
        if (key.index == self.len() - 1) self.modItemsLen(-1);
    }

    pub fn destroy(self: *Self, mem: Allocator, key: Key) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.destroyLocked(mem, key);
    }

    pub fn clear(self: *Self) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.items.clearRetainingCapacity();
        self.generation.clearRetainingCapacity();
        if (self.recycle) |*rec| rec.clear();
    }

    pub fn clearFree(self: *Self, mem: Allocator) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.items.clearAndFree(mem);
        self.generation.clearAndFree(mem);
        if (self.recycle) |*rec| rec.clear();
    }

    pub fn trim(self: *Self, mem: Allocator) void {
        if (self.items.len *| 2 >= self.items.capacity) return;
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.items.shrinkAndFree(mem, @divFloor(self.items.capacity, 1));
        self.generation.shrinkAndFree(mem, self.items.capacity);
    }

    pub fn slice(self: *const Self) Slice {
        self.rw.lock();
        return .{
            .source = self,
            .inner_slice = if (is_multi) self.items.slice() else {},
            .valid = true,
            .rootValid = null,
            .releaseFn = Slice.releaseInner
        };
    }

    pub fn sliceMut(self: *Self) SliceMut {
        self.rw.lockMut();
        return .{
            .source = self,
            .inner_slice = if (is_multi) self.items.slice() else {},
            .valid = true,
            .rootValid = null,
            .releaseFn = SliceMut.releaseInner
        };
    }

    pub fn iter(self: *const Self) Iter {
        self.rw.lock();
        return .{
            .source = self,
            .inner_slice = if (is_multi) self.items.slice() else {},
            .index = 0,
            .valid = true,
            .rootValid = null,
            .releaseFn = Iter.releaseInner
        };
    }

    pub fn iterMut(self: *Self) IterMut {
        self.rw.lockMut();
        return .{
            .source = self,
            .inner_slice = if (is_multi) self.items.slice() else {},
            .index = 0,
            .valid = true,
            .rootValid = null,
            .releaseFn = IterMut.releaseInner
        };
    }

    fn SliceFunctions(comptime Slc: type) type { return struct {
        inline fn assertValid(self: *const Slc) void {
            if ((if (self.rootValid) |pv| pv.* else self.valid) == false) {
                std.debug.print("Attempt to use a slice or iterator after it or it's root was released.", .{});
                unreachable;
            }
        }

        pub inline fn exists(self: *const Slc, key: Key) bool {
            self.assertValid();
            return self.source.existsLocked(key);
        }

        pub inline fn get(self: *const Slc, key: Key) ?T {
            self.assertValid();
            return self.source.getLocked(key);
        }

        pub inline fn iter(self: *const Slc) Iter {
            self.assertValid();
            return .{
                .source = self.source,
                .inner_slice = self.inner_slice,
                .index = 0,
                .valid = true,
                .rootValid = &(self.valid),
                .release = Iter.releaseInnerDerived
            };
        }
    };}

    pub const Slice = struct {
        source: *const Self,
        inner_slice: if (is_multi) Items.Slice else void,
        valid: bool,
        rootValid: ?*bool,
        releaseFn: *const fn (*const Slice) void,

        pub inline fn release(self: *const Slice) void {
            return self.releaseFn(self);
        }

        pub fn releaseInner(self: *const Slice) void {
            self.assertValid();
            @constCast(self).valid = false;
            self.source.rw.unlock();
        }

        pub fn releaseInnerDerived(_: *const Slice) void {
            comptime { @compileError("Attempt to release a slice that is derived from another. Release the root isntead."); }
        }

        pub fn toMut(self: *const Slice) ?SliceMut {
            self.assertValid();
            const snapped = self.source.rw.snapshot.load(.acq);
            self.release();
            self.source.rw.lockMut();
            if (self.source.rw.snapshot.load(.acq) == snapped) {
                return .{
                    .source = self.source,
                    .inner_slice = if (is_multi) self.items.slice() else {},
                    .valid = true,
                    .rootValid = null
                };
            } else { self.source.rw.unlockMut(); return null; }
        }

        const sliceFn = SliceFunctions(Slice);
        const assertValid = sliceFn.assertValid;
        pub const exists = sliceFn.exists;
        pub const get = sliceFn.get;
        pub const iter = sliceFn.iter;
    };

    fn MutFunctions(comptime Slc: type) type { return struct {
        pub inline fn create(self: *Slc, mem: Allocator, val: T) Allocator.Error!Key {
            self.assertValid();
            const key = try self.source.awaitNewLocked(mem);
            // awaitNew can invalidate slices, refresh them before proceeding
            if (is_multi) self.inner_slice = self.items.slice();
            self.set(key, val);
            return key;
        }

        pub inline fn set(self: *Slc, key: Key, val: T) void {
            self.assertValid();
            std.debug.assert(self.source.existsLocked(key));
            if (is_multi) self.inner_slice.set(key.index, val) else self.source.items.items[key.index] = val;
        }

        pub inline fn destroy(self: *Slc, mem: Allocator, key: Key) void {
            self.assertValid();
            self.source.destroyLocked(mem, key);
        }
    };}

    pub const SliceMut = struct {
        source: *Self,
        inner_slice: if (is_multi) Items.Slice else void,
        valid: bool,
        rootValid: ?*bool,
        releaseFn: *const fn (*SliceMut) void,

        pub inline fn release(self: *SliceMut) void {
            return self.releaseFn(self);
        }

        pub fn releaseInner(self: *SliceMut) void {
            self.assertValid();
            self.valid = false;
            self.source.rw.unlockMut();
        }

        pub fn releaseInnerDerived(_: *SliceMut) void {
            comptime { @compileError("Attempt to release a slice that is derived from another. Release the root isntead."); }
        }

        const sliceFn = SliceFunctions(SliceMut);
        const assertValid = sliceFn.assertValid;
        pub const exists = sliceFn.exists;
        pub const get = sliceFn.get;
        pub const iter = sliceFn.iter;
        const mutFn = MutFunctions(SliceMut);
        pub const create = mutFn.create;
        pub const set = mutFn.set;
        pub const destroy = mutFn.destroy;

        pub inline fn iterMut(self: *SliceMut) void {
            self.assertValid();
            return .{
                .source = self.source,
                .inner_slice = self.inner_slice,
                .index = 0,
                .valid = true,
                .rootValid = &(self.valid),
                .release = IterMut.releaseInnerDerived
            };
        }
    };

    fn IterFunctions(comptime It: type) type { return struct {
        pub fn next(self: *It) ?Key {
            self.assertValid();
            while (!self.done()) {
                if (self.source.generation.items[self.index] != 0) {
                    const k: Key = .{ .index = self.index, .generation = self.source.generation.items[self.index] };
                    self.index += 1;
                    return k;
                }
                self.index += 1;
            }
            return null;
        }

        pub inline fn done(self: *const It) bool {
            self.assertValid();
            return self.index >= self.source.len();
        }

        pub inline fn reset(self: *It) void {
            self.assertValid();
            self.index = 0;
        }

        pub inline fn subIter(self: *const It) It {
            self.assertValid();
            return .{
                .source = self.source,
                .inner_slice = self.inner_slice,
                .release = It.releaseInnerDerived
            };
        }
    };}

    pub const Iter = struct {
        source: *Self,
        inner_slice: if (is_multi) Items.Slice else void,
        index: Key.Index,
        valid: bool,
        rootValid: ?*bool,
        releaseFn: *const fn (*const Iter) void,

        pub inline fn release(self: *const Iter) void {
            return self.releaseFn(self);
        }

        pub fn releaseInner(self: *const Iter) void {
            self.assertValid();
            @constCast(self).valid = false;
            self.source.rw.unlock();
        }

        pub fn releaseInnerDerived(_: *const Iter) void {
            comptime { @compileError("Attempt to release a iterator that is derived from another. Release the root isntead."); }
        }

        const sliceFn = SliceFunctions(Iter);
        const assertValid = sliceFn.assertValid;
        pub const exists = sliceFn.exists;
        pub const get = sliceFn.get;
        const iterFn = IterFunctions(Iter);
        pub const next = iterFn.next;
        pub const done = iterFn.done;
        pub const reset = iterFn.reset;
        pub const subIter = iterFn.subIter;
    };

    pub const IterMut = struct {
        source: *Self,
        inner_slice: if (is_multi) Items.Slice else void,
        index: Key.Index,
        valid: bool,
        rootValid: ?*bool,
        releaseFn: *const fn (*IterMut) void,

        pub inline fn release(self: *IterMut) void {
            return self.releaseFn(self);
        }

        pub fn releaseInner(self: *IterMut) void {
            self.assertValid();
            self.valid = false;
            self.source.rw.unlockMut();
        }

        pub fn releaseInnerDerived(_: *IterMut) void {
            comptime { @compileError("Attempt to release a iterator that is derived from another. Release the root isntead."); }
        }

        const sliceFn = SliceFunctions(IterMut);
        const assertValid = sliceFn.assertValid;
        pub const exists = sliceFn.exists;
        pub const get = sliceFn.get;
        const mutFn = MutFunctions(IterMut);
        pub const create = mutFn.create;
        pub const destroy = mutFn.destroy;
        pub const set = mutFn.set;
        const iterFn = IterFunctions(IterMut);
        pub const next = iterFn.next;
        pub const done = iterFn.done;
        pub const reset = iterFn.reset;
        pub const subIter = iterFn.subIter;
    };
};}
