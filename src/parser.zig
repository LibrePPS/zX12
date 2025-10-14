const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const X12Error = error{
    InvalidFormat,
    MissingSegment,
    InvalidSegment,
    InvalidElement,
    MissingISA,
    MissingIEA,
    MismatchedEnvelope,
    AllocationFailed,
    InvalidTransactionType,
};

pub const Element = struct {
    value: []const u8,
    components: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Element {
        return Element{
            .value = "",
            .components = std.ArrayList([]const u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Element) void {
        self.components.deinit(self.allocator);
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        return try utils.jsonStringify(self.*, out);
    }
};

pub const Segment = struct {
    id: []const u8,
    elements: std.ArrayList(Element),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Segment {
        return Segment{
            .id = "",
            .elements = std.ArrayList(Element){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Segment) void {
        for (0..self.elements.items.len) |i| {
            self.elements.items[i].deinit();
        }
        self.elements.deinit(self.allocator);
    }

    pub fn getElement(self: *const Segment, index: usize) ?*const Element {
        if (index >= self.elements.items.len) return null;
        return &self.elements.items[index];
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        return try utils.jsonStringify(self.*, out);
    }
};

pub const X12Document = struct {
    segments: std.ArrayList(Segment),
    segment_terminator: u8 = '~',
    element_delimiter: u8 = '*',
    component_delimiter: u8 = ':',
    repetition_separator: u8 = '^',
    allocator: Allocator,

    pub fn init(allocator: Allocator) X12Document {
        return X12Document{
            .segments = std.ArrayList(Segment){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *X12Document) void {
        for (0..self.segments.items.len) |i| {
            self.allocator.free(self.segments.items[i].id);
            self.segments.items[i].deinit();
        }
        self.segments.deinit(self.allocator);
    }

    pub fn parse(self: *X12Document, data: []const u8) !void {
        // First detect delimiters from ISA segment
        if (data.len < 106) return X12Error.InvalidFormat;

        // ISA segment must be exactly 106 chars in X12
        if (!std.mem.eql(u8, data[0..3], "ISA")) return X12Error.MissingISA;

        // Extract delimiters from ISA
        self.element_delimiter = data[3];
        self.component_delimiter = data[104];
        self.repetition_separator = data[82];
        self.segment_terminator = data[105];

        var segment_start: usize = 0;
        var i: usize = 0;

        while (i < data.len) {
            if (data[i] == self.segment_terminator) {
                try self.parseSegment(data[segment_start..i]);
                segment_start = i + 1;
            }
            i += 1;
        }

        // Parse any remaining segment that might not have a terminator
        if (segment_start < data.len) {
            try self.parseSegment(data[segment_start..]);
        }

        // Validate basic structure - at minimum need ISA/IEA pair
        try self.validateStructure();
    }

    fn parseSegment(self: *X12Document, segment_data: []const u8) !void {
        if (segment_data.len < 2) return X12Error.InvalidSegment;

        var segment = Segment.init(self.allocator);
        errdefer segment.deinit();

        var element_start: usize = 0;
        var i: usize = 0;

        // First get the segment ID (first element)
        while (i < segment_data.len) {
            if (segment_data[i] == self.element_delimiter) {
                var id: std.ArrayList(u8) = std.ArrayList(u8){};
                errdefer id.deinit(self.allocator);
                defer id.deinit(self.allocator);
                // Remove any newlines from the segment ID
                for (segment_data[0..i]) |c| {
                    if (c != '\n') {
                        try id.append(self.allocator, c);
                    }
                }
                segment.id = try self.allocator.dupe(u8, id.items);
                element_start = i + 1;
                break;
            }
            i += 1;
        }

        // Parse remaining elements
        i = element_start;
        element_start = i;
        while (i < segment_data.len) {
            if (segment_data[i] == self.element_delimiter) {
                try self.parseElement(&segment, segment_data[element_start..i]);
                element_start = i + 1;
            }
            i += 1;
        }

        // Handle the last element
        if (element_start < segment_data.len) {
            try self.parseElement(&segment, segment_data[element_start .. segment_data.len - 1]);
        }

        try self.segments.append(self.allocator, segment);
    }

    fn parseElement(self: *X12Document, segment: *Segment, element_data: []const u8) !void {
        var element = Element.init(self.allocator);
        errdefer element.deinit();

        element.value = element_data;

        // Parse components if they exist
        var component_start: usize = 0;
        var i: usize = 0;

        while (i < element_data.len) {
            if (element_data[i] == self.component_delimiter) {
                try element.components.append(self.allocator, element_data[component_start..i]);
                component_start = i + 1;
            }
            i += 1;
        }

        // Handle the last component if component delimiter was found
        if (element.components.items.len > 0 and component_start < element_data.len) {
            try element.components.append(self.allocator, element_data[component_start..]);
        }

        try segment.elements.append(self.allocator, element);
    }

    pub fn getSegmentsFollowing(self: *const X12Document, segmentId: []const u8, afterIndex: usize, maxDistance: usize, allocator: Allocator) !std.ArrayList(*const Segment) {
        var result: std.ArrayList(*const Segment) = {};
        errdefer result.deinit();

        var distance: usize = 0;
        var i: usize = afterIndex + 1;

        while (i < self.segments.items.len and distance < maxDistance) {
            const segment = &self.segments.items[i];
            if (std.mem.eql(u8, segment.id, segmentId)) {
                try result.append(allocator, segment);
            } else if (std.mem.eql(u8, segment.id, "HL") or
                std.mem.eql(u8, segment.id, "CLM") or
                std.mem.eql(u8, segment.id, "NM1"))
            {
                // Stop at logical boundaries like HL, CLM, or NM1
                break;
            }
            i += 1;
            distance += 1;
        }

        return result;
    }

    // Helper to get first segment following another segment within a certain distance
    pub fn getSegmentFollowing(self: *const X12Document, segmentId: []const u8, afterIndex: usize, maxDistance: usize) ?*const Segment {
        var distance: usize = 0;
        var i: usize = afterIndex + 1;

        while (i < self.segments.items.len and distance < maxDistance) {
            const segment = &self.segments.items[i];
            if (std.mem.eql(u8, segment.id, segmentId)) {
                return segment;
            } else if (std.mem.eql(u8, segment.id, "HL") or
                std.mem.eql(u8, segment.id, "CLM") or
                std.mem.eql(u8, segment.id, "NM1"))
            {
                // Stop at logical boundaries
                break;
            }
            i += 1;
            distance += 1;
        }

        return null;
    }

    fn validateStructure(self: *X12Document) !void {
        var has_isa = false;
        var has_iea = false;

        for (self.segments.items) |segment| {
            if (std.mem.eql(u8, segment.id, "ISA")) has_isa = true;
            if (std.mem.eql(u8, segment.id, "IEA")) has_iea = true;
        }

        if (!has_isa) return X12Error.MissingISA;
        if (!has_iea) return X12Error.MissingIEA;

        // Advanced validation would check control numbers, segment counts, etc.
    }

    // Helper functions for common operations
    pub fn getSegment(self: *const X12Document, id: []const u8) ?*const Segment {
        for (self.segments.items) |*segment| {
            if (std.mem.eql(u8, segment.id, id)) {
                return segment;
            }
        }
        return null;
    }

    pub fn getSegments(self: *const X12Document, id: []const u8, allocator: Allocator) !std.ArrayList(*const Segment) {
        var result: std.ArrayList(*const Segment) = {};
        errdefer result.deinit();

        for (self.segments.items) |*segment| {
            if (std.mem.eql(u8, segment.id, id)) {
                try result.append(allocator, segment);
            }
        }

        return result;
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        return try utils.jsonStringify(self.*, out);
    }
};
