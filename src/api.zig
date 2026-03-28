const std = @import("std");
const lua = @import("lua.zig");
const memory = @import("memory.zig");
const proc = @import("proc.zig");
const Context = @import("context.zig");

const context_registry_key: [:0]const u8 = "memscript_context";

const ProcessRegionError = error{
    InvalidSelf,
    PidOutOfRange,
};

const AddressParseError = error{
    InvalidType,
    InvalidFormat,
    OutOfRange,
};

pub fn register(state: *lua.State, context: *const Context) void {
    // store context pointer in Lua registry
    lua.pushLightUserdata(state, context);
    lua.setField(state, lua.REGISTRY_INDEX, context_registry_key);

    // create mem table and register functions
    lua.newTable(state);

    lua.pushCFunction(state, readU32);
    lua.setField(state, -2, "read_u32");

    lua.pushCFunction(state, writeU32);
    lua.setField(state, -2, "write_u32");

    lua.setGlobal(state, "mem");

    lua.newTable(state);

    lua.pushCFunction(state, listProcesses);
    lua.setField(state, -2, "list");

    lua.setGlobal(state, "proc");
}

pub fn readU32(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const pid = lua.checkInteger(state, 1);

    const pid_value = std.math.cast(std.posix.pid_t, pid) orelse {
        return raiseLuaError(state, "pid out of range");
    };
    const address_value = parseAddressArgument(state, 2) catch |err| switch (err) {
        error.InvalidType => return raiseLuaError(state, "address must be an integer or string"),
        error.InvalidFormat => return raiseLuaError(state, "address string must be decimal or hex"),
        error.OutOfRange => return raiseLuaError(state, "address out of range"),
    };

    const value = memory.readU32(pid_value, address_value) catch |err| {
        return raiseMemoryError(state, "mem.read_u32", err);
    };

    lua.pushInteger(state, value);
    return 1;
}

pub fn writeU32(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const pid = lua.checkInteger(state, 1);
    const value = lua.checkInteger(state, 3);

    const pid_value = std.math.cast(std.posix.pid_t, pid) orelse {
        return raiseLuaError(state, "pid out of range");
    };
    const address_value = parseAddressArgument(state, 2) catch |err| switch (err) {
        error.InvalidType => return raiseLuaError(state, "address must be an integer or string"),
        error.InvalidFormat => return raiseLuaError(state, "address string must be decimal or hex"),
        error.OutOfRange => return raiseLuaError(state, "address out of range"),
    };
    const value_u32 = std.math.cast(u32, value) orelse {
        return raiseLuaError(state, "value out of range for u32");
    };

    memory.writeU32(pid_value, address_value, value_u32) catch |err| {
        return raiseMemoryError(state, "mem.write_u32", err);
    };

    return 0;
}

pub fn listProcesses(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const context = getContext(state);

    var options: proc.ListOptions = .{};
    switch (lua.valueType(state, 1)) {
        .none, .nil => {},
        .table => {
            const name_type = lua.getField(state, 1, "name");
            defer lua.pop(state, 1);

            switch (name_type) {
                .none, .nil => {},
                .string => options.name_substring = lua.toString(state, -1) orelse unreachable,
                else => return raiseLuaError(state, "proc.list options.name must be a string"),
            }
        },
        else => return raiseLuaError(state, "proc.list expects an optional options table"),
    }

    const processes = proc.list(context, options) catch |err| {
        return raiseProcError(state, "proc.list", err);
    };
    defer {
        for (processes) |*process| process.deinit(context);
        context.allocator.free(processes);
    }

    lua.createTable(state, @intCast(processes.len), 0);
    for (processes, 0..) |process, index| {
        pushProcessTable(state, process);
        lua.setIndex(state, -2, std.math.cast(lua.Integer, index + 1) orelse unreachable);
    }

    return 1;
}

pub fn processRegions(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const context = getContext(state);

    const pid = getProcessPid(state, 1) catch |err| switch (err) {
        error.InvalidSelf => return raiseLuaError(state, "process.regions expects a process table with a pid field"),
        error.PidOutOfRange => return raiseLuaError(state, "process pid out of range"),
    };

    var options: proc.RegionsOptions = .{};
    switch (lua.valueType(state, 2)) {
        .none, .nil => {},
        .table => {
            const perms_type = lua.getField(state, 2, "perms");
            defer lua.pop(state, 1);

            switch (perms_type) {
                .none, .nil => {},
                .string => options.perms = lua.toString(state, -1) orelse unreachable,
                else => return raiseLuaError(state, "process.regions options.perms must be a string"),
            }
        },
        else => return raiseLuaError(state, "process.regions expects an optional options table"),
    }

    const regions = proc.regions(context, pid, options) catch |err| {
        return raiseProcError(state, "process.regions", err);
    };
    defer {
        for (regions) |*region| region.deinit(context);
        context.allocator.free(regions);
    }

    lua.createTable(state, @intCast(regions.len), 0);
    for (regions, 0..) |region, index| {
        pushRegionTable(state, region);
        lua.setIndex(state, -2, std.math.cast(lua.Integer, index + 1) orelse unreachable);
    }

    return 1;
}

// Context helpers

/// Get the zig Context (GPA, Io, buffers) from the Lua state.
/// Used when the API requires allocation, file access, async, networking, and well now Io does everything so yeah.
fn getContext(state: *lua.State) *const Context {
    _ = lua.getField(state, lua.REGISTRY_INDEX, context_registry_key);
    const context = lua.toLightUserdata(state, -1) orelse unreachable;
    lua.pop(state, 1);
    return @ptrCast(@alignCast(context));
}

// Process helpers

fn getProcessPid(state: *lua.State, arg_index: lua.StackIndex) ProcessRegionError!std.posix.pid_t {
    if (lua.valueType(state, arg_index) != .table) return error.InvalidSelf;

    const pid_type = lua.getField(state, arg_index, "pid");
    defer lua.pop(state, 1);
    if (pid_type != .number) return error.InvalidSelf;

    const pid = lua.toInteger(state, -1) orelse return error.InvalidSelf;
    return std.math.cast(std.posix.pid_t, pid) orelse error.PidOutOfRange;
}

// Parsing helpers

fn parseAddressArgument(state: *lua.State, arg_index: lua.StackIndex) AddressParseError!usize {
    return switch (lua.valueType(state, arg_index)) {
        .number => parseAddressInteger(state, arg_index),
        .string => parseAddressString(lua.toString(state, arg_index) orelse return error.InvalidFormat),
        else => error.InvalidType,
    };
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

// Lua table helpers

fn pushProcessTable(state: *lua.State, process: proc.Process) void {
    lua.createTable(state, 0, 5);

    lua.pushInteger(state, std.math.cast(lua.Integer, process.pid) orelse unreachable);
    lua.setField(state, -2, "pid");

    lua.pushInteger(state, std.math.cast(lua.Integer, process.uid) orelse unreachable);
    lua.setField(state, -2, "uid");

    lua.pushString(state, process.name);
    lua.setField(state, -2, "name");

    lua.pushString(state, process.cmdLine);
    lua.setField(state, -2, "cmdline");

    lua.pushCFunction(state, processRegions);
    lua.setField(state, -2, "regions");
}

fn pushRegionTable(state: *lua.State, region: proc.Region) void {
    lua.createTable(state, 0, 7);

    pushHexAddress(state, region.start);
    lua.setField(state, -2, "start");

    pushHexAddress(state, region.end);
    lua.setField(state, -2, "end");

    lua.pushInteger(state, std.math.cast(lua.Integer, region.size()) orelse unreachable);
    lua.setField(state, -2, "size");

    pushHexAddress(state, region.offset);
    lua.setField(state, -2, "offset");

    lua.pushString(state, region.perms[0..]);
    lua.setField(state, -2, "perms");

    lua.pushInteger(state, std.math.cast(lua.Integer, region.inode) orelse unreachable);
    lua.setField(state, -2, "inode");

    lua.pushString(state, region.pathname);
    lua.setField(state, -2, "pathname");
}

// Formatting helpers

fn pushHexAddress(state: *lua.State, value: usize) void {
    var buffer: [2 + @sizeOf(usize) * 2]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "0x{x}", .{value}) catch unreachable;
    lua.pushString(state, text);
}

// Error helpers

fn raiseMemoryError(state: *lua.State, operation: []const u8, err: memory.Error) c_int {
    const context = getContext(state);
    const message = std.fmt.allocPrint(context.allocator, "{s} failed: {s}", .{ operation, @errorName(err) }) catch {
        return raiseLuaError(state, "memory operation failed and error message allocation failed");
    };
    defer context.allocator.free(message);
    return raiseLuaError(state, message);
}

fn raiseProcError(state: *lua.State, operation: []const u8, err: anyerror) c_int {
    const context = getContext(state);
    const message = std.fmt.allocPrint(context.allocator, "{s} failed: {s}", .{ operation, @errorName(err) }) catch {
        return raiseLuaError(state, "process listing failed and error message allocation failed");
    };
    defer context.allocator.free(message);
    return raiseLuaError(state, message);
}

fn raiseLuaError(state: *lua.State, message: []const u8) c_int {
    lua.pushString(state, message);
    return lua.raiseError(state);
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
