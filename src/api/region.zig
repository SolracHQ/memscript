const std = @import("std");
const lua = @import("../lua.zig");
const shared = @import("shared.zig");
const scan = @import("../scan.zig");
const entry_api = @import("entry.zig");

pub fn regionScan(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const context = shared.getContext(state);

    const handle = shared.getRegionHandle(state, 1) catch |err| switch (err) {
        error.InvalidSelf, error.InvalidField => return shared.raiseLuaError(state, "region.scan expects a region table from process.regions"),
        error.PidOutOfRange => return shared.raiseLuaError(state, "region pid out of range"),
    };
    const request = shared.parseScanRequest(state, 2) catch |err| {
        return shared.raiseScanOptionsError(state, "region.scan", err);
    };

    var entries: std.ArrayList(scan.Entry) = .empty;
    const data_types = shared.expandTypeSelector(request.type_selector);

    for (data_types) |data_type| {
        const typed_entries = scan.scan(context.allocator, handle.pid, handle.region, data_type, request.condition) catch |err| {
            entries.deinit(context.allocator);
            return shared.raiseRegionScanError(state, "region.scan", handle.region, err);
        };

        entries.appendSlice(context.allocator, typed_entries) catch |err| {
            context.allocator.free(typed_entries);
            entries.deinit(context.allocator);
            return shared.raiseProcError(state, "region.scan", err);
        };

        context.allocator.free(typed_entries);
    }

    entry_api.pushEntryList(state, handle.pid, entries.items);
    entries.deinit(context.allocator);
    return 1;
}

pub fn pushRegionTable(state: *lua.State, pid: std.posix.pid_t, region: @import("../proc.zig").Region) void {
    lua.createTable(state, 0, 9);

    lua.pushInteger(state, std.math.cast(lua.Integer, pid) orelse unreachable);
    lua.setField(state, -2, "_pid");

    shared.pushHexAddress(state, region.start);
    lua.setField(state, -2, "start");

    shared.pushHexAddress(state, region.end);
    lua.setField(state, -2, "end");

    lua.pushInteger(state, std.math.cast(lua.Integer, region.size()) orelse unreachable);
    lua.setField(state, -2, "size");

    shared.pushHexAddress(state, region.offset);
    lua.setField(state, -2, "offset");

    lua.pushString(state, region.perms[0..]);
    lua.setField(state, -2, "perms");

    lua.pushInteger(state, std.math.cast(lua.Integer, region.inode) orelse unreachable);
    lua.setField(state, -2, "inode");

    lua.pushString(state, region.pathname);
    lua.setField(state, -2, "pathname");

    lua.pushCFunction(state, regionScan);
    lua.setField(state, -2, "scan");

    setRegionMetatable(state);
}

fn setRegionMetatable(state: *lua.State) void {
    lua.createTable(state, 0, 1);
    lua.pushCFunction(state, regionToString);
    lua.setField(state, -2, "__tostring");
    _ = lua.setMetatable(state, -2);
}

fn regionToString(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const handle = shared.getRegionHandle(state, 1) catch {
        return shared.raiseLuaError(state, "region tostring expects a region table");
    };

    const pathname = if (handle.region.pathname.len == 0) "(anonymous)" else handle.region.pathname;
    var buffer: [320]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buffer,
        "region(0x{x}-0x{x}, perms={s}, path={s})",
        .{ handle.region.start, handle.region.end, handle.region.perms[0..], pathname },
    ) catch unreachable;
    lua.pushString(state, text);
    return 1;
}
