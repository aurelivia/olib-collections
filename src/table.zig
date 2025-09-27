const std = @import("std");
const UQueue = @import("./queue.zig").UQueue;

pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Index = u32;
        pub const Generation = u16;

        pub const Key = packed struct(u48) {
            generation: Generation,
            index: Index
        };

        // fn itemsFunctions(comptime I: type, comptime IT: type) type {
        //     return struct {
        //         pub inline fn assertValid(self: *Items) void {
        //             std.debug.assert(self.parentValid.*);
        //         }
        //
        //         pub inline fn exists(self: *I, key: Key) bool {
        //             return self.source.exists(key);
        //         }
        //
        //         pub inline fn get(self: *I, key: Key) ?IT {
        //             self.assertValid();
        //             if (self.exists(key)) return self.items[key.index];
        //             return null;
        //         }
        //     };
        // }
        //
        // pub fn Items(comptime IT: type) type {
        //     return struct {
        //         source: *Self = undefined,
        //         items: []IT = undefined,
        //         parentValid: *bool = undefined,
        //
        //         const itemFn = itemsFunctions(Items, IT);
        //         const assertValid = itemFn.assertValid;
        //         pub const exists = itemFn.exists;
        //         pub const get = itemFn.get;
        //     };
        // }
        //
        // pub fn ItemsMut(comptime IT: type) type {
        //     return struct {
        //         source: *Self = undefined,
        //         items: []IT = undefined,
        //         parentValid: *bool = undefined,
        //
        //         const itemFn = itemsFunctions(ItemsMut, IT);
        //         const assertValid = itemFn.assertValid;
        //         pub const exists = itemFn.exists;
        //         pub const get = itemFn.get;
        //
        //         pub inline fn trySet(self: *@This(), key: Key, val: IT) bool {
        //             self.assertValid();
        //             if (self.exists(key)) { self.items[key.index] = val; return true; }
        //             return false;
        //         }
        //
        //         pub inline fn set(self: *@This(), key: Key, val: IT) void {
        //             self.assertValid();
        //             if (!self.exists(key)) unreachable;
        //             self.items[key.index] = val;
        //         }
        //     };
        // }
        //
        fn sliceFunctions(comptime S: type) type {
            return struct {
                pub inline fn assertValid(self: *const S) void {
                    std.debug.assert(if (self.parentValid) |pv| pv.* else self.valid);
                }

                pub inline fn exists(self: *const S, key: Key) bool {
                    return self.source.exists(key);
                }

                pub inline fn get(self: *const S, key: Key) ?T {
                    self.assertValid();
                    if (self.exists(key)) return self.slice.get(key.index);
                    return null;
                }

                // pub inline fn items(self: *const S, comptime field: std.meta.FieldEnum(T)) Items(std.meta.FieldType(T, field)) {
                //     return .{
                //         .source = &(self.source),
                //         .items = self.slice.items(field),
                //         .parentValid = if (self.parentValid) |pv| pv else &self.valid
                //     };
                // }
                //
                pub inline fn iter(self: *const S) Iter {
                    return .{
                        .source = self.source,
                        .slice = self.slice,
                        .parentValid = if (self.parentValid) |pv| pv else &self.valid
                    };
                }
            };
        }

        pub const Slice = struct {
            source: *Self = undefined,
            slice: std.MultiArrayList(T).Slice = undefined,
            valid: bool = true,
            parentValid: ?*bool = null,

            pub inline fn release(self: *Slice) void {
                std.debug.assert(self.parentValid == null and self.valid == true);
                self.valid = false; self.source.mut.unlockShared();
            }

            const sliceFn = sliceFunctions(Slice);
            const assertValid = sliceFn.assertValid;
            pub const exists = sliceFn.exists;
            pub const get = sliceFn.get;
            // pub const items = sliceFn.items;
            pub const iter = sliceFn.iter;
        };

        fn mutFunctions(comptime S: type) type {
            return struct {
                pub inline fn create(self: *S, val: T) !Key {
                    self.assertValid();
                    const key = self.source._awaitNew();
                    self.set(key, val);
                    return key;
                }

                pub inline fn destroy(self: *S, key: Key) void {
                    self.assertValid();
                    self.source.recycle.push(self.mem, key.index).?;
                    self.source.valid.unset(key.index);
                    if (key.index == self.source.items.len - 1) self.source.items.len -= 1;
                }

                pub inline fn set(self: *S, key: Key, val: T) void {
                    self.assertValid();
                    self.slice.set(key.index, val);
                    self.source.valid.set(key.index);
                }

            };
        }

        pub const SliceMut = struct {
            source: *Self = undefined,
            slice: std.MultiArrayList(T).Slice = undefined,
            valid: bool = true,
            parentValid: ?*bool = null,

            pub inline fn release(self: *SliceMut) void {
                std.debug.assert(self.parentValid == null and self.valid == true);
                self.valid = false; self.source.mut.unlock();
            }

            const sliceFn = sliceFunctions(SliceMut);
            const assertValid = sliceFn.assertValid;
            pub const exists = sliceFn.exists;
            pub const get = sliceFn.get;
            // pub const items = sliceFn.items;
            pub const iter = sliceFn.iter;
            const mutFn = mutFunctions(SliceMut);
            pub const create = mutFn.create;
            pub const destroy = mutFn.destroy;
            pub const set = mutFn.set;

            pub inline fn iterMut(self: *const SliceMut) IterMut {
                return .{
                    .source = self.source,
                    .slice = self.slice,
                    .parentValid = if (self.parentValid) |pv| pv else &self.valid
                };
            }
        };

        fn iterFunctions(comptime I: type) type {
            return struct {
                pub fn next(self: *I) ?Key {
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

                pub inline fn done(self: *I) bool {
                    return self.index >= self.slice.len;
                }

                pub inline fn reset(self: *I) void {
                    self.index = 0;
                }

                pub inline fn subIter(self: *I) I {
                    return .{
                        .source = self.source,
                        .slice = self.slice,
                        .parentValid = if (self.parentValid) |pv| pv else &self.valid
                    };
                }

                pub inline fn subIterFrom(self: *I) I {
                    var sub = self.subIter();
                    sub.index = self.index;
                    return sub;
                }
            };
        }

        pub const Iter = struct {
            source: *Self = undefined,
            slice: std.MultiArrayList(T).Slice = undefined,
            valid: bool = true,
            parentValid: ?*bool = null,
            index: u32 = 0,

            pub inline fn release(self: *Iter) void {
                std.debug.assert(self.parentValid == null and self.valid == true);
                self.valid = false; self.source.mut.unlockShared();
            }

            const iterFn = iterFunctions(Iter);
            pub const next = iterFn.next;
            pub const done = iterFn.done;
            pub const reset = iterFn.reset;
            pub const subIter = iterFn.subIter;
            pub const subIterFrom = iterFn.subIterFrom;
            const sliceFn = sliceFunctions(Iter);
            const assertValid = sliceFn.assertValid;
            pub const exists = sliceFn.exists;
            pub const get = sliceFn.get;
            // pub const items = sliceFn.items;

            pub inline fn subSlice(self: *Iter) Slice {
                return .{
                    .source = self.source,
                    .slice = self.slice,
                    .parentValid = if (self.parentValid) |pv| pv else &self.valid
                };
            }
        };

        pub const IterMut = struct {
            source: *Self = undefined,
            slice: std.MultiArrayList(T).Slice = undefined,
            valid: bool = true,
            parentValid: ?*bool = null,
            index: u32 = 0,

            pub inline fn release(self: *IterMut) void {
                std.debug.assert(self.parentValid == null and self.valid == true);
                self.valid = false; self.source.mut.unlock();
            }

            const iterFn = iterFunctions(IterMut);
            pub const next = iterFn.next;
            pub const done = iterFn.done;
            pub const reset = iterFn.reset;
            pub const subIter = iterFn.subIter;
            pub const subIterFrom = iterFn.subIterFrom;
            const sliceFn = sliceFunctions(IterMut);
            const assertValid = sliceFn.assertValid;
            pub const exists = sliceFn.exists;
            pub const get = sliceFn.get;
            // pub const items = sliceFn.items;
            const mutFn = mutFunctions(IterMut);
            pub const create = mutFn.create;
            pub const destroy = mutFn.destroy;
            pub const set = mutFn.set;
        };

        mem: std.mem.Allocator = undefined,
        mut: std.Thread.RwLock = .{},
        items: std.MultiArrayList(T) = .{},
        valid: std.bit_set.DynamicBitSetUnmanaged = .{},
        generation: std.ArrayListUnmanaged(Generation) = .{},
        recycle: UQueue(Key) = .{},

        pub fn init(self: *Self, mem: std.mem.Allocator, size: usize) !void {
            self.mem = mem;
            self.mut.lock();
            defer self.mut.unlock();
            try self.items.ensureTotalCapacity(self.mem, size);
            errdefer self.items.deinit(self.mem);
            try self.valid.resize(self.mem, self.items.capacity, false);
            errdefer self.valid.deinit(self.mem);
            try self.generation.ensureTotalCapacity(self.mem, self.items.capacity);
        }

        pub fn deinit(self: *Self) void {
            self.mut.lock();
            defer self.mut.unlock();
            self.items.deinit(self.mem);
            self.valid.deinit(self.mem);
            self.generation.deinit(self.mem);
            self.recycle.deinit(self.mem);
        }

        pub fn slice(self: *Self) Slice {
            self.mut.lockShared();
            return .{
                .source = self,
                .slice = self.items.slice()
            };
        }

        pub fn sliceMut(self: *Self) SliceMut {
            self.mut.lock();
            return .{
                .source = self,
                .slice = self.items.slice()
            };
        }

        pub fn iter(self: *Self) Iter {
            self.mut.lockShared();
            return .{
                .source = self,
                .slice = self.items.slice()
            };
        }

        pub fn iterMut(self: *Self) IterMut {
            self.mut.lock();
            return .{
                .source = self,
                .slice = self.items.slice()
            };
        }

        pub fn exists(self: *Self, key: Key) bool {
            return self.valid.isSet(key.index) and self.generation.items[key.index] == key.generation;
        }

        fn _awaitNew(self: *Self) !Key {
            while (self.recycle.pop(self.mem)) |rec_key| {
                if (rec_key.index < self.items.len and !self.valid.isSet(rec_key.index)) {
                    const gen = self.generation.items[rec_key.index] +% 1;
                    self.generation.items[rec_key.index] = gen;
                    return .{ .index = rec_key.index, .generation = gen };
                }
            }

            if (self.items.len == self.items.capacity) {
                std.debug.assert(self.items.len < std.math.maxInt(Index));
                try self.items.ensureUnusedCapacity(self.mem, 1);
                try self.valid.resize(self.mem, self.items.capacity, false);
                try self.generation.ensureTotalCapacityPrecise(self.mem, self.items.capacity);
            }

            self.items.len += 1;
            self.generation.items.len = self.items.len;
            self.generation.items[self.items.len - 1] = 0;
            return .{ .index = @as(u32, @intCast(self.items.len - 1)), .generation = 0 };
        }

        pub fn awaitNew(self: *Self) !Key {
            self.mut.lock();
            defer self.mut.unlock();
            return self._awaitNew();
        }

        pub fn create(self: *Self, val: T) !Key {
            const key = try self.awaitNew();
            self.set(key, val);
            return key;
        }

        pub fn set(self: *Self, key: Key, val: T) void {
            self.mut.lock();
            defer self.mut.unlock();
            self.items.set(key.index, val);
            self.valid.set(key.index);
        }

        pub fn destroy(self: *Self, key: Key) void {
            self.mut.lock();
            defer self.mut.unlock();
            self.recycle.push(self.mem, key).?;
            self.valid.unset(key.index);
            if (key.index == self.items.len - 1) self.items.len -= 1;
        }

        pub fn clear(self: *Self) void {
            self.mut.lock();
            defer self.mut.unlock();
            self.items.clearRetainingCapacity();
            self.valid.unsetAll();
            self.generation.clearRetainingCapacity();
            self.recycle.clear();
        }

        pub fn clearFree(self: *Self) void {
            self.mut.lock();
            defer self.mut.unlock();
            self.items.clearAndFree(self.mem);
            self.valid.resize(self.mem, 0, false).?;
            self.generation.clearAndFree(self.mem);
            self.recycle.clear();
        }

        fn _get(self: *Self, key: Key) ?T {
            if (self.exists(key)) return self.items.get(key.index);
            return null;
        }

        pub fn get(self: *Self, key: Key) ?T {
            self.mut.lockShared();
            defer self.mut.unlockShared();
            return self._get(key);
        }

        pub fn trim(self: *Self) void {
            if (self.items.len *| 2 >= self.items.capacity) return;
            self.mut.lock();
            defer self.mut.unlock();
            self.items.shrinkAndFree(self.mem, @divFloor(self.items.capacity, 1));
            std.debug.assert(self.items.capacity <= self.valid.bit_length);
            self.valid.resize(self.mem, self.items.capacity, false) catch unreachable;
            self.generation.shrinkAndFree(self.mem, self.items.capacity);
        }
    };
}

