const std = @import("std");
const x12_parser = @import("x12_parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read the sample file
    const file_path = "samples/837p_example.x12";
    const content = try std.fs.cwd().readFileAlloc(file_path, allocator, @enumFromInt(1024 * 1024)); // 1MB max
    defer allocator.free(content);

    std.debug.print("📄 File size: {} bytes\n", .{content.len});

    // Parse the document
    var doc = try x12_parser.parse(allocator, content);
    defer doc.deinit();

    std.debug.print("✅ Successfully parsed {d} segments\n\n", .{doc.segments.len});

    // Print delimiters
    std.debug.print("🔍 Detected Delimiters:\n", .{});
    std.debug.print("  Element:    '{c}'\n", .{doc.delimiters.element});
    std.debug.print("  Segment:    '{c}'\n", .{doc.delimiters.segment});
    std.debug.print("  Composite:  '{c}'\n", .{doc.delimiters.composite});
    std.debug.print("  Repetition: '{c}'\n\n", .{doc.delimiters.repetition});

    // Count key segments
    std.debug.print("📊 Segment Counts:\n", .{});
    std.debug.print("  HL:  {d} (Hierarchy Levels)\n", .{doc.countSegments("HL")});
    std.debug.print("  NM1: {d} (Names)\n", .{doc.countSegments("NM1")});
    std.debug.print("  CLM: {d} (Claims)\n", .{doc.countSegments("CLM")});
    std.debug.print("  HI:  {d} (Health Information)\n", .{doc.countSegments("HI")});
    std.debug.print("  SV1: {d} (Service Lines)\n", .{doc.countSegments("SV1")});
    std.debug.print("  LX:  {d} (Service Line Numbers)\n\n", .{doc.countSegments("LX")});

    // Show first ST segment
    if (doc.findSegment("ST")) |st| {
        std.debug.print("📋 Transaction Set (ST):\n", .{});
        std.debug.print("  Transaction Set ID: {s}\n", .{st.getElement(1).?});
        std.debug.print("  Control Number: {s}\n", .{st.getElement(2).?});
        std.debug.print("  Implementation Guide: {s}\n\n", .{st.getElement(3).?});
    }

    // Analyze CLM segments with composite elements
    const clm_segments = try doc.findAllSegments(allocator, "CLM");
    defer allocator.free(clm_segments);

    std.debug.print("💰 Claims Analysis:\n", .{});
    for (clm_segments, 0..) |clm, i| {
        const claim_id = clm.getElement(1) orelse "UNKNOWN";
        const amount = clm.getElement(2) orelse "0.00";

        std.debug.print("  Claim {d}: {s} - ${s}\n", .{ i + 1, claim_id, amount });

        // Parse CLM05 composite element (facility code information)
        if (try clm.parseComposite(allocator, 5, doc.delimiters.composite)) |comp| {
            var composite = comp;
            defer composite.deinit();
            std.debug.print("    Facility Type: {s}:{s}:{s}\n", .{
                composite.getComponent(0) orelse "",
                composite.getComponent(1) orelse "",
                composite.getComponent(2) orelse "",
            });
        }
    }
    std.debug.print("\n", .{});

    // Analyze HI segments with repetition and composite elements
    const hi_segments = try doc.findAllSegments(allocator, "HI");
    defer allocator.free(hi_segments);

    std.debug.print("🏥 Health Information (HI) Segments: {d}\n", .{hi_segments.len});
    for (hi_segments[0..@min(5, hi_segments.len)], 0..) |hi, i| {
        std.debug.print("  HI Segment {d}:\n", .{i + 1});

        // Try parsing as repetition (diagnosis codes can repeat)
        if (try hi.parseRepetition(allocator, 1, doc.delimiters.repetition)) |r| {
            var rep = r;
            defer rep.deinit();
            std.debug.print("    Repetitions: {d}\n", .{rep.repetitions.len});

            // Parse each repetition as composite (qualifier:code)
            for (rep.repetitions, 0..) |repetition, rep_idx| {
                var iter = std.mem.splitAny(u8, repetition, &[_]u8{doc.delimiters.composite});
                const qualifier = iter.next() orelse "";
                const code = iter.next() orelse "";
                std.debug.print("      {d}. {s}:{s}\n", .{ rep_idx + 1, qualifier, code });
            }
        } else {
            // Not a repetition, try as single composite
            if (try hi.parseComposite(allocator, 1, doc.delimiters.composite)) |c| {
                var comp = c;
                defer comp.deinit();
                std.debug.print("    Composite: {s}\n", .{hi.getElement(1).?});
            }
        }
    }
    std.debug.print("\n", .{});

    // Show HL hierarchy
    const hl_segments = try doc.findAllSegments(allocator, "HL");
    defer allocator.free(hl_segments);

    std.debug.print("🌲 Hierarchy Levels (HL):\n", .{});
    for (hl_segments) |hl| {
        const hl_id = hl.getElement(1) orelse "?";
        const parent_id = hl.getElement(2) orelse "";
        const level_code = hl.getElement(3) orelse "?";
        const has_children = hl.getElement(4) orelse "?";

        if (parent_id.len > 0) {
            std.debug.print("  HL {s} (parent={s}, level={s}, children={s})\n", .{
                hl_id,
                parent_id,
                level_code,
                has_children,
            });
        } else {
            std.debug.print("  HL {s} (root, level={s}, children={s})\n", .{
                hl_id,
                level_code,
                has_children,
            });
        }
    }

    std.debug.print("\n✨ Tokenizer test complete!\n", .{});
}
