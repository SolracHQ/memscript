const std = @import("std");
const lua = @import("../lua.zig");
const core_proc = @import("../proc.zig");
const scan = @import("../scan.zig");
const shared = @import("shared.zig");
const region_api = @import("region.zig");
const entry_api = @import("entry.zig");

pub fn register(state: *lua.State) void {
    lua.newTable(state);

    lua.pushCFunction(state, listProcesses);
    lua.setField(state, -2, "list");

    lua.setGlobal(state, "proc");
}

pub fn listProcesses(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const context = shared.getContext(state);

    var options: core_proc.ListOptions = .{};
    switch (lua.valueType(state, 1)) {
        .none, .nil => {},
        .table => {
            const name_type = lua.getField(state, 1, "name");
            defer lua.pop(state, 1);

            switch (name_type) {
                .none, .nil => {},
                .string => options.name_substring = lua.toString(state, -1) orelse unreachable,
                else => return shared.raiseLuaError(state, "proc.list options.name must be a string"),
            }
        },
        else => return shared.raiseLuaError(state, "proc.list expects an optional options table"),
    }

    const processes = core_proc.list(context, options) catch |err| {
        return shared.raiseProcError(state, "proc.list", err);
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
    const context = shared.getContext(state);

    const pid = shared.getProcessPid(state, 1) catch |err| switch (err) {
        error.InvalidSelf => return shared.raiseLuaError(state, "process.regions expects a process table with a pid field"),
        error.PidOutOfRange => return shared.raiseLuaError(state, "process pid out of range"),
    };

    var options: core_proc.RegionsOptions = .{};
    switch (lua.valueType(state, 2)) {
        .none, .nil => {},
        .table => {
            const perms_type = lua.getField(state, 2, "perms");
            defer lua.pop(state, 1);

            switch (perms_type) {
                .none, .nil => {},
                .string => options.perms = lua.toString(state, -1) orelse unreachable,
                else => return shared.raiseLuaError(state, "process.regions options.perms must be a string"),
            }
        },
        else => return shared.raiseLuaError(state, "process.regions expects an optional options table"),
    }

    const regions = core_proc.regions(context, pid, options) catch |err| {
        return shared.raiseProcError(state, "process.regions", err);
    };
    defer shared.freeRegions(context, regions);

    lua.createTable(state, @intCast(regions.len), 0);
    for (regions, 0..) |region, index| {
        region_api.pushRegionTable(state, pid, region);
        lua.setIndex(state, -2, std.math.cast(lua.Integer, index + 1) orelse unreachable);
    }

    return 1;
}

pub fn processScan(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    const context = shared.getContext(state);

    const pid = shared.getProcessPid(state, 1) catch |err| switch (err) {
        error.InvalidSelf => return shared.raiseLuaError(state, "process.scan expects a process table with a pid field"),
        error.PidOutOfRange => return shared.raiseLuaError(state, "process pid out of range"),
    };
    const request = shared.parseScanRequest(state, 2) catch |err| {
        return shared.raiseScanOptionsError(state, "process.scan", err);
    };

    const regions = core_proc.regions(context, pid, .{ .perms = "r" }) catch |err| {
        return shared.raiseProcError(state, "process.scan", err);
    };

    var entries: std.ArrayList(scan.Entry) = .empty;
    const data_types = shared.expandTypeSelector(request.type_selector);

    for (regions) |region| {
        for (data_types) |data_type| {
            const region_entries = scan.scan(context.allocator, pid, region, data_type, request.condition) catch |err| {
                switch (err) {
                    error.AccessDenied,
                    error.InvalidAddress,
                    error.PartialTransfer,
                    => continue,
                    else => {
                        shared.freeRegions(context, regions);
                        entries.deinit(context.allocator);
                        return shared.raiseRegionScanError(state, "process.scan", region, err);
                    },
                }
            };

            entries.appendSlice(context.allocator, region_entries) catch |err| {
                context.allocator.free(region_entries);
                shared.freeRegions(context, regions);
                entries.deinit(context.allocator);
                return shared.raiseProcError(state, "process.scan", err);
            };

            context.allocator.free(region_entries);
        }
    }

    entry_api.pushEntryList(state, pid, entries.items);
    entries.deinit(context.allocator);
    shared.freeRegions(context, regions);
    return 1;
}

pub fn pushProcessTable(state: *lua.State, process: core_proc.Process) void {
    lua.createTable(state, 0, 6);

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

    lua.pushCFunction(state, processScan);
    lua.setField(state, -2, "scan");

    setProcessMetatable(state);
}

fn setProcessMetatable(state: *lua.State) void {
    lua.createTable(state, 0, 1);
    lua.pushCFunction(state, processToString);
    lua.setField(state, -2, "__tostring");
    _ = lua.setMetatable(state, -2);
}

fn processToString(state_: ?*lua.State) callconv(.c) c_int {
    const state = state_ orelse unreachable;
    if (lua.valueType(state, 1) != .table) return shared.raiseLuaError(state, "process tostring expects a process table");

    const pid_type = lua.getField(state, 1, "pid");
    defer lua.pop(state, 1);
    const name_type = lua.getField(state, 1, "name");
    defer lua.pop(state, 1);
    if (pid_type != .number or name_type != .string) return shared.raiseLuaError(state, "process tostring expects a process table");

    const pid = lua.toInteger(state, -2) orelse return shared.raiseLuaError(state, "process tostring expects a process table");
    const name = lua.toString(state, -1) orelse return shared.raiseLuaError(state, "process tostring expects a process table");
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "process(pid={d}, name={s})", .{ pid, name }) catch unreachable;
    lua.pushString(state, text);
    return 1;
}
