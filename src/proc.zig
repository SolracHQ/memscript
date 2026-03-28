const std = @import("std");
const Io = std.Io;
const Context = @import("context.zig");
const maps = @import("maps.zig");

pub const ListOptions = struct {
    name_substring: ?[]const u8 = null,
};

pub const Error = std.mem.Allocator.Error || Io.Dir.OpenError || Io.Dir.Reader.Error || Io.Dir.ReadFileError || error{
    InvalidStatus,
    StreamTooLong,
};

pub const Region = maps.Region;
pub const RegionsOptions = maps.ListOptions;
pub const RegionsError = maps.Error;

pub const Process = struct {
    pid: std.posix.pid_t,
    uid: std.posix.uid_t,
    name: []const u8,
    cmdLine: []const u8,

    pub fn deinit(self: *Process, context: *const Context) void {
        context.allocator.free(self.name);
        context.allocator.free(self.cmdLine);
    }
};

const proc_small_file_limit = 16 * 1024;
const proc_cmd_line_limit = 64 * 1024;

pub fn list(context: *const Context, options: ListOptions) Error![]Process {
    var proc_dir = try Io.Dir.cwd().openDir(context.io, "/proc", .{ .iterate = true });
    defer proc_dir.close(context.io);

    var iter = proc_dir.iterateAssumeFirstIteration();
    var processes: std.ArrayList(Process) = .empty;
    errdefer {
        for (processes.items) |*process| process.deinit(context);
        processes.deinit(context.allocator);
    }

    while (try iter.next(context.io)) |entry| {
        if (entry.kind != .directory) continue;

        const pid = parsePid(entry.name) orelse continue;

        const process = readProcess(context, proc_dir, entry.name, pid) catch |err| switch (err) {
            error.FileNotFound,
            error.AccessDenied,
            error.PermissionDenied,
            error.NotDir,
            error.InvalidStatus,
            => continue,
            else => return err,
        };

        if (options.name_substring) |needle| {
            if (std.mem.indexOf(u8, process.name, needle) == null) {
                var skipped = process;
                skipped.deinit(context);
                continue;
            }
        }

        try processes.append(context.allocator, process);
    }

    return processes.toOwnedSlice(context.allocator);
}

pub fn regions(context: *const Context, pid: std.posix.pid_t, options: RegionsOptions) RegionsError![]Region {
    return maps.list(context, pid, options);
}

fn parsePid(text: []const u8) ?std.posix.pid_t {
    if (text.len == 0) return null;

    for (text) |char| {
        if (!std.ascii.isDigit(char)) return null;
    }

    return std.fmt.parseInt(std.posix.pid_t, text, 10) catch null;
}

fn readProcess(context: *const Context, proc_dir: Io.Dir, pid_dir_name: []const u8, pid: std.posix.pid_t) Error!Process {
    var pid_dir = try proc_dir.openDir(context.io, pid_dir_name, .{});
    defer pid_dir.close(context.io);

    const name = try readName(context, pid_dir);
    errdefer context.allocator.free(name);

    const cmdLine = try readCmdline(context, pid_dir);
    errdefer context.allocator.free(cmdLine);

    const uid = try readUid(context, pid_dir);

    return .{
        .pid = pid,
        .uid = uid,
        .name = name,
        .cmdLine = cmdLine,
    };
}

fn readName(context: *const Context, pid_dir: Io.Dir) Error![]const u8 {
    return readTrimmedFile(context, pid_dir, "comm", "\r\n", proc_small_file_limit);
}

fn readCmdline(context: *const Context, pid_dir: Io.Dir) Error![]const u8 {
    var buffer: [proc_cmd_line_limit + 1]u8 = undefined;
    const raw = try readFileBounded(pid_dir, context, "cmdline", &buffer);

    if (raw.len == 0) {
        return context.allocator.dupe(u8, "");
    }

    const cmdline = try context.allocator.dupe(u8, raw);
    errdefer context.allocator.free(cmdline);

    for (cmdline) |*char| {
        if (char.* == 0) char.* = ' ';
    }

    const trimmed = std.mem.trim(u8, cmdline, " \t\r\n");
    if (trimmed.ptr == cmdline.ptr and trimmed.len == cmdline.len) {
        return cmdline;
    }

    const result = try context.allocator.dupe(u8, trimmed);
    context.allocator.free(cmdline);
    return result;
}

fn readUid(context: *const Context, pid_dir: Io.Dir) Error!std.posix.uid_t {
    var buffer: [proc_small_file_limit + 1]u8 = undefined;
    const raw = try readFileBounded(pid_dir, context, "status", &buffer);

    const uid_prefix_index = std.mem.indexOf(u8, raw, "\nUid:") orelse blk: {
        if (std.mem.startsWith(u8, raw, "Uid:")) break :blk 0;
        return error.InvalidStatus;
    };

    const uid_start = if (uid_prefix_index == 0) 4 else uid_prefix_index + 5;
    var uid_lines = std.mem.splitScalar(u8, raw[uid_start..], '\n');
    const uid_line = uid_lines.first();
    var fields = std.mem.tokenizeAny(u8, uid_line, " \t");
    const uid_text = fields.next() orelse return error.InvalidStatus;
    return std.fmt.parseInt(std.posix.uid_t, uid_text, 10) catch error.InvalidStatus;
}

fn readTrimmedFile(context: *const Context, proc_dir: Io.Dir, path: []const u8, trim_chars: []const u8, comptime limit: usize) Error![]const u8 {
    var buffer: [limit + 1]u8 = undefined;
    const raw = try readFileBounded(proc_dir, context, path, &buffer);
    const trimmed = std.mem.trimEnd(u8, raw, trim_chars);
    return context.allocator.dupe(u8, trimmed);
}

fn readFileBounded(dir: Io.Dir, context: *const Context, path: []const u8, buffer: []u8) Error![]const u8 {
    const raw = try dir.readFile(context.io, path, buffer);
    if (raw.len == buffer.len) return error.StreamTooLong;
    return raw;
}

test "parse pid from proc entry name" {
    try std.testing.expectEqual(@as(?std.posix.pid_t, 1234), parsePid("1234"));
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), parsePid("self"));
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), parsePid("12x"));
}
