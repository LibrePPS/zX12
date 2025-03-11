const std = @import("std");

pub fn jsonStringify(self: anytype, out: anytype) !void {
    const self_type: type = @TypeOf(self);
    const fields = std.meta.fields(self_type);
    if (@typeInfo(self_type) == .optional) {
        if (self == null) {
            return;
        }
    }
    //Start the serializer
    try out.beginObject();

    inline for (fields) |field| {
        const field_name = field.name;
        const field_type = field.type;
        const field_type_info = @typeInfo(field_type);
        //Skip any allocator
        if (comptime field_type == std.mem.Allocator or std.mem.eql(u8, field_name, "allocator")) {
            continue;
        }
        const field_value = @field(self, field_name);
        if (field_type == []const u8 or field_type == comptime [:0]const u8) {
            try out.objectField(field_name);
            try out.print("\"{s}\"", .{field_value});
            continue;
        }
        switch (field_type_info) {
            .@"struct" => {
                if (@hasField(field_type, "items")) {
                    const array_type = @TypeOf(field_value.items);
                    const child_type = std.meta.Elem(array_type);
                    switch (@typeInfo(child_type)) {
                        .@"struct" => {
                            if (!std.meta.hasMethod(child_type, "jsonStringify")) {
                                @compileLog(field_name);
                                @compileError("Struct does not have a jsonStringify method");
                            }
                            try out.objectField(field_name);
                            try out.beginArray();
                            for (field_value.items) |item| {
                                try item.jsonStringify(out);
                            }
                            try out.endArray();
                            continue;
                        },
                        .pointer => {
                            if (child_type == []const u8) {
                                try out.objectField(field_name);
                                try out.beginArray();
                                for (field_value.items) |item| {
                                    try out.print("\"{s}\"", .{item});
                                }
                                try out.endArray();
                                continue;
                            } else {
                                @compileLog(child_type);
                                @compileError("Unsupported type in array");
                            }
                        },
                        else => {
                            @compileLog(child_type);
                            @compileError("Unsupported type in array");
                        },
                    }
                }
            },
            .@"enum" => {
                //Enums don't need any special handling
                try out.objectField(field_name);
                try out.write(field_value);
            },
            .optional => {
                if (field_value == null) {
                    if (out.options.emit_null_optional_fields == true) {
                        try out.objectField(field_name);
                        try out.write(null);
                    }
                } else {
                    try out.objectField(field_name);
                    try out.print("\"{s}\"", .{field_value.?});
                }
                continue;
            },
            .comptime_int, .int => {
                try out.objectField(field_name);
                if (field_type == u8) {
                    try out.print("\"{c}\"", .{field_value});
                    continue;
                }
                try out.print("{d}", .{field_value});
                continue;
            },
            else => {
                @compileLog("Unsupported type: {any}", .{@typeInfo(field_type)});
            },
        }
    }
    try out.endObject();
}
