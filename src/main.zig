const std = @import("std");
const x12 = @import("parser.zig");
const schema_parser = @import("schema_parser.zig");

// Handle-based design with proper error handling
pub const ZX12_Error = enum(c_int) {
    SUCCESS = 0,
    INVALID_ARGUMENT = -1,
    FILE_NOT_FOUND = -2,
    MEMORY_ERROR = -3,
    PARSE_ERROR = -4,
    SCHEMA_NOT_FOUND = -5,
    BUFFER_NOT_FOUND = -6,
    UNKNOWN_ERROR = -99,
};

// Context struct to replace globals
pub const ZX12_Context = struct {
    allocator: std.mem.Allocator,
    schemas: std.StringArrayHashMap(schema_parser.Schema),
    schema_names: std.StringArrayHashMap([]const u8),
    buffers: std.AutoArrayHashMap(usize, []const u8),

    pub fn init(allocator: std.mem.Allocator) !*ZX12_Context {
        const ctx = try allocator.create(ZX12_Context);
        ctx.* = ZX12_Context{
            .allocator = allocator,
            .schemas = std.StringArrayHashMap(schema_parser.Schema).init(allocator),
            .schema_names = std.StringArrayHashMap([]const u8).init(allocator),
            .buffers = std.AutoArrayHashMap(usize, []const u8).init(allocator),
        };
        return ctx;
    }

    pub fn deinit(self: *ZX12_Context) void {
        // Free all schemas
        var schema_it = self.schemas.iterator();
        while (schema_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.schemas.deinit();

        // Free all schema names
        var name_it = self.schema_names.iterator();
        while (name_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.schema_names.deinit();

        // Free all buffers
        var buffer_it = self.buffers.iterator();
        while (buffer_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.buffers.deinit();

        // Free the context itself
        self.allocator.destroy(self);
    }
};

// Exported C API functions
export fn zx12_create_context() callconv(.C) ?*ZX12_Context {
    const ctx = ZX12_Context.init(std.heap.c_allocator) catch {
        return null;
    };
    return ctx;
}

export fn zx12_destroy_context(ctx: ?*ZX12_Context) callconv(.C) void {
    if (ctx) |context| {
        context.deinit();
    }
}

export fn zx12_load_schema(ctx: ?*ZX12_Context, path: [*c]const u8, path_len: usize, name: [*c]const u8, name_len: usize) callconv(.C) c_int {
    if (ctx == null or path == null or name == null) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    const context = ctx.?;

    if (name_len == 0 or name_len >= 128) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    if (path_len == 0 or path_len >= 4096) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    // Open and read file
    const file = std.fs.openFileAbsoluteZ(path, .{ .mode = .read_only }) catch {
        return @intFromEnum(ZX12_Error.FILE_NOT_FOUND);
    };
    defer file.close();

    const file_stat = file.stat() catch {
        return @intFromEnum(ZX12_Error.FILE_NOT_FOUND);
    };

    if (file_stat.size == 0) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    // Read file contents
    const buff = context.allocator.alloc(u8, file_stat.size) catch {
        return @intFromEnum(ZX12_Error.MEMORY_ERROR);
    };
    defer context.allocator.free(buff);

    _ = file.readAll(buff) catch {
        return @intFromEnum(ZX12_Error.FILE_NOT_FOUND);
    };

    // Parse schema
    var schema = schema_parser.Schema.fromJson(context.allocator, buff) catch {
        return @intFromEnum(ZX12_Error.PARSE_ERROR);
    };

    // Copy the schema name
    const schema_name = context.allocator.alloc(u8, name_len) catch {
        schema.deinit();
        return @intFromEnum(ZX12_Error.MEMORY_ERROR);
    };
    @memcpy(schema_name, name[0..name_len]);

    // Store schema and name
    context.schemas.put(schema_name, schema) catch {
        context.allocator.free(schema_name);
        schema.deinit();
        return @intFromEnum(ZX12_Error.MEMORY_ERROR);
    };

    context.schema_names.put(schema_name, schema_name) catch {
        _ = context.schemas.swapRemove(schema_name);
        context.allocator.free(schema_name);
        schema.deinit();
        return @intFromEnum(ZX12_Error.MEMORY_ERROR);
    };

    return @intFromEnum(ZX12_Error.SUCCESS);
}

export fn zx12_parse_x12(
    ctx: ?*ZX12_Context,
    schema_name: [*c]const u8,
    schema_name_len: usize,
    x12_data: [*c]const u8,
    x12_data_len: usize,
    out_buffer_id: *isize,
    out_length: *isize,
) callconv(.C) c_int {
    if (ctx == null or schema_name == null or x12_data == null) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    const context = ctx.?;

    if (schema_name_len == 0 or x12_data_len == 0) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    // Get schema
    const schema = context.schemas.getPtr(schema_name[0..schema_name_len]) orelse {
        return @intFromEnum(ZX12_Error.SCHEMA_NOT_FOUND);
    };

    // Parse x12 data
    var document = x12.X12Document.init(context.allocator);
    defer document.deinit();

    document.parse(x12_data[0..x12_data_len]) catch {
        return @intFromEnum(ZX12_Error.PARSE_ERROR);
    };

    // Process with schema
    var parsed = schema_parser.parseWithSchema(context.allocator, &document, schema) catch {
        return @intFromEnum(ZX12_Error.PARSE_ERROR);
    };
    defer parsed.deinit();

    // Convert to JSON
    const json_str = std.json.stringifyAlloc(context.allocator, parsed.value, .{}) catch {
        return @intFromEnum(ZX12_Error.MEMORY_ERROR);
    };

    // Store in buffers map
    const buffer_id = @intFromPtr(json_str.ptr);
    context.buffers.put(buffer_id, json_str) catch {
        context.allocator.free(json_str);
        return @intFromEnum(ZX12_Error.MEMORY_ERROR);
    };

    // Return buffer info
    out_buffer_id.* = @intCast(buffer_id);
    out_length.* = @intCast(json_str.len);

    return @intFromEnum(ZX12_Error.SUCCESS);
}

export fn zx12_get_buffer_data(ctx: ?*ZX12_Context, buffer_id: usize, out_buffer: ?[*]u8, buffer_capacity: usize) callconv(.C) c_int {
    if (ctx == null or out_buffer == null) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    const context = ctx.?;

    // Get the buffer
    const buffer = context.buffers.get(buffer_id) orelse {
        return @intFromEnum(ZX12_Error.BUFFER_NOT_FOUND);
    };

    if (buffer.len > buffer_capacity) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    // Copy data to provided buffer
    @memcpy(out_buffer.?[0..buffer.len], buffer);

    return @intFromEnum(ZX12_Error.SUCCESS);
}

export fn zx12_free_buffer(ctx: ?*ZX12_Context, buffer_id: usize) callconv(.C) c_int {
    if (ctx == null) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    const context = ctx.?;

    const buffer = context.buffers.get(buffer_id) orelse {
        return @intFromEnum(ZX12_Error.BUFFER_NOT_FOUND);
    };

    context.allocator.free(buffer);
    _ = context.buffers.swapRemove(buffer_id);
    return @intFromEnum(ZX12_Error.SUCCESS);
}

export fn zx12_free_schema(ctx: ?*ZX12_Context, schema_name: [*c]const u8, schema_name_len: usize) callconv(.C) c_int {
    if (ctx == null or schema_name == null) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    const context = ctx.?;

    if (schema_name_len == 0) {
        return @intFromEnum(ZX12_Error.INVALID_ARGUMENT);
    }

    const schema_key = schema_name[0..schema_name_len];
    const schema = context.schemas.getPtr(schema_key) orelse {
        return @intFromEnum(ZX12_Error.SCHEMA_NOT_FOUND);
    };

    // Free the schema
    schema.deinit();

    // Remove from maps
    const name_ptr = context.schema_names.get(schema_key) orelse {
        _ = context.schemas.swapRemove(schema_key);
        return @intFromEnum(ZX12_Error.SCHEMA_NOT_FOUND);
    };

    context.allocator.free(name_ptr);
    _ = context.schemas.swapRemove(schema_key);
    _ = context.schema_names.swapRemove(schema_key);

    return @intFromEnum(ZX12_Error.SUCCESS);
}

export fn zx12_get_error_message(error_code: c_int) callconv(.C) [*:0]const u8 {
    const err = @as(ZX12_Error, @enumFromInt(error_code));
    return switch (err) {
        .SUCCESS => "Success",
        .INVALID_ARGUMENT => "Invalid argument",
        .FILE_NOT_FOUND => "File not found",
        .MEMORY_ERROR => "Memory allocation error",
        .PARSE_ERROR => "Parse error",
        .SCHEMA_NOT_FOUND => "Schema not found",
        .BUFFER_NOT_FOUND => "Buffer not found",
        .UNKNOWN_ERROR => "Unknown error",
    };
}

export fn zx12_get_buffer_size(ctx: ?*ZX12_Context, buffer_id: usize) callconv(.C) c_int {
    if (ctx == null) {
        return -1;
    }

    const context = ctx.?;
    const buffer = context.buffers.get(buffer_id) orelse {
        return -1;
    };

    return @intCast(buffer.len);
}
