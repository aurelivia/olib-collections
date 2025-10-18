const std = @import("std");

rw: std.Thread.RwLock = .{},
snapshot: std.atomic.Value(usize) = .init(0),

pub inline fn lock(self: *const @This()) void {
    @constCast(self).rw.lockShared();
}

pub inline fn tryLock(self: *const @This()) bool {
    return @constCast(self).rw.tryLockShared();
}

pub inline fn unlock(self: *const @This()) void {
    @constCast(self).rw.unlockShared();
}

pub inline fn lockMut(self: *@This()) void {
    self.rw.lock();
}

pub inline fn tryLockMut(self: *@This()) bool {
    return self.rw.tryLock();
}

pub inline fn unlockMut(self: *@This()) void {
    _ = self.snapshot.fetchAdd(1, .acq_rel);
    self.rw.unlock();
}

pub fn toMut(self: *@This()) bool {
    const snapped = self.snapshot.load(.acquire);
    self.rw.unlockShared();
    self.rw.lock();
    if (self.snapshot.load(.acquire) != snapped) {
        self.rw.unlock();
        return false;
    } return true;
}
