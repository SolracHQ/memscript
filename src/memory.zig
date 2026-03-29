//! Linux process memory access helpers built around `process_vm_readv` and
//! `process_vm_writev`.
const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    AccessDenied,
    InvalidAddress,
    InvalidArgument,
    NoSuchProcess,
    OutOfMemory,
    PartialTransfer,
    NotImplemented,
    Unexpected,
};

/// A parsed region from `/proc/<pid>/maps`.
pub const Region = struct {
    start: usize,
    end: usize,
    readable: bool,
    writable: bool,
    executable: bool,
    pathname: ?[]const u8 = null,
};

const iovec = std.posix.iovec;
const iovec_const = std.posix.iovec_const;

/// Reads a single native-endian `u32` from another process.
///
/// This uses a single remote iovec entry, so any short result is reported as
/// `error.PartialTransfer` instead of returning truncated data.
pub fn readU32(pid: std.posix.pid_t, address: usize) Error!u32 {
    var buffer: [4]u8 = undefined;
    const local = [_]iovec{.{
        .base = buffer[0..].ptr,
        .len = buffer.len,
    }};
    const remote = [_]iovec_const{.{
        .base = @ptrFromInt(address),
        .len = buffer.len,
    }};
    try expectFullTransfer(linux.process_vm_readv(pid, &local, &remote, 0), buffer.len);
    return @bitCast(buffer);
}

/// Reads an arbitrary byte range from another process into `buffer`.
pub fn readBytes(pid: std.posix.pid_t, address: usize, buffer: []u8) Error!void {
    if (buffer.len == 0) return;

    const local = [_]iovec{.{
        .base = buffer.ptr,
        .len = buffer.len,
    }};
    const remote = [_]iovec_const{.{
        .base = @ptrFromInt(address),
        .len = buffer.len,
    }};
    try expectFullTransfer(linux.process_vm_readv(pid, &local, &remote, 0), buffer.len);
}

/// Writes a single native-endian `u32` into another process.
///
/// The syscall is not atomic across processes; this wrapper only guarantees
/// that short writes are surfaced as `error.PartialTransfer`.
pub fn writeU32(pid: std.posix.pid_t, address: usize, value: u32) Error!void {
    const bytes: [4]u8 = @bitCast(value);
    const local = [_]iovec_const{.{
        .base = bytes[0..].ptr,
        .len = bytes.len,
    }};
    const remote = [_]iovec_const{.{
        .base = @ptrFromInt(address),
        .len = bytes.len,
    }};
    try expectFullTransfer(linux.process_vm_writev(pid, &local, &remote, 0), bytes.len);
}

/// Writes an arbitrary byte range into another process.
pub fn writeBytes(pid: std.posix.pid_t, address: usize, bytes: []const u8) Error!void {
    if (bytes.len == 0) return;

    const local = [_]iovec_const{.{
        .base = bytes.ptr,
        .len = bytes.len,
    }};
    const remote = [_]iovec_const{.{
        .base = @ptrFromInt(address),
        .len = bytes.len,
    }};
    try expectFullTransfer(linux.process_vm_writev(pid, &local, &remote, 0), bytes.len);
}

/// Parses `/proc/<pid>/maps` into memory regions.
///
/// This is still intentionally left as a stub while the raw read/write path is
/// being established first.
pub fn parseMaps(allocator: std.mem.Allocator, pid: std.posix.pid_t) Error![]Region {
    _ = allocator;
    _ = pid;
    return Error.NotImplemented;
}

fn expectFullTransfer(result: usize, expected_len: usize) Error!void {
    switch (linux.errno(result)) {
        .SUCCESS => {
            if (result != expected_len) return Error.PartialTransfer;
        },
        .FAULT => return Error.InvalidAddress,
        .INVAL => return Error.InvalidArgument,
        .NOMEM => return Error.OutOfMemory,
        .PERM => return Error.AccessDenied,
        .SRCH => return Error.NoSuchProcess,
        else => return Error.Unexpected,
    }
}
