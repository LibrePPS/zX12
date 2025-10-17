# Schema Loader Module

## Overview
The schema loader module loads and parses v2.0 JSON schemas that define how to transform X12 EDI files into structured JSON output. These schemas specify segment definitions, element mappings, value transformations, and hierarchical structure.

## Key Components

### Data Structures

#### `ElementMapping`
Maps X12 segment elements to JSON output paths:
- `seg`: Optional segment ID (for grouped segments)
- `pos`: Element position (0-based)
- `path`: JSON output path (e.g., "provider.name.last")
- `expect`: Expected value for validation
- `map`: Value transformation map (e.g., "M" → "Male")
- `transform`: Array of transformations to apply
- `optional`: Whether element is optional
- `allocator`: For memory cleanup

#### `SegmentDef`
Defines a segment and its elements:
- `id`: Segment ID (e.g., "NM1", "CLM")
- `qualifier`: Qualifier check [position, value]
- `group`: Grouped segments
- `elements`: Array of element mappings
- `optional`: Whether segment is optional
- `max_use`: Maximum occurrences allowed
- `allocator`: For memory cleanup

#### `HLLevel`
Defines a hierarchical level (HL segment type):
- `code`: HL level code (e.g., "20" = provider, "22" = subscriber)
- `name`: Human-readable name
- `output_array`: Output array name (e.g., "subscribers")
- `segments`: Segment definitions for this level
- `child_levels`: Valid child level codes
- `allocator`: For memory cleanup

#### `SequentialSection`
Defines a sequential (non-hierarchical) section:
- `name`: Section name (e.g., "Submitter")
- `output_path`: JSON output path
- `segments`: Segment definitions
- `allocator`: For memory cleanup

#### `Schema`
Top-level schema structure:
- `version`: Schema version (e.g., "2.0")
- `transaction_id`: Transaction ID (e.g., "837P", "837I")
- `transaction_version`: X12 version (e.g., "005010X222A1")
- `transaction_type`: Transaction type (e.g., "837")
- `description`: Schema description
- `header_segments`: Header segment definitions (ISA, GS, ST, BHT)
- `sequential_sections`: Non-hierarchical sections
- `hl_levels`: Hierarchical levels mapped by code
- `trailer_segments`: Trailer segment definitions (SE, GE, IEA)
- `hierarchical_output_array`: Top-level array name
- `_json_content`: Internal JSON file content (kept alive for string refs)
- `_json_parsed`: Internal parsed JSON (kept alive for string refs)
- `allocator`: For memory cleanup

### Main Functions

#### `loadSchema(allocator, file_path) -> Schema`
Load and parse a schema JSON file:
```zig
var schema = try loadSchema(allocator, "schema/837p.json");
defer schema.deinit();
```

#### `Schema.getLevel(code) -> ?HLLevel`
Get hierarchical level definition by code:
```zig
const subscriber = schema.getLevel("22"); // Get subscriber level
if (subscriber) |sub| {
    std.debug.print("Level: {s}\n", .{sub.name});
}
```

#### `Schema.findSegmentInLevel(level, segment_id) -> ?SegmentDef`
Find segment definition in a hierarchical level:
```zig
const level = schema.getLevel("22").?;
const nm1_seg = schema.findSegmentInLevel(level, "NM1");
```

### Helper Functions

#### `parseHLLevel(allocator, code, json_obj) -> HLLevel`
Parse hierarchical level from JSON object.

#### `parseSegments(allocator, json_array) -> []SegmentDef`
Parse array of segment definitions from JSON.

#### `parseSegment(allocator, json_obj) -> SegmentDef`
Parse single segment definition from JSON.

#### `parseElement(allocator, json_obj) -> ElementMapping`
Parse element mapping from JSON.

## Schema File Structure

v2.0 schemas have this JSON structure:

```json
{
  "version": "2.0",
  "transaction_header": {
    "transaction_id": "837P",
    "transaction_version": "005010X222A1",
    "transaction_type": "837",
    "description": "Professional Claims",
    "segments": ["ISA", "GS", "ST", "BHT"]
  },
  "sequential_sections": [
    {
      "name": "Submitter",
      "output_path": "submitter",
      "segments": [...]
    }
  ],
  "hierarchical_structure": {
    "output_array": "billing_providers",
    "levels": {
      "20": {
        "name": "Billing Provider",
        "output_array": null,
        "child_levels": ["22"],
        "segments": [...]
      },
      "22": {
        "name": "Subscriber",
        "output_array": "subscribers",
        "child_levels": ["23"],
        "segments": [...]
      }
    }
  },
  "transaction_trailer": {
    "segments": ["SE", "GE", "IEA"]
  }
}
```

### Segment Definition Example
```json
{
  "id": "NM1",
  "qualifier": [1, "IL"],
  "elements": [
    {
      "pos": 3,
      "path": "subscriber.name.last",
      "expect": null,
      "map": null,
      "transform": ["uppercase"]
    },
    {
      "pos": 4,
      "path": "subscriber.name.first"
    }
  ]
}
```

## Memory Management

The schema loader uses explicit memory management:

1. **JSON Content**: The raw JSON file content is kept alive in `_json_content` because string references in the JSON point directly to this memory.

2. **Parsed JSON**: The `std.json.Parsed` object is kept alive in `_json_parsed` to maintain string references.

3. **Owned Allocations**: 
   - Segment/element arrays are allocated and owned by their parent structs
   - Qualifier values are duplicated to owned strings
   - Transform arrays are allocated
   - Value mapping hashmaps are allocated

4. **Cleanup**: Call `schema.deinit()` to recursively free all allocated memory.

## Usage Example

```zig
const std = @import("std");
const schema_mod = @import("schema.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load schema
    var schema = try schema_mod.loadSchema(allocator, "schema/837p.json");
    defer schema.deinit();

    // Get hierarchical levels
    const provider = schema.getLevel("20").?;
    const subscriber = schema.getLevel("22").?;

    std.debug.print("Provider level: {s}\n", .{provider.name});
    std.debug.print("Subscriber level: {s}\n", .{subscriber.name});

    // Find segment in level
    if (schema.findSegmentInLevel(subscriber, "NM1")) |nm1| {
        std.debug.print("Found NM1 segment with {d} elements\n", .{nm1.elements.len});
    }
}
```

## Test Coverage

The module includes 7 comprehensive tests:
1. **load 837P schema** - Basic schema loading and metadata validation
2. **get HL level from schema** - Hierarchical level retrieval
3. **find segment in level** - Segment lookup in levels
4. **check segment qualifiers and groups** - Qualifier/group parsing
5. **check element mappings** - Element mapping details
6. **check value mappings** - Value transformation maps
7. **load 837I schema** - Institutional claims schema

All tests pass with zero memory leaks when using `std.testing.allocator`.

## Design Notes

### Why Keep JSON Alive?
The `std.json.parseFromSlice` function returns a `Parsed(T)` object that contains the parsed data structure, but string fields in that structure point directly to the original JSON content. If we free the JSON content or the `Parsed` object, those string references become invalid (dangling pointers). By keeping both `_json_content` and `_json_parsed` alive for the schema's lifetime, we ensure all string references remain valid.

### Owned vs Borrowed Strings
Most strings (IDs, paths, names) are borrowed from the JSON and don't need explicit cleanup. However, some strings are allocated:
- Qualifier values (duplicated to simplify memory management)
- Transform arrays (allocated during parsing)
- Integer conversions (e.g., qualifier value "1" from integer 1)

### Future Enhancements
- Schema validation (check for required fields, valid references)
- Schema merging (combine multiple schemas)
- Schema querying (find all segments with specific element)
- Default value support
- Conditional element mappings
