const std = @import("std");
const maps = @import("maps.zig");
const memory = @import("memory.zig");

const float_epsilon = 1e-6;

pub const DataType = enum {
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
};

pub const Entry = struct {
    address: usize,
    data_type: DataType,
};

pub const Condition = union(enum) {
    eq: f64,
    in_range: struct {
        min: f64,
        max: f64,
    },
};

pub const Error = std.mem.Allocator.Error || memory.Error;

pub fn parseDataTypeName(text: []const u8) ?DataType {
    inline for (std.meta.fields(DataType)) |field| {
        if (std.mem.eql(u8, text, field.name)) {
            return @field(DataType, field.name);
        }
    }

    return null;
}

pub fn dataTypeName(data_type: DataType) []const u8 {
    return @tagName(data_type);
}

pub fn dataTypeSize(data_type: DataType) usize {
    return switch (data_type) {
        .u8, .i8 => @sizeOf(u8),
        .u16, .i16 => @sizeOf(u16),
        .u32, .i32, .f32 => @sizeOf(u32),
        .u64, .i64, .f64 => @sizeOf(u64),
    };
}

pub fn scan(
    allocator: std.mem.Allocator,
    pid: std.posix.pid_t,
    region: maps.Region,
    data_type: DataType,
    condition: Condition,
) Error![]Entry {
    const step = dataTypeSize(data_type);
    const region_size = region.size();
    if (region_size < step) return allocator.alloc(Entry, 0);

    const buffer = try allocator.alloc(u8, region_size);
    defer allocator.free(buffer);

    try memory.readBytes(pid, region.start, buffer);

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    try entries.ensureTotalCapacity(allocator, region_size / step);

    var offset: usize = 0;
    while (offset + step <= buffer.len) : (offset += step) {
        const bytes = buffer[offset .. offset + step];
        if (!matchesCondition(data_type, bytes, condition)) continue;

        try entries.append(allocator, .{
            .address = region.start + offset,
            .data_type = data_type,
        });
    }

    return entries.toOwnedSlice(allocator);
}

pub fn rescan(
    allocator: std.mem.Allocator,
    pid: std.posix.pid_t,
    entries: []const Entry,
    condition: Condition,
) Error![]Entry {
    if (entries.len == 0) return allocator.alloc(Entry, 0);

    var filtered: std.ArrayList(Entry) = .empty;
    defer filtered.deinit(allocator);

    try filtered.ensureTotalCapacity(allocator, entries.len);

    var buffer: [@sizeOf(u64)]u8 = undefined;
    for (entries) |entry| {
        const size = dataTypeSize(entry.data_type);
        try memory.readBytes(pid, entry.address, buffer[0..size]);
        if (!matchesCondition(entry.data_type, buffer[0..size], condition)) continue;
        try filtered.append(allocator, entry);
    }

    return filtered.toOwnedSlice(allocator);
}

pub const reScan = rescan;

// Matching helpers

fn matchesCondition(data_type: DataType, bytes: []const u8, condition: Condition) bool {
    return switch (data_type) {
        .u8 => matchesInteger(u8, bytesToValue(u8, bytes), condition),
        .u16 => matchesInteger(u16, bytesToValue(u16, bytes), condition),
        .u32 => matchesInteger(u32, bytesToValue(u32, bytes), condition),
        .u64 => matchesInteger(u64, bytesToValue(u64, bytes), condition),
        .i8 => matchesInteger(i8, bytesToValue(i8, bytes), condition),
        .i16 => matchesInteger(i16, bytesToValue(i16, bytes), condition),
        .i32 => matchesInteger(i32, bytesToValue(i32, bytes), condition),
        .i64 => matchesInteger(i64, bytesToValue(i64, bytes), condition),
        .f32 => matchesFloat(f32, bytesToValue(f32, bytes), condition),
        .f64 => matchesFloat(f64, bytesToValue(f64, bytes), condition),
    };
}

fn bytesToValue(comptime T: type, bytes: []const u8) T {
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
    return value;
}

fn matchesInteger(comptime T: type, value: T, condition: Condition) bool {
    return switch (condition) {
        .eq => |expected| blk: {
            const typed_expected = exactFloatToInteger(T, expected) orelse break :blk false;
            break :blk value == typed_expected;
        },
        .in_range => |range| blk: {
            const numeric_value = @as(f64, @floatFromInt(value));
            break :blk numeric_value >= range.min and numeric_value <= range.max;
        },
    };
}

fn matchesFloat(comptime T: type, value: T, condition: Condition) bool {
    return switch (condition) {
        .eq => |expected| blk: {
            if (!std.math.isFinite(expected)) break :blk false;
            const typed_expected: T = @floatCast(expected);
            break :blk @abs(value - typed_expected) <= @as(T, @floatCast(float_epsilon));
        },
        .in_range => |range| blk: {
            const numeric_value = @as(f64, @floatCast(value));
            break :blk numeric_value >= range.min and numeric_value <= range.max;
        },
    };
}

fn exactFloatToInteger(comptime T: type, value: f64) ?T {
    if (!std.math.isFinite(value)) return null;
    if (@trunc(value) != value) return null;

    const info = @typeInfo(T).int;
    const min_value = if (info.signedness == .signed)
        @as(f64, @floatFromInt(std.math.minInt(T)))
    else
        0.0;
    const max_value = @as(f64, @floatFromInt(std.math.maxInt(T)));
    if (value < min_value or value > max_value) return null;

    return @as(T, @intFromFloat(value));
}

test "parse data type name" {
    try std.testing.expectEqual(DataType.u32, parseDataTypeName("u32") orelse unreachable);
    try std.testing.expectEqual(@as(?DataType, null), parseDataTypeName("wat"));
}

test "integer equality requires exact integer condition" {
    const bytes = [_]u8{ 0x2a, 0x00, 0x00, 0x00 };

    try std.testing.expect(matchesCondition(.u32, &bytes, .{ .eq = 42.0 }));
    try std.testing.expect(!matchesCondition(.u32, &bytes, .{ .eq = 42.5 }));
}

test "float equality uses epsilon" {
    var value: f32 = 8.3;
    const bytes = std.mem.asBytes(&value);

    try std.testing.expect(matchesCondition(.f32, bytes, .{ .eq = 8.3000004 }));
    try std.testing.expect(!matchesCondition(.f32, bytes, .{ .eq = 8.31 }));
}
