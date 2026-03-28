const std = @import("std");
const Io = std.Io;
const Context = @import("context.zig");

const proc_maps_limit = 1024 * 1024;

pub const ListOptions = struct {
    perms: ?[]const u8 = null,
};

pub const Error = std.mem.Allocator.Error || std.fmt.ParseIntError || Io.Dir.OpenError || Io.Dir.ReadFileError || error{
    InvalidLine,
    InvalidPermissions,
    StreamTooLong,
};

pub const Region = struct {
    start: usize,
    end: usize,
    offset: usize,
    inode: u64,
    perms: [4]u8,
    pathname: []const u8,

    pub fn deinit(self: *Region, context: *const Context) void {
        context.allocator.free(self.pathname);
    }

    pub fn size(self: Region) usize {
        return self.end - self.start;
    }
};

pub fn list(context: *const Context, pid: std.posix.pid_t, options: ListOptions) Error![]Region {
    var proc_dir = try Io.Dir.cwd().openDir(context.io, "/proc", .{});
    defer proc_dir.close(context.io);

    var pid_path_buffer: [32]u8 = undefined;
    const pid_path = try std.fmt.bufPrint(&pid_path_buffer, "{d}", .{pid});
    var pid_dir = try proc_dir.openDir(context.io, pid_path, .{});
    defer pid_dir.close(context.io);

    var maps_buffer: [proc_maps_limit + 1]u8 = undefined;
    const maps_data = try pid_dir.readFile(context.io, "maps", &maps_buffer);
    if (maps_data.len == maps_buffer.len) return error.StreamTooLong;

    var regions: std.ArrayList(Region) = .empty;
    errdefer {
        for (regions.items) |*region| region.deinit(context);
        regions.deinit(context.allocator);
    }

    var lines = std.mem.splitScalar(u8, maps_data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const region = try parseLine(context.allocator, trimmed);
        errdefer {
            var owned_region = region;
            owned_region.deinit(context);
        }

        if (!matchesOptions(region, options)) {
            var skipped = region;
            skipped.deinit(context);
            continue;
        }

        try regions.append(context.allocator, region);
    }

    return regions.toOwnedSlice(context.allocator);
}

// Parsing helpers

fn parseLine(allocator: std.mem.Allocator, line: []const u8) Error!Region {
    var cursor: usize = 0;
    const address_field = nextField(line, &cursor) orelse return error.InvalidLine;
    const perms_field = nextField(line, &cursor) orelse return error.InvalidLine;
    const offset_field = nextField(line, &cursor) orelse return error.InvalidLine;
    _ = nextField(line, &cursor) orelse return error.InvalidLine;
    const inode_field = nextField(line, &cursor) orelse return error.InvalidLine;
    while (cursor < line.len and isWhitespace(line[cursor])) {
        cursor += 1;
    }
    const pathname_field = line[cursor..];

    const range = std.mem.indexOfScalar(u8, address_field, '-') orelse return error.InvalidLine;
    const start = try std.fmt.parseInt(usize, address_field[0..range], 16);
    const end = try std.fmt.parseInt(usize, address_field[range + 1 ..], 16);
    if (start > end) return error.InvalidLine;

    if (perms_field.len != 4) return error.InvalidPermissions;
    const perms: [4]u8 = .{ perms_field[0], perms_field[1], perms_field[2], perms_field[3] };
    if (!isValidPerms(perms)) return error.InvalidPermissions;

    const offset = try std.fmt.parseInt(usize, offset_field, 16);
    const inode = try std.fmt.parseInt(u64, inode_field, 10);
    const pathname = try allocator.dupe(u8, pathname_field);

    return .{
        .start = start,
        .end = end,
        .offset = offset,
        .inode = inode,
        .perms = perms,
        .pathname = pathname,
    };
}

fn nextField(line: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < line.len and isWhitespace(line[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* == line.len) return null;

    const start = cursor.*;
    while (cursor.* < line.len and !isWhitespace(line[cursor.*])) {
        cursor.* += 1;
    }
    return line[start..cursor.*];
}

fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\t';
}

fn isValidPerms(perms: [4]u8) bool {
    return (perms[0] == 'r' or perms[0] == '-') and
        (perms[1] == 'w' or perms[1] == '-') and
        (perms[2] == 'x' or perms[2] == '-') and
        (perms[3] == 'p' or perms[3] == 's');
}

// Filter helpers

fn matchesOptions(region: Region, options: ListOptions) bool {
    if (options.perms) |required_perms| {
        if (!matchesPerms(region.perms[0..], required_perms)) return false;
    }

    return true;
}

fn matchesPerms(region_perms: []const u8, required_perms: []const u8) bool {
    for (required_perms) |perm| {
        if (perm == ' ' or perm == '\t') continue;
        if (std.mem.indexOfScalar(u8, region_perms, perm) == null) return false;
    }
    return true;
}

test "parse named maps line" {
    const allocator = std.testing.allocator;

    var region = try parseLine(allocator, "7f8f09d36000-7f8f09d69000 r-xp 00000000 00:21 296841 /usr/lib64/liblua-5.4.so");
    defer allocator.free(region.pathname);

    try std.testing.expectEqual(@as(usize, 0x7f8f09d36000), region.start);
    try std.testing.expectEqual(@as(usize, 0x7f8f09d69000), region.end);
    try std.testing.expectEqual(@as(usize, 0), region.offset);
    try std.testing.expectEqual(@as(u64, 296841), region.inode);
    try std.testing.expectEqualStrings("r-xp", region.perms[0..]);
    try std.testing.expectEqualStrings("/usr/lib64/liblua-5.4.so", region.pathname);
}

test "parse anonymous maps line" {
    const allocator = std.testing.allocator;

    var region = try parseLine(allocator, "012d6000-012d7000 rw-p 00000000 00:00 0");
    defer allocator.free(region.pathname);

    try std.testing.expectEqual(@as(usize, 0x012d6000), region.start);
    try std.testing.expectEqual(@as(usize, 0x012d7000), region.end);
    try std.testing.expectEqualStrings("rw-p", region.perms[0..]);
    try std.testing.expectEqualStrings("", region.pathname);
}

test "permissions filter matches required flags" {
    try std.testing.expect(matchesPerms("rw-p", "rw"));
    try std.testing.expect(matchesPerms("r-xp", "xp"));
    try std.testing.expect(!matchesPerms("r--p", "w"));
}
