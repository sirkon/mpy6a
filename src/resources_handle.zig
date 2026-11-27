//! Descriptor handles, the ownership transitions over them and the plain
//! input/output helpers that work on the number.
//!
//! This leaf imports only `std`: it knows nothing about the controller, so any
//! file may use it without pulling the controller in. The descriptor itself is
//! still a plain number on the wire and in the OS table; the handle only
//! records who owns it in the code. Every helper here is *use* except
//! `syncAll`, the commit point: it is management, so only `resources.zig`
//! calls it.
//!
//! `OwnedFd.fd` is written by this file alone, plus the default `-1` the
//! struct constructors leave behind. Zig has no private fields, so nothing
//! stops another file from assigning `.fd` by hand; that rule is enforced by
//! review, not by the compiler, and the M7 guard watches acquire/release and
//! the destruction of owning objects instead.

const std = @import("std");
const posix = std.posix;

/// A descriptor this code owns. `-1` means "not held".
pub const OwnedFd = struct {
    fd: posix.fd_t = -1,

    pub fn isHeld(self: OwnedFd) bool {
        return self.fd >= 0;
    }
};

pub const FileHandle = OwnedFd;
pub const SocketHandle = OwnedFd;

/// Take a number nobody else owns. The caller must hand over a live `fd`.
pub fn adopt(fd: posix.fd_t) OwnedFd {
    std.debug.assert(fd >= 0);
    return .{ .fd = fd };
}

/// Hand the number to the caller, keeping ownership with them; the field
/// becomes `-1`.
pub fn take(held: *OwnedFd) posix.fd_t {
    const fd = held.fd;
    held.fd = -1;
    return fd;
}

/// Close and clear; a no-op while nothing is held.
pub fn close(held: *OwnedFd) std.os.linux.E {
    if (!held.isHeld()) return .SUCCESS;
    const err = std.os.linux.errno(std.os.linux.close(held.fd));
    held.fd = -1;
    return err;
}

/// Move ownership inside the logic: `dst` receives the number, `src` empties.
/// The caller must have released `dst` first.
pub fn move(dst: *OwnedFd, src: *OwnedFd) void {
    if (dst == src) return;
    dst.fd = src.fd;
    src.fd = -1;
}

/// Read the number without changing ownership. Valid for borrowed descriptors
/// only: the borrower never closes or hands it over.
pub fn borrow(held: *const OwnedFd) posix.fd_t {
    return held.fd;
}

/// Writes every byte of `bytes` into `fd`.
pub fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const res = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        const errno = std.os.linux.errno(res);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        if (res == 0) return error.WriteZero;
        done += res;
    }
}

/// The commit point: `fdatasync`. Only `resources.zig` calls this.
pub fn syncAll(fd: posix.fd_t) !void {
    const errno = std.os.linux.errno(std.os.linux.fdatasync(fd));
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
}

/// Reads exactly `dst.len` bytes at `offset`. A short read is a torn file.
pub fn readFully(fd: posix.fd_t, dst: []u8, offset: u64) !void {
    var got: usize = 0;
    while (got < dst.len) {
        const at: posix.off_t = @intCast(offset + got);
        const res = std.os.linux.pread(fd, dst[got..].ptr, dst.len - got, at);
        const errno = std.os.linux.errno(res);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        if (res == 0) return error.EndOfStream;
        got += res;
    }
}

/// Writes all of `bytes` at `offset`.
pub fn pwriteAll(fd: posix.fd_t, bytes: []const u8, offset: u64) !void {
    var put: usize = 0;
    while (put < bytes.len) {
        const at: posix.off_t = @intCast(offset + put);
        const res = std.os.linux.pwrite(fd, bytes[put..].ptr, bytes.len - put, at);
        const errno = std.os.linux.errno(res);
        if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
        put += res;
    }
}

/// The byte size behind `fd` — a WAL file's length or the PMEM device's
/// capacity. `statx` is the only stat family call the platform layer still
/// offers on Linux; `AT.EMPTY_PATH` targets the descriptor itself.
pub fn fileSize(fd: posix.fd_t) !u64 {
    var stx: std.os.linux.Statx = undefined;
    const res = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx);
    const errno = std.os.linux.errno(res);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
    return stx.size;
}
