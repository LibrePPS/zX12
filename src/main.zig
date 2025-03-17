const std = @import("std");
const x12 = @import("parser.zig");
const schema_parser = @import("schema_parser.zig");

//@TODO - Clean this up and use a struct to hold everything, use a linked list to hold the schema and schema names
const ALLOCATOR = std.heap.c_allocator;
var SCHMEAS = std.StringArrayHashMap(schema_parser.Schema).init(ALLOCATOR);
var SCHMEA_NAMES = std.StringArrayHashMap([]const u8).init(ALLOCATOR);
var BUFFERS = std.AutoArrayHashMap(usize, usize).init(ALLOCATOR);

export fn loadSchema(path: [*c]const u8, name: [*c]const u8) callconv(.C) i8 {
    const name_len = std.mem.len(name);
    if (name_len == 0 or name_len >= 128) {
        std.log.err("Please choose a name for the schema that is longer between 0 and 128 characters", .{});
        return -1;
    }
    const path_len = std.mem.len(path);
    if (path_len == 0 or path_len >= 256) {
        std.log.err("Path is invalid length. Path length - {d}", .{path_len});
        return -1;
    }
    //Check the file exists
    const file = std.fs.openFileAbsoluteZ(path, .{ .mode = .read_only }) catch |err| {
        std.log.err("Error opening file {s}. Error - {any}", .{ path, err });
        return -1;
    };
    //Stat the file and get size
    const file_stat = file.stat() catch |err| {
        std.log.err("Could not stat file {s}. Error - {any}", .{ path, err });
        return -1;
    };

    if (file_stat.size == 0) {
        std.log.err("Schema file is empty!", .{});
        return -1;
    }
    //Allocate space to read file to buffer
    const buff = ALLOCATOR.alloc(u8, file_stat.size) catch {
        std.log.err("Memory Allocation Failure!!", .{});
        return -1;
    };
    //Read contents to buffer
    _ = file.readAll(buff) catch |err| {
        std.log.err("Failed to read file contents. Error - {any}", .{err});
        return -1;
    };
    //Parse to Schema
    const schema = schema_parser.Schema.fromJson(ALLOCATOR, buff) catch |err| {
        std.log.err("Failed to parse Json to X12 Schemea. Error - {any}", .{err});
        return -1;
    };
    //Add to hash map
    const dup_name = ALLOCATOR.alloc(u8, name_len) catch {
        std.log.err("Memory Allocation Failure!!", .{});
        return -1;
    };
    @memcpy(dup_name, name[0..name_len]);
    SCHMEAS.put(dup_name, schema) catch |err| {
        std.log.err("Failed to add schema to hash map. Error - {any}", .{err});
        return -1;
    };
    //Add name to names hash map
    SCHMEA_NAMES.put(dup_name, dup_name) catch |err| {
        std.log.err("Failed to add schema name to hash map. Error - {any}", .{err});
        return -1;
    };
    return 0;
}

export fn parseFromSchema(schema_name: [*c]const u8, x12_data: [*c]const u8) callconv(.C) [*c]const u8 {
    const schema_name_len = std.mem.len(schema_name);
    const schema = SCHMEAS.getPtr(schema_name[0..schema_name_len]) orelse {
        std.log.err("Schema name {s} does not exist in Schema hash map", .{schema_name});
        return "";
    };
    //Parse the x12 data
    const x12_len = std.mem.len(x12_data);
    if (x12_len == 0) {
        std.log.err("X12 data given is empty!", .{});
        return "";
    }
    var document = x12.X12Document.init(ALLOCATOR);
    defer document.deinit();
    document.parse(x12_data[0..x12_len]) catch |err| {
        std.log.err("Error while parsing the X12 data. Error - {any}", .{err});
        return "";
    };

    var parsed = schema_parser.parseWithSchema(ALLOCATOR, &document, schema) catch |err| {
        std.log.err("Error parsing X12 with the Schema {s}. Error {any}", .{ schema_name, err });
        return "";
    };
    defer parsed.deinit();
    //Return JSON
    const j = std.json.stringifyAlloc(ALLOCATOR, parsed.value, .{}) catch |err| {
        std.log.err("Error while serializing to json. Error - {any}", .{err});
        return "";
    };
    BUFFERS.put(@intFromPtr(j.ptr), j.len) catch |err| {
        std.log.err("Failed to add buffer to hash map. Error - {any}", .{err});
        return "";
    };
    return @ptrCast(j);
}

export fn getBufferSize(ptr: [*c]const u8) callconv(.C) usize {
    const key = @intFromPtr(ptr);
    const size = BUFFERS.get(key) orelse {
        std.log.err("Buffer not found for key {d}", .{key});
        return 0;
    };
    return size;
}

export fn freeSchema(name: [*c]const u8) callconv(.C) i8 {
    const name_len = std.mem.len(name);
    const schema = SCHMEAS.getPtr(name[0..name_len]) orelse {
        std.log.err("Schema name {s} does not exist in Schema hash map", .{name});
        return -1;
    };
    schema.deinit();
    //Free the name
    const dup_name = SCHMEA_NAMES.getPtr(name[0..name_len]) orelse {
        std.log.err("Schema name {s} does not exist in Schema names hash map", .{name});
        return -1;
    };
    ALLOCATOR.free(dup_name.*);
    _ = SCHMEA_NAMES.swapRemove(name[0..name_len]);
    return 0;
}

export fn freeBuffer(ptr: [*c]const u8) callconv(.C) i8 {
    const key = @intFromPtr(ptr);
    const sz = BUFFERS.get(key) orelse {
        std.log.err("Buffer not found for key {d}", .{key});
        return -1;
    };
    ALLOCATOR.free(ptr[0..sz]);
    _ = BUFFERS.swapRemove(key);
    return 0;
}
