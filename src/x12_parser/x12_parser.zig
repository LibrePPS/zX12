const std = @import("std");
const testing = std.testing;

/// X12 delimiters detected from the ISA segment
pub const Delimiters = struct {
    element: u8, // Typically '*'
    segment: u8, // Typically '~'
    composite: u8, // Typically ':' or '>'
    repetition: u8, // Typically '^' (ISA-11)
};

/// A composite element (e.g., "1:2:3" split into ["1", "2", "3"])
pub const CompositeElement = struct {
    components: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompositeElement) void {
        self.allocator.free(self.components);
    }

    /// Get a component by position (0-based)
    pub fn getComponent(self: CompositeElement, pos: usize) ?[]const u8 {
        if (pos >= self.components.len) return null;
        return self.components[pos];
    }
};

/// A repeated element (e.g., "A^B^C" split into ["A", "B", "C"])
pub const RepeatedElement = struct {
    repetitions: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RepeatedElement) void {
        self.allocator.free(self.repetitions);
    }

    /// Get a repetition by position (0-based)
    pub fn getRepetition(self: RepeatedElement, pos: usize) ?[]const u8 {
        if (pos >= self.repetitions.len) return null;
        return self.repetitions[pos];
    }
};

/// A single X12 segment with its elements
pub const Segment = struct {
    id: []const u8, // Segment identifier (e.g., "ISA", "NM1", "CLM")
    elements: [][]const u8, // Array of element strings (including the ID as element 0)
    index: usize, // Position in the document (0-based)

    /// Get an element by position (0-based, where 0 is the segment ID)
    pub fn getElement(self: Segment, pos: usize) ?[]const u8 {
        if (pos >= self.elements.len) return null;
        return self.elements[pos];
    }

    /// Parse composite element (split by ':' or '>')
    pub fn parseComposite(self: Segment, allocator: std.mem.Allocator, pos: usize, composite_sep: u8) !?CompositeElement {
        const element = self.getElement(pos) orelse return null;
        if (element.len == 0) return null;

        // Check if element contains composite separator
        if (std.mem.indexOfScalar(u8, element, composite_sep) == null) {
            return null; // Not a composite element
        }

        var components = std.ArrayList([]const u8){};
        errdefer components.deinit(allocator);

        var iter = std.mem.splitAny(u8, element, &[_]u8{composite_sep});
        while (iter.next()) |component| {
            try components.append(allocator, component);
        }

        return CompositeElement{
            .components = try components.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    /// Parse repeated element (split by '^')
    pub fn parseRepetition(self: Segment, allocator: std.mem.Allocator, pos: usize, repetition_sep: u8) !?RepeatedElement {
        const element = self.getElement(pos) orelse return null;
        if (element.len == 0) return null;

        // Check if element contains repetition separator
        if (std.mem.indexOfScalar(u8, element, repetition_sep) == null) {
            return null; // Not a repeated element
        }

        var repetitions = std.ArrayList([]const u8){};
        errdefer repetitions.deinit(allocator);

        var iter = std.mem.splitAny(u8, element, &[_]u8{repetition_sep});
        while (iter.next()) |repetition| {
            try repetitions.append(allocator, repetition);
        }

        return RepeatedElement{
            .repetitions = try repetitions.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }
};

/// Parsed X12 document containing all segments and delimiter info
pub const X12Document = struct {
    segments: []Segment,
    delimiters: Delimiters,
    allocator: std.mem.Allocator,
    raw_content: []const u8, // Cleaned content (newlines removed)

    /// Free all memory associated with this document
    pub fn deinit(self: *X12Document) void {
        for (self.segments) |segment| {
            self.allocator.free(segment.elements);
        }
        self.allocator.free(self.segments);
        self.allocator.free(self.raw_content);
    }

    /// Find the first segment with the given ID
    pub fn findSegment(self: X12Document, segment_id: []const u8) ?Segment {
        for (self.segments) |segment| {
            if (std.mem.eql(u8, segment.id, segment_id)) {
                return segment;
            }
        }
        return null;
    }

    /// Find all segments with the given ID
    pub fn findAllSegments(self: X12Document, allocator: std.mem.Allocator, segment_id: []const u8) ![]Segment {
        var matches = std.ArrayList(Segment){};
        errdefer matches.deinit(allocator);

        for (self.segments) |segment| {
            if (std.mem.eql(u8, segment.id, segment_id)) {
                try matches.append(allocator, segment);
            }
        }

        return matches.toOwnedSlice(allocator);
    }

    /// Get a slice of segments within a range (inclusive start, exclusive end)
    pub fn getSegmentRange(self: X12Document, start_index: usize, end_index: usize) ?[]Segment {
        if (start_index >= self.segments.len or end_index > self.segments.len or start_index >= end_index) {
            return null;
        }
        return self.segments[start_index..end_index];
    }

    /// Find the index of the first segment with the given ID, starting from start_index
    pub fn findSegmentIndex(self: X12Document, segment_id: []const u8, start_index: usize) ?usize {
        for (self.segments[start_index..], start_index..) |segment, idx| {
            if (std.mem.eql(u8, segment.id, segment_id)) {
                return idx;
            }
        }
        return null;
    }

    /// Count segments with the given ID
    pub fn countSegments(self: X12Document, segment_id: []const u8) usize {
        var count: usize = 0;
        for (self.segments) |segment| {
            if (std.mem.eql(u8, segment.id, segment_id)) {
                count += 1;
            }
        }
        return count;
    }
};

/// Parse X12 document from raw text
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !X12Document {
    // Step 1: Remove newlines and carriage returns from content
    // X12 files may have newlines added for readability, but they're not part of the standard
    var cleaned_content = std.ArrayList(u8){};
    defer cleaned_content.deinit(allocator);

    for (content) |c| {
        if (c != '\n' and c != '\r') {
            try cleaned_content.append(allocator, c);
        }
    }

    const clean_data = try cleaned_content.toOwnedSlice(allocator);
    errdefer allocator.free(clean_data);

    // Step 2: Extract delimiters from ISA segment
    const delimiters = try detectDelimiters(clean_data);

    // Step 3: Split into segments
    var segments = std.ArrayList(Segment){};
    errdefer {
        for (segments.items) |segment| {
            allocator.free(segment.elements);
        }
        segments.deinit(allocator);
    }
    var segment_iter = std.mem.splitAny(u8, clean_data, &[_]u8{delimiters.segment});
    var segment_index: usize = 0;

    while (segment_iter.next()) |segment_text| {
        // Skip empty segments
        const trimmed = std.mem.trim(u8, segment_text, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Parse the segment
        const segment = try parseSegment(allocator, trimmed, delimiters, segment_index);
        try segments.append(allocator, segment);
        segment_index += 1;
    }

    return X12Document{
        .segments = try segments.toOwnedSlice(allocator),
        .delimiters = delimiters,
        .allocator = allocator,
        .raw_content = clean_data,
    };
}

/// Detect delimiters from the ISA segment
/// Per X12 standard, ISA segment is EXACTLY 106 characters:
/// - Position 0-2: "ISA"
/// - Position 3: Element separator (typically '*')
/// - Position 82: Repetition separator at ISA11 (typically '^')
/// - Position 104: Composite separator at ISA16-1 (typically ':' or '>')
/// - Position 105: Segment terminator (typically '~')
fn detectDelimiters(content: []const u8) !Delimiters {
    // ISA segment must be exactly 106 characters per X12 standard
    if (content.len < 106) return error.InvalidISA;

    // ISA segment must start with "ISA"
    if (!std.mem.startsWith(u8, content, "ISA")) return error.MissingISASegment;

    // Element separator is at position 3 (immediately after "ISA")
    const element_sep = content[3];

    // Repetition separator is at position 82 (ISA11)
    const repetition_sep = content[82];

    // Composite separator is at position 104 (ISA16-1)
    const composite_sep = content[104];

    // Segment terminator is at position 105 (end of ISA)
    const segment_term = content[105];

    return Delimiters{
        .element = element_sep,
        .segment = segment_term,
        .composite = composite_sep,
        .repetition = repetition_sep,
    };
}

/// Parse a single segment into its components
fn parseSegment(
    allocator: std.mem.Allocator,
    segment_text: []const u8,
    delimiters: Delimiters,
    index: usize,
) !Segment {
    var elements = std.ArrayList([]const u8){};
    errdefer elements.deinit(allocator);

    var element_iter = std.mem.splitAny(u8, segment_text, &[_]u8{delimiters.element});

    while (element_iter.next()) |element| {
        try elements.append(allocator, element);
    }

    const elements_slice = try elements.toOwnedSlice(allocator);

    // First element is always the segment ID
    const segment_id = if (elements_slice.len > 0) elements_slice[0] else "";

    return Segment{
        .id = segment_id,
        .elements = elements_slice,
        .index = index,
    };
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "detect delimiters from ISA segment" {
    const isa_segment = "ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~";

    const delimiters = try detectDelimiters(isa_segment);

    try testing.expectEqual(@as(u8, '*'), delimiters.element);
    try testing.expectEqual(@as(u8, '~'), delimiters.segment);
    try testing.expectEqual(@as(u8, ':'), delimiters.composite);
    try testing.expectEqual(@as(u8, '^'), delimiters.repetition);
}

test "parse simple segment" {
    const allocator = testing.allocator;
    const delimiters = Delimiters{
        .element = '*',
        .segment = '~',
        .composite = ':',
        .repetition = '^',
    };

    const segment = try parseSegment(allocator, "NM1*85*2*PROVIDER*NAME****XX*1234567890", delimiters, 0);
    defer allocator.free(segment.elements);

    try testing.expectEqualStrings("NM1", segment.id);
    try testing.expectEqual(@as(usize, 10), segment.elements.len);
    try testing.expectEqualStrings("85", segment.elements[1]);
    try testing.expectEqualStrings("2", segment.elements[2]);
    try testing.expectEqualStrings("PROVIDER", segment.elements[3]);
}

test "parse simple X12 document" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\GS*HC*SENDER*RECEIVER*20210101*1200*1*X*005010X222A1~
        \\ST*837*0001*005010X222A1~
        \\BHT*0019*00*BATCH123*20210101*1200*CH~
        \\SE*4*0001~
        \\GE*1*1~
        \\IEA*1*000000001~
    ;

    var doc = try parse(allocator, x12_content);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 7), doc.segments.len);
    try testing.expectEqualStrings("ISA", doc.segments[0].id);
    try testing.expectEqualStrings("GS", doc.segments[1].id);
    try testing.expectEqualStrings("ST", doc.segments[2].id);
    try testing.expectEqualStrings("BHT", doc.segments[3].id);
}

test "segment getElement method" {
    const allocator = testing.allocator;
    const delimiters = Delimiters{
        .element = '*',
        .segment = '~',
        .composite = ':',
        .repetition = '^',
    };

    const segment = try parseSegment(allocator, "CLM*CLAIM123*1000.00", delimiters, 0);
    defer allocator.free(segment.elements);

    try testing.expectEqualStrings("CLM", segment.getElement(0).?);
    try testing.expectEqualStrings("CLAIM123", segment.getElement(1).?);
    try testing.expectEqualStrings("1000.00", segment.getElement(2).?);
    try testing.expect(segment.getElement(99) == null);
}

test "parse document with empty elements" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\NM1*85*2*LAST**FIRST*****XX*1234567890~
        \\SE*2*0001~
    ;

    var doc = try parse(allocator, x12_content);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 3), doc.segments.len);

    const nm1 = doc.segments[1];
    try testing.expectEqualStrings("NM1", nm1.id);
    try testing.expectEqualStrings("LAST", nm1.elements[3]);
    try testing.expectEqualStrings("", nm1.elements[4]); // Empty middle name
    try testing.expectEqualStrings("FIRST", nm1.elements[5]);
}

test "parse composite element" {
    const allocator = testing.allocator;
    const delimiters = Delimiters{
        .element = '*',
        .segment = '~',
        .composite = ':',
        .repetition = '^',
    };

    const segment = try parseSegment(allocator, "CLM*CLAIM123*1000.00***11:B:1*Y", delimiters, 0);
    defer allocator.free(segment.elements);

    // CLM05 is a composite element "11:B:1"
    var composite = try segment.parseComposite(allocator, 5, delimiters.composite);
    try testing.expect(composite != null);
    defer composite.?.deinit();

    try testing.expectEqual(@as(usize, 3), composite.?.components.len);
    try testing.expectEqualStrings("11", composite.?.getComponent(0).?);
    try testing.expectEqualStrings("B", composite.?.getComponent(1).?);
    try testing.expectEqualStrings("1", composite.?.getComponent(2).?);
}

test "parse repetition element" {
    const allocator = testing.allocator;
    const delimiters = Delimiters{
        .element = '*',
        .segment = '~',
        .composite = ':',
        .repetition = '^',
    };

    const segment = try parseSegment(allocator, "HI*ABK:25000^ABF:41401", delimiters, 0);
    defer allocator.free(segment.elements);

    // HI01 contains repetition "ABK:25000^ABF:41401"
    var repetition = try segment.parseRepetition(allocator, 1, delimiters.repetition);
    try testing.expect(repetition != null);
    defer repetition.?.deinit();

    try testing.expectEqual(@as(usize, 2), repetition.?.repetitions.len);
    try testing.expectEqualStrings("ABK:25000", repetition.?.getRepetition(0).?);
    try testing.expectEqualStrings("ABF:41401", repetition.?.getRepetition(1).?);
}

test "parse non-composite element returns null" {
    const allocator = testing.allocator;
    const delimiters = Delimiters{
        .element = '*',
        .segment = '~',
        .composite = ':',
        .repetition = '^',
    };

    const segment = try parseSegment(allocator, "NM1*85*2*PROVIDER", delimiters, 0);
    defer allocator.free(segment.elements);

    // NM101 is not a composite
    const composite = try segment.parseComposite(allocator, 1, delimiters.composite);
    try testing.expect(composite == null);
}

test "find segment in document" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\GS*HC*SENDER*RECEIVER*20210101*1200*1*X*005010X222A1~
        \\ST*837*0001*005010X222A1~
        \\BHT*0019*00*BATCH123*20210101*1200*CH~
        \\SE*4*0001~
        \\GE*1*1~
        \\IEA*1*000000001~
    ;

    var doc = try parse(allocator, x12_content);
    defer doc.deinit();

    const bht = doc.findSegment("BHT");
    try testing.expect(bht != null);
    try testing.expectEqualStrings("BHT", bht.?.id);
    try testing.expectEqualStrings("0019", bht.?.getElement(1).?);

    const missing = doc.findSegment("NM1");
    try testing.expect(missing == null);
}

test "find all segments in document" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\NM1*85*2*PROVIDER1~
        \\NM1*87*2*PROVIDER2~
        \\NM1*IL*1*SUBSCRIBER~
        \\SE*4*0001~
    ;

    var doc = try parse(allocator, x12_content);
    defer doc.deinit();

    const nm1_segments = try doc.findAllSegments(allocator, "NM1");
    defer allocator.free(nm1_segments);

    try testing.expectEqual(@as(usize, 3), nm1_segments.len);
    try testing.expectEqualStrings("85", nm1_segments[0].getElement(1).?);
    try testing.expectEqualStrings("87", nm1_segments[1].getElement(1).?);
    try testing.expectEqualStrings("IL", nm1_segments[2].getElement(1).?);
}

test "count segments in document" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\NM1*85*2*PROVIDER1~
        \\NM1*87*2*PROVIDER2~
        \\REF*EI*123456789~
        \\NM1*IL*1*SUBSCRIBER~
        \\SE*5*0001~
    ;

    var doc = try parse(allocator, x12_content);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 3), doc.countSegments("NM1"));
    try testing.expectEqual(@as(usize, 1), doc.countSegments("REF"));
    try testing.expectEqual(@as(usize, 0), doc.countSegments("CLM"));
}

test "find segment index" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\GS*HC*SENDER*RECEIVER*20210101*1200*1*X*005010X222A1~
        \\ST*837*0001*005010X222A1~
        \\BHT*0019*00*BATCH123*20210101*1200*CH~
        \\SE*4*0001~
    ;

    var doc = try parse(allocator, x12_content);
    defer doc.deinit();

    const st_index = doc.findSegmentIndex("ST", 0);
    try testing.expect(st_index != null);
    try testing.expectEqual(@as(usize, 2), st_index.?);

    // Find SE after ST
    const se_index = doc.findSegmentIndex("SE", st_index.? + 1);
    try testing.expect(se_index != null);
    try testing.expectEqual(@as(usize, 4), se_index.?);
}

test "get segment range" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\GS*HC*SENDER*RECEIVER*20210101*1200*1*X*005010X222A1~
        \\ST*837*0001*005010X222A1~
        \\BHT*0019*00*BATCH123*20210101*1200*CH~
        \\NM1*85*2*PROVIDER~
        \\SE*5*0001~
    ;

    var doc = try parse(allocator, x12_content);
    defer doc.deinit();

    // Get ST through NM1 (indices 2-5, exclusive end)
    const range = doc.getSegmentRange(2, 5);
    try testing.expect(range != null);
    try testing.expectEqual(@as(usize, 3), range.?.len);
    try testing.expectEqualStrings("ST", range.?[0].id);
    try testing.expectEqualStrings("BHT", range.?[1].id);
    try testing.expectEqualStrings("NM1", range.?[2].id);
}

test "composite within repetition - complex HI segment" {
    const allocator = testing.allocator;
    const delimiters = Delimiters{
        .element = '*',
        .segment = '~',
        .composite = ':',
        .repetition = '^',
    };

    // Real-world HI segment with diagnosis codes
    const segment = try parseSegment(allocator, "HI*ABK:25000^ABF:41401^ABF:E119", delimiters, 0);
    defer allocator.free(segment.elements);

    // Parse the repetition first
    var repetition = try segment.parseRepetition(allocator, 1, delimiters.repetition);
    try testing.expect(repetition != null);
    defer repetition.?.deinit();

    try testing.expectEqual(@as(usize, 3), repetition.?.repetitions.len);

    // Now parse each repetition as a composite
    var iter = std.mem.splitAny(u8, repetition.?.getRepetition(0).?, &[_]u8{delimiters.composite});
    const qualifier1 = iter.next().?;
    const code1 = iter.next().?;
    try testing.expectEqualStrings("ABK", qualifier1);
    try testing.expectEqualStrings("25000", code1);
}

test "reject ISA segment that is too short" {
    const allocator = testing.allocator;

    // ISA segment with only 100 characters - should fail
    const x12_content = "ISA*00*          *00*          *ZZ*SHORT~";

    const result = parse(allocator, x12_content);
    try testing.expectError(error.InvalidISA, result);
}

test "reject content without ISA segment" {
    const allocator = testing.allocator;

    // Content that doesn't start with ISA (but is long enough to pass length check)
    const x12_content = "GS*HC*SENDER*RECEIVER*20230301*1200*1*X*005010X222A1*THIS_IS_PADDED_TO_BE_LONGER_THAN_106_CHARACTERS_SO_WE_TEST_ISA_CHECK~";

    const result = parse(allocator, x12_content);
    try testing.expectError(error.MissingISASegment, result);
}

test "ISA segment must be exactly 106 characters" {
    const allocator = testing.allocator;

    // Valid 106-character ISA
    const valid_isa = "ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~";
    try testing.expectEqual(@as(usize, 106), valid_isa.len);

    var doc = try parse(allocator, valid_isa ++ "SE*1*0001~");
    defer doc.deinit();

    try testing.expectEqual(@as(u8, '*'), doc.delimiters.element);
    try testing.expectEqual(@as(u8, '~'), doc.delimiters.segment);
    try testing.expectEqual(@as(u8, ':'), doc.delimiters.composite);
    try testing.expectEqual(@as(u8, '^'), doc.delimiters.repetition);
}
