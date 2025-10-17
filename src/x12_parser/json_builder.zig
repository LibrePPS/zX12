const std = @import("std");
const testing = std.testing;

/// JSON value types
pub const JsonValue = union(enum) {
    null_value: void,
    bool_value: bool,
    number: f64,
    string: []const u8,
    array: *JsonArray,
    object: *JsonObject,

    pub fn deinit(self: *JsonValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                arr.deinit();
                allocator.destroy(arr);
            },
            .object => |obj| {
                obj.deinit();
                allocator.destroy(obj);
            },
            else => {},
        }
    }
};

/// JSON array with lazy allocation
pub const JsonArray = struct {
    items: std.ArrayList(JsonValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JsonArray {
        return JsonArray{
            .items = std.ArrayList(JsonValue){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JsonArray) void {
        for (self.items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.items.deinit(self.allocator);
    }

    pub fn append(self: *JsonArray, value: JsonValue) !void {
        try self.items.append(self.allocator, value);
    }

    pub fn len(self: *const JsonArray) usize {
        return self.items.items.len;
    }
};

/// JSON object with lazy allocation
pub const JsonObject = struct {
    fields: std.StringHashMap(JsonValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JsonObject {
        return JsonObject{
            .fields = std.StringHashMap(JsonValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JsonObject) void {
        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var value = entry.value_ptr.*;
            value.deinit(self.allocator);
        }
        self.fields.deinit();
    }

    pub fn put(self: *JsonObject, key: []const u8, value: JsonValue) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        try self.fields.put(owned_key, value);
    }

    pub fn get(self: *const JsonObject, key: []const u8) ?JsonValue {
        return self.fields.get(key);
    }

    pub fn getPtr(self: *JsonObject, key: []const u8) ?*JsonValue {
        return self.fields.getPtr(key);
    }
};

/// JSON builder with path-based access and lazy array creation
pub const JsonBuilder = struct {
    root: JsonObject,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JsonBuilder {
        return JsonBuilder{
            .root = JsonObject.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JsonBuilder) void {
        self.root.deinit();
    }

    /// Set a value at a dot-separated path (e.g., "provider.name.last")
    /// Creates intermediate objects as needed
    pub fn set(self: *JsonBuilder, path: []const u8, value: JsonValue) !void {
        var parts = std.mem.splitScalar(u8, path, '.');
        var current_obj = &self.root;

        while (parts.next()) |part| {
            const remaining = parts.rest();

            if (remaining.len == 0) {
                // Last part - set the value
                try current_obj.put(part, value);
                return;
            }

            // Intermediate part - ensure object exists
            if (current_obj.getPtr(part)) |existing| {
                switch (existing.*) {
                    .object => |obj| current_obj = obj,
                    else => return error.PathConflict,
                }
            } else {
                // Create new object
                const new_obj = try self.allocator.create(JsonObject);
                new_obj.* = JsonObject.init(self.allocator);
                try current_obj.put(part, JsonValue{ .object = new_obj });
                current_obj = new_obj;
            }
        }
    }

    /// Get or create an array at a path
    /// Arrays are lazily created on first access
    pub fn getOrCreateArray(self: *JsonBuilder, path: []const u8) !*JsonArray {
        var parts = std.mem.splitScalar(u8, path, '.');
        var current_obj = &self.root;

        var last_part: []const u8 = undefined;
        while (parts.next()) |part| {
            const remaining = parts.rest();
            last_part = part;

            if (remaining.len == 0) {
                // Last part - get or create array
                if (current_obj.getPtr(part)) |existing| {
                    switch (existing.*) {
                        .array => |arr| return arr,
                        else => return error.PathConflict,
                    }
                } else {
                    // Create new array
                    const new_arr = try self.allocator.create(JsonArray);
                    new_arr.* = JsonArray.init(self.allocator);
                    try current_obj.put(part, JsonValue{ .array = new_arr });
                    return new_arr;
                }
            }

            // Intermediate part - ensure object exists
            if (current_obj.getPtr(part)) |existing| {
                switch (existing.*) {
                    .object => |obj| current_obj = obj,
                    else => return error.PathConflict,
                }
            } else {
                // Create new object
                const new_obj = try self.allocator.create(JsonObject);
                new_obj.* = JsonObject.init(self.allocator);
                try current_obj.put(part, JsonValue{ .object = new_obj });
                current_obj = new_obj;
            }
        }

        unreachable;
    }

    /// Push an object to an array at the given path
    /// Creates the array if it doesn't exist
    pub fn pushToArray(self: *JsonBuilder, path: []const u8, obj: *JsonObject) !void {
        const arr = try self.getOrCreateArray(path);
        try arr.append(JsonValue{ .object = obj });
    }

    /// Get a value at a path (returns null if not found)
    pub fn get(self: *const JsonBuilder, path: []const u8) ?JsonValue {
        var parts = std.mem.splitScalar(u8, path, '.');
        var current_obj = &self.root;

        while (parts.next()) |part| {
            const remaining = parts.rest();

            if (remaining.len == 0) {
                // Last part - return value
                return current_obj.get(part);
            }

            // Intermediate part - navigate down
            if (current_obj.get(part)) |value| {
                switch (value) {
                    .object => |obj| current_obj = obj,
                    else => return null,
                }
            } else {
                return null;
            }
        }

        return null;
    }

    /// Convert to JSON string (output written to ArrayList(u8))
    pub fn stringify(self: *const JsonBuilder, output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        try self.stringifyObject(&self.root, output, allocator, 0);
    }

    fn stringifyValue(self: *const JsonBuilder, value: *const JsonValue, output: *std.ArrayList(u8), allocator: std.mem.Allocator, indent: usize) std.mem.Allocator.Error!void {
        switch (value.*) {
            .null_value => try output.appendSlice(allocator, "null"),
            .bool_value => |b| try output.appendSlice(allocator, if (b) "true" else "false"),
            .number => |n| {
                const num_str = try std.fmt.allocPrint(allocator, "{d}", .{n});
                defer allocator.free(num_str);
                try output.appendSlice(allocator, num_str);
            },
            .string => |s| {
                try output.append(allocator, '"');
                for (s) |c| {
                    switch (c) {
                        '"' => try output.appendSlice(allocator, "\\\""),
                        '\\' => try output.appendSlice(allocator, "\\\\"),
                        '\n' => try output.appendSlice(allocator, "\\n"),
                        '\r' => try output.appendSlice(allocator, "\\r"),
                        '\t' => try output.appendSlice(allocator, "\\t"),
                        else => try output.append(allocator, c),
                    }
                }
                try output.append(allocator, '"');
            },
            .array => |arr| try self.stringifyArray(arr, output, allocator, indent),
            .object => |obj| try self.stringifyObject(obj, output, allocator, indent),
        }
    }

    fn stringifyObject(self: *const JsonBuilder, obj: *const JsonObject, output: *std.ArrayList(u8), allocator: std.mem.Allocator, indent: usize) std.mem.Allocator.Error!void {
        try output.appendSlice(allocator, "{\n");

        var iter = obj.fields.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try output.appendSlice(allocator, ",\n");
            first = false;

            try self.writeIndent(output, allocator, indent + 1);
            try output.append(allocator, '"');
            try output.appendSlice(allocator, entry.key_ptr.*);
            try output.appendSlice(allocator, "\": ");

            try self.stringifyValue(entry.value_ptr, output, allocator, indent + 1);
        }

        try output.append(allocator, '\n');
        try self.writeIndent(output, allocator, indent);
        try output.append(allocator, '}');
    }

    fn stringifyArray(self: *const JsonBuilder, arr: *const JsonArray, output: *std.ArrayList(u8), allocator: std.mem.Allocator, indent: usize) std.mem.Allocator.Error!void {
        try output.appendSlice(allocator, "[\n");

        for (arr.items.items, 0..) |*item, i| {
            if (i > 0) try output.appendSlice(allocator, ",\n");

            try self.writeIndent(output, allocator, indent + 1);
            try self.stringifyValue(item, output, allocator, indent + 1);
        }

        try output.append(allocator, '\n');
        try self.writeIndent(output, allocator, indent);
        try output.append(allocator, ']');
    }

    fn writeIndent(self: *const JsonBuilder, output: *std.ArrayList(u8), allocator: std.mem.Allocator, indent: usize) std.mem.Allocator.Error!void {
        _ = self;
        var i: usize = 0;
        while (i < indent) : (i += 1) {
            try output.appendSlice(allocator, "  ");
        }
    }
};

// ============================================================================
// UNIT TESTS
// ============================================================================

test "create empty JSON builder" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    try testing.expect(builder.root.fields.count() == 0);
}

test "set simple string value" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    const str = try allocator.dupe(u8, "John");
    try builder.set("name", JsonValue{ .string = str });

    const value = builder.get("name");
    try testing.expect(value != null);
    try testing.expect(value.?.string.len == 4);
}

test "set nested object path" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    const str = try allocator.dupe(u8, "Doe");
    try builder.set("person.name.last", JsonValue{ .string = str });

    const value = builder.get("person.name.last");
    try testing.expect(value != null);
    try testing.expectEqualStrings("Doe", value.?.string);
}

test "create and access array" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    const arr = try builder.getOrCreateArray("providers");
    try testing.expect(arr.len() == 0);

    // Add item to array
    var obj = try allocator.create(JsonObject);
    obj.* = JsonObject.init(allocator);
    const name_str = try allocator.dupe(u8, "Provider 1");
    try obj.put("name", JsonValue{ .string = name_str });
    try arr.append(JsonValue{ .object = obj });

    try testing.expect(arr.len() == 1);
}

test "push to array with path" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    var obj = try allocator.create(JsonObject);
    obj.* = JsonObject.init(allocator);
    const name_str = try allocator.dupe(u8, "Provider 1");
    try obj.put("name", JsonValue{ .string = name_str });

    try builder.pushToArray("providers", obj);

    const arr = try builder.getOrCreateArray("providers");
    try testing.expect(arr.len() == 1);
}

test "nested array path" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    var obj = try allocator.create(JsonObject);
    obj.* = JsonObject.init(allocator);
    const name_str = try allocator.dupe(u8, "Claim 1");
    try obj.put("claim_id", JsonValue{ .string = name_str });

    try builder.pushToArray("provider.claims", obj);

    const arr = try builder.getOrCreateArray("provider.claims");
    try testing.expect(arr.len() == 1);
}

test "stringify simple object" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    const name_str = try allocator.dupe(u8, "John");
    try builder.set("name", JsonValue{ .string = name_str });
    try builder.set("age", JsonValue{ .number = 30 });

    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    try builder.stringify(&output, allocator);
    const json = output.items;

    try testing.expect(std.mem.indexOf(u8, json, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"John\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"age\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "30") != null);
}

test "stringify nested object" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    const first_str = try allocator.dupe(u8, "John");
    try builder.set("person.name.first", JsonValue{ .string = first_str });

    const last_str = try allocator.dupe(u8, "Doe");
    try builder.set("person.name.last", JsonValue{ .string = last_str });

    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    try builder.stringify(&output, allocator);
    const json = output.items;

    try testing.expect(std.mem.indexOf(u8, json, "\"person\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"first\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"John\"") != null);
}

test "stringify with array" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    var obj1 = try allocator.create(JsonObject);
    obj1.* = JsonObject.init(allocator);
    const name1 = try allocator.dupe(u8, "Provider 1");
    try obj1.put("name", JsonValue{ .string = name1 });

    var obj2 = try allocator.create(JsonObject);
    obj2.* = JsonObject.init(allocator);
    const name2 = try allocator.dupe(u8, "Provider 2");
    try obj2.put("name", JsonValue{ .string = name2 });

    try builder.pushToArray("providers", obj1);
    try builder.pushToArray("providers", obj2);

    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    try builder.stringify(&output, allocator);
    const json = output.items;

    try testing.expect(std.mem.indexOf(u8, json, "\"providers\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Provider 1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Provider 2\"") != null);
}
