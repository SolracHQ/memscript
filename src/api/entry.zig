const std = @import("std");
const lua = @import("../lua.zig");
const memory = @import("../memory.zig");
const scan = @import("../scan.zig");
const shared = @import("shared.zig");

pub fn entryListRescan(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const context = shared.getContext(state);

    const pid = shared.getTablePid(state, 1) catch |err| switch (err) {
        error.InvalidSelf, error.InvalidField => return shared.raiseLuaError(state, "entries.rescan expects an entry list"),
        error.PidOutOfRange => return shared.raiseLuaError(state, "entry list pid out of range"),
    };
    const request = shared.parseRescanRequest(state, 2) catch |err| {
        return shared.raiseScanOptionsError(state, "entries.rescan", err);
    };
    const entries = collectEntryList(state, context.allocator, 1) catch |err| switch (err) {
        error.OutOfMemory => return shared.raiseProcError(state, "entries.rescan", err),
        error.InvalidSelf, error.InvalidField => return shared.raiseLuaError(state, "entries.rescan expects a list of entry tables"),
        error.PidOutOfRange => return shared.raiseLuaError(state, "entry pid out of range"),
    };

    const candidates = shared.expandEntriesForRescan(context.allocator, entries, request.type_selector) catch |err| {
        context.allocator.free(entries);
        return shared.raiseProcError(state, "entries.rescan", err);
    };
    context.allocator.free(entries);

    const filtered = scan.rescan(context.allocator, pid, candidates, request.condition) catch |err| {
        context.allocator.free(candidates);
        return shared.raiseProcError(state, "entries.rescan", err);
    };

    pushEntryList(state, pid, filtered);
    context.allocator.free(filtered);
    context.allocator.free(candidates);
    return 1;
}

pub fn entryGet(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;

    const handle = shared.getEntryHandle(state, 1) catch |err| switch (err) {
        error.InvalidSelf, error.InvalidField => return shared.raiseLuaError(state, "entry.get expects an entry table"),
        error.PidOutOfRange => return shared.raiseLuaError(state, "entry pid out of range"),
    };

    readAndPushEntryValue(state, handle.pid, handle.entry) catch |err| {
        return shared.raiseMemoryError(state, "entry.get", err);
    };
    return 1;
}

pub fn entrySet(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;

    const handle = shared.getEntryHandle(state, 1) catch |err| switch (err) {
        error.InvalidSelf, error.InvalidField => return shared.raiseLuaError(state, "entry.set expects an entry table"),
        error.PidOutOfRange => return shared.raiseLuaError(state, "entry pid out of range"),
    };

    var buffer: [@sizeOf(u64)]u8 = undefined;
    const bytes = encodeEntryValue(state, handle.entry, 2, &buffer) catch |err| switch (err) {
        error.InvalidType => return shared.raiseLuaError(state, "entry.set value has the wrong type for this entry"),
        error.OutOfRange => return shared.raiseLuaError(state, "entry.set value out of range for this entry type"),
    };

    memory.writeBytes(handle.pid, handle.entry.address, bytes) catch |err| {
        return shared.raiseMemoryError(state, "entry.set", err);
    };
    return 0;
}

pub fn entryRescan(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const context = shared.getContext(state);

    const handle = shared.getEntryHandle(state, 1) catch |err| switch (err) {
        error.InvalidSelf, error.InvalidField => return shared.raiseLuaError(state, "entry.rescan expects an entry table"),
        error.PidOutOfRange => return shared.raiseLuaError(state, "entry pid out of range"),
    };
    const request = shared.parseRescanRequest(state, 2) catch |err| {
        return shared.raiseScanOptionsError(state, "entry.rescan", err);
    };

    const single_entry = [_]scan.Entry{handle.entry};
    const candidates = shared.expandEntriesForRescan(context.allocator, &single_entry, request.type_selector) catch |err| {
        return shared.raiseProcError(state, "entry.rescan", err);
    };

    const filtered = scan.rescan(context.allocator, handle.pid, candidates, request.condition) catch |err| {
        context.allocator.free(candidates);
        return shared.raiseProcError(state, "entry.rescan", err);
    };

    pushEntryList(state, handle.pid, filtered);
    context.allocator.free(filtered);
    context.allocator.free(candidates);
    return 1;
}

pub fn pushEntryList(state: *lua.State, pid: std.posix.pid_t, entries: []const scan.Entry) void {
    lua.createTable(state, @intCast(entries.len), 2);

    lua.pushInteger(state, std.math.cast(lua.Integer, pid) orelse unreachable);
    lua.setField(state, -2, "_pid");

    lua.pushCFunction(state, entryListRescan);
    lua.setField(state, -2, "rescan");

    for (entries, 0..) |entry, index| {
        pushEntryTable(state, pid, entry);
        lua.setIndex(state, -2, std.math.cast(lua.Integer, index + 1) orelse unreachable);
    }

    setEntryListMetatable(state);
}

pub fn pushEntryTable(state: *lua.State, pid: std.posix.pid_t, entry: scan.Entry) void {
    lua.createTable(state, 0, 6);

    lua.pushInteger(state, std.math.cast(lua.Integer, pid) orelse unreachable);
    lua.setField(state, -2, "_pid");

    shared.pushHexAddress(state, entry.address);
    lua.setField(state, -2, "address");

    lua.pushString(state, scan.dataTypeName(entry.data_type));
    lua.setField(state, -2, "type");

    lua.pushCFunction(state, entryGet);
    lua.setField(state, -2, "get");

    lua.pushCFunction(state, entrySet);
    lua.setField(state, -2, "set");

    lua.pushCFunction(state, entryRescan);
    lua.setField(state, -2, "rescan");

    setEntryMetatable(state);
}

pub fn collectEntryList(state: *lua.State, allocator: std.mem.Allocator, arg_index: lua.StackIndex) (std.mem.Allocator.Error || shared.TableFieldError)![]scan.Entry {
    if (lua.valueType(state, arg_index) != .table) return error.InvalidSelf;

    const count: usize = @intCast(lua.rawLen(state, arg_index));
    const entries = try allocator.alloc(scan.Entry, count);
    errdefer allocator.free(entries);

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry_type = lua.getIndex(state, arg_index, std.math.cast(lua.Integer, index + 1) orelse unreachable);
        if (entry_type != .table) {
            lua.pop(state, 1);
            return error.InvalidField;
        }

        const handle = shared.getEntryHandle(state, -1) catch |err| {
            lua.pop(state, 1);
            return err;
        };
        entries[index] = handle.entry;
        lua.pop(state, 1);
    }

    return entries;
}

fn setEntryListMetatable(state: *lua.State) void {
    lua.createTable(state, 0, 1);
    lua.pushCFunction(state, entryListToString);
    lua.setField(state, -2, "__tostring");
    _ = lua.setMetatable(state, -2);
}

fn setEntryMetatable(state: *lua.State) void {
    lua.createTable(state, 0, 1);
    lua.pushCFunction(state, entryToString);
    lua.setField(state, -2, "__tostring");
    _ = lua.setMetatable(state, -2);
}

fn entryListToString(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    if (lua.valueType(state, 1) != .table) return shared.raiseLuaError(state, "entries tostring expects an entry list");

    const count = lua.rawLen(state, 1);
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "entries(len={d})", .{count}) catch unreachable;
    lua.pushString(state, text);
    return 1;
}

fn entryToString(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const handle = shared.getEntryHandle(state, 1) catch {
        return shared.raiseLuaError(state, "entry tostring expects an entry table");
    };

    var buffer: [192]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "entry(address=0x{x}, type={s})", .{ handle.entry.address, scan.dataTypeName(handle.entry.data_type) }) catch unreachable;
    lua.pushString(state, text);
    return 1;
}

fn readAndPushEntryValue(state: *lua.State, pid: std.posix.pid_t, entry: scan.Entry) memory.Error!void {
    var buffer: [@sizeOf(u64)]u8 = undefined;
    const bytes = buffer[0..scan.dataTypeSize(entry.data_type)];
    try memory.readBytes(pid, entry.address, bytes);

    switch (entry.data_type) {
        .u8 => lua.pushInteger(state, bytesToLuaInteger(u8, bytes)),
        .u16 => lua.pushInteger(state, bytesToLuaInteger(u16, bytes)),
        .u32 => lua.pushInteger(state, bytesToLuaInteger(u32, bytes)),
        .u64 => pushWideUnsigned(state, bytesToValue(u64, bytes)),
        .i8 => lua.pushInteger(state, bytesToLuaInteger(i8, bytes)),
        .i16 => lua.pushInteger(state, bytesToLuaInteger(i16, bytes)),
        .i32 => lua.pushInteger(state, bytesToLuaInteger(i32, bytes)),
        .i64 => pushWideSigned(state, bytesToValue(i64, bytes)),
        .f32 => lua.pushNumber(state, bytesToValue(f32, bytes)),
        .f64 => lua.pushNumber(state, bytesToValue(f64, bytes)),
    }
}

fn encodeEntryValue(state: *lua.State, entry: scan.Entry, value_index: lua.StackIndex, buffer: *[@sizeOf(u64)]u8) shared.EntryValueError![]const u8 {
    return switch (entry.data_type) {
        .u8 => try encodeTypedEntry(u8, state, value_index, buffer),
        .u16 => try encodeTypedEntry(u16, state, value_index, buffer),
        .u32 => try encodeTypedEntry(u32, state, value_index, buffer),
        .u64 => try encodeTypedEntry(u64, state, value_index, buffer),
        .i8 => try encodeTypedEntry(i8, state, value_index, buffer),
        .i16 => try encodeTypedEntry(i16, state, value_index, buffer),
        .i32 => try encodeTypedEntry(i32, state, value_index, buffer),
        .i64 => try encodeTypedEntry(i64, state, value_index, buffer),
        .f32 => try encodeTypedFloatEntry(f32, state, value_index, buffer),
        .f64 => try encodeTypedFloatEntry(f64, state, value_index, buffer),
    };
}

fn bytesToLuaInteger(comptime T: type, bytes: []const u8) lua.Integer {
    const value = bytesToValue(T, bytes);
    return std.math.cast(lua.Integer, value) orelse unreachable;
}

fn pushWideUnsigned(state: *lua.State, value: u64) void {
    if (std.math.cast(lua.Integer, value)) |integer_value| {
        lua.pushInteger(state, integer_value);
        return;
    }

    lua.pushNumber(state, @floatFromInt(value));
}

fn pushWideSigned(state: *lua.State, value: i64) void {
    if (std.math.cast(lua.Integer, value)) |integer_value| {
        lua.pushInteger(state, integer_value);
        return;
    }

    lua.pushNumber(state, @floatFromInt(value));
}

fn encodeTypedEntry(comptime T: type, state: *lua.State, value_index: lua.StackIndex, buffer: *[@sizeOf(u64)]u8) shared.EntryValueError![]const u8 {
    const integer_value = lua.toInteger(state, value_index) orelse return error.InvalidType;
    const typed_value = std.math.cast(T, integer_value) orelse return error.OutOfRange;
    return valueToBytes(T, typed_value, buffer);
}

fn encodeTypedFloatEntry(comptime T: type, state: *lua.State, value_index: lua.StackIndex, buffer: *[@sizeOf(u64)]u8) shared.EntryValueError![]const u8 {
    const number_value = lua.toNumber(state, value_index) orelse return error.InvalidType;
    const typed_value: T = @floatCast(number_value);
    return valueToBytes(T, typed_value, buffer);
}

fn bytesToValue(comptime T: type, bytes: []const u8) T {
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
    return value;
}

fn valueToBytes(comptime T: type, value: T, buffer: *[@sizeOf(u64)]u8) []const u8 {
    var typed_value = value;
    const bytes = std.mem.asBytes(&typed_value);
    @memcpy(buffer[0..bytes.len], bytes);
    return buffer[0..bytes.len];
}
