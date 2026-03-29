const std = @import("std");
const lua = @import("../lua.zig");
const memory = @import("../memory.zig");
const shared = @import("shared.zig");

pub fn register(state: *lua.State) void {
    lua.newTable(state);

    lua.pushCFunction(state, readU32);
    lua.setField(state, -2, "read_u32");

    lua.pushCFunction(state, writeU32);
    lua.setField(state, -2, "write_u32");

    lua.setGlobal(state, "mem");
}

pub fn readU32(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const pid = lua.checkInteger(state, 1);

    const pid_value = std.math.cast(std.posix.pid_t, pid) orelse {
        return shared.raiseLuaError(state, "pid out of range");
    };
    const address_value = shared.parseAddressArgument(state, 2) catch |err| switch (err) {
        error.InvalidType => return shared.raiseLuaError(state, "address must be an integer or string"),
        error.InvalidFormat => return shared.raiseLuaError(state, "address string must be decimal or hex"),
        error.OutOfRange => return shared.raiseLuaError(state, "address out of range"),
    };

    const value = memory.readU32(pid_value, address_value) catch |err| {
        return shared.raiseMemoryError(state, "mem.read_u32", err);
    };

    lua.pushInteger(state, value);
    return 1;
}

pub fn writeU32(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const pid = lua.checkInteger(state, 1);
    const value = lua.checkInteger(state, 3);

    const pid_value = std.math.cast(std.posix.pid_t, pid) orelse {
        return shared.raiseLuaError(state, "pid out of range");
    };
    const address_value = shared.parseAddressArgument(state, 2) catch |err| switch (err) {
        error.InvalidType => return shared.raiseLuaError(state, "address must be an integer or string"),
        error.InvalidFormat => return shared.raiseLuaError(state, "address string must be decimal or hex"),
        error.OutOfRange => return shared.raiseLuaError(state, "address out of range"),
    };
    const value_u32 = std.math.cast(u32, value) orelse {
        return shared.raiseLuaError(state, "value out of range for u32");
    };

    memory.writeU32(pid_value, address_value, value_u32) catch |err| {
        return shared.raiseMemoryError(state, "mem.write_u32", err);
    };

    return 0;
}
