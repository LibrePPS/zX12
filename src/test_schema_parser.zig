// filepath: /home/jjw07006/Deveolpment/zX12/src/test_schema_parser.zig
const std = @import("std");
const testing = std.testing;
const x12 = @import("parser.zig");
const schema_parser = @import("schema_parser.zig");

/// Helper function to load a file into a string
fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size + 1;

    return try file.reader().readAllAlloc(allocator, file_size);
}

test "Load schema from file and parse X12 document" {
    // Use an arena allocator to simplify memory management
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1. Load the schema file
    const schema_json = try loadFile(allocator, "./schema/837p.json");

    // 2. Load the X12 document
    const x12_data = try loadFile(allocator, "./samples/837p_example.x12");

    // 3. Parse the schema
    var schema = try schema_parser.Schema.fromJson(allocator, schema_json);
    defer schema.deinit();

    // Verify basic schema properties
    try testing.expectEqualStrings("837P", schema.id);
    try testing.expectEqualStrings("005010X222A1", schema.version);

    // 4. Parse the X12 document
    var document = x12.X12Document.init(allocator);
    defer document.deinit();
    try document.parse(x12_data);

    // 5. Use schema to parse the document
    var result = try schema_parser.parseWithSchema(allocator, &document, &schema);
    defer result.deinit();

    // 6. Verify a selection of fields from different parts of the document
    const root = result.value.object;
    const interchange = root.get("interchange").?.object;
    // Header segment values
    if (interchange.get("sender_id")) |sender_id| {
        std.debug.print("Sender ID: {s}\n", .{sender_id.string});
    } else {
        try testing.expect(false); // Field should exist
    }

    if (interchange.get("receiver_id")) |receiver_id| {
        std.debug.print("Receiver ID: {s}\n", .{receiver_id.string});
    } else {
        try testing.expect(false); // Field should exist
    }

    // Check if 2000A loop exists
    if (root.get("2000A")) |loop_2000a_value| {
        const loop_2000a = loop_2000a_value.object;

        // Check billing provider data
        if (loop_2000a.get("billing_provider")) |bp| {
            const billing_provider = bp.object;

            if (billing_provider.get("last_name")) |name| {
                std.debug.print("Billing Provider Name: {s}\n", .{name.string});
            }

            if (billing_provider.get("address1")) |address| {
                std.debug.print("Billing Provider Address: {s}\n", .{address.string});
            }

            if (billing_provider.get("city")) |city| {
                std.debug.print("Billing Provider City: {s}\n", .{city.string});
            }
        }

        // Check 2000B subscriber loop
        if (loop_2000a.get("2000B")) |loop_2000b_array| {
            if (loop_2000b_array.array.items.len > 0) {
                const loop_2000b = loop_2000b_array.array.items[0].object;

                // Check subscriber information
                if (loop_2000b.get("subscriber")) |subscriber_value| {
                    const subscriber = subscriber_value.object;

                    if (subscriber.get("first_name")) |first_name| {
                        std.debug.print("Subscriber First Name: {s}\n", .{first_name.string});
                    }

                    if (subscriber.get("last_name")) |last_name| {
                        std.debug.print("Subscriber Last Name: {s}\n", .{last_name.string});
                    }
                }

                // Check 2300 loop
                if (loop_2000b.get("2300")) |loop_2300_array| {
                    if (loop_2300_array.array.items.len > 0) {
                        const loop_2300 = loop_2300_array.array.items[0].object;
                        // Check claim information
                        if (loop_2300.get("claim")) |claim_value| {
                            const claim = claim_value.object;

                            if (claim.get("claim_id")) |claim_number| {
                                std.debug.print("Claim Number: {s}\n", .{claim_number.string});
                            }

                            if (claim.get("total_charges")) |total_charge| {
                                std.debug.print("Total Charge: {s}\n", .{total_charge.string});
                            }
                        }
                    }
                } else {
                    try testing.expect(false); // 2300 loop should exist
                }
            }
        }
    } else {
        try testing.expect(false); // 2000A loop should exist
    }
}
