const std = @import("std");
const zx12 = @import("zx12");

pub fn main() !void {
    const test_schema: []const u8 = @embedFile("837p.json");
    const test_x12: []const u8 = @embedFile("837p_example.x12");

    // Initialize the general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse the schema
    var schema = zx12.schema_parser_mod.Schema.fromJson(allocator, test_schema) catch |err| {
        std.debug.print("Failed to parse schema: {}\n", .{err});
        return;
    };
    defer schema.deinit();

    std.debug.print("Successfully parsed schema\n", .{});
    std.debug.print("  Schema ID: {s}\n", .{schema.id});
    std.debug.print("  Description: {s}\n", .{schema.description});
    std.debug.print("  Version: {s}\n", .{schema.version});
    std.debug.print("  Transaction Type: {s}\n", .{schema.transaction_type});

    // Parse the X12 document
    var document = zx12.parser.X12Document.init(allocator);
    defer document.deinit();

    document.parse(test_x12) catch |err| {
        std.debug.print("Failed to parse X12 document: {}\n", .{err});
        return;
    };

    std.debug.print("Successfully parsed X12 document\n", .{});
    std.debug.print("  Number of segments: {}\n", .{document.segments.items.len});

    // Parse with schema to get structured output
    std.debug.print("\nApplying schema to X12 document...\n", .{});
    var result = zx12.schema_parser_mod.parseWithSchema(allocator, &document, &schema) catch |err| {
        std.debug.print("Failed to parse with schema: {}\n", .{err});
        return;
    };
    defer result.deinit();

    std.debug.print("Successfully applied schema\n", .{});

    // Convert to JSON string
    const json_str = std.json.stringifyAlloc(allocator, result.value, .{
        .whitespace = .indent_2,
    }) catch |err| {
        std.debug.print("Failed to convert to JSON: {}\n", .{err});
        return;
    };
    defer allocator.free(json_str);

    std.debug.print("Generated structured JSON output\n", .{});
    std.debug.print("\nStructured JSON Output (first 500 characters):\n", .{});
    std.debug.print("================================================\n", .{});

    const preview_len = @min(500, json_str.len);
    std.debug.print("{s}", .{json_str[0..preview_len]});
    if (json_str.len > 500) {
        std.debug.print("...\n[Output truncated - total length: {} characters]\n", .{json_str.len});
    } else {
        std.debug.print("\n", .{});
    }

    std.debug.print("\nSchema-based parsing complete!\n", .{});
}
