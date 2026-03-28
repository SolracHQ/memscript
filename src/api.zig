const std = @import("std");
const lua = @import("lua.zig");
const memory = @import("memory.zig");

pub fn register(state: *lua.State) void {
    lua.newTable(state);

    lua.pushFunction(state, readU32);
    lua.setField(state, -2, "read_u32");

    lua.pushFunction(state, writeU32);
    lua.setField(state, -2, "write_u32");

    lua.setGlobal(state, "mem");
}

pub fn readU32(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const pid = lua.checkInteger(state, 1);
    const address = lua.checkInteger(state, 2);

    const pid_value = std.math.cast(std.posix.pid_t, pid) orelse {
        return raiseLuaError(state, "pid out of range");
    };
    const address_value = std.math.cast(usize, address) orelse {
        return raiseLuaError(state, "address out of range");
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
    const address = lua.checkInteger(state, 2);
    const value = lua.checkInteger(state, 3);

    const pid_value = std.math.cast(std.posix.pid_t, pid) orelse {
        return raiseLuaError(state, "pid out of range");
    };
    const address_value = std.math.cast(usize, address) orelse {
        return raiseLuaError(state, "address out of range");
    };
    const value_u32 = std.math.cast(u32, value) orelse {
        return raiseLuaError(state, "value out of range for u32");
    };

    memory.writeU32(pid_value, address_value, value_u32) catch |err| {
        return raiseMemoryError(state, "mem.write_u32", err);
    };

    return 0;
}

fn raiseMemoryError(state: *lua.State, operation: []const u8, err: memory.Error) c_int {
    var buffer: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "{s} failed: {s}", .{ operation, @errorName(err) }) catch operation;
    return raiseLuaError(state, message);
}

fn raiseLuaError(state: *lua.State, message: []const u8) c_int {
    lua.pushString(state, message);
    return lua.raiseError(state);
}
