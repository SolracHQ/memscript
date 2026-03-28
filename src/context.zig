const std = @import("std");
const Io = std.Io;

allocator: std.mem.Allocator,
io: Io,
stdout_buffer: []u8,
stderr_buffer: []u8,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, io: Io, stdout_buffer: []u8, stderr_buffer: []u8) Self {
    return Self{
        .allocator = allocator,
        .io = io,
        .stdout_buffer = stdout_buffer,
        .stderr_buffer = stderr_buffer,
    };
}

pub fn printStderr(self: Self, comptime fmt: []const u8, args: anytype) !void {
    var writer: Io.File.Writer = .init(.stderr(), self.io, self.stderr_buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

pub fn printStdout(self: Self, comptime fmt: []const u8, args: anytype) !void {
    var writer: Io.File.Writer = .init(.stdout(), self.io, self.stdout_buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
