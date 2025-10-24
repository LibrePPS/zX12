const std = @import("std");
const testing = std.testing;

/// Element mapping from X12 segment to JSON output
pub const ElementMapping = struct {
    seg: ?[]const u8 = null, // Segment ID (for grouped segments), null means current segment
    pos: usize, // Element position (0-based)
    path: []const u8, // JSON output path
    expect: ?[]const u8 = null, // Expected value (for validation)
    map: ?std.StringHashMap([]const u8) = null, // Value mapping
    transform: ?[]const []const u8 = null, // Transformations to apply
    optional: bool = false, // Whether element is optional
    composite: ?[]usize = null, // Composite sub-component indices to extract
    allocator: ?std.mem.Allocator = null, // Allocator for cleanup

    pub fn deinit(self: *ElementMapping) void {
        if (self.map) |*m| {
            m.deinit();
        }
        if (self.transform) |trans| {
            if (self.allocator) |alloc| {
                alloc.free(trans);
            }
        }
        if (self.composite) |comp| {
            if (self.allocator) |alloc| {
                alloc.free(comp);
            }
        }
    }
};

/// Repeating element field definition
pub const RepeatingElementField = struct {
    component: usize, // Component index within composite element
    name: []const u8, // Field name in output
};

/// Repeating element pattern definition
pub const RepeatingElementPattern = struct {
    when_qualifier: []const []const u8, // Qualifiers to match
    output_array: []const u8, // Array name in output
    fields: []RepeatingElementField, // Fields to extract
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RepeatingElementPattern) void {
        for (self.when_qualifier) |qual| {
            self.allocator.free(qual);
        }
        self.allocator.free(self.when_qualifier);
        self.allocator.free(self.fields);
    }
};

/// Repeating elements configuration
pub const RepeatingElements = struct {
    all: bool, // Whether to process all elements
    separator: []const u8, // Composite element separator
    patterns: []RepeatingElementPattern, // Patterns to match
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RepeatingElements) void {
        for (self.patterns) |*pattern| {
            pattern.deinit();
        }
        self.allocator.free(self.patterns);
    }
};

/// Segment definition in schema
pub const SegmentDef = struct {
    id: []const u8, // Segment ID (e.g., "NM1", "CLM")
    qualifier: ?[]const []const u8 = null, // Qualifier check [pos, value]
    group: ?[]const []const u8 = null, // Grouped segments
    elements: []ElementMapping, // Element mappings
    repeating_elements: ?RepeatingElements = null, // Repeating composite elements
    optional: bool = false, // Whether segment is optional
    multiple: bool = false, // Whether segment can appear multiple times
    max_use: ?usize = null, // Maximum times segment can appear
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SegmentDef) void {
        for (self.elements) |*elem| {
            elem.deinit();
        }
        if (self.elements.len > 0) {
            self.allocator.free(self.elements);
        }
        if (self.qualifier) |q| {
            for (q) |qual_str| {
                self.allocator.free(qual_str);
            }
            self.allocator.free(q);
        }
        if (self.group) |g| {
            self.allocator.free(g);
        }
        if (self.repeating_elements) |*rep| {
            var rep_mut = rep.*;
            rep_mut.deinit();
        }
    }
};

/// Non-hierarchical loop (repeating section within an HL level)
pub const NonHierarchicalLoop = struct {
    name: []const u8,
    trigger: []const u8, // Segment that triggers this loop
    output_array: []const u8,
    segments: []SegmentDef,
    nested_loops: []NonHierarchicalLoop = &[_]NonHierarchicalLoop{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *NonHierarchicalLoop) void {
        for (self.segments) |*seg| {
            seg.deinit();
        }
        self.allocator.free(self.segments);
        for (self.nested_loops) |*loop| {
            loop.deinit();
        }
        if (self.nested_loops.len > 0) {
            self.allocator.free(self.nested_loops);
        }
    }
};

/// HL level definition
pub const HLLevel = struct {
    code: []const u8, // Level code (e.g., "20", "22", "23")
    name: []const u8, // Human-readable name
    output_array: ?[]const u8 = null, // Output array name
    segments: []SegmentDef, // Segment definitions
    child_levels: ?[]const []const u8 = null, // Valid child level codes
    non_hierarchical_loops: []NonHierarchicalLoop = &[_]NonHierarchicalLoop{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HLLevel) void {
        for (self.segments) |*seg| {
            seg.deinit();
        }
        self.allocator.free(self.segments);
        if (self.child_levels) |levels| {
            self.allocator.free(levels);
        }
        for (self.non_hierarchical_loops) |*loop| {
            loop.deinit();
        }
        if (self.non_hierarchical_loops.len > 0) {
            self.allocator.free(self.non_hierarchical_loops);
        }
    }
};

/// Sequential section definition
pub const SequentialSection = struct {
    name: []const u8,
    output_path: []const u8,
    segments: []SegmentDef,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SequentialSection) void {
        for (self.segments) |*seg| {
            seg.deinit();
        }
        self.allocator.free(self.segments);
    }
};

/// Schema for an X12 transaction
pub const Schema = struct {
    version: []const u8, // Schema version (e.g., "2.0")
    transaction_id: []const u8, // Transaction ID (e.g., "837P", "837I")
    transaction_version: []const u8, // X12 version (e.g., "005010X222A1")
    transaction_type: []const u8, // Transaction type (e.g., "837")
    description: []const u8, // Description

    // Section definitions
    header_segments: []SegmentDef,
    sequential_sections: []SequentialSection,
    hl_levels: std.StringHashMap(HLLevel),
    trailer_segments: []SegmentDef,

    hierarchical_output_array: []const u8, // Top-level array name

    allocator: std.mem.Allocator,

    // Internal: Keep JSON content alive for string references
    _json_content: []const u8,
    _json_parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Schema) void {
        for (self.header_segments) |*seg| {
            seg.deinit();
        }
        self.allocator.free(self.header_segments);

        for (self.sequential_sections) |*section| {
            section.deinit();
        }
        self.allocator.free(self.sequential_sections);

        var iter = self.hl_levels.valueIterator();
        while (iter.next()) |level| {
            var lvl = level.*;
            lvl.deinit();
        }
        self.hl_levels.deinit();

        for (self.trailer_segments) |*seg| {
            seg.deinit();
        }
        self.allocator.free(self.trailer_segments);

        // Free JSON content
        self._json_parsed.deinit();
        self.allocator.free(self._json_content);
    }

    /// Get HL level definition by code
    pub fn getLevel(self: *const Schema, level_code: []const u8) ?*const HLLevel {
        return self.hl_levels.getPtr(level_code);
    }

    /// Find segment definition in a level
    pub fn findSegmentInLevel(self: *const Schema, level_code: []const u8, segment_id: []const u8) ?*const SegmentDef {
        const level = self.getLevel(level_code) orelse return null;
        for (level.segments) |*seg| {
            if (std.mem.eql(u8, seg.id, segment_id)) {
                return seg;
            }
        }
        return null;
    }
};

/// Load schema from JSON file
pub fn loadSchema(allocator: std.mem.Allocator, file_path: []const u8) !Schema {
    // Read file
    const content = try std.fs.cwd().readFileAlloc(file_path, allocator, @enumFromInt(10 * 1024 * 1024)); // 10MB max
    // Don't free content - we need it for string references
    // It will be kept alive during schema lifetime

    // Parse JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    // Don't defer parsed.deinit() - keep it alive with the schema

    const root = parsed.value.object; // Extract transaction info
    const transaction = root.get("transaction").?.object;
    const schema_version = root.get("schema_version").?.string;
    const transaction_id = transaction.get("id").?.string;
    const transaction_version = transaction.get("version").?.string;
    const transaction_type = transaction.get("type").?.string;
    const description = transaction.get("description").?.string;

    // Parse header segments
    const header_obj = root.get("transaction_header").?.object;
    const header_segments_json = header_obj.get("segments").?.array;
    const header_segments = try parseSegments(allocator, header_segments_json.items);
    errdefer {
        for (header_segments) |*seg| {
            seg.deinit();
        }
        allocator.free(header_segments);
    }

    // Parse sequential sections
    var sequential_sections: []SequentialSection = &[_]SequentialSection{};
    if (root.get("sequential_sections")) |seq_array| {
        const sections_json = seq_array.array.items;
        sequential_sections = try allocator.alloc(SequentialSection, sections_json.len);
        errdefer allocator.free(sequential_sections);

        for (sections_json, 0..) |section_value, i| {
            const section_obj = section_value.object;
            const name = section_obj.get("name").?.string;
            const output_path = section_obj.get("output_path").?.string;
            const segments_json = section_obj.get("segments").?.array.items;
            const segments = try parseSegments(allocator, segments_json);

            sequential_sections[i] = SequentialSection{
                .name = name,
                .output_path = output_path,
                .segments = segments,
                .allocator = allocator,
            };
        }
    }
    errdefer {
        for (sequential_sections) |*section| {
            section.deinit();
        }
        allocator.free(sequential_sections);
    }

    // Parse hierarchical structure
    const hier_obj = root.get("hierarchical_structure").?.object;
    const hier_output_array = hier_obj.get("output_array").?.string;
    const levels_obj = hier_obj.get("levels").?.object;

    var hl_levels = std.StringHashMap(HLLevel).init(allocator);
    errdefer {
        var iter = hl_levels.valueIterator();
        while (iter.next()) |level| {
            var lvl = level.*;
            lvl.deinit();
        }
        hl_levels.deinit();
    }

    var levels_iter = levels_obj.iterator();
    while (levels_iter.next()) |entry| {
        const level_code = entry.key_ptr.*;
        const level_obj = entry.value_ptr.*.object;

        const level = try parseHLLevel(allocator, level_code, level_obj);
        try hl_levels.put(level_code, level);
    }

    // Parse trailer segments
    const trailer_obj = root.get("transaction_trailer").?.object;
    const trailer_segments_json = trailer_obj.get("segments").?.array;
    const trailer_segments = try parseSegments(allocator, trailer_segments_json.items);
    errdefer {
        for (trailer_segments) |*seg| {
            seg.deinit();
        }
        allocator.free(trailer_segments);
    }

    return Schema{
        .version = schema_version,
        .transaction_id = transaction_id,
        .transaction_version = transaction_version,
        .transaction_type = transaction_type,
        .description = description,
        .header_segments = header_segments,
        .sequential_sections = sequential_sections,
        .hl_levels = hl_levels,
        .trailer_segments = trailer_segments,
        .hierarchical_output_array = hier_output_array,
        .allocator = allocator,
        ._json_content = content,
        ._json_parsed = parsed,
    };
}

/// Parse HL level from JSON
fn parseHLLevel(allocator: std.mem.Allocator, level_code: []const u8, level_obj: std.json.ObjectMap) !HLLevel {
    const name = level_obj.get("name").?.string;
    const output_array = if (level_obj.get("output_array")) |arr| arr.string else null;
    const segments_json = level_obj.get("segments").?.array;

    const segments = try parseSegments(allocator, segments_json.items);
    errdefer {
        for (segments) |*seg| {
            seg.deinit();
        }
        allocator.free(segments);
    }

    var child_levels: ?[]const []const u8 = null;
    if (level_obj.get("child_levels")) |child_arr| {
        const children_json = child_arr.array;
        const children = try allocator.alloc([]const u8, children_json.items.len);
        for (children_json.items, 0..) |item, i| {
            children[i] = item.string;
        }
        child_levels = children;
    }

    // Parse non-hierarchical loops if present
    var non_hierarchical_loops: []NonHierarchicalLoop = &[_]NonHierarchicalLoop{};
    if (level_obj.get("non_hierarchical_loops")) |loops_arr| {
        const loops_json = loops_arr.array;
        const loops = try allocator.alloc(NonHierarchicalLoop, loops_json.items.len);
        errdefer allocator.free(loops);

        for (loops_json.items, 0..) |loop_value, i| {
            loops[i] = try parseNonHierarchicalLoop(allocator, loop_value.object);
        }
        non_hierarchical_loops = loops;
    }

    return HLLevel{
        .code = level_code,
        .name = name,
        .output_array = output_array,
        .segments = segments,
        .child_levels = child_levels,
        .non_hierarchical_loops = non_hierarchical_loops,
        .allocator = allocator,
    };
}

/// Parse non-hierarchical loop from JSON
fn parseNonHierarchicalLoop(allocator: std.mem.Allocator, loop_obj: std.json.ObjectMap) !NonHierarchicalLoop {
    const name = loop_obj.get("name").?.string;
    const trigger = loop_obj.get("trigger").?.string;
    const output_array = loop_obj.get("output_array").?.string;
    const segments_json = loop_obj.get("segments").?.array;

    const segments = try parseSegments(allocator, segments_json.items);
    errdefer {
        for (segments) |*seg| {
            seg.deinit();
        }
        allocator.free(segments);
    }

    // Parse nested loops if present
    var nested_loops: []NonHierarchicalLoop = &[_]NonHierarchicalLoop{};
    if (loop_obj.get("nested_loops")) |nested_arr| {
        const nested_json = nested_arr.array;
        const nested = try allocator.alloc(NonHierarchicalLoop, nested_json.items.len);
        errdefer allocator.free(nested);

        for (nested_json.items, 0..) |nested_value, i| {
            nested[i] = try parseNonHierarchicalLoop(allocator, nested_value.object);
        }
        nested_loops = nested;
    }

    return NonHierarchicalLoop{
        .name = name,
        .trigger = trigger,
        .output_array = output_array,
        .segments = segments,
        .nested_loops = nested_loops,
        .allocator = allocator,
    };
}

/// Parse segments array from JSON
fn parseSegments(allocator: std.mem.Allocator, segments_json: []const std.json.Value) ![]SegmentDef {
    const segments = try allocator.alloc(SegmentDef, segments_json.len);
    errdefer allocator.free(segments);

    for (segments_json, 0..) |seg_value, i| {
        const seg_obj = seg_value.object;
        segments[i] = try parseSegment(allocator, seg_obj);
    }

    return segments;
}

/// Parse single segment from JSON
fn parseSegment(allocator: std.mem.Allocator, seg_obj: std.json.ObjectMap) !SegmentDef {
    const id = seg_obj.get("id").?.string;
    const optional = if (seg_obj.get("optional")) |opt| opt.bool else false;
    const multiple = if (seg_obj.get("multiple")) |mult| mult.bool else false;

    // Parse qualifier
    var qualifier: ?[]const []const u8 = null;
    if (seg_obj.get("qualifier")) |qual_arr| {
        const qual_items = qual_arr.array.items;
        const qual = try allocator.alloc([]const u8, qual_items.len);
        errdefer allocator.free(qual);
        for (qual_items, 0..) |item, i| {
            qual[i] = switch (item) {
                .string => |s| try allocator.dupe(u8, s), // Duplicate to own the memory
                .integer => |int| try std.fmt.allocPrint(allocator, "{d}", .{int}),
                else => try allocator.dupe(u8, ""),
            };
        }
        qualifier = qual;
    }

    // Parse group
    var group: ?[]const []const u8 = null;
    if (seg_obj.get("group")) |grp_arr| {
        const grp_items = grp_arr.array.items;
        const grp = try allocator.alloc([]const u8, grp_items.len);
        for (grp_items, 0..) |item, i| {
            grp[i] = item.string;
        }
        group = grp;
    }

    // Parse elements (optional)
    var elements: []ElementMapping = &[_]ElementMapping{};
    if (seg_obj.get("elements")) |elem_arr| {
        const elements_json = elem_arr.array.items;
        const elems = try allocator.alloc(ElementMapping, elements_json.len);
        errdefer allocator.free(elems);

        for (elements_json, 0..) |elem_value, i| {
            const elem_obj = elem_value.object;
            elems[i] = try parseElement(allocator, elem_obj);
        }
        elements = elems;
    }

    // Parse repeating_elements (optional)
    var repeating_elements: ?RepeatingElements = null;
    if (seg_obj.get("repeating_elements")) |rep_obj| {
        repeating_elements = try parseRepeatingElements(allocator, rep_obj.object);
    }

    return SegmentDef{
        .id = id,
        .qualifier = qualifier,
        .group = group,
        .elements = elements,
        .repeating_elements = repeating_elements,
        .optional = optional,
        .multiple = multiple,
        .allocator = allocator,
    };
}

/// Parse element mapping from JSON
fn parseElement(allocator: std.mem.Allocator, elem_obj: std.json.ObjectMap) !ElementMapping {
    const seg = if (elem_obj.get("seg")) |s| s.string else null;
    const pos = switch (elem_obj.get("pos").?) {
        .integer => |i| @as(usize, @intCast(i)),
        else => 0,
    };
    const path = if (elem_obj.get("path") != null) elem_obj.get("path").?.string else "";
    const expect = if (elem_obj.get("expect")) |e| e.string else null;
    const optional = if (elem_obj.get("optional")) |o| o.bool else false;

    // Parse value mapping
    var map: ?std.StringHashMap([]const u8) = null;
    if (elem_obj.get("map")) |map_obj| {
        var hash_map = std.StringHashMap([]const u8).init(allocator);
        var map_iter = map_obj.object.iterator();
        while (map_iter.next()) |entry| {
            try hash_map.put(entry.key_ptr.*, entry.value_ptr.*.string);
        }
        map = hash_map;
    }

    // Parse transforms
    var transform: ?[]const []const u8 = null;
    if (elem_obj.get("transform")) |trans_arr| {
        const trans_items = trans_arr.array.items;
        const trans = try allocator.alloc([]const u8, trans_items.len);
        for (trans_items, 0..) |item, i| {
            trans[i] = item.string;
        }
        transform = trans;
    }

    // Parse composite sub-component indices
    var composite: ?[]usize = null;
    if (elem_obj.get("composite")) |comp_arr| {
        const comp_items = comp_arr.array.items;
        const comp = try allocator.alloc(usize, comp_items.len);
        for (comp_items, 0..) |item, i| {
            comp[i] = @intCast(item.integer);
        }
        composite = comp;
    }

    return ElementMapping{
        .seg = seg,
        .pos = pos,
        .path = path,
        .expect = expect,
        .map = map,
        .transform = transform,
        .optional = optional,
        .composite = composite,
        .allocator = allocator,
    };
}

/// Parse repeating elements configuration from JSON
fn parseRepeatingElements(allocator: std.mem.Allocator, rep_obj: std.json.ObjectMap) !RepeatingElements {
    const all = if (rep_obj.get("all")) |a| a.bool else false;
    const separator = rep_obj.get("separator").?.string;
    const patterns_json = rep_obj.get("patterns").?.array.items;

    const patterns = try allocator.alloc(RepeatingElementPattern, patterns_json.len);
    errdefer allocator.free(patterns);

    for (patterns_json, 0..) |pattern_value, i| {
        patterns[i] = try parseRepeatingElementPattern(allocator, pattern_value.object);
    }

    return RepeatingElements{
        .all = all,
        .separator = separator,
        .patterns = patterns,
        .allocator = allocator,
    };
}

/// Parse repeating element pattern from JSON
fn parseRepeatingElementPattern(allocator: std.mem.Allocator, pattern_obj: std.json.ObjectMap) !RepeatingElementPattern {
    const when_qualifier_json = pattern_obj.get("when_qualifier").?.array.items;
    const output_array = pattern_obj.get("output_array").?.string;
    const fields_json = pattern_obj.get("fields").?.array.items;

    // Parse qualifiers
    const when_qualifier = try allocator.alloc([]const u8, when_qualifier_json.len);
    errdefer allocator.free(when_qualifier);
    for (when_qualifier_json, 0..) |qual_value, i| {
        when_qualifier[i] = try allocator.dupe(u8, qual_value.string);
    }

    // Parse fields
    const fields = try allocator.alloc(RepeatingElementField, fields_json.len);
    errdefer allocator.free(fields);
    for (fields_json, 0..) |field_value, i| {
        const field_obj = field_value.object;
        const component = switch (field_obj.get("component").?) {
            .integer => |comp| @as(usize, @intCast(comp)),
            else => 0,
        };
        const name = field_obj.get("name").?.string;

        fields[i] = RepeatingElementField{
            .component = component,
            .name = name,
        };
    }

    return RepeatingElementPattern{
        .when_qualifier = when_qualifier,
        .output_array = output_array,
        .fields = fields,
        .allocator = allocator,
    };
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "load 837P schema" {
    const allocator = testing.allocator;

    var schema = try loadSchema(allocator, "schema/837p.json");
    defer schema.deinit();

    try testing.expectEqualStrings("2.0", schema.version);
    try testing.expectEqualStrings("837P", schema.transaction_id);
    try testing.expectEqualStrings("005010X222A1", schema.transaction_version);
    try testing.expectEqualStrings("837", schema.transaction_type);
    try testing.expectEqualStrings("billing_providers", schema.hierarchical_output_array);

    // Check header segments
    try testing.expect(schema.header_segments.len > 0);
    try testing.expectEqualStrings("ISA", schema.header_segments[0].id);

    // Check trailer segments
    try testing.expect(schema.trailer_segments.len > 0);
}

test "get HL level from schema" {
    const allocator = testing.allocator;

    var schema = try loadSchema(allocator, "schema/837p.json");
    defer schema.deinit();

    const level20 = schema.getLevel("20");
    try testing.expect(level20 != null);
    try testing.expectEqualStrings("Billing Provider", level20.?.name);
    try testing.expectEqualStrings("20", level20.?.code);

    const level22 = schema.getLevel("22");
    try testing.expect(level22 != null);
    try testing.expectEqualStrings("Subscriber", level22.?.name);
    try testing.expectEqualStrings("subscribers", level22.?.output_array.?);

    const level99 = schema.getLevel("99");
    try testing.expect(level99 == null);
}

test "find segment in level" {
    const allocator = testing.allocator;

    var schema = try loadSchema(allocator, "schema/837p.json");
    defer schema.deinit();

    const hl_seg = schema.findSegmentInLevel("20", "HL");
    try testing.expect(hl_seg != null);
    try testing.expectEqualStrings("HL", hl_seg.?.id);

    const nm1_seg = schema.findSegmentInLevel("22", "NM1");
    try testing.expect(nm1_seg != null);
    try testing.expectEqualStrings("NM1", nm1_seg.?.id);

    const missing = schema.findSegmentInLevel("20", "INVALID");
    try testing.expect(missing == null);
}

test "check segment qualifiers and groups" {
    const allocator = testing.allocator;

    var schema = try loadSchema(allocator, "schema/837p.json");
    defer schema.deinit();

    const level20 = schema.getLevel("20").?;

    // Find NM1*85 segment
    var found_nm1 = false;
    for (level20.segments) |*seg| {
        if (std.mem.eql(u8, seg.id, "NM1")) {
            if (seg.qualifier) |qual| {
                if (qual.len == 2) {
                    try testing.expectEqualStrings("0", qual[0]);
                    try testing.expectEqualStrings("85", qual[1]);
                    found_nm1 = true;
                }
            }

            // Check group
            if (seg.group) |grp| {
                try testing.expect(grp.len > 0);
                try testing.expectEqualStrings("NM1", grp[0]);
            }
        }
    }

    try testing.expect(found_nm1);
}

test "check element mappings" {
    const allocator = testing.allocator;

    var schema = try loadSchema(allocator, "schema/837p.json");
    defer schema.deinit();

    // Check ISA element mapping
    const isa_seg = &schema.header_segments[0];
    try testing.expectEqualStrings("ISA", isa_seg.id);
    try testing.expect(isa_seg.elements.len > 0);

    // Check first element (ISA01)
    const isa01 = isa_seg.elements[0];
    try testing.expectEqual(@as(usize, 0), isa01.pos);
    try testing.expectEqualStrings("interchange.auth_info_qualifier", isa01.path);
    try testing.expectEqualStrings("00", isa01.expect.?);
}

test "check value mappings" {
    const allocator = testing.allocator;

    var schema = try loadSchema(allocator, "schema/837p.json");
    defer schema.deinit();

    const level22 = schema.getLevel("22").?;

    // Find SBR segment
    for (level22.segments) |*seg| {
        if (std.mem.eql(u8, seg.id, "SBR")) {
            // Find payer_responsibility element
            for (seg.elements) |elem| {
                if (std.mem.eql(u8, elem.path, "payer_responsibility")) {
                    try testing.expect(elem.map != null);
                    const mapped = elem.map.?.get("P");
                    try testing.expect(mapped != null);
                    try testing.expectEqualStrings("primary", mapped.?);
                    break;
                }
            }
            break;
        }
    }
}

test "load 837I schema" {
    const allocator = testing.allocator;

    var schema = try loadSchema(allocator, "schema/837i.json");
    defer schema.deinit();

    try testing.expectEqualStrings("2.0", schema.version);
    try testing.expectEqualStrings("837I", schema.transaction_id);
    try testing.expectEqualStrings("005010X223A2", schema.transaction_version);
}
