const std = @import("std");
const x12_parser = @import("x12_parser.zig");
const hl_tree = @import("hl_tree.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read the sample file
    const file_path = "samples/837p_example.x12";
    const content = try std.fs.cwd().readFileAlloc(file_path, allocator, @enumFromInt(1024 * 1024));
    defer allocator.free(content);

    std.debug.print("📄 File: {s}\n", .{file_path});
    std.debug.print("📊 Size: {} bytes\n\n", .{content.len});

    // Parse the document
    var doc = try x12_parser.parse(allocator, content);
    defer doc.deinit();

    std.debug.print("✅ Parsed {d} segments\n\n", .{doc.segments.len});

    // Build HL tree
    var tree = try hl_tree.buildTree(allocator, doc);
    defer tree.deinit();

    std.debug.print("🌲 HL Tree Structure:\n", .{});
    std.debug.print("  Total nodes: {d}\n", .{tree.countNodes()});
    std.debug.print("  Root nodes: {d}\n\n", .{tree.roots.len});

    // Print tree structure
    for (tree.roots) |root| {
        try printNode(&root, doc, 0);
    }

    std.debug.print("\n📋 Nodes by Level:\n", .{});

    // Get billing providers (level 20)
    const providers = try tree.getNodesByLevel(allocator, "20");
    defer allocator.free(providers);
    std.debug.print("  Level 20 (Billing Provider): {d} node(s)\n", .{providers.len});

    // Get subscribers (level 22)
    const subscribers = try tree.getNodesByLevel(allocator, "22");
    defer allocator.free(subscribers);
    std.debug.print("  Level 22 (Subscriber): {d} node(s)\n", .{subscribers.len});

    // Get patients (level 23)
    const patients = try tree.getNodesByLevel(allocator, "23");
    defer allocator.free(patients);
    std.debug.print("  Level 23 (Patient): {d} node(s)\n\n", .{patients.len});

    // Analyze each subscriber
    std.debug.print("💼 Subscriber Details:\n", .{});
    for (subscribers, 0..) |subscriber, i| {
        std.debug.print("  Subscriber {d} (HL {s}):\n", .{ i + 1, subscriber.id });

        const segments = subscriber.getSegments(doc) orelse continue;
        std.debug.print("    Segments: {d} (index {d}-{d})\n", .{
            segments.len,
            subscriber.segment_start,
            subscriber.segment_end,
        });

        // Find NM1 segment for subscriber
        for (segments) |seg| {
            if (std.mem.eql(u8, seg.id, "NM1")) {
                const entity_type = seg.getElement(1) orelse "";
                if (std.mem.eql(u8, entity_type, "IL")) {
                    const last_name = seg.getElement(3) orelse "";
                    const first_name = seg.getElement(4) orelse "";
                    const middle = seg.getElement(5) orelse "";
                    std.debug.print("    Name: {s}, {s} {s}\n", .{ last_name, first_name, middle });
                }
            } else if (std.mem.eql(u8, seg.id, "CLM")) {
                const claim_id = seg.getElement(1) orelse "";
                const amount = seg.getElement(2) orelse "";
                std.debug.print("    Claim: {s} - ${s}\n", .{ claim_id, amount });
            }
        }

        // Count service lines
        var service_count: usize = 0;
        for (segments) |seg| {
            if (std.mem.eql(u8, seg.id, "LX")) {
                service_count += 1;
            }
        }
        if (service_count > 0) {
            std.debug.print("    Service Lines: {d}\n", .{service_count});
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("✨ HL Tree analysis complete!\n", .{});
}

fn printNode(node: *const hl_tree.HLNode, doc: x12_parser.X12Document, indent: usize) !void {
    // Print indentation
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        std.debug.print("  ", .{});
    }

    // Print node info
    const level_name = switch (node.level_code[0]) {
        '2' => if (node.level_code.len > 1 and node.level_code[1] == '0')
            "Billing Provider"
        else if (node.level_code.len > 1 and node.level_code[1] == '2')
            "Subscriber"
        else if (node.level_code.len > 1 and node.level_code[1] == '3')
            "Patient"
        else
            "Unknown",
        else => "Unknown",
    };

    std.debug.print("HL {s} [{s}] - {s}\n", .{
        node.id,
        node.level_code,
        level_name,
    });

    // Print segment range
    i = 0;
    while (i < indent + 1) : (i += 1) {
        std.debug.print("  ", .{});
    }
    std.debug.print("Segments: {d}-{d} ({d} total)\n", .{
        node.segment_start,
        node.segment_end,
        node.segment_end - node.segment_start,
    });

    // Print children
    for (node.children) |*child| {
        try printNode(child, doc, indent + 1);
    }
}
