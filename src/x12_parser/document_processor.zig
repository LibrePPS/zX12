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

/// Process X12 document and convert to JSON
pub fn processDocument(
    allocator: std.mem.Allocator,
    x12_file_path: std.fs.File,
    schema_path: []const u8,
) !std.ArrayList(u8) {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const parser_allocator = arena.allocator();
    const x12_sz = try x12_file_path.getEndPos();
    const x12_content = try allocator.alloc(u8, x12_sz);
    defer allocator.free(x12_content);
    _ = try x12_file_path.readAll(x12_content);
    // Parse X12 document
    var document = try x12_parser.parse(parser_allocator, x12_content);
    defer document.deinit();

    // Load schema
    var schema = try schema_mod.loadSchema(parser_allocator, schema_path);
    defer schema.deinit();

    // Build HL tree
    var tree = try hl_tree.buildTree(parser_allocator, document);
    defer tree.deinit();

    // Create JSON builder
    var builder = JsonBuilder.init(parser_allocator);
    defer builder.deinit();

    // Process sections
    try processHeader(&builder, &document, &schema, parser_allocator);
    try processSequentialSections(&builder, &document, &schema, parser_allocator);
    try processHierarchy(&builder, &tree, &document, &schema, parser_allocator);
    try processTrailer(&builder, &document, &schema, parser_allocator);

    // Stringify JSON
    var output = std.ArrayList(u8){};
    try builder.stringify(&output, allocator); //<--Use the callers allocator here so they own memorys

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
fn processSequentialSections(
    builder: *JsonBuilder,
    document: *const X12Document,
    schema: *const Schema,
    allocator: std.mem.Allocator,
) !void {
    _ = builder;
    _ = document;
    _ = allocator;
    for (schema.sequential_sections) |section| {
        // Find start of section by trigger segment (implementation placeholder)
        _ = section;
    }
}

/// Process a single section (group of segments)
fn processSection(
    builder: *JsonBuilder,
    path_prefix: []const u8,
    document: *const X12Document,
    segment_defs: []const schema_mod.SegmentDef,
    start_idx: usize,
    allocator: std.mem.Allocator,
) !void {
    var seg_idx = start_idx;

    for (segment_defs) |seg_def| {
        // Find next matching segment
        while (seg_idx < document.segments.len) : (seg_idx += 1) {
            const segment = &document.segments[seg_idx];

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
                    // Process this segment with path prefix
                    try processSegmentWithPrefix(builder, segment, &seg_def, document, path_prefix, allocator);
                    seg_idx += 1;
                    break;
                }
            }
        }
    }
}

/// Process hierarchical structure (HL segments and their children)
fn processHierarchy(
    builder: *JsonBuilder,
    tree: *const HLTree,
    document: *const X12Document,
    schema: *const Schema,
    allocator: std.mem.Allocator,
) !void {
    // Process each root node
    for (tree.roots) |*root| {
        try processHLNode(builder, root, tree, document, schema, schema.hierarchical_output_array, allocator);
    }
}

/// Process a single HL node and its descendants
fn processHLNode(
    builder: *JsonBuilder,
    node: *const HLNode,
    _: *const HLTree,
    document: *const X12Document,
    schema: *const Schema,
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
                    // Process segment into node object
                    try processSegmentIntoObject(node_obj, segment, &seg_def, segments, seg_idx, allocator);
                    seg_idx += 1;
                    break;
                }
            }
        }
    }

    // Process non-hierarchical loops for this level
    for (level.non_hierarchical_loops) |loop| {
        try processNonHierarchicalLoop(node_obj, &loop, segments, seg_idx, document, allocator);
    }

    // Add node to parent array
    try builder.pushToArray(parent_array_path, node_obj);

    // Process children - each child level has its own output_array nested within this node
    if (node.children.len > 0) {
        for (node.children) |*child| {
            // Get the child's level definition to find its output_array
            const child_level = schema.getLevel(child.level_code) orelse continue;
            if (child_level.output_array) |child_array_name| {
                // Create child object
                const child_obj = try allocator.create(JsonObject);
                child_obj.* = JsonObject.init(allocator);

                // Process the child node
                const child_segments = child.getSegments(document.*) orelse continue;
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
                                try processSegmentIntoObject(child_obj, segment, &seg_def, child_segments, search_idx, allocator);
                                child_seg_idx = search_idx + 1;
                                break;
                            }
                        }
                    }
                }

                // Process non-hierarchical loops for child
                for (child_level.non_hierarchical_loops) |loop| {
                    try processNonHierarchicalLoop(child_obj, &loop, child_segments, child_seg_idx, document, allocator);
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
                                            try processSegmentIntoObject(grandchild_obj, segment, &seg_def, grandchild_segments, search_idx, allocator);
                                            grandchild_seg_idx = search_idx + 1;
                                            break;
                                        }
                                    }
                                }
                            }

                            // Process non-hierarchical loops for grandchild (e.g., claims)
                            for (grandchild_level.non_hierarchical_loops) |loop| {
                                try processNonHierarchicalLoop(grandchild_obj, &loop, grandchild_segments, grandchild_seg_idx, document, allocator);
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
fn processNonHierarchicalLoop(
    parent_obj: *JsonObject,
    loop: *const schema_mod.NonHierarchicalLoop,
    segments: []const x12_parser.Segment,
    start_idx: usize,
    document: *const X12Document,
    allocator: std.mem.Allocator,
) !void {
    std.log.debug("Processing non-hierarchical loop: {s}, trigger: {s}, starting from index {d}", .{ loop.name, loop.trigger, start_idx });

    var seg_idx = start_idx;

    // Find all instances of this loop (triggered by trigger segment)
    while (seg_idx < segments.len) {
        const segment = &segments[seg_idx];

        // Check if this segment triggers the loop
        if (std.mem.eql(u8, segment.id, loop.trigger)) {
            std.log.debug("Found loop trigger '{s}' at index {d}", .{ loop.trigger, seg_idx });
            // Create object for this loop instance
            var loop_obj = JsonObject.init(allocator);

            // Process segments for this loop instance
            var max_idx = seg_idx; // Track the furthest position we've processed
            std.log.debug("Processing segments for loop instance, starting from index {d}", .{seg_idx});
            for (loop.segments) |seg_def| {
                std.log.debug("Looking for segment: {s} (multiple: {}, optional: {})", .{ seg_def.id, seg_def.multiple, seg_def.optional });
                // Find matching segment(s) starting from loop start position
                // This allows segments to appear in any order in the X12 file
                var search_idx = seg_idx;
                var found_any = false;
                while (search_idx < segments.len) : (search_idx += 1) {
                    const inner_seg = &segments[search_idx];

                    // Stop if we hit the next loop trigger (next instance of this loop)
                    if (search_idx > seg_idx and std.mem.eql(u8, inner_seg.id, loop.trigger)) {
                        break;
                    }

                    // Stop if we hit a hierarchical segment (HL) - that's definitely a boundary
                    if (std.mem.eql(u8, inner_seg.id, "HL")) {
                        break;
                    }

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
                            std.log.debug("Found matching segment '{s}' at index {d}", .{ seg_def.id, search_idx });
                            try processSegmentIntoObject(&loop_obj, inner_seg, &seg_def, segments, search_idx, allocator);
                            found_any = true;
                            // Track furthest position
                            if (search_idx >= max_idx) {
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

            // Process nested loops if any
            // Start nested loops from the loop trigger position, not from max_idx
            // This allows nested loops to find segments that may have been interspersed with parent loop segments
            for (loop.nested_loops) |nested_loop| {
                try processNonHierarchicalLoop(&loop_obj, &nested_loop, segments, seg_idx, document, allocator);
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
            seg_idx = max_idx;
        } else {
            seg_idx += 1;
        }
    }
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

/// Process segment with path prefix
fn processSegmentWithPrefix(
    builder: *JsonBuilder,
    segment: *const x12_parser.Segment,
    seg_def: *const schema_mod.SegmentDef,
    document: *const X12Document,
    prefix: []const u8,
    allocator: std.mem.Allocator,
) !void {
    for (seg_def.elements) |elem_def| {
        // Build full path with prefix
        const full_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, elem_def.path });
        defer allocator.free(full_path);

        try processElementWithPath(builder, segment, &elem_def, document, full_path, allocator);
    }
}

/// Process segment elements into an existing object
fn processSegmentIntoObject(
    obj: *JsonObject,
    segment: *const x12_parser.Segment,
    seg_def: *const schema_mod.SegmentDef,
    segments: []const x12_parser.Segment,
    segment_idx: usize,
    allocator: std.mem.Allocator,
) !void {
    std.log.debug("processSegmentIntoObject: segment '{s}', has {d} elements, repeating_elements: {}", .{ segment.id, seg_def.elements.len, seg_def.repeating_elements != null });

    // Process elements from current segment
    for (seg_def.elements) |elem_def| {
        // Skip if element specifies a different segment
        if (elem_def.seg) |seg_id| {
            if (!std.mem.eql(u8, seg_id, segment.id)) {
                continue;
            }
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

            // Add to object at the path (just last part)
            var path_parts = std.mem.splitScalar(u8, elem_def.path, '.');
            var last_part: []const u8 = elem_def.path;
            while (path_parts.next()) |part| {
                if (path_parts.rest().len == 0) {
                    last_part = part;
                }
            }

            try obj.put(last_part, JsonValue{ .string = owned });
        }
    }

    // Process repeating elements if configured
    if (seg_def.repeating_elements) |rep_config| {
        std.log.debug("Processing repeating elements with separator '{s}', {d} patterns", .{ rep_config.separator, rep_config.patterns.len });
        try processRepeatingElements(obj, segment, &rep_config, allocator);
    }

    // If this segment has a group, look for the group segments and process them too
    if (seg_def.group) |group| {
        // Process subsequent segments that are part of the group
        var search_idx = segment_idx + 1;
        for (group[1..]) |group_seg_id| { // Skip first as it's the current segment
            // Search for this segment starting from current position
            var found = false;
            while (search_idx < segments.len) : (search_idx += 1) {
                const group_segment = &segments[search_idx];

                // Check if this is the segment we're looking for
                if (std.mem.eql(u8, group_segment.id, group_seg_id)) {
                    // Process elements from this group segment
                    for (seg_def.elements) |elem_def| {
                        if (elem_def.seg) |seg_id| {
                            if (std.mem.eql(u8, seg_id, group_seg_id)) {
                                // Add 1 to pos to skip segment ID at position 0
                                if (group_segment.getElement(elem_def.pos + 1)) |raw_value| {
                                    var value = raw_value;
                                    if (elem_def.map) |map| {
                                        if (map.get(value)) |mapped| {
                                            value = mapped;
                                        }
                                    }
                                    const owned = try allocator.dupe(u8, value);
                                    var path_parts = std.mem.splitScalar(u8, elem_def.path, '.');
                                    var last_part: []const u8 = elem_def.path;
                                    while (path_parts.next()) |part| {
                                        if (path_parts.rest().len == 0) {
                                            last_part = part;
                                        }
                                    }
                                    try obj.put(last_part, JsonValue{ .string = owned });
                                }
                            }
                        }
                    }
                    search_idx += 1;
                    found = true;
                    break; // Found and processed, move to next group segment
                }

                // Stop searching if we hit a segment that indicates the group has ended
                // (another segment with the same ID as our trigger, or a structural segment)
                if (std.mem.eql(u8, group_segment.id, segment.id) or
                    std.mem.eql(u8, group_segment.id, "HL") or
                    std.mem.eql(u8, group_segment.id, "CLM") or
                    std.mem.eql(u8, group_segment.id, "SBR"))
                {
                    break; // Stop searching for this group segment
                }
            }

            // If we didn't find the segment, stop looking for the rest of the group
            if (!found) break;
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

/// Process element with custom path
fn processElementWithPath(
    builder: *JsonBuilder,
    segment: *const x12_parser.Segment,
    elem_def: *const schema_mod.ElementMapping,
    document: *const X12Document,
    path: []const u8,
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
        const owned = try allocator.dupe(u8, value);

        // Set in builder with custom path
        try builder.set(path, JsonValue{ .string = owned });
    }
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "process simple X12 document" {
    const allocator = testing.allocator;

    const file = try std.fs.cwd().openFile("samples/simple_test.x12", .{ .mode = .read_only });
    defer file.close();
    // Process document
    var output = try processDocument(allocator, file, "schema/837p.json");
    defer output.deinit(allocator);

    // Check output contains expected fields
    const json = output.items;
    try testing.expect(std.mem.indexOf(u8, json, "interchange") != null);
    try testing.expect(std.mem.indexOf(u8, json, "functional_group") != null);
    try testing.expect(std.mem.indexOf(u8, json, "transaction_set") != null);
}

test "process document with HL hierarchy" {
    const allocator = testing.allocator;
    const x12_file = try std.fs.cwd().openFile(
        "samples/837p_example.x12",
        .{
            .mode = .read_only,
        },
    );
    defer x12_file.close();
    // Use existing sample file
    var output = try processDocument(allocator, x12_file, "schema/837p.json");
    defer output.deinit(allocator);

    // Check output contains hierarchical structure
    const json = output.items;
    try testing.expect(std.mem.indexOf(u8, json, "billing_providers") != null);
}
