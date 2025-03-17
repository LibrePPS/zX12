const std = @import("std");
const Allocator = std.mem.Allocator;
const x12 = @import("parser.zig");
const utils = @import("utils.zig");
comptime {
    _ = @import("test_schema_parser.zig");
}

/// Result type that holds both the parsed data and the arena that owns all allocations
pub const ParseResult = struct {
    value: std.json.Value,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

/// Errors that can occur during schema parsing
pub const SchemaError = error{
    InvalidSchema,
    InvalidPath,
    MissingRequiredField,
    UnsupportedTransform,
    ParseError,
};

pub const ParserError = error{
    LoopError,
};

/// Error type specifically for JSON parsing issues
pub const JsonError = error{
    FieldMissing,
    TypeMismatch,
};

/// Generic function to get a typed value from a JSON object
/// T is the return type (bool, []const u8, usize, etc.)
/// alloc parameter is only used when T is []const u8
pub fn getJsonValue(comptime T: type, obj: std.json.ObjectMap, key: []const u8, allocator: Allocator, default_value: ?T) !T {
    // Try to get the value from the JSON object
    const value_ptr = obj.get(key) orelse {
        if (default_value != null) {
            return default_value.?;
        }
        return JsonError.FieldMissing;
    };

    // Handle different return types with comptime branching
    switch (@typeInfo(T)) {
        .bool => {
            // Bool type
            if (value_ptr.* != .bool) {
                return JsonError.TypeMismatch;
            }
            return value_ptr.bool;
        },
        .int => {
            // Integer type
            switch (value_ptr.*) {
                .integer => return @intCast(value_ptr.integer),
                .float => return @intFromFloat(value_ptr.float),
                else => return JsonError.TypeMismatch,
            }
        },
        .float => {
            // Float type
            switch (value_ptr.*) {
                .integer => return @floatFromInt(value_ptr.integer),
                .float => return value_ptr.float,
                else => return JsonError.TypeMismatch,
            }
        },
        .pointer => |ptr_info| {
            if (ptr_info.child == u8) {
                // String ([]const u8) type
                if (value_ptr != .string) {
                    return JsonError.TypeMismatch;
                }
                return try allocator.dupe(u8, value_ptr.string);
            } else {
                @compileError("Unsupported pointer type");
            }
        },
        .optional => |opt_info| {
            // For optional types, recursively call with the child type
            // but return null instead of FieldMissing error
            if (obj.get(key) == null) {
                return null;
            }

            // Forward to the underlying type handler
            return try getJsonValue(opt_info.child, obj, key, allocator, null);
        },
        else => @compileError("Unsupported type"),
    }
}

/// The root Schema struct that represents an entire X12 transaction definition
pub const Schema = struct {
    id: []const u8, // e.g. "837P"
    description: []const u8,
    version: []const u8, // e.g. "005010X222A1"
    transaction_type: []const u8, // e.g. "837"
    header: Header,
    loops: std.ArrayList(Loop),
    allocator: Allocator,

    /// Initialize a new empty Schema
    pub fn init(allocator: Allocator) Schema {
        return Schema{
            .id = "",
            .description = "",
            .version = "",
            .transaction_type = "",
            .header = Header.init(allocator),
            .loops = std.ArrayList(Loop).init(allocator),
            .allocator = allocator,
        };
    }

    /// Free all resources
    pub fn deinit(self: *Schema) void {
        self.header.deinit();
        for (self.loops.items) |*loop| {
            loop.deinit();
        }
        self.loops.deinit();

        self.allocator.free(self.id);
        self.allocator.free(self.description);
        self.allocator.free(self.version);
        self.allocator.free(self.transaction_type);
    }

    /// Load a schema from a JSON string
    pub fn fromJson(allocator: Allocator, json_str: []const u8) !Schema {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        return try fromValue(allocator, parsed.value);
    }

    /// Load a schema from a JSON value
    fn fromValue(allocator: Allocator, value: std.json.Value) !Schema {
        var schema = Schema.init(allocator);
        errdefer schema.deinit();

        // Parse basic fields
        const obj = value.object;

        schema.id = try getJsonValue([]const u8, obj, "id", allocator, null);
        schema.description = try getJsonValue([]const u8, obj, "description", allocator, null);
        schema.version = try getJsonValue([]const u8, obj, "version", allocator, null);
        schema.transaction_type = try getJsonValue([]const u8, obj, "transaction_type", allocator, null);

        // Parse header
        schema.header = try Header.fromValue(allocator, obj.get("header").?);

        // Parse loops
        const loops_json = obj.get("loops").?.array;
        for (loops_json.items) |loop_json| {
            const loop = try Loop.fromValue(allocator, loop_json);
            try schema.loops.append(loop);
        }

        return schema;
    }
};

/// Header contains configurations for header segments
pub const Header = struct {
    segments: std.ArrayList(HeaderSegment),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Header {
        return Header{
            .segments = std.ArrayList(HeaderSegment).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Header) void {
        for (self.segments.items) |*segment| {
            segment.deinit();
        }
        self.segments.deinit();
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !Header {
        var header = Header.init(allocator);
        errdefer header.deinit();

        const segments_json = value.object.get("segments").?.array;
        for (segments_json.items) |segment_json| {
            const segment = try HeaderSegment.fromValue(allocator, segment_json);
            try header.segments.append(segment);
        }

        return header;
    }
};

/// HeaderSegment represents a segment in the header (like ISA or ST)
pub const HeaderSegment = struct {
    id: []const u8,
    required: bool,
    elements: std.ArrayList(Element),
    allocator: Allocator,

    pub fn init(allocator: Allocator) HeaderSegment {
        return HeaderSegment{
            .id = "",
            .required = false,
            .elements = std.ArrayList(Element).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HeaderSegment) void {
        self.allocator.free(self.id);
        for (self.elements.items) |*element| {
            element.deinit();
        }
        self.elements.deinit();
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !HeaderSegment {
        var segment = HeaderSegment.init(allocator);
        errdefer segment.deinit();

        const obj = value.object;
        segment.id = try allocator.dupe(u8, obj.get("id").?.string);

        if (obj.get("required")) |required_json| {
            segment.required = required_json.bool;
        }

        if (obj.get("elements")) |elements_json| {
            const elements_array = elements_json.array;
            for (elements_array.items) |element_json| {
                const element = try Element.fromValue(allocator, element_json);
                try segment.elements.append(element);
            }
        }

        return segment;
    }
};

/// Loop represents a logical group of segments (like 2000A)
pub const Loop = struct {
    id: []const u8,
    name: []const u8,
    multiple: bool,
    trigger: Trigger,
    segments: std.ArrayList(Segment),
    loops: std.ArrayList(Loop),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Loop {
        return Loop{
            .id = "",
            .name = "",
            .multiple = false,
            .trigger = Trigger.init(),
            .segments = std.ArrayList(Segment).init(allocator),
            .loops = std.ArrayList(Loop).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Loop) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.trigger.deinit(self.allocator);

        for (self.segments.items) |*segment| {
            segment.deinit();
        }
        self.segments.deinit();

        for (self.loops.items) |*loop| {
            loop.deinit();
        }
        self.loops.deinit();
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !Loop {
        var loop = Loop.init(allocator);
        errdefer loop.deinit();

        const obj = value.object;
        loop.id = try allocator.dupe(u8, obj.get("id").?.string);
        loop.name = try allocator.dupe(u8, obj.get("name").?.string);

        if (obj.get("multiple")) |multiple_json| {
            loop.multiple = multiple_json.bool;
        }

        if (obj.get("trigger")) |trigger_json| {
            loop.trigger = try Trigger.fromValue(allocator, trigger_json);
        }

        if (obj.get("segments")) |segments_json| {
            const segments_array = segments_json.array;
            for (segments_array.items) |segment_json| {
                const segment = try Segment.fromValue(allocator, segment_json);
                try loop.segments.append(segment);
            }
        }

        if (obj.get("loops")) |loops_json| {
            const loops_array = loops_json.array;
            for (loops_array.items) |nested_loop_json| {
                const nested_loop = try Loop.fromValue(allocator, nested_loop_json);
                try loop.loops.append(nested_loop);
            }
        }

        return loop;
    }
};

const Trigger = struct {
    segment_id: []const u8,
    element_position: usize,
    value: ?[]const u8 = null,

    pub fn init() Trigger {
        return Trigger{
            .segment_id = "", // Empty string, not heap allocated
            .element_position = 0,
            .value = null,
        };
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !Trigger {
        const obj = value.object;

        const segment_id = try allocator.dupe(u8, obj.get("segment_id").?.string);
        errdefer allocator.free(segment_id);

        const element_position = @as(usize, @intCast(obj.get("element_position").?.integer));

        var result = Trigger{
            .segment_id = segment_id,
            .element_position = element_position,
            .value = null,
        };

        if (obj.get("value")) |value_json| {
            result.value = try allocator.dupe(u8, value_json.string);
        }

        return result;
    }

    pub fn deinit(self: *Trigger, allocator: Allocator) void {
        allocator.free(self.segment_id);
        if (self.value) |value| {
            allocator.free(value);
        }
    }
};
/// Element represents a data field in an X12 segment
pub const Element = struct {
    position: usize,
    path: ?[]const u8, // Output path where value should be placed (e.g. "billing_provider.name")
    expected_value: ?[]const u8, // Expected value for validation (if any)
    transforms: std.ArrayList([]const u8), // Transformations to apply (e.g. "trim_whitespace")
    value_mappings: std.ArrayList(ValueMapping), // Value mappings for enumerations
    composite: ?CompositeConfig, // Configuration for composite elements
    allocator: Allocator,

    pub fn init(allocator: Allocator) Element {
        return Element{
            .position = 0,
            .path = null,
            .expected_value = null,
            .transforms = std.ArrayList([]const u8).init(allocator),
            .value_mappings = std.ArrayList(ValueMapping).init(allocator),
            .composite = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Element) void {
        if (self.path) |path| {
            self.allocator.free(path);
        }

        if (self.expected_value) |value| {
            self.allocator.free(value);
        }

        for (self.transforms.items) |transform| {
            self.allocator.free(transform);
        }
        self.transforms.deinit();

        for (self.value_mappings.items) |*mapping| {
            mapping.deinit();
        }
        self.value_mappings.deinit();
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !Element {
        var element = Element.init(allocator);
        errdefer element.deinit();

        const obj = value.object;
        element.position = @intCast(obj.get("position").?.integer);

        if (obj.get("path")) |path_json| {
            element.path = try allocator.dupe(u8, path_json.string);
        }

        if (obj.get("expected_value")) |expected_value_json| {
            element.expected_value = try allocator.dupe(u8, expected_value_json.string);
        }

        if (obj.get("transform")) |transform_json| {
            const transform_array = transform_json.array;
            for (transform_array.items) |transform_item| {
                const transform_name = try allocator.dupe(u8, transform_item.string);
                try element.transforms.append(transform_name);
            }
        }

        if (obj.get("value_mappings")) |mappings_json| {
            const mappings_array = mappings_json.array;
            for (mappings_array.items) |mapping_json| {
                const mapping = try ValueMapping.fromValue(allocator, mapping_json);
                try element.value_mappings.append(mapping);
            }
        }

        if (obj.get("composite")) |composite_json| {
            element.composite = try CompositeConfig.fromValue(allocator, composite_json);
        }

        return element;
    }
};

/// ValueMapping maps values from X12 to application-specific values
pub const ValueMapping = struct {
    value: []const u8,
    mapped_value: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ValueMapping {
        return ValueMapping{
            .value = "",
            .mapped_value = "",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ValueMapping) void {
        self.allocator.free(self.value);
        self.allocator.free(self.mapped_value);
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !ValueMapping {
        const obj = value.object;
        return ValueMapping{
            .value = try allocator.dupe(u8, obj.get("value").?.string),
            .mapped_value = try allocator.dupe(u8, obj.get("mapped_value").?.string),
            .allocator = allocator,
        };
    }
};

/// Configuration for parsing composite elements (those with component separator)
pub const CompositeConfig = struct {
    separator: u8,
    index: usize, // Which part to extract
    allocator: ?Allocator,

    pub fn init() CompositeConfig {
        return CompositeConfig{
            .separator = ':',
            .index = 0,
            .allocator = null,
        };
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !CompositeConfig {
        const obj = value.object;

        // Get separator character from string
        const separator_str = obj.get("separator").?.string;
        if (separator_str.len != 1) return SchemaError.InvalidSchema;

        return CompositeConfig{
            .separator = separator_str[0],
            .index = @intCast(obj.get("index").?.integer),
            .allocator = allocator,
        };
    }
};

pub const ElementPattern = struct {
    qualifier_position: usize = 0, // Which component contains the qualifier
    qualifier_values: std.ArrayList([]const u8), // Which qualifiers this pattern applies to
    target_collection: []const u8, // Where to store the results (e.g., "diagnosis_codes")
    component_mappings: std.ArrayList(ComponentMapping),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ElementPattern {
        return ElementPattern{
            .qualifier_position = 0,
            .qualifier_values = std.ArrayList([]const u8).init(allocator),
            .target_collection = "",
            .component_mappings = std.ArrayList(ComponentMapping).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ElementPattern) void {
        // Free the target collection string
        self.allocator.free(self.target_collection);

        for (self.qualifier_values.items) |qualifier| {
            self.allocator.free(qualifier);
        }
        self.qualifier_values.deinit();

        for (self.component_mappings.items) |*mapping| {
            mapping.deinit();
        }
        self.component_mappings.deinit();
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !ElementPattern {
        var pattern = ElementPattern.init(allocator);
        errdefer pattern.deinit();

        const obj = value.object;
        pattern.qualifier_position = @intCast(obj.get("qualifier_position").?.integer);
        pattern.target_collection = try allocator.dupe(u8, obj.get("target_collection").?.string);

        if (obj.get("qualifier_values")) |qualifiers_json| {
            const qualifiers_array = qualifiers_json.array;
            for (qualifiers_array.items) |qualifier_json| {
                const qualifier = try allocator.dupe(u8, qualifier_json.string);
                try pattern.qualifier_values.append(qualifier);
            }
        }

        if (obj.get("component_mappings")) |mappings_json| {
            const mappings_array = mappings_json.array;
            for (mappings_array.items) |mapping_json| {
                const mapping = try ComponentMapping.fromValue(allocator, mapping_json);
                try pattern.component_mappings.append(mapping);
            }
        }

        return pattern;
    }
};

pub const ComponentMapping = struct {
    component_position: usize,
    target_field: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ComponentMapping {
        return ComponentMapping{
            .component_position = 0,
            .target_field = "",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ComponentMapping) void {
        self.allocator.free(self.target_field);
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !ComponentMapping {
        var mapping = ComponentMapping.init(allocator);
        errdefer mapping.deinit();

        const obj = value.object;
        mapping.component_position = @intCast(obj.get("component_position").?.integer);
        mapping.target_field = try allocator.dupe(u8, obj.get("target_field").?.string);

        return mapping;
    }
};

/// Segment represents an X12 segment in the schema
pub const Segment = struct {
    id: []const u8,
    required: bool,
    multiple: bool,
    qualifiers: std.ArrayList(Qualifier),
    elements: std.ArrayList(Element),
    related_segments: std.ArrayList(RelatedSegment),
    composite_elements: std.ArrayList(CompositeElement),
    process_all_elements: bool = false,
    element_patterns: std.ArrayList(ElementPattern),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Segment {
        return Segment{
            .id = "",
            .required = false,
            .multiple = false,
            .qualifiers = std.ArrayList(Qualifier).init(allocator),
            .elements = std.ArrayList(Element).init(allocator),
            .related_segments = std.ArrayList(RelatedSegment).init(allocator),
            .composite_elements = std.ArrayList(CompositeElement).init(allocator),
            .process_all_elements = false,
            .element_patterns = std.ArrayList(ElementPattern).init(allocator),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Segment) void {
        self.allocator.free(self.id);

        for (self.qualifiers.items) |*qualifier| {
            qualifier.deinit();
        }
        self.qualifiers.deinit();

        for (self.elements.items) |*element| {
            element.deinit();
        }
        self.elements.deinit();

        for (self.related_segments.items) |*related| {
            related.deinit();
        }
        self.related_segments.deinit();

        for (self.composite_elements.items) |*composite| {
            composite.deinit();
        }
        self.composite_elements.deinit();

        // Free element patterns
        for (self.element_patterns.items) |*pattern| {
            pattern.deinit();
        }
        self.element_patterns.deinit();
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !Segment {
        var segment = Segment.init(allocator);
        errdefer segment.deinit();

        const obj = value.object;
        segment.id = try allocator.dupe(u8, obj.get("id").?.string);

        // Parse required flag
        if (obj.get("required")) |required_json| {
            segment.required = required_json.bool;
        }

        // Parse multiple flag
        if (obj.get("multiple")) |multiple_json| {
            segment.multiple = multiple_json.bool;
        }

        // Parse qualifiers
        if (obj.get("qualifiers")) |qualifiers_json| {
            const qualifiers_array = qualifiers_json.array;
            for (qualifiers_array.items) |qualifier_json| {
                const qualifier = try Qualifier.fromValue(allocator, qualifier_json);
                try segment.qualifiers.append(qualifier);
            }
        }

        // Parse elements
        if (obj.get("elements")) |elements_json| {
            const elements_array = elements_json.array;
            for (elements_array.items) |element_json| {
                const element = try Element.fromValue(allocator, element_json);
                try segment.elements.append(element);
            }
        }

        // Parse related segments
        if (obj.get("related_segments")) |related_json| {
            const related_array = related_json.array;
            for (related_array.items) |related_segment_json| {
                const related = try RelatedSegment.fromValue(allocator, related_segment_json);
                try segment.related_segments.append(related);
            }
        }

        // Parse composite elements
        if (obj.get("composite_elements")) |composite_json| {
            const composite_array = composite_json.array;
            for (composite_array.items) |composite_element_json| {
                const composite = try CompositeElement.fromValue(allocator, composite_element_json);
                try segment.composite_elements.append(composite);
            }
        }

        // Parse process_all_elements flag
        if (obj.get("process_all_elements")) |process_json| {
            segment.process_all_elements = process_json.bool;
        }

        // Parse element patterns
        if (obj.get("element_patterns")) |patterns_json| {
            const patterns_array = patterns_json.array;
            for (patterns_array.items) |pattern_json| {
                const pattern = try ElementPattern.fromValue(allocator, pattern_json);
                try segment.element_patterns.append(pattern);
            }
        }

        return segment;
    }
};

/// Qualifier specifies conditions for a segment to match
pub const Qualifier = struct {
    position: usize,
    value: []const u8,
    value_prefix: ?[]const u8, // For matching prefix (like "ABK:")
    allocator: Allocator,

    pub fn init(allocator: Allocator) Qualifier {
        return Qualifier{
            .position = 0,
            .value = "",
            .value_prefix = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Qualifier) void {
        self.allocator.free(self.value);
        if (self.value_prefix) |prefix| {
            self.allocator.free(prefix);
        }
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !Qualifier {
        var qualifier = Qualifier.init(allocator);
        errdefer qualifier.deinit();

        const obj = value.object;
        qualifier.position = @intCast(obj.get("position").?.integer);

        if (obj.get("value")) |value_json| {
            qualifier.value = try allocator.dupe(u8, value_json.string);
        }

        if (obj.get("value_prefix")) |prefix_json| {
            qualifier.value_prefix = try allocator.dupe(u8, prefix_json.string);
        }

        return qualifier;
    }
};

/// RelatedSegment defines segments that follow another segment (like N3/N4 following NM1)
pub const RelatedSegment = struct {
    id: []const u8,
    max_distance: usize, // Maximum distance from parent segment
    elements: std.ArrayList(Element),
    allocator: Allocator,

    pub fn init(allocator: Allocator) RelatedSegment {
        return RelatedSegment{
            .id = "",
            .max_distance = 0,
            .elements = std.ArrayList(Element).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RelatedSegment) void {
        self.allocator.free(self.id);

        for (self.elements.items) |*element| {
            element.deinit();
        }
        self.elements.deinit();
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !RelatedSegment {
        var related = RelatedSegment.init(allocator);
        errdefer related.deinit();

        const obj = value.object;
        related.id = try allocator.dupe(u8, obj.get("id").?.string);
        related.max_distance = @intCast(obj.get("max_distance").?.integer);

        if (obj.get("elements")) |elements_json| {
            const elements_array = elements_json.array;
            for (elements_array.items) |element_json| {
                const element = try Element.fromValue(allocator, element_json);
                try related.elements.append(element);
            }
        }

        return related;
    }
};

/// CompositeElement handles parsing elements that have component delimiter
pub const CompositeElement = struct {
    position: usize,
    separator: u8,
    parts: std.ArrayList(CompositePart),
    allocator: Allocator,

    pub fn init(allocator: Allocator) CompositeElement {
        return CompositeElement{
            .position = 0,
            .separator = ':',
            .parts = std.ArrayList(CompositePart).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompositeElement) void {
        for (self.parts.items) |*part| {
            part.deinit();
        }
        self.parts.deinit();
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !CompositeElement {
        var composite = CompositeElement.init(allocator);
        errdefer composite.deinit();

        const obj = value.object;
        composite.position = @intCast(obj.get("position").?.integer);

        // Get separator character from string
        if (obj.get("separator")) |separator_json| {
            const separator_str = separator_json.string;
            if (separator_str.len != 1) return SchemaError.InvalidSchema;
            composite.separator = separator_str[0];
        }

        if (obj.get("parts")) |parts_json| {
            const parts_array = parts_json.array;
            for (parts_array.items) |part_json| {
                const part = try CompositePart.fromValue(allocator, part_json);
                try composite.parts.append(part);
            }
        }

        return composite;
    }
};

/// CompositePart handles individual components of a composite element
pub const CompositePart = struct {
    position: usize,
    path: ?[]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) CompositePart {
        return CompositePart{
            .position = 0,
            .path = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompositePart) void {
        if (self.path) |path| {
            self.allocator.free(path);
        }
    }

    pub fn fromValue(allocator: Allocator, value: std.json.Value) !CompositePart {
        var part = CompositePart.init(allocator);
        errdefer part.deinit();

        const obj = value.object;
        part.position = @intCast(obj.get("position").?.integer);

        if (obj.get("path")) |path_json| {
            part.path = try allocator.dupe(u8, path_json.string);
        }

        return part;
    }
};

/// Context for X12 document parsing
pub const ParseContext = struct {
    allocator: Allocator,
    document: *const x12.X12Document,
    result: *std.json.Value,
    segment_index: usize = 0,
};

pub const LoopRange = struct {
    start: usize,
    end: usize,
};

/// Find segments that match a loop's trigger conditions
fn findLoopTriggers(document: *const x12.X12Document, trigger: *const Trigger, allocator: Allocator) !std.ArrayList(usize) {
    var result = std.ArrayList(usize).init(allocator);
    errdefer result.deinit();

    // Look for segments with the matching ID
    for (document.segments.items, 0..) |segment, i| {
        if (std.mem.eql(u8, segment.id, trigger.segment_id)) {
            // If no value is specified in the trigger, just match on segment ID
            if (trigger.value == null) {
                try result.append(i);
                continue;
            }

            // Otherwise check if the element at the specified position matches the value
            if (trigger.element_position < segment.elements.items.len) {
                const element = &segment.elements.items[trigger.element_position];
                if (std.mem.eql(u8, element.value, trigger.value.?)) {
                    try result.append(i);
                }
            }
        }
    }

    return result;
}

/// Find the range (start and end indices) for a loop's segments
fn findLoopRange(document: *const x12.X12Document, trigger_idx: usize) !LoopRange {
    const start = trigger_idx;
    var end = document.segments.items.len;
    // Look for the next trigger segment (HL or similar) that would start a new loop
    for (document.segments.items[start + 1 ..], start + 1..) |segment, i| {
        if (std.mem.eql(u8, segment.id, "HL") or
            std.mem.eql(u8, segment.id, "ST") or
            std.mem.eql(u8, segment.id, "SE") or
            std.mem.eql(u8, segment.id, "GS") or
            std.mem.eql(u8, segment.id, "GE") or
            std.mem.eql(u8, segment.id, "ISA") or
            std.mem.eql(u8, segment.id, "IEA"))
        {
            end = i;
            break;
        }
    }

    return .{ .start = start, .end = end };
}

/// Process a segment within a loop
fn processLoopSegment(context: *ParseContext, segment_def: Segment, loop_range: LoopRange, loop_obj: *std.json.Value) !void {
    const segment_id = segment_def.id;
    var segments_found = std.ArrayList(*const x12.Segment).init(context.allocator);
    defer segments_found.deinit();

    // Find all matching segments within loop range
    for (context.document.segments.items[loop_range.start..loop_range.end]) |*segment| {
        if (!std.mem.eql(u8, segment.id, segment_id)) continue;
        // Check qualifiers if any
        var qualifier_match = segment_def.qualifiers.items.len == 0;
        for (segment_def.qualifiers.items) |qualifier| {
            if (qualifier.position < segment.elements.items.len) {
                const element = &segment.elements.items[qualifier.position];
                // Check for exact match
                if (std.mem.eql(u8, element.value, qualifier.value)) {
                    qualifier_match = true;
                    break;
                }

                // Check for prefix match if specified
                if (qualifier.value_prefix) |prefix| {
                    if (std.mem.startsWith(u8, element.value, prefix)) {
                        qualifier_match = true;
                        break;
                    }
                }
            }
        }

        if (qualifier_match) {
            try segments_found.append(segment);
        }
    }

    if (segments_found.items.len == 0) {
        if (segment_def.required) {
            return SchemaError.MissingRequiredField;
        }
        return;
    }

    // Special case for segments that use element patterns (like HI) that need to be merged
    if (segment_def.process_all_elements) {
        // For segments that define element patterns (like HI segments with different qualifiers),
        // we want to process all instances and merge them into a single result object

        // Process regular element mappings from the first segment
        try processElementMappings(context.allocator, segments_found.items[0], &segment_def, loop_obj);

        // Process element patterns from all segments - they'll merge into the same arrays
        for (segments_found.items) |segment| {
            try processElementPatterns(context.allocator, segment, &segment_def, loop_obj);
        }

        // Process related segments if any (from first segment only)
        try processRelatedSegments(context, segments_found.items[0], &segment_def, loop_obj);

        return;
    }

    // Process found segments with normal logic (for non-element pattern segments)
    if (segment_def.multiple) {
        // Create array for multiple segments
        var segments_array = std.json.Value{ .array = std.ArrayList(std.json.Value).init(context.allocator) };

        for (segments_found.items) |segment| {
            var segment_obj = std.json.Value{ .object = std.json.ObjectMap.init(context.allocator) };

            // Process regular element mappings
            try processElementMappings(context.allocator, segment, &segment_def, &segment_obj);

            // Process element patterns for repeating fields
            try processElementPatterns(context.allocator, segment, &segment_def, &segment_obj);

            // Process related segments if any
            try processRelatedSegments(context, segment, &segment_def, &segment_obj);

            try segments_array.array.append(segment_obj);
        }

        try loop_obj.object.put(segment_def.id, segments_array);
    } else {
        // Just process the first segment found
        const segment = segments_found.items[0];

        // Process regular element mappings
        try processElementMappings(context.allocator, segment, &segment_def, loop_obj);

        // Process element patterns for repeating fields
        try processElementPatterns(context.allocator, segment, &segment_def, loop_obj);

        // Process related segments if any
        try processRelatedSegments(context, segment, &segment_def, loop_obj);
    }
}

/// Process related segments like N3, N4 following an NM1
/// Process related segments like N3, N4 following an NM1
fn processRelatedSegments(context: *ParseContext, parent_segment: *const x12.Segment, parent_def: *const Segment, result: *std.json.Value) !void {
    // Find the index of the parent segment
    var parent_idx: ?usize = null;

    // Method 1: Compare segment ID and content instead of pointers
    for (context.document.segments.items, 0..) |segment, i| {
        // We need to compare segment properties, not pointers
        if (std.mem.eql(u8, segment.id, parent_segment.id)) {
            // Basic equality check - in a real app you might want deeper comparison
            parent_idx = i;
            break;
        }
    }

    if (parent_idx == null) return;

    // Process each related segment
    for (parent_def.related_segments.items) |related_def| {
        // Calculate the maximum index we should search up to
        const max_idx = @min(parent_idx.? + related_def.max_distance + 1, context.document.segments.items.len);

        // Look for the related segment within allowed distance
        for (context.document.segments.items[parent_idx.? + 1 .. max_idx]) |*segment| {
            if (std.mem.eql(u8, segment.id, related_def.id)) {
                // Found the related segment, process its elements
                try processElementMappings(context.allocator, segment, &related_def, result);
                break;
            }
        }
    }
}

/// Parse an X12 document using a schema configuration
pub fn parseWithSchema(allocator: Allocator, document: *const x12.X12Document, schema: *const Schema) !ParseResult {
    // Create an arena for all json allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();

    // Initialize result object
    var result = std.json.Value{ .object = std.json.ObjectMap.init(arena_allocator) };

    var context = ParseContext{
        .allocator = arena_allocator,
        .document = document,
        .result = &result,
    };

    // First process header segments
    try processHeaderSegments(&context, schema);

    // Then process loops
    try processLoops(&context, schema.loops.items);

    return ParseResult{
        .value = result,
        .arena = arena,
    };
}

fn processHeaderSegments(context: *ParseContext, schema: *const Schema) !void {
    for (schema.header.segments.items) |header_segment| {
        const segment_id = header_segment.id;

        // Find segment in document
        const segment_opt = findSegmentById(context.document, segment_id);

        if (segment_opt == null and header_segment.required) {
            return SchemaError.MissingRequiredField;
        }

        if (segment_opt) |segment| {
            // Process this header segment
            try processElementMappings(context.allocator, segment, &header_segment, context.result);
        }
    }
}

fn findSegmentById(document: *const x12.X12Document, segment_id: []const u8) ?*const x12.Segment {
    for (document.segments.items) |*segment| {
        if (std.mem.eql(u8, segment.id, segment_id)) {
            return segment;
        }
    }
    return null;
}

fn processElementMappings(allocator: Allocator, segment: *const x12.Segment, segment_def: anytype, result: *std.json.Value) !void {
    // Process regular elements with defined positions
    for (segment_def.elements.items) |element| {
        if (element.position >= segment.elements.items.len) continue;

        const segment_element = &segment.elements.items[element.position];
        var value = segment_element.value;

        // Handle composite fields
        if (element.composite != null) {
            const composite = element.composite.?;
            const separator = composite.separator;
            const index = composite.index;

            var parts = std.mem.splitAny(u8, value, &[_]u8{separator});
            var i: usize = 0;
            while (parts.next()) |part| : (i += 1) {
                if (i == index) {
                    value = part;
                    break;
                }
            }
        }

        // Apply transforms
        for (element.transforms.items) |transform| {
            if (std.mem.eql(u8, transform, "trim_whitespace")) {
                value = std.mem.trim(u8, value, &std.ascii.whitespace);
            } else if (std.mem.eql(u8, transform, "split_pointers")) {
                // Handle special transform for diagnosis pointers
                // (implementation depends on your requirements)
            } else {
                return SchemaError.UnsupportedTransform;
            }
        }

        if (element.path) |path| {
            // Look for value mappings
            var mapped = false;
            for (element.value_mappings.items) |mapping| {
                if (std.mem.eql(u8, value, mapping.value)) {
                    try setJsonPath(allocator, result, path, std.json.Value{ .string = mapping.mapped_value });
                    mapped = true;
                    break;
                }
            }

            if (!mapped) {
                try setJsonPath(allocator, result, path, std.json.Value{ .string = value });
            }
        }
    }
}

fn processLoops(context: *ParseContext, loops: []const Loop) ParserError!void {
    for (loops) |loop| {
        // Find all instances of this loop's trigger
        const triggers = findLoopTriggers(context.document, &loop.trigger, context.allocator) catch return ParserError.LoopError;
        defer triggers.deinit();

        if (triggers.items.len == 0) continue; // No triggers found

        // Multiple loops need an array to hold all instances
        if (loop.multiple and triggers.items.len > 0) {
            var loop_array = std.json.Value{ .array = std.ArrayList(std.json.Value).init(context.allocator) };

            for (triggers.items) |trigger_idx| {
                // Process one loop instance
                var loop_obj = std.json.Value{ .object = std.json.ObjectMap.init(context.allocator) };

                processLoopInstance(context, &loop, trigger_idx, &loop_obj) catch return ParserError.LoopError;
                loop_array.array.append(loop_obj) catch return ParserError.LoopError;
            }

            context.result.object.put(loop.id, loop_array) catch return ParserError.LoopError;
        } else if (triggers.items.len > 0) {
            // Single loop - create one object
            var loop_obj = std.json.Value{ .object = std.json.ObjectMap.init(context.allocator) };

            processLoopInstance(context, &loop, triggers.items[0], &loop_obj) catch return ParserError.LoopError;
            context.result.object.put(loop.id, loop_obj) catch return ParserError.LoopError;
        }
    }
}

fn processLoopInstance(context: *ParseContext, loop: *const Loop, trigger_idx: usize, loop_obj: *std.json.Value) !void {
    // Find the range of segments for this loop instance
    const loop_range = try findLoopRange(context.document, trigger_idx);
    // Process each segment in the loop definition
    for (loop.segments.items) |segment_def| {
        try processLoopSegment(context, segment_def, loop_range, loop_obj);
    }

    // Process nested loops
    if (loop.loops.items.len > 0) {
        var nested_context = context.*;
        nested_context.result = loop_obj;
        try processLoops(&nested_context, loop.loops.items);
    }
}

fn processElementPatterns(allocator: Allocator, segment: *const x12.Segment, segment_def: *const Segment, result: *std.json.Value) !void {
    if (!segment_def.process_all_elements) return;
    for (segment_def.element_patterns.items) |pattern| {
        // Create array for the target collection if it doesn't exist
        var collection = try getOrCreateArray(allocator, result, pattern.target_collection);

        // Process each element in the segment
        for (segment.elements.items) |element| {
            //Split the element value into components on the component separator
            var components = std.mem.splitAny(u8, element.value, &[_]u8{':'});
            var component_array = std.ArrayList([]const u8).init(allocator);
            defer component_array.deinit();
            while (components.next()) |component| {
                try component_array.append(component);
            }
            // Skip elements without components
            if (component_array.items.len <= pattern.qualifier_position) continue;

            // Check if qualifier matches
            const qualifier = component_array.items[pattern.qualifier_position];
            var matches = false;

            for (pattern.qualifier_values.items) |valid_qualifier| {
                if (std.mem.eql(u8, qualifier, valid_qualifier)) {
                    matches = true;
                    break;
                }
            }

            if (!matches) continue;

            // Create an object for this matched element
            var item_obj = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };

            // Map components according to pattern
            for (pattern.component_mappings.items) |mapping| {
                if (mapping.component_position < component_array.items.len) {
                    const component_value = component_array.items[mapping.component_position];
                    try item_obj.object.put(mapping.target_field, std.json.Value{ .string = component_value });
                }
            }
            try collection.array.append(item_obj);
        }
    }
}

/// Helper to set a value at a nested JSON path
fn setJsonPath(allocator: Allocator, obj: *std.json.Value, path: []const u8, value: std.json.Value) !void {
    var parts = std.mem.splitAny(u8, path, ".");
    var current = obj;

    // Navigate to the parent object
    var part = parts.next();
    while (parts.next()) |next_part| {
        if (current.object.getPtr(part.?)) |existing| {
            if (existing.* != .object) {
                // Convert to object if needed
                existing.* = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
            }
            current = existing;
        } else {
            // Create intermediate object
            const new_obj = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
            try current.object.put(part.?, new_obj);
            current = current.object.getPtr(part.?).?;
        }
        part = next_part;
    }

    // Set the value in the final object
    if (part) |final_key| {
        try current.object.put(final_key, value);
    }
}

/// Get or create an array at the specified path
fn getOrCreateArray(allocator: Allocator, obj: *std.json.Value, path: []const u8) !*std.json.Value {
    var parts = std.mem.splitAny(u8, path, ".");
    var current = obj;

    // Navigate/create path to the array
    while (parts.next()) |part| {
        if (current.object.getPtr(part)) |existing| {
            if (existing.* == .array) {
                return existing; // Array already exists
            } else if (existing.* != .object) {
                // Convert to object
                existing.* = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
            }
            current = existing;
        } else {
            // Last part - create the array
            if (parts.next() == null) {
                const new_array = std.json.Value{ .array = std.ArrayList(std.json.Value).init(allocator) };
                try current.object.put(part, new_array);
                return current.object.getPtr(part).?;
            } else {
                // Create intermediate object
                const new_obj = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
                try current.object.put(part, new_obj);
                current = current.object.getPtr(part).?;
            }
        }
    }

    // This shouldn't happen if path is non-empty
    return obj;
}
