# X12 Parser Tokenizer

A fully-featured X12 document tokenizer that strictly adheres to the X12 EDI standard.

## Features

### ✅ Core Functionality
- **ISA Validation**: Enforces the X12 standard of exactly 106 characters for ISA segments
- **Delimiter Detection**: Automatically detects all four delimiters from ISA segment at fixed positions:
  - Position 3: Element separator (typically `*`)
  - Position 82: Repetition separator (typically `^`)
  - Position 104: Composite separator (typically `:`)
  - Position 105: Segment terminator (typically `~`)
- **Newline Handling**: Automatically strips `\n` and `\r` from content before parsing
- **Segment Parsing**: Splits document into segments and elements in a single pass
- **Memory Safe**: Proper allocator usage with cleanup via `deinit()`

### ✅ Advanced Parsing
- **Composite Elements**: Parse elements like `11:B:1` into sub-components
- **Repeated Elements**: Parse elements like `ABK:25000^ABF:41401` into repetitions
- **Empty Elements**: Correctly handles empty elements (e.g., `NM1*85*2*LAST**FIRST`)

### ✅ Document Utilities
- **Find Segment**: Locate first occurrence of a segment by ID
- **Find All Segments**: Get all segments with a given ID
- **Count Segments**: Count occurrences of a segment type
- **Segment Range**: Extract a slice of segments by index range
- **Find Index**: Locate segment position for range-based operations

## Data Structures

### `Delimiters`
```zig
pub const Delimiters = struct {
    element: u8,      // Element separator (e.g., '*')
    segment: u8,      // Segment terminator (e.g., '~')
    composite: u8,    // Composite separator (e.g., ':')
    repetition: u8,   // Repetition separator (e.g., '^')
};
```

### `Segment`
```zig
pub const Segment = struct {
    id: []const u8,              // Segment identifier
    elements: [][]const u8,      // All elements (including ID as element 0)
    index: usize,                // Position in document
    
    pub fn getElement(self: Segment, pos: usize) ?[]const u8;
    pub fn parseComposite(...) !?CompositeElement;
    pub fn parseRepetition(...) !?RepeatedElement;
};
```

### `X12Document`
```zig
pub const X12Document = struct {
    segments: []Segment,
    delimiters: Delimiters,
    allocator: std.mem.Allocator,
    raw_content: []const u8,
    
    pub fn deinit(self: *X12Document) void;
    pub fn findSegment(self: X12Document, segment_id: []const u8) ?Segment;
    pub fn findAllSegments(...) ![]Segment;
    pub fn countSegments(self: X12Document, segment_id: []const u8) usize;
    pub fn getSegmentRange(self: X12Document, start: usize, end: usize) ?[]Segment;
    pub fn findSegmentIndex(...) ?usize;
};
```

## Usage Example

```zig
const std = @import("std");
const x12_parser = @import("x12_parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read X12 file
    const content = try std.fs.cwd().readFileAlloc(
        "sample.x12",
        allocator,
        @enumFromInt(1024 * 1024)
    );
    defer allocator.free(content);

    // Parse the document
    var doc = try x12_parser.parse(allocator, content);
    defer doc.deinit();

    // Access delimiters
    std.debug.print("Element separator: {c}\n", .{doc.delimiters.element});

    // Find segments
    if (doc.findSegment("CLM")) |clm| {
        const claim_id = clm.getElement(1) orelse "UNKNOWN";
        const amount = clm.getElement(2) orelse "0.00";
        std.debug.print("Claim {s}: ${s}\n", .{claim_id, amount});
        
        // Parse composite element (e.g., CLM05)
        if (try clm.parseComposite(allocator, 5, doc.delimiters.composite)) |comp| {
            var composite = comp;
            defer composite.deinit();
            std.debug.print("Facility: {s}:{s}:{s}\n", .{
                composite.getComponent(0) orelse "",
                composite.getComponent(1) orelse "",
                composite.getComponent(2) orelse "",
            });
        }
    }

    // Find all segments of a type
    const hi_segments = try doc.findAllSegments(allocator, "HI");
    defer allocator.free(hi_segments);
    
    for (hi_segments) |hi| {
        // Parse repetition (diagnosis codes)
        if (try hi.parseRepetition(allocator, 1, doc.delimiters.repetition)) |r| {
            var rep = r;
            defer rep.deinit();
            for (rep.repetitions) |diagnosis| {
                std.debug.print("Diagnosis: {s}\n", .{diagnosis});
            }
        }
    }

    // Count segments
    const claim_count = doc.countSegments("CLM");
    std.debug.print("Total claims: {d}\n", .{claim_count});
}
```

## Test Coverage

**17 unit tests** covering:
- ✅ Delimiter detection from ISA segment
- ✅ Simple segment parsing
- ✅ Full document parsing
- ✅ Element access with `getElement()`
- ✅ Empty element handling
- ✅ Composite element parsing
- ✅ Repetition element parsing
- ✅ Non-composite element handling
- ✅ Segment finding
- ✅ Finding all segments
- ✅ Segment counting
- ✅ Segment index lookup
- ✅ Segment range extraction
- ✅ Complex HI segments (composite within repetition)
- ✅ ISA too short rejection
- ✅ Missing ISA rejection
- ✅ ISA exactly 106 characters validation

All tests passing with Zig 0.15.

## X12 Standard Compliance

This tokenizer strictly enforces the X12 standard:

1. **ISA Segment**: Must be exactly 106 characters
2. **Fixed Positions**: Delimiters at standard positions (3, 82, 104, 105)
3. **Segment Structure**: Proper element/composite/repetition hierarchy
4. **Error Handling**: Clear errors for malformed documents

## Performance Characteristics

- **Single Pass**: Parses entire document in one iteration
- **Zero Copy**: Segment elements are slices of cleaned content
- **Lazy Parsing**: Composite/repetition parsing only when requested
- **Minimal Allocations**: Only allocates for segment list and cleaned content

## Next Steps

This tokenizer provides the foundation for:
1. **HL Tree Builder**: Use parsed segments to build hierarchy tree
2. **Schema Loader**: Load v2.0 JSON schemas for validation
3. **JSON Builder**: Convert parsed segments to JSON output
4. **Document Processor**: Orchestrate full parsing pipeline

## Files

- `x12_parser.zig`: Main tokenizer implementation (17 tests)
- `test_real_file.zig`: Real-world 837P sample file testing
- `README.md`: This documentation

## Testing

```bash
# Run all unit tests
zig test src/x12_parser/x12_parser.zig

# Test with real 837P file
zig run src/x12_parser/test_real_file.zig
```

## License

Part of the zX12 project - X12 EDI parser for healthcare claims (837P/837I).
