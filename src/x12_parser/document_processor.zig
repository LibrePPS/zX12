const std = @import("std");
const testing = std.testing;
const x12_parser = @import("x12_parser.zig");
const hl_tree = @import("hl_tree.zig");
const schema_mod = @import("schema.zig");
const json_builder = @import("json_builder.zig");

const X12Document = x12_parser.X12Document;
const HLTree = hl_tree.HLTree;
const HLNode = hl_tree.HLNode;
const Schema = schema_mod.Schema;
const JsonBuilder = json_builder.JsonBuilder;
const JsonValue = json_builder.JsonValue;
const JsonObject = json_builder.JsonObject;
const JsonArray = json_builder.JsonArray;

pub const X12_File = struct {
    file_path: ?[]const u8,
    file_contents: ?[]u8,
    owned: bool = false,

    /// Load file contents into memory
    /// Non-op if contents are already loaded
    pub fn loadContents(self: *X12_File, allocator: std.mem.Allocator) !void {
        if (self.file_contents != null) {
            return;
        }
        if (self.file_path) |path| {
            var file: std.fs.File = undefined;
            const is_absoulte = std.fs.path.isAbsolute(path);
            switch (is_absoulte) {
                true => {
                    file = try std.fs.openFileAbsolute(path, .{
                        .mode = .read_only,
                    });
                },
                false => {
                    file = try std.fs.cwd().openFile(path, .{
                        .mode = .read_only,
                    });
                },
            }
            defer file.close();
            const file_sz = try file.getEndPos();
            self.file_contents = try allocator.alloc(u8, file_sz);
            const read_sz = try file.readAll(self.file_contents.?);
            if (read_sz != file_sz) {
                return std.fs.File.ReadError.Unexpected;
            }
            self.owned = true;
        } else {
            return std.fs.File.OpenError.FileNotFound;
        }
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        if (self.file_contents) |contents| {
            allocator.free(contents);
        }
    }
};

/// Process X12 document and convert to JSON
pub fn processDocument(
    allocator: std.mem.Allocator,
    x12_file: *X12_File,
    schema_path: ?[]const u8,
    schema: ?Schema,
) !std.ArrayList(u8) {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const parser_allocator = arena.allocator();
    defer x12_file.deinit(parser_allocator);
    // Parse X12 document
    if (x12_file.file_contents == null and x12_file.file_path != null) {
        try x12_file.loadContents(parser_allocator);
    }
    if (x12_file.file_contents == null) {
        return std.fs.File.ReadError.Unexpected;
    }
    var document = try x12_parser.parse(parser_allocator, x12_file.file_contents.?);
    defer document.deinit();

    if (schema == null and schema_path == null) {
        return std.json.Error.UnexpectedEndOfInput;
    }

    var schema_to_use: ?Schema = schema;
    // Load schema
    if (schema_to_use == null) {
        schema_to_use = try schema_mod.loadSchema(parser_allocator, schema_path.?);
    }

    // Collect boundary segments from schema
    var boundary_segments = try schema_to_use.?.collectBoundarySegments(parser_allocator);
    defer boundary_segments.deinit();

    // Build HL tree
    var tree = try hl_tree.buildTree(parser_allocator, document);
    defer tree.deinit();

    // Create JSON builder
    var builder = JsonBuilder.init(parser_allocator);
    defer builder.deinit();

    // Process sections
    try processHeader(&builder, &document, &schema_to_use.?, parser_allocator);
    try processHierarchy(&builder, &tree, &document, &schema_to_use.?, &boundary_segments, parser_allocator);
    try processTrailer(&builder, &document, &schema_to_use.?, parser_allocator);

    // Stringify JSON
    var output = std.ArrayList(u8){};
    try builder.stringify(&output, allocator); //<--Use the callers allocator here so they own memorys

    if (schema == null) {
        // Only deinit schema if it was loaded by this function
        schema_to_use.?.deinit();
    }
    return output;
}

/// Process header segments (ISA, GS, ST, BHT)
fn processHeader(
    builder: *JsonBuilder,
    document: *const X12Document,
    schema: *const Schema,
    allocator: std.mem.Allocator,
) !void {
    for (schema.header_segments) |seg_def| {
        if (document.findSegment(seg_def.id)) |segment| {
            try processSegment(builder, &segment, &seg_def, document, allocator);
        }
    }
}

/// Process sequential (non-hierarchical) sections
/// Process hierarchical structure (HL segments and their children)
fn processHierarchy(
    builder: *JsonBuilder,
    tree: *const HLTree,
    document: *const X12Document,
    schema: *const Schema,
    boundary_segments: *const std.StringHashMap(void),
    allocator: std.mem.Allocator,
) !void {
    // Process each root node
    for (tree.roots) |*root| {
        try processHLNode(builder, root, tree, document, schema, boundary_segments, schema.hierarchical_output_array, allocator);
    }
}

/// Process a single HL node and its descendants
fn processHLNode(
    builder: *JsonBuilder,
    node: *const HLNode,
    _: *const HLTree,
    document: *const X12Document,
    schema: *const Schema,
    boundary_segments: *const std.StringHashMap(void),
    parent_array_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    // Get level definition from schema
    const level = schema.getLevel(node.level_code) orelse return error.UnknownHLLevel;

    // Create object for this node
    const node_obj = try allocator.create(JsonObject);
    node_obj.* = JsonObject.init(allocator);

    // Process segments for this HL level
    const segments = node.getSegments(document.*) orelse return;
    std.log.debug("HL node level={s}, segment_start={d}, segment_end={d}, segments.len={d}", .{ node.level_code, node.segment_start, node.segment_end, segments.len });
    var seg_idx: usize = 0;

    for (level.segments) |seg_def| {
        // Find matching segments in this node's range
        while (seg_idx < segments.len) : (seg_idx += 1) {
            const segment = &segments[seg_idx];

            if (std.mem.eql(u8, segment.id, seg_def.id)) {
                // Check qualifier if specified
                var matches = true;
                if (seg_def.qualifier) |qual| {
                    if (qual.len >= 2) {
                        const pos = try std.fmt.parseInt(usize, qual[0], 10);
                        const expected = qual[1];
                        // Add 1 to pos to skip segment ID at position 0
                        if (segment.getElement(pos + 1)) |elem| {
                            if (!std.mem.eql(u8, elem, expected)) {
                                matches = false;
                            }
                        } else {
                            matches = false;
                        }
                    }
                }

                if (matches) {
                    // Create empty processed segments map for node-level segments
                    var dummy_processed = std.AutoHashMap(*const x12_parser.Segment, void).init(allocator);
                    defer dummy_processed.deinit();
                    // Process segment into node object
                    try processSegmentIntoObject(node_obj, segment, &seg_def, segments, seg_idx, boundary_segments, allocator, &dummy_processed);
                    seg_idx += 1;
                    break;
                }
            }
        }
    }

    // Process each non-hierarchical loop at this level
    // Create a processed_segments map to track segments consumed by groups
    var processed_segments = std.AutoHashMap(*const x12_parser.Segment, void).init(allocator);
    defer processed_segments.deinit();

    for (level.non_hierarchical_loops) |loop| {
        _ = try processNonHierarchicalLoop(node_obj, &loop, segments, seg_idx, segments.len, document, boundary_segments, allocator, &processed_segments);
    }

    // Add node to parent array
    try builder.pushToArray(parent_array_path, node_obj);

    // Process children - each child level has its own output_array nested within this node
    std.log.debug("Node has {d} children", .{node.children.len});
    if (node.children.len > 0) {
        for (node.children) |*child| {
            std.log.debug("Processing child with level_code: {s}", .{child.level_code});
            // Get the child's level definition to find its output_array
            const child_level = schema.getLevel(child.level_code) orelse continue;
            if (child_level.output_array) |child_array_name| {
                // Create child object
                const child_obj = try allocator.create(JsonObject);
                child_obj.* = JsonObject.init(allocator);

                // Process the child node
                const child_segments = child.getSegments(document.*) orelse continue;
                std.log.debug("Child level={s}, segment_start={d}, segment_end={d}, segments.len={d}", .{ child.level_code, child.segment_start, child.segment_end, child_segments.len });
                var child_seg_idx: usize = 0;

                // Process segments for child level
                for (child_level.segments) |seg_def| {
                    // Reset to start of search for each segment definition
                    var search_idx = child_seg_idx;
                    while (search_idx < child_segments.len) : (search_idx += 1) {
                        const segment = &child_segments[search_idx];
                        if (std.mem.eql(u8, segment.id, seg_def.id)) {
                            var matches = true;
                            if (seg_def.qualifier) |qual| {
                                if (qual.len >= 2) {
                                    const pos = try std.fmt.parseInt(usize, qual[0], 10);
                                    const expected = qual[1];
                                    // Add 1 to pos to skip segment ID at position 0
                                    if (segment.getElement(pos + 1)) |elem| {
                                        if (!std.mem.eql(u8, elem, expected)) {
                                            matches = false;
                                        }
                                    } else {
                                        matches = false;
                                    }
                                }
                            }
                            if (matches) {
                                var dummy_processed = std.AutoHashMap(*const x12_parser.Segment, void).init(allocator);
                                defer dummy_processed.deinit();
                                try processSegmentIntoObject(child_obj, segment, &seg_def, child_segments, search_idx, boundary_segments, allocator, &dummy_processed);
                                child_seg_idx = search_idx + 1;
                                break;
                            }
                        }
                    }
                }

                // Process non-hierarchical loops for child
                for (child_level.non_hierarchical_loops) |loop| {
                    var child_processed = std.AutoHashMap(*const x12_parser.Segment, void).init(allocator);
                    defer child_processed.deinit();
                    _ = try processNonHierarchicalLoop(child_obj, &loop, child_segments, child_seg_idx, child_segments.len, document, boundary_segments, allocator, &child_processed);
                }

                // Add child array to parent object if it doesn't exist
                if (node_obj.get(child_array_name) == null) {
                    const child_array = try allocator.create(JsonArray);
                    child_array.* = JsonArray.init(allocator);
                    try node_obj.put(child_array_name, JsonValue{ .array = child_array });
                }

                // Add child object to the array
                if (node_obj.get(child_array_name)) |array_value| {
                    if (array_value == .array) {
                        try array_value.array.append(JsonValue{ .object = child_obj });
                    }
                }

                // Recursively process grandchildren (e.g., patients under subscribers)
                if (child.children.len > 0) {
                    for (child.children) |*grandchild| {
                        const grandchild_level = schema.getLevel(grandchild.level_code) orelse continue;
                        if (grandchild_level.output_array) |grandchild_array_name| {
                            // Create grandchild object
                            const grandchild_obj = try allocator.create(JsonObject);
                            grandchild_obj.* = JsonObject.init(allocator);

                            // Process the grandchild node
                            const grandchild_segments = grandchild.getSegments(document.*) orelse continue;
                            std.log.debug("Grandchild level={s}, segment_start={d}, segment_end={d}, segments.len={d}", .{ grandchild.level_code, grandchild.segment_start, grandchild.segment_end, grandchild_segments.len });

                            // Debug: List segments to find LX
                            std.log.debug("First 150 grandchild segments:", .{});
                            for (grandchild_segments, 0..) |seg, i| {
                                if (i < 150) {
                                    const first_elem = if (seg.elements.len > 1) seg.elements[1] else "";
                                    std.log.debug("  [{d}] {s}: {s}", .{ i, seg.id, first_elem });
                                }
                            }

                            var grandchild_seg_idx: usize = 0;

                            // Process segments for grandchild level
                            for (grandchild_level.segments) |seg_def| {
                                var search_idx = grandchild_seg_idx;
                                while (search_idx < grandchild_segments.len) : (search_idx += 1) {
                                    const segment = &grandchild_segments[search_idx];
                                    if (std.mem.eql(u8, segment.id, seg_def.id)) {
                                        var matches = true;
                                        if (seg_def.qualifier) |qual| {
                                            if (qual.len >= 2) {
                                                const pos = try std.fmt.parseInt(usize, qual[0], 10);
                                                const expected = qual[1];
                                                // Add 1 to pos to skip segment ID at position 0
                                                if (segment.getElement(pos + 1)) |elem| {
                                                    if (!std.mem.eql(u8, elem, expected)) {
                                                        matches = false;
                                                    }
                                                } else {
                                                    matches = false;
                                                }
                                            }
                                        }
                                        if (matches) {
                                            var dummy_processed = std.AutoHashMap(*const x12_parser.Segment, void).init(allocator);
                                            defer dummy_processed.deinit();
                                            try processSegmentIntoObject(grandchild_obj, segment, &seg_def, grandchild_segments, search_idx, boundary_segments, allocator, &dummy_processed);
                                            grandchild_seg_idx = search_idx + 1;
                                            break;
                                        }
                                    }
                                }
                            }

                            // Process non-hierarchical loops for grandchild (e.g., claims)
                            for (grandchild_level.non_hierarchical_loops) |loop| {
                                var grandchild_processed = std.AutoHashMap(*const x12_parser.Segment, void).init(allocator);
                                defer grandchild_processed.deinit();
                                _ = try processNonHierarchicalLoop(grandchild_obj, &loop, grandchild_segments, grandchild_seg_idx, grandchild_segments.len, document, boundary_segments, allocator, &grandchild_processed);
                            }

                            // Add grandchild array to child object if it doesn't exist
                            if (child_obj.get(grandchild_array_name) == null) {
                                const grandchild_array = try allocator.create(JsonArray);
                                grandchild_array.* = JsonArray.init(allocator);
                                try child_obj.put(grandchild_array_name, JsonValue{ .array = grandchild_array });
                            }

                            // Add grandchild object to the array
                            if (child_obj.get(grandchild_array_name)) |array_value| {
                                if (array_value == .array) {
                                    try array_value.array.append(JsonValue{ .object = grandchild_obj });
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Process non-hierarchical loop (repeating section within an HL level)
/// Returns the maximum segment index processed (for nested loop tracking)
fn processNonHierarchicalLoop(
    parent_obj: *JsonObject,
    loop: *const schema_mod.NonHierarchicalLoop,
    segments: []const x12_parser.Segment,
    start_idx: usize,
    end_idx: usize,
    document: *const X12Document,
    boundary_segments: *const std.StringHashMap(void),
    allocator: std.mem.Allocator,
    processed_segments: *std.AutoHashMap(*const x12_parser.Segment, void),
) !usize {
    std.log.debug("Processing non-hierarchical loop: {s}, trigger: {s}, starting from index {d}", .{ loop.name, loop.trigger, start_idx });

    var seg_idx = start_idx;
    var overall_max_idx = start_idx; // Track the furthest index across all loop instances

    // Find all instances of this loop (triggered by trigger segment)
    while (seg_idx < segments.len and seg_idx < end_idx) {
        const segment = &segments[seg_idx];

        // Check if this segment triggers the loop
        if (std.mem.eql(u8, segment.id, loop.trigger)) {
            const first_elem = if (segment.elements.len > 0) segment.elements[0] else "";
            std.log.debug("Found loop trigger '{s}' at index {d}, segment ID: {s}, first element: '{s}', total elements: {d}", .{ loop.trigger, seg_idx, segment.id, first_elem, segment.elements.len });
            // Create object for this loop instance
            var loop_obj = JsonObject.init(allocator);

            // Process segments for this loop instance
            var max_idx = seg_idx; // Track the furthest position we've processed

            // Find the end boundary for this loop instance
            // Should stop at: 1) next instance of this loop, OR 2) first nested loop trigger
            var nested_end_idx = end_idx;
            for (seg_idx + 1..end_idx) |search_idx| {
                // Check if this is the next instance of the current loop
                if (std.mem.eql(u8, segments[search_idx].id, loop.trigger)) {
                    nested_end_idx = search_idx;
                    break;
                }
                // Check if this is a nested loop trigger
                for (loop.nested_loops) |nested_loop| {
                    if (std.mem.eql(u8, segments[search_idx].id, nested_loop.trigger)) {
                        if (search_idx < nested_end_idx) {
                            nested_end_idx = search_idx;
                        }
                        break;
                    }
                }
            }
            std.log.debug("Loop instance boundary: seg_idx={d}, nested_end_idx={d}, end_idx={d}", .{ seg_idx, nested_end_idx, end_idx });

            std.log.debug("Processing segments for loop instance, starting from index {d}", .{seg_idx});

            // Process segments with groups first, so they can claim their group members
            // before other segment definitions try to process them
            for (loop.segments) |seg_def| {
                if (seg_def.group == null) continue; // Skip non-group segments in first pass

                std.log.debug("Looking for segment: {s} (multiple: {}, optional: {}) [GROUP PASS]", .{ seg_def.id, seg_def.multiple, seg_def.optional });
                // Find matching segment(s) starting from loop start position
                // This allows segments to appear in any order in the X12 file
                var search_idx = seg_idx;
                var found_any = false;
                if (std.mem.eql(u8, seg_def.id, "NM1")) {
                    std.log.debug("NM1 GROUP search range: {d} to {d}", .{ seg_idx, nested_end_idx });
                }
                while (search_idx < segments.len and search_idx < nested_end_idx) : (search_idx += 1) {
                    const inner_seg = &segments[search_idx];
                    if (std.mem.eql(u8, seg_def.id, "NM1") and search_idx >= 90 and search_idx <= 95) {
                        std.log.debug("Checking segment at index {d}: ID={s}", .{ search_idx, inner_seg.id });
                    }

                    // Skip if this segment was already processed by a group
                    if (processed_segments.contains(inner_seg)) {
                        if (std.mem.eql(u8, seg_def.id, "NM1")) {
                            std.log.debug("Skipping already-processed NM1 at index {d}", .{search_idx});
                        }
                        continue;
                    }

                    // Stop if we hit the next loop trigger (next instance of this loop)
                    if (search_idx > seg_idx and std.mem.eql(u8, inner_seg.id, loop.trigger)) {
                        if (std.mem.eql(u8, seg_def.id, "NM1")) {
                            std.log.debug("NM1 search breaking at index {d}: hit next loop trigger {s}", .{ search_idx, loop.trigger });
                        }
                        break;
                    }

                    // Stop if we hit a hierarchical segment (HL) - that's definitely a boundary
                    if (std.mem.eql(u8, inner_seg.id, "HL")) {
                        if (std.mem.eql(u8, seg_def.id, "NM1")) {
                            std.log.debug("NM1 search breaking at index {d}: hit HL segment", .{search_idx});
                        }
                        break;
                    }

                    // Note: We don't break on nested loop triggers here because the parent loop
                    // may have segments (like NM1 groups) that come after nested loop triggers.
                    // The processed_segments map will prevent double-processing.

                    if (std.mem.eql(u8, inner_seg.id, seg_def.id)) {
                        if (std.mem.eql(u8, seg_def.id, "NM1")) {
                            std.log.debug("Found NM1 at index {d}", .{search_idx});
                        }
                        // Check qualifier if specified
                        var matches = true;
                        if (seg_def.qualifier) |qual| {
                            if (qual.len >= 2) {
                                const pos = try std.fmt.parseInt(usize, qual[0], 10);
                                const expected = qual[1];
                                // Add 1 to pos to skip segment ID at position 0
                                if (inner_seg.getElement(pos + 1)) |elem| {
                                    if (!std.mem.eql(u8, elem, expected)) {
                                        matches = false;
                                    }
                                } else {
                                    matches = false;
                                }
                            }
                        }

                        if (matches) {
                            // Process segment into loop object
                            try processSegmentIntoObject(&loop_obj, inner_seg, &seg_def, segments, search_idx, boundary_segments, allocator, processed_segments);
                            found_any = true;

                            // Mark this segment as processed
                            try processed_segments.put(inner_seg, {});

                            // Track furthest position
                            if (search_idx >= max_idx) {
                                std.log.debug("Updating max_idx from {d} to {d} (GROUP segment {s} at index {d})", .{ max_idx, search_idx + 1, seg_def.id, search_idx });
                                max_idx = search_idx + 1;
                            }

                            // If not multiple, break after first match
                            if (!seg_def.multiple) {
                                break;
                            }
                            // Otherwise, continue searching for more instances
                        }
                    }
                }

                // If this was a non-multiple segment and we didn't find it, that's okay if it's optional
                // If multiple, we might have found 0 or more, that's also okay
            }

            // Process nested loops after group segments but before non-group segments
            // This allows nested loops to claim their segments before the parent loop's non-group processing
            for (loop.nested_loops, 0..) |nested_loop, nested_idx| {
                // Calculate end boundary for this specific nested loop
                // It should stop at the next sibling nested loop trigger or the parent's end
                var this_nested_end = end_idx;

                // Find this nested loop's trigger position
                var this_loop_start: ?usize = null;
                for (seg_idx..end_idx) |search_idx| {
                    if (std.mem.eql(u8, segments[search_idx].id, nested_loop.trigger)) {
                        this_loop_start = search_idx;
                        break;
                    }
                }

                // If we found this loop's trigger, find where it should end
                if (this_loop_start) |loop_start| {
                    // Look for the next sibling nested loop trigger after this one starts
                    for (loop_start + 1..end_idx) |search_idx| {
                        // Check all sibling nested loops
                        for (loop.nested_loops, 0..) |sibling_loop, sibling_idx| {
                            if (sibling_idx != nested_idx and std.mem.eql(u8, segments[search_idx].id, sibling_loop.trigger)) {
                                if (search_idx < this_nested_end) {
                                    this_nested_end = search_idx;
                                }
                            }
                        }
                        // Also check for next instance of parent loop
                        if (std.mem.eql(u8, segments[search_idx].id, loop.trigger)) {
                            if (search_idx < this_nested_end) {
                                this_nested_end = search_idx;
                            }
                            break;
                        }
                    }

                    const nested_max_idx = try processNonHierarchicalLoop(&loop_obj, &nested_loop, segments, loop_start, this_nested_end, document, boundary_segments, allocator, processed_segments);
                    std.log.debug("Nested loop '{s}' returned max index: {d}, current max_idx: {d}", .{ nested_loop.name, nested_max_idx, max_idx });
                    // Update max_idx to account for segments processed by nested loops
                    if (nested_max_idx > max_idx) {
                        std.log.debug("Updating max_idx from {d} to {d} based on nested loop", .{ max_idx, nested_max_idx });
                        max_idx = nested_max_idx;
                    }
                    // Also update overall max
                    if (max_idx > overall_max_idx) {
                        overall_max_idx = max_idx;
                    }
                }
            }

            // Now process segments without groups
            for (loop.segments) |seg_def| {
                if (seg_def.group != null) continue; // Skip group segments in second pass

                std.log.debug("Looking for segment: {s} (multiple: {}, optional: {})", .{ seg_def.id, seg_def.multiple, seg_def.optional });
                // Find matching segment(s) starting from loop start position
                // This allows segments to appear in any order in the X12 file
                var search_idx = seg_idx;
                var found_any = false;
                while (search_idx < segments.len and search_idx < nested_end_idx) : (search_idx += 1) {
                    const inner_seg = &segments[search_idx];

                    // Skip if this segment was already processed by a group
                    if (processed_segments.contains(inner_seg)) {
                        if (std.mem.eql(u8, seg_def.id, "NM1")) {
                            std.log.debug("Skipping already-processed NM1 at index {d} (non-group pass)", .{search_idx});
                        }
                        continue;
                    }

                    // Stop if we hit the next loop trigger (next instance of this loop)
                    if (search_idx > seg_idx and std.mem.eql(u8, inner_seg.id, loop.trigger)) {
                        break;
                    }

                    // Stop if we hit a hierarchical segment (HL) - that's definitely a boundary
                    if (std.mem.eql(u8, inner_seg.id, "HL")) {
                        break;
                    }

                    // Note: We don't break on nested loop triggers here because the parent loop
                    // may have segments that come after nested loop triggers.
                    // The processed_segments map will prevent double-processing.

                    if (std.mem.eql(u8, inner_seg.id, seg_def.id)) {
                        // Check qualifier if specified
                        var matches = true;
                        if (seg_def.qualifier) |qual| {
                            if (qual.len >= 2) {
                                const pos = try std.fmt.parseInt(usize, qual[0], 10);
                                const expected = qual[1];
                                // Add 1 to pos to skip segment ID at position 0
                                if (inner_seg.getElement(pos + 1)) |elem| {
                                    if (!std.mem.eql(u8, elem, expected)) {
                                        matches = false;
                                    }
                                } else {
                                    matches = false;
                                }
                            }
                        }

                        if (matches) {
                            // Process segment into loop object
                            try processSegmentIntoObject(&loop_obj, inner_seg, &seg_def, segments, search_idx, boundary_segments, allocator, processed_segments);
                            found_any = true;

                            // Mark this segment as processed
                            try processed_segments.put(inner_seg, {});

                            // Track furthest position
                            if (search_idx >= max_idx) {
                                std.log.debug("Updating max_idx from {d} to {d} (segment {s} at index {d})", .{ max_idx, search_idx + 1, seg_def.id, search_idx });
                                max_idx = search_idx + 1;
                            }

                            // If not multiple, break after first match
                            if (!seg_def.multiple) {
                                break;
                            }
                            // Otherwise, continue searching for more instances
                        }
                    }
                }

                // If this was a non-multiple segment and we didn't find it, that's okay if it's optional
                // If multiple, we might have found 0 or more, that's also okay
            }

            // Add loop object to parent array
            const loop_obj_ptr = try allocator.create(JsonObject);
            loop_obj_ptr.* = loop_obj;
            const loop_value = JsonValue{ .object = loop_obj_ptr };

            // Get or create the array for this loop
            if (parent_obj.get(loop.output_array)) |_| {
                // Array already exists, append to it
                var array_value = parent_obj.getPtr(loop.output_array).?;
                try array_value.array.append(loop_value);
            } else {
                // Create new array with this object
                const new_array_ptr = try allocator.create(JsonArray);
                new_array_ptr.* = JsonArray.init(allocator);
                try new_array_ptr.append(loop_value);
                try parent_obj.put(loop.output_array, JsonValue{ .array = new_array_ptr });
            }

            // Move to next potential loop instance using max_idx
            std.log.debug("Moving to next loop instance: max_idx={d}, seg_idx before={d}", .{ max_idx, seg_idx });
            // Update overall max before moving to next instance
            if (max_idx > overall_max_idx) {
                overall_max_idx = max_idx;
            }
            seg_idx = max_idx;
            std.log.debug("seg_idx after={d}, segments.len={d}", .{ seg_idx, segments.len });
        } else {
            seg_idx += 1;
        }
    }

    // Return the furthest segment index we've seen across all loop instances
    return overall_max_idx;
}

/// Process trailer segments (SE, GE, IEA)
fn processTrailer(
    builder: *JsonBuilder,
    document: *const X12Document,
    schema: *const Schema,
    allocator: std.mem.Allocator,
) !void {
    for (schema.trailer_segments) |seg_def| {
        if (document.findSegment(seg_def.id)) |segment| {
            try processSegment(builder, &segment, &seg_def, document, allocator);
        }
    }
}

/// Process a segment's elements into JSON builder
fn processSegment(
    builder: *JsonBuilder,
    segment: *const x12_parser.Segment,
    seg_def: *const schema_mod.SegmentDef,
    document: *const X12Document,
    allocator: std.mem.Allocator,
) !void {
    for (seg_def.elements) |elem_def| {
        try processElement(builder, segment, &elem_def, document, allocator);
    }
}

/// Process repeating composite elements into arrays in an object
fn processRepeatingElements(
    obj: *JsonObject,
    segment: *const x12_parser.Segment,
    rep_config: *const schema_mod.RepeatingElements,
    allocator: std.mem.Allocator,
) !void {
    std.log.debug("processRepeatingElements: Starting for segment '{s}'", .{segment.id});

    // Get all elements from the segment (skip element 0 which is the segment ID)
    var elem_idx: usize = 1; // Start at 1 to skip segment ID
    var element_count: usize = 0;

    while (segment.getElement(elem_idx)) |element_value| : (elem_idx += 1) {
        element_count += 1;
        std.log.debug("Element {d}: '{s}'", .{ elem_idx, element_value });

        // Split the element by the separator to get composite components
        var components = std.ArrayList([]const u8){};
        defer components.deinit(allocator);

        var iter = std.mem.splitSequence(u8, element_value, rep_config.separator);
        while (iter.next()) |component| {
            try components.append(allocator, component);
        }

        std.log.debug("Split into {d} components", .{components.items.len});

        // Must have at least a qualifier component
        if (components.items.len == 0) continue;

        const qualifier = components.items[0];
        std.log.debug("Qualifier: '{s}'", .{qualifier});

        // Find matching pattern for this qualifier
        for (rep_config.patterns) |pattern| {
            var matched = false;
            for (pattern.when_qualifier) |when_qual| {
                if (std.mem.eql(u8, qualifier, when_qual)) {
                    matched = true;
                    break;
                }
            }

            if (!matched) continue;

            std.log.debug("Matched pattern for array: '{s}'", .{pattern.output_array});

            // Create object for this element with fields from pattern
            var elem_obj = JsonObject.init(allocator);
            var field_count: usize = 0;

            for (pattern.fields) |field| {
                if (field.component < components.items.len) {
                    const component_value = components.items[field.component];
                    if (component_value.len > 0) {
                        const owned = try allocator.dupe(u8, component_value);
                        try elem_obj.put(field.name, JsonValue{ .string = owned });
                        field_count += 1;
                        std.log.debug("Added field '{s}' = '{s}'", .{ field.name, component_value });
                    }
                }
            }

            std.log.debug("Created object with {d} fields", .{field_count});

            // Create pointer to object
            const elem_obj_ptr = try allocator.create(JsonObject);
            elem_obj_ptr.* = elem_obj;

            // Get or create the array for this pattern
            if (obj.getPtr(pattern.output_array)) |existing_value| {
                // Array exists, append to it
                if (existing_value.* == .array) {
                    std.log.debug("Appending to existing array '{s}'", .{pattern.output_array});
                    try existing_value.array.append(JsonValue{ .object = elem_obj_ptr });
                }
            } else {
                // Create new array
                std.log.debug("Creating new array '{s}'", .{pattern.output_array});
                const new_array_ptr = try allocator.create(JsonArray);
                new_array_ptr.* = JsonArray.init(allocator);
                try new_array_ptr.append(JsonValue{ .object = elem_obj_ptr });
                try obj.put(pattern.output_array, JsonValue{ .array = new_array_ptr });
            }

            break; // Matched a pattern, move to next element
        }
    }

    std.log.debug("processRepeatingElements: Processed {d} elements", .{element_count});
}

/// Process segment elements into an existing object
fn processSegmentIntoObject(
    obj: *JsonObject,
    segment: *const x12_parser.Segment,
    seg_def: *const schema_mod.SegmentDef,
    segments: []const x12_parser.Segment,
    segment_idx: usize,
    boundary_segments: *const std.StringHashMap(void),
    allocator: std.mem.Allocator,
    processed_segments: *std.AutoHashMap(*const x12_parser.Segment, void),
) !void {
    std.log.debug("processSegmentIntoObject: segment '{s}', has {d} elements, repeating_elements: {}", .{ segment.id, seg_def.elements.len, seg_def.repeating_elements != null });

    // Check if this is a multiple segment with qualifier mapping
    // If so, we need to create a nested object based on the qualifier value
    var target_obj = obj;
    var qualifier_key: ?[]const u8 = null;
    var should_cleanup_nested = false;
    var use_direct_value = false; // Flag to indicate if we should flatten to a direct value

    if (seg_def.multiple and seg_def.elements.len > 0) {
        const first_elem = seg_def.elements[0];
        // Check if first element is at position 0 (qualifier position)
        if (first_elem.pos == 0) {
            // Check if there's only one other element and it has an empty path (indicating flatten)
            var element_count: usize = 0;
            var has_empty_path = false;
            for (seg_def.elements) |elem| {
                if (elem.pos != 0) { // Skip qualifier
                    element_count += 1;
                    if (elem.path.len == 0 or std.mem.eql(u8, elem.path, ".")) {
                        has_empty_path = true;
                    }
                }
            }

            // If there's only one non-qualifier element with empty path, use direct value
            if (element_count == 1 and has_empty_path) {
                use_direct_value = true;
            }

            // Get the qualifier value from the segment
            if (segment.getElement(1)) |qualifier_value| { // pos 0 + 1 to skip segment ID
                // Try to map the qualifier, or use the raw value if no mapping exists
                var key_to_use: []const u8 = qualifier_value;
                if (first_elem.map) |map| {
                    if (map.get(qualifier_value)) |mapped_key| {
                        key_to_use = mapped_key;
                        std.log.debug("Multiple segment with qualifier mapping: '{s}' -> '{s}'", .{ qualifier_value, mapped_key });
                    } else {
                        std.log.debug("Multiple segment with unmapped qualifier: '{s}' (using raw value)", .{qualifier_value});
                    }
                } else {
                    std.log.debug("Multiple segment with qualifier: '{s}' (no map defined, using raw value)", .{qualifier_value});
                }

                // Need to allocate the key if it's the raw qualifier value (not already in schema)
                if (key_to_use.ptr == qualifier_value.ptr) {
                    key_to_use = try allocator.dupe(u8, qualifier_value);
                }
                qualifier_key = key_to_use;

                if (!use_direct_value) {
                    // Get or create nested object for this qualifier
                    if (obj.get(key_to_use)) |existing| {
                        // Object already exists, use it
                        target_obj = existing.object;
                    } else {
                        // Create new nested object
                        const nested_obj_ptr = try allocator.create(JsonObject);
                        nested_obj_ptr.* = JsonObject.init(allocator);
                        try obj.put(key_to_use, JsonValue{ .object = nested_obj_ptr });
                        target_obj = nested_obj_ptr;
                        should_cleanup_nested = true;
                    }
                }
            }
        }
    }

    // Process elements from current segment
    for (seg_def.elements) |elem_def| {
        // Skip if element specifies a different segment
        if (elem_def.seg) |seg_id| {
            if (!std.mem.eql(u8, seg_id, segment.id)) {
                continue;
            }
        }

        // Skip the qualifier element if we're using it for nested object key
        if (qualifier_key != null and elem_def.pos == 0) {
            continue;
        }

        // Add 1 to pos to skip segment ID at position 0
        if (segment.getElement(elem_def.pos + 1)) |raw_value| {
            var value = raw_value;

            // Handle composite elements (extract sub-component)
            if (elem_def.composite) |comp_indices| {
                if (comp_indices.len > 0) {
                    const comp_idx = comp_indices[0]; // Use first index specified
                    // Split by composite delimiter - need to get delimiter from segments
                    // For now, we need access to document for delimiter
                    // This is a limitation - we'll need to pass document to this function
                    // For now, hardcode composite delimiter as ':'
                    var iter = std.mem.splitScalar(u8, raw_value, ':');
                    var idx: usize = 0;
                    var found = false;
                    while (iter.next()) |component| : (idx += 1) {
                        if (idx == comp_idx) {
                            value = component;
                            found = true;
                            break;
                        }
                    }
                    // If composite index not found, skip this element
                    if (!found or value.len == 0) continue;
                }
            }

            // Apply value mapping if specified
            if (elem_def.map) |map| {
                if (map.get(value)) |mapped| {
                    value = mapped;
                }
            }

            // Create owned string
            const owned = try allocator.dupe(u8, value);

            // Check if we should use direct value (flatten)
            if (use_direct_value and qualifier_key != null and (elem_def.path.len == 0 or std.mem.eql(u8, elem_def.path, "."))) {
                // Put the value directly on the parent object with the qualifier key
                try obj.put(qualifier_key.?, JsonValue{ .string = owned });
            } else {
                // Add to object at the path (just last part)
                var path_parts = std.mem.splitScalar(u8, elem_def.path, '.');
                var last_part: []const u8 = elem_def.path;
                while (path_parts.next()) |part| {
                    if (path_parts.rest().len == 0) {
                        last_part = part;
                    }
                }

                try target_obj.put(last_part, JsonValue{ .string = owned });
            }
        }
    }

    // Process repeating elements if configured
    if (seg_def.repeating_elements) |rep_config| {
        std.log.debug("Processing repeating elements with separator '{s}', {d} patterns", .{ rep_config.separator, rep_config.patterns.len });
        try processRepeatingElements(target_obj, segment, &rep_config, allocator);
    }

    // If this segment has a group, look for the group segments and process them too
    if (seg_def.group) |group| {
        // Process subsequent segments that are part of the group
        const group_start_idx = segment_idx + 1;
        for (group[1..]) |group_seg_id| { // Skip first as it's the current segment
            // Search for this segment starting from group start position
            var found_any = false;
            var current_search = group_start_idx;

            // Find ALL instances of this segment type in the group
            while (current_search < segments.len) : (current_search += 1) {
                const group_segment = &segments[current_search];

                // Stop searching if we hit a boundary segment (loop trigger or structural segment)
                // These indicate the group has ended
                if (boundary_segments.contains(group_segment.id)) {
                    break;
                }

                // Stop if we hit another instance of the trigger segment (start of next group)
                if (current_search > segment_idx and std.mem.eql(u8, group_segment.id, segment.id)) {
                    break;
                }

                // Check if this is the segment we're looking for
                if (std.mem.eql(u8, group_segment.id, group_seg_id)) {
                    found_any = true;

                    // Mark this segment as processed so parent loop doesn't process it again
                    try processed_segments.put(group_segment, {});

                    // Check if this segment has qualifier mapping defined in schema
                    // If position 0 has a map, use it to create nested objects based on qualifier value
                    var group_target_obj = target_obj;
                    var group_qualifier_key: ?[]const u8 = null;

                    // Look for qualifier mapping at position 0 in the schema
                    for (seg_def.elements) |elem_def| {
                        if (elem_def.seg) |seg_id| {
                            if (std.mem.eql(u8, seg_id, group_seg_id) and elem_def.pos == 0 and elem_def.map != null) {
                                // This segment has a qualifier map - use it for nesting
                                if (group_segment.getElement(1)) |qualifier_value| {
                                    var key_to_use: []const u8 = qualifier_value;
                                    if (elem_def.map) |map| {
                                        if (map.get(qualifier_value)) |mapped_key| {
                                            key_to_use = mapped_key;
                                        }
                                    }

                                    // Allocate if using raw qualifier
                                    if (key_to_use.ptr == qualifier_value.ptr) {
                                        key_to_use = try allocator.dupe(u8, qualifier_value);
                                    }
                                    group_qualifier_key = key_to_use;

                                    // Create or get nested object for this qualifier
                                    if (target_obj.get(key_to_use)) |existing| {
                                        group_target_obj = existing.object;
                                    } else {
                                        const nested_obj_ptr = try allocator.create(JsonObject);
                                        nested_obj_ptr.* = JsonObject.init(allocator);
                                        try target_obj.put(key_to_use, JsonValue{ .object = nested_obj_ptr });
                                        group_target_obj = nested_obj_ptr;
                                    }
                                }
                                break;
                            }
                        }
                    }

                    // Process elements from this group segment
                    for (seg_def.elements) |elem_def| {
                        if (elem_def.seg) |seg_id| {
                            if (std.mem.eql(u8, seg_id, group_seg_id)) {
                                // Skip qualifier element if we used it for nested object key
                                if (group_qualifier_key != null and elem_def.pos == 0) {
                                    continue;
                                }

                                // Add 1 to pos to skip segment ID at position 0
                                if (group_segment.getElement(elem_def.pos + 1)) |raw_value| {
                                    var value = raw_value;
                                    if (elem_def.map) |map| {
                                        if (map.get(value)) |mapped| {
                                            value = mapped;
                                        }
                                    }
                                    const owned = try allocator.dupe(u8, value);

                                    // Check if we should use direct value for groups (flatten)
                                    if (group_qualifier_key != null and (elem_def.path.len == 0 or std.mem.eql(u8, elem_def.path, "."))) {
                                        // Put the value directly on the parent object with the qualifier key
                                        try target_obj.put(group_qualifier_key.?, JsonValue{ .string = owned });
                                    } else {
                                        var path_parts = std.mem.splitScalar(u8, elem_def.path, '.');
                                        var last_part: []const u8 = elem_def.path;
                                        while (path_parts.next()) |part| {
                                            if (path_parts.rest().len == 0) {
                                                last_part = part;
                                            }
                                        }
                                        try group_target_obj.put(last_part, JsonValue{ .string = owned });
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Process a single element into JSON builder
fn processElement(
    builder: *JsonBuilder,
    segment: *const x12_parser.Segment,
    elem_def: *const schema_mod.ElementMapping,
    document: *const X12Document,
    allocator: std.mem.Allocator,
) !void {
    // Add 1 to pos to skip segment ID at position 0
    if (segment.getElement(elem_def.pos + 1)) |raw_value| {
        var value = raw_value;

        // Handle composite elements (extract sub-component)
        if (elem_def.composite) |comp_indices| {
            if (comp_indices.len > 0) {
                const comp_idx = comp_indices[0]; // Use first index specified
                // Split by composite delimiter
                var iter = std.mem.splitScalar(u8, raw_value, document.delimiters.composite);
                var idx: usize = 0;
                var found = false;
                while (iter.next()) |component| : (idx += 1) {
                    if (idx == comp_idx) {
                        value = component;
                        found = true;
                        break;
                    }
                }
                // If composite index not found, skip this element
                if (!found or value.len == 0) return;
            }
        }

        // Apply value mapping if specified
        if (elem_def.map) |map| {
            if (map.get(value)) |mapped| {
                value = mapped;
            }
        }

        // Check expected value if specified
        if (elem_def.expect) |expected| {
            if (!std.mem.eql(u8, value, expected)) {
                // Value doesn't match expected - skip or warn
                return;
            }
        }

        // Create owned string
        const owned = try allocator.dupe(u8, value);

        // Set in builder
        try builder.set(elem_def.path, JsonValue{ .string = owned });
    }
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "process simple X12 document" {
    const allocator = testing.allocator;

    var x12_file = X12_File{ .file_contents = null, .file_path = "samples/simple_test.x12" };
    // Process document
    var output = try processDocument(allocator, &x12_file, "schema/837p.json", null);
    defer output.deinit(allocator);

    // Check output contains expected fields
    const json = output.items;
    try testing.expect(std.mem.indexOf(u8, json, "interchange") != null);
    try testing.expect(std.mem.indexOf(u8, json, "functional_group") != null);
    try testing.expect(std.mem.indexOf(u8, json, "transaction_set") != null);
}

test "process document with HL hierarchy" {
    const allocator = testing.allocator;
    var x12_file = X12_File{ .file_contents = null, .file_path = "samples/837p_example.x12" };
    // Use existing sample file
    var output = try processDocument(allocator, &x12_file, "schema/837p.json", null);
    defer output.deinit(allocator);

    // Check output contains hierarchical structure
    const json = output.items;
    try testing.expect(std.mem.indexOf(u8, json, "billing_providers") != null);
}
