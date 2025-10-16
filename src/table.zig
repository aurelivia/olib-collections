const std = @import("std");
const log = std.log.scoped(.@"olib-collections");
const Allocator = std.mem.Allocator;
const Queue = @import("./queue.zig").Queue;

pub fn Table(comptime T: type, comptime BackingInt: type) type { return struct {
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
        pub const Generation = @Type(std.builtin.Type.Int{ .signedness = .unsigned, .bits = generation_bits });
        pub const Index = @Type(std.builtin.Type.Int{ .signedness = .unsigned, .bits = index_bits });

        generation: Generation,
        index: Index
    };

    const is_multi = @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".layout != .@"packed";
    const Items = if (is_multi) std.MultiArrayList(T) else std.ArrayList(T);

    rw: @import("./mutability_lock.zig"),
    items: Items,
    living: std.bit_set.DynamicBitSetUnmanaged,
    generation: std.ArrayList(Key.Generation),
    recycle: Queue(Key.Generation),

    pub fn deinit(self: *@This(), mem: Allocator) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.items.deinit(mem);
        self.living.deinit(mem);
        self.generation.deinit(mem);
        self.recycle.deinit(mem);
    }

    pub inline fn init(mem: Allocator) Allocator.Error!@This() {
        return initCapacity(mem, 0);
    }

    pub fn initCapacity(mem: Allocator, size: Key.Index) Allocator.Error!@This() {
        var table = .{
            .rw = .{},
            .items = .empty,
            .living = try .initEmpty(mem, size),
            .generation = .empty,
            .recycle = .{}
        };
        errdefer table.deinit(mem);
        try table.items.ensureTotalCapacity(mem, size);
        table.generation = try .initCapacity(mem, size);
        return table;
    }

    pub inline fn len(self: *const @This()) Key.Index {
        return if (is_multi) self.items.len else self.items.items.len;
    }

    inline fn modItemsLen(self: *@This(), mod: isize) void {
        if (is_multi) self.items.len += mod else self.items.items.len += mod;
    }

    fn awaitNewLocked(self: *@This(), mem: Allocator) Allocator.Error!Key {
        while (self.recycle.pop()) |rec| {
            if (rec.index < self.items.len and !self.living.isSet(rec.index)) {
                const gen = self.generation.items[rec.index] +% 1;
                self.generation.items[rec.index] = gen;
                return .{ .index = rec.index, .generation = gen };
            }
        }

        if (self.len() == self.items.capacity) {
            std.debug.assert(self.items.len < std.math.maxInt(Key.Index));
            try self.items.ensureUnusedCapacity(mem, 1);
            try self.living.resize(mem, self.items.capacity, false);
            try self.generation.ensureTotalCapacityPrecise(mem, self.items.capacity);
        }

        self.modItemsLen(1);
        const newlen = self.len();
        self.generation.items.len = newlen;
        self.generation.items[newlen - 1] = 0;
        return .{ .index = @as(Key.Index, @intCast(len - 1)), .generation = 0 };
    }

    pub fn awaitNew(self: *@This(), mem: Allocator) Allocator.Error!Key {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        return try self.awaitNewLocked(mem);
    }

    fn createLocked(self: *@This(), mem: Allocator, val: T) Allocator.Error!Key {
        const key = try self.awaitNewLocked(mem);
        self.setLocked(key, val);
        return key;
    }

    pub fn create(self: *@This(), mem: Allocator, val: T) Allocator.Error!Key {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        return try self.createLocked(mem, val);
    }

    fn getLocked(self: *const @This(), key: Key) ?T {
        if (self.exists(key)) return if (is_multi) self.items.get(key.index) else self.items.items[key.index];
        return null;
    }

    pub fn get(self: *const @This(), key: Key) ?T {
        self.rw.lock();
        defer self.rw.unlock();
        return self.getLocked(key);
    }

    fn setLocked(self: *@This(), key: Key, val: T) void {
        if (is_multi) self.items.set(key.index, val) else self.items.items[key.index] = val;
        self.living.set(key.index);
    }

    pub fn set(self: *@This(), key: Key, val: T) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.setLocked(key, val);
    }

    fn destroyLocked(self: *@This(), mem: Allocator, key: Key) void {
        self.recycle.push(mem, key) catch {};
        self.living.unset(key.index);
        if (key.index == self.len() - 1) self.modItemsLen(-1);
    }

    pub fn destroy(self: *@This(), mem: Allocator, key: Key) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.destroyLocked(mem, key);
    }

    pub fn clear(self: *@This()) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.items.clearRetainingCapacity();
        self.living.unsetAll();
        self.generation.clearRetainingCapacity();
        self.recycle.clear();
    }

    pub fn clearFree(self: *@This(), mem: Allocator) void {
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.items.clearAndFree(mem);
        self.living.resize(mem, 0, false).?;
        self.generation.clearAndFree(mem);
        self.recycle.clear();
    }

    pub fn trim(self: *@This(), mem: Allocator) void {
        if (self.items.len *| 2 >= self.items.capacity) return;
        self.rw.lockMut();
        defer self.rw.unlockMut();
        self.items.shrinkAndFree(mem, @divFloor(self.items.capacity, 1));
        std.debug.assert(self.items.capacity <= self.living.bit_length);
        self.living.resize(mem, self.items.capacity, false) catch unreachable;
        self.generation.shrinkAndFree(mem, self.items.capacity);
    }

    pub fn slice(self: *const @This()) Slice {
        self.rw.lock();
        return .{
            .source = self,
            .inner_slice = if (is_multi) self.items.slice() else {},
            .valid = true,
            .rootValid = null,
            .release = Slice.releaseInner
        };
    }

    pub fn sliceMut(self: *@This()) SliceMut {
        self.rw.lockMut();
        return .{
            .source = self,
            .inner_slice = if (is_multi) self.items.slice() else {},
            .valid = true,
            .rootValid = null,
            .release = SliceMut.releaseInner
        };
    }

    pub fn iter(self: *const @This()) Iter {
        self.rw.lock();
        return .{
            .source = self,
            .inner_slice = if (is_multi) self.items.slice() else {},
            .index = 0,
            .valid = true,
            .rootValid = null,
            .release = Iter.releaseInner
        };
    }

    pub fn iterMut(self: *@This()) IterMut {
        self.rw.lockMut();
        return .{
            .source = self,
            .inner_slice = if (is_multi) self.items.slice() else {},
            .index = 0,
            .valid = true,
            .rootValid = null,
            .release = IterMut.releaseInner
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
            return self.source.exists(key);
        }

        pub inline fn get(self: *const Slc, key: Key) ?T {
            if (self.source.exists(key))
                return if (is_multi) self.inner_slice.get(key.index) else self.source.items.items[key.index];
            return null;
        }

        pub inline fn iter(self: *const Slc) Iter {
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
        source: *const @This(),
        inner_slice: if (is_multi) Items.Slice else void,
        valid: bool,
        rootValid: ?*bool,
        release: fn (*const Slice) void,

        pub inline fn releaseInner(self: *const Slice) void {
            self.assertValid();
            @constCast(self).valid = false;
            self.source.rw.unlock();
        }

        pub inline fn releaseInnerDerived(_: *const Slice) void {
            comptime { @compileError("Attempt to release a slice that is derived from another. Release the root isntead."); }
        }

        pub fn toMut(self: *const Slice) ?SliceMut {
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
        pub const exists = sliceFn.exists;
        pub const get = sliceFn.get;
        pub const iter = sliceFn.iter;
    };

    fn MutFunctions(comptime Slc: type) type { return struct {
        pub inline fn create(self: *Slc, mem: Allocator, val: T) Allocator.Error!Key {
            const key = try self.source.awaitNewLocked(mem);
            // awaitNew can invalidate slices, refresh them before proceeding
            if (is_multi) self.inner_slice = self.items.slice();
            self.set(key, val);
            return key;
        }

        pub inline fn set(self: *Slc, key: Key, val: T) void {
            if (is_multi) self.inner_slice.set(key.index, val) else self.source.items.items[key.index] = val;
            self.living.set(key.index);
        }

        pub inline fn destroy(self: *Slc, mem: Allocator, key: Key) void {
            self.source.destroyLocked(mem, key);
        }
    };}

    pub const SliceMut = struct {
        source: *@This(),
        inner_slice: if (is_multi) Items.Slice else void,
        valid: bool,
        rootValid: ?*bool,
        release: fn (*SliceMut) void,

        pub inline fn releaseInner(self: *SliceMut) void {
            self.assertValid();
            self.valid = false;
            self.source.rw.unlockMut();
        }

        pub inline fn releaseInnerDerived(_: *SliceMut) void {
            comptime { @compileError("Attempt to release a slice that is derived from another. Release the root isntead."); }
        }

        const sliceFn = SliceFunctions(SliceMut);
        pub const exists = sliceFn.exists;
        pub const get = sliceFn.get;
        pub const iter = sliceFn.iter;
        const mutFn = MutFunctions(SliceMut);
        pub const create = mutFn.create;
        pub const set = mutFn.set;
        pub const destroy = mutFn.destroy;

        pub inline fn iterMut(self: *SliceMut) void {
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
            while (!self.done()) {
                if (self.source.valid.isSet(self.index)) {
                    const k: Key = .{ .index = self.index, .generation = self.source.generation.items[self.index] };
                    self.index += 1;
                    return k;
                }
                self.index += 1;
            }
            return null;
        }

        pub inline fn done(self: *const It) bool {
            return self.index >= self.source.len();
        }

        pub inline fn reset(self: *It) void {
            self.index = 0;
        }

        pub inline fn subIter(self: *const It) It {
            return .{
                .source = self.source,
                .inner_slice = self.inner_slice,
                .release = It.releaseInnerDerived
            };
        }
    };}

    pub const Iter = struct {
        source: *@This(),
        inner_slice: if (is_multi) Items.Slice else void,
        index: Key.Index,
        valid: bool,
        rootValid: ?*bool,
        release: fn (*const Iter) void,

        pub inline fn releaseInner(self: *const Iter) void {
            self.assertValid();
            @constCast(self).valid = false;
            self.source.rw.unlock();
        }

        pub inline fn releaseInnerDerived(_: *const Iter) void {
            comptime { @compileError("Attempt to release a iterator that is derived from another. Release the root isntead."); }
        }

        const sliceFn = SliceFunctions(Iter);
        pub const exists = sliceFn.exists;
        pub const get = sliceFn.get;
        const iterFn = IterFunctions(Iter);
        pub const next = iterFn.next;
        pub const done = iterFn.done;
        pub const reset = iterFn.reset;
        pub const subIter = iterFn.subIter;
    };

    pub const IterMut = struct {
        source: *@This(),
        inner_slice: if (is_multi) Items.Slice else void,
        index: Key.Index,
        valid: bool,
        rootValid: ?*bool,
        release: fn (*IterMut) void,

        pub inline fn releaseInner(self: *IterMut) void {
            self.assertValid();
            self.valid = false;
            self.source.rw.unlockMut();
        }

        pub inline fn releaseInnerDerived(_: *IterMut) void {
            comptime { @compileError("Attempt to release a iterator that is derived from another. Release the root isntead."); }
        }

        const sliceFn = SliceFunctions(IterMut);
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
