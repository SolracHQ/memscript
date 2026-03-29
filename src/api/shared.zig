const std = @import("std");
const lua = @import("../lua.zig");
const memory = @import("../memory.zig");
const maps = @import("../maps.zig");
const proc = @import("../proc.zig");
const scan = @import("../scan.zig");
const Context = @import("../context.zig");

pub const context_registry_key: [:0]const u8 = "memscript_context";

pub const ProcessRegionError = error{
    InvalidSelf,
    PidOutOfRange,
};

pub const AddressParseError = error{
    InvalidType,
    InvalidFormat,
    OutOfRange,
};

pub const TableFieldError = error{
    InvalidSelf,
    InvalidField,
    PidOutOfRange,
};

pub const ScanOptionsError = error{
    ExpectedTable,
    MissingType,
    InvalidType,
    MissingCondition,
    MultipleConditions,
    InvalidEq,
    InvalidRange,
};

pub const EntryValueError = error{
    InvalidType,
    OutOfRange,
};

pub const ScanRequest = struct {
    type_selector: TypeSelector,
    condition: scan.Condition,
};

pub const RescanRequest = struct {
    type_selector: ?TypeSelector,
    condition: scan.Condition,
};

pub const TypeSelector = union(enum) {
    concrete: scan.DataType,
    int,
    uint,
    float,
    number,
};

pub const RegionHandle = struct {
    pid: std.posix.pid_t,
    region: maps.Region,
};

pub const EntryHandle = struct {
    pid: std.posix.pid_t,
    entry: scan.Entry,
};

const uint_types = [_]scan.DataType{ .u8, .u16, .u32, .u64 };
const int_types = [_]scan.DataType{ .i8, .i16, .i32, .i64 };
const float_types = [_]scan.DataType{ .f32, .f64 };
const number_types = [_]scan.DataType{ .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f32, .f64 };

pub fn registerContext(state: *lua.State, context: *const Context) void {
    lua.pushLightUserdata(state, context);
    lua.setField(state, lua.REGISTRY_INDEX, context_registry_key);
}

pub fn getContext(state: *lua.State) *const Context {
    _ = lua.getField(state, lua.REGISTRY_INDEX, context_registry_key);
    const context = lua.toLightUserdata(state, -1) orelse unreachable;
    lua.pop(state, 1);
    return @ptrCast(@alignCast(context));
}

pub fn getProcessPid(state: *lua.State, arg_index: lua.StackIndex) ProcessRegionError!std.posix.pid_t {
    if (lua.valueType(state, arg_index) != .table) return error.InvalidSelf;

    const pid_type = lua.getField(state, arg_index, "pid");
    defer lua.pop(state, 1);
    if (pid_type != .number) return error.InvalidSelf;

    const pid = lua.toInteger(state, -1) orelse return error.InvalidSelf;
    return std.math.cast(std.posix.pid_t, pid) orelse error.PidOutOfRange;
}

pub fn getTablePid(state: *lua.State, arg_index: lua.StackIndex) TableFieldError!std.posix.pid_t {
    if (lua.valueType(state, arg_index) != .table) return error.InvalidSelf;

    const pid_type = lua.getField(state, arg_index, "_pid");
    defer lua.pop(state, 1);
    if (pid_type != .number) return error.InvalidField;

    const pid = lua.toInteger(state, -1) orelse return error.InvalidField;
    return std.math.cast(std.posix.pid_t, pid) orelse error.PidOutOfRange;
}

pub fn getRegionHandle(state: *lua.State, arg_index: lua.StackIndex) TableFieldError!RegionHandle {
    const pid = try getTablePid(state, arg_index);
    const start = try getAddressField(state, arg_index, "start");
    const end = try getAddressField(state, arg_index, "end");
    const perms = try getPermsField(state, arg_index, "perms");
    const pathname = try getOptionalStringField(state, arg_index, "pathname");
    if (start > end) return error.InvalidField;

    return .{
        .pid = pid,
        .region = .{
            .start = start,
            .end = end,
            .offset = 0,
            .inode = 0,
            .perms = perms,
            .pathname = pathname,
        },
    };
}

pub fn getEntryHandle(state: *lua.State, arg_index: lua.StackIndex) TableFieldError!EntryHandle {
    const pid = try getTablePid(state, arg_index);
    const address = try getAddressField(state, arg_index, "address");
    const data_type = try getDataTypeField(state, arg_index, "type");

    return .{
        .pid = pid,
        .entry = .{
            .address = address,
            .data_type = data_type,
        },
    };
}

pub fn parseAddressArgument(state: *lua.State, arg_index: lua.StackIndex) AddressParseError!usize {
    return switch (lua.valueType(state, arg_index)) {
        .number => parseAddressInteger(state, arg_index),
        .string => parseAddressString(lua.toString(state, arg_index) orelse return error.InvalidFormat),
        else => error.InvalidType,
    };
}

pub fn parseScanRequest(state: *lua.State, arg_index: lua.StackIndex) ScanOptionsError!ScanRequest {
    if (lua.valueType(state, arg_index) != .table) return error.ExpectedTable;

    return .{
        .type_selector = try parseRequiredTypeSelector(state, arg_index),
        .condition = try parseCondition(state, arg_index),
    };
}

pub fn parseRescanRequest(state: *lua.State, arg_index: lua.StackIndex) ScanOptionsError!RescanRequest {
    if (lua.valueType(state, arg_index) != .table) return error.ExpectedTable;

    return .{
        .type_selector = try parseOptionalTypeSelector(state, arg_index),
        .condition = try parseCondition(state, arg_index),
    };
}

pub fn parseTypeSelector(text: []const u8) ?TypeSelector {
    if (scan.parseDataTypeName(text)) |data_type| {
        return .{ .concrete = data_type };
    }

    if (std.mem.eql(u8, text, "uint")) return .uint;
    if (std.mem.eql(u8, text, "int")) return .int;
    if (std.mem.eql(u8, text, "float")) return .float;
    if (std.mem.eql(u8, text, "number")) return .number;
    return null;
}

pub fn expandTypeSelector(selector: TypeSelector) []const scan.DataType {
    return switch (selector) {
        .concrete => |data_type| switch (data_type) {
            .u8 => uint_types[0..1],
            .u16 => uint_types[1..2],
            .u32 => uint_types[2..3],
            .u64 => uint_types[3..4],
            .i8 => int_types[0..1],
            .i16 => int_types[1..2],
            .i32 => int_types[2..3],
            .i64 => int_types[3..4],
            .f32 => float_types[0..1],
            .f64 => float_types[1..2],
        },
        .uint => uint_types[0..],
        .int => int_types[0..],
        .float => float_types[0..],
        .number => number_types[0..],
    };
}

pub fn expandEntriesForRescan(allocator: std.mem.Allocator, entries: []const scan.Entry, selector: ?TypeSelector) std.mem.Allocator.Error![]scan.Entry {
    if (selector == null) return allocator.dupe(scan.Entry, entries);

    const data_types = expandTypeSelector(selector.?);
    var expanded: std.ArrayList(scan.Entry) = .empty;
    defer expanded.deinit(allocator);

    try expanded.ensureTotalCapacity(allocator, entries.len * data_types.len);

    for (entries) |entry| {
        for (data_types) |data_type| {
            try expanded.append(allocator, .{
                .address = entry.address,
                .data_type = data_type,
            });
        }
    }

    return expanded.toOwnedSlice(allocator);
}

pub fn getOptionalStringField(state: *lua.State, arg_index: lua.StackIndex, key: [:0]const u8) TableFieldError![]const u8 {
    const field_type = lua.getField(state, arg_index, key);
    defer lua.pop(state, 1);

    return switch (field_type) {
        .none, .nil => "",
        .string => lua.toString(state, -1) orelse error.InvalidField,
        else => error.InvalidField,
    };
}

pub fn getAddressField(state: *lua.State, arg_index: lua.StackIndex, key: [:0]const u8) TableFieldError!usize {
    const field_type = lua.getField(state, arg_index, key);
    defer lua.pop(state, 1);
    if (field_type != .string and field_type != .number) return error.InvalidField;

    return parseAddressArgument(state, -1) catch error.InvalidField;
}

pub fn getDataTypeField(state: *lua.State, arg_index: lua.StackIndex, key: [:0]const u8) TableFieldError!scan.DataType {
    const field_type = lua.getField(state, arg_index, key);
    defer lua.pop(state, 1);
    if (field_type != .string) return error.InvalidField;

    const text = lua.toString(state, -1) orelse return error.InvalidField;
    return scan.parseDataTypeName(text) orelse error.InvalidField;
}

pub fn getPermsField(state: *lua.State, arg_index: lua.StackIndex, key: [:0]const u8) TableFieldError![4]u8 {
    const text = try getOptionalStringField(state, arg_index, key);
    if (text.len != 4) return error.InvalidField;
    return .{ text[0], text[1], text[2], text[3] };
}

pub fn freeRegions(context: *const Context, regions: []proc.Region) void {
    for (regions) |*region| region.deinit(context);
    context.allocator.free(regions);
}

pub fn pushHexAddress(state: *lua.State, value: usize) void {
    var buffer: [2 + @sizeOf(usize) * 2]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "0x{x}", .{value}) catch unreachable;
    lua.pushString(state, text);
}

pub fn raiseScanOptionsError(state: *lua.State, operation: []const u8, err: ScanOptionsError) c_int {
    const message = switch (err) {
        error.ExpectedTable => "expects an options table",
        error.MissingType => "requires options.type",
        error.InvalidType => "options.type must be one of u8, u16, u32, u64, i8, i16, i32, i64, f32, f64, uint, int, float, or number",
        error.MissingCondition => "requires either options.eq or options.in_range",
        error.MultipleConditions => "accepts either options.eq or options.in_range, not both",
        error.InvalidEq => "options.eq must be a number",
        error.InvalidRange => "options.in_range must be a table with numeric min and max",
    };
    return raiseOperationError(state, operation, message);
}

pub fn raiseMemoryError(state: *lua.State, operation: []const u8, err: memory.Error) c_int {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "{s} failed: {s}", .{ operation, @errorName(err) }) catch {
        return raiseLuaError(state, "memory operation failed");
    };
    return raiseLuaError(state, message);
}

pub fn raiseProcError(state: *lua.State, operation: []const u8, err: anyerror) c_int {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "{s} failed: {s}", .{ operation, @errorName(err) }) catch {
        return raiseLuaError(state, "process operation failed");
    };
    return raiseLuaError(state, message);
}

pub fn raiseRegionScanError(state: *lua.State, operation: []const u8, region: maps.Region, err: anyerror) c_int {
    const pathname = if (region.pathname.len == 0) "(anonymous)" else region.pathname;
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "{s} failed at 0x{x}-0x{x} [{s}] {s}: {s}",
        .{ operation, region.start, region.end, region.perms[0..], pathname, @errorName(err) },
    ) catch {
        return raiseLuaError(state, "scan failed");
    };
    return raiseLuaError(state, message);
}

pub fn raiseOperationError(state: *lua.State, operation: []const u8, details: []const u8) c_int {
    var buffer: [320]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "{s} {s}", .{ operation, details }) catch {
        return raiseLuaError(state, "operation failed");
    };
    return raiseLuaError(state, message);
}

pub fn raiseLuaError(state: *lua.State, message: []const u8) c_int {
    lua.pushString(state, message);
    return lua.raiseError(state);
}

fn parseAddressInteger(state: *lua.State, arg_index: lua.StackIndex) AddressParseError!usize {
    const address = lua.toInteger(state, arg_index) orelse return error.InvalidType;
    return std.math.cast(usize, address) orelse error.OutOfRange;
}

fn parseAddressString(text: []const u8) AddressParseError!usize {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidFormat;

    const base: u8 = if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) 16 else 10;
    const digits = if (base == 16) trimmed[2..] else trimmed;
    if (digits.len == 0) return error.InvalidFormat;

    return std.fmt.parseInt(usize, digits, base) catch |err| switch (err) {
        error.InvalidCharacter => error.InvalidFormat,
        error.Overflow => error.OutOfRange,
    };
}

fn parseCondition(state: *lua.State, arg_index: lua.StackIndex) ScanOptionsError!scan.Condition {
    if (lua.valueType(state, arg_index) != .table) return error.ExpectedTable;

    const eq_type = lua.getField(state, arg_index, "eq");
    const has_eq = eq_type != .none and eq_type != .nil;
    var eq_value: f64 = undefined;
    if (has_eq) {
        if (eq_type != .number) {
            lua.pop(state, 1);
            return error.InvalidEq;
        }
        eq_value = lua.toNumber(state, -1) orelse {
            lua.pop(state, 1);
            return error.InvalidEq;
        };
    }
    lua.pop(state, 1);

    const range_type = lua.getField(state, arg_index, "in_range");
    const has_range = range_type != .none and range_type != .nil;
    if (has_eq and has_range) {
        lua.pop(state, 1);
        return error.MultipleConditions;
    }
    if (has_eq) {
        lua.pop(state, 1);
        return .{ .eq = eq_value };
    }
    if (!has_range) {
        lua.pop(state, 1);
        return error.MissingCondition;
    }
    if (range_type != .table) {
        lua.pop(state, 1);
        return error.InvalidRange;
    }

    const min_value = getRequiredNumberField(state, -1, "min") catch {
        lua.pop(state, 1);
        return error.InvalidRange;
    };
    const max_value = getRequiredNumberField(state, -1, "max") catch {
        lua.pop(state, 1);
        return error.InvalidRange;
    };
    lua.pop(state, 1);

    if (min_value > max_value) return error.InvalidRange;
    return .{ .in_range = .{ .min = min_value, .max = max_value } };
}

fn getRequiredNumberField(state: *lua.State, arg_index: lua.StackIndex, key: [:0]const u8) TableFieldError!f64 {
    const field_type = lua.getField(state, arg_index, key);
    defer lua.pop(state, 1);
    if (field_type != .number) return error.InvalidField;
    return lua.toNumber(state, -1) orelse error.InvalidField;
}

fn parseRequiredTypeSelector(state: *lua.State, arg_index: lua.StackIndex) ScanOptionsError!TypeSelector {
    const type_type = lua.getField(state, arg_index, "type");
    defer lua.pop(state, 1);
    if (type_type == .none or type_type == .nil) return error.MissingType;
    if (type_type != .string) return error.InvalidType;

    const type_name = lua.toString(state, -1) orelse return error.InvalidType;
    return parseTypeSelector(type_name) orelse error.InvalidType;
}

fn parseOptionalTypeSelector(state: *lua.State, arg_index: lua.StackIndex) ScanOptionsError!?TypeSelector {
    const type_type = lua.getField(state, arg_index, "type");
    defer lua.pop(state, 1);
    if (type_type == .none or type_type == .nil) return null;
    if (type_type != .string) return error.InvalidType;

    const type_name = lua.toString(state, -1) orelse return error.InvalidType;
    return parseTypeSelector(type_name) orelse error.InvalidType;
}

test "parse hex address string" {
    try std.testing.expectEqual(@as(usize, 0xffffffffff600000), try parseAddressString("0xffffffffff600000"));
}

test "parse decimal address string" {
    try std.testing.expectEqual(@as(usize, 1234), try parseAddressString("1234"));
}

test "reject invalid address string" {
    try std.testing.expectError(error.InvalidFormat, parseAddressString("0x"));
    try std.testing.expectError(error.InvalidFormat, parseAddressString("wat"));
}

test "parse type selector aliases" {
    try std.testing.expectEqual(TypeSelector.int, parseTypeSelector("int") orelse unreachable);
    try std.testing.expectEqual(TypeSelector.float, parseTypeSelector("float") orelse unreachable);
    try std.testing.expectEqual(TypeSelector.number, parseTypeSelector("number") orelse unreachable);
    const concrete = parseTypeSelector("u32") orelse unreachable;
    try std.testing.expectEqual(scan.DataType.u32, concrete.concrete);
}
