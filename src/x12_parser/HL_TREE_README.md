# HL Tree Builder

Builds an explicit parent-child hierarchy tree from X12 HL (Hierarchy Level) segments.

## Overview

The HL Tree Builder parses HL segments and constructs a tree that represents the hierarchical structure of an X12 document. This is essential for processing 837P and 837I claims where billing providers contain subscribers, and subscribers may contain patients.

## Features

### ✅ Core Functionality
- **Tree Building**: Constructs explicit parent-child relationships from HL segments
- **Segment Ranges**: Calculates segment boundaries for each HL node
- **Level Codes**: Supports standard X12 levels (20=Provider, 22=Subscriber, 23=Patient)
- **Multiple Children**: Handles HL nodes with multiple child nodes
- **Root Detection**: Automatically identifies root nodes (HL segments with no parent)

### ✅ Tree Operations
- **Find Node by ID**: Locate any node in the tree by its HL ID
- **Find by Level**: Get all nodes at a specific level (e.g., all subscribers)
- **Count Nodes**: Total node count and descendant counting
- **Segment Access**: Direct access to segments belonging to each HL node

## Data Structures

### `HLNode`
```zig
pub const HLNode = struct {
    id: []const u8,              // HL01 - Unique identifier
    parent_id: []const u8,       // HL02 - Parent ID (empty if root)
    level_code: []const u8,      // HL03 - Level code (e.g., "20", "22", "23")
    has_children: bool,          // HL04 - Has subordinate HL segments
    hl_segment_index: usize,     // Index of HL segment in document
    segment_start: usize,        // Start of segments for this HL (inclusive)
    segment_end: usize,          // End of segments for this HL (exclusive)
    children: []HLNode,          // Child nodes
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *HLNode) void;
    pub fn getSegments(self: HLNode, doc: X12Document) ?[]Segment;
    pub fn findChild(self: HLNode, id: []const u8) ?*const HLNode;
    pub fn countDescendants(self: HLNode) usize;
};
```

### `HLTree`
```zig
pub const HLTree = struct {
    roots: []HLNode,             // Root nodes (typically one)
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *HLTree) void;
    pub fn findNode(self: HLTree, id: []const u8) ?*const HLNode;
    pub fn countNodes(self: HLTree) usize;
    pub fn getNodesByLevel(self: HLTree, allocator, level_code: []const u8) ![]HLNode;
};
```

## Usage Example

```zig
const std = @import("std");
const x12_parser = @import("x12_parser.zig");
const hl_tree = @import("hl_tree.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse X12 document
    var doc = try x12_parser.parse(allocator, content);
    defer doc.deinit();

    // Build HL tree
    var tree = try hl_tree.buildTree(allocator, doc);
    defer tree.deinit();

    // Access root (billing provider)
    const provider = tree.roots[0];
    std.debug.print("Provider HL: {s}\n", .{provider.id});
    std.debug.print("Level: {s}\n", .{provider.level_code});
    std.debug.print("Children: {d}\n", .{provider.children.len});

    // Get provider's segments
    if (provider.getSegments(doc)) |segments| {
        for (segments) |seg| {
            if (std.mem.eql(u8, seg.id, "NM1")) {
                const name = seg.getElement(3) orelse "";
                std.debug.print("Provider Name: {s}\n", .{name});
            }
        }
    }

    // Find all subscribers
    const subscribers = try tree.getNodesByLevel(allocator, "22");
    defer allocator.free(subscribers);
    
    for (subscribers) |subscriber| {
        std.debug.print("Subscriber HL {s}\n", .{subscriber.id});
        
        const sub_segments = subscriber.getSegments(doc) orelse continue;
        for (sub_segments) |seg| {
            if (std.mem.eql(u8, seg.id, "CLM")) {
                const claim_id = seg.getElement(1) orelse "";
                const amount = seg.getElement(2) orelse "";
                std.debug.print("  Claim: {s} - ${s}\n", .{claim_id, amount});
            }
        }
    }

    // Find specific node
    if (tree.findNode("2")) |node| {
        std.debug.print("Found node with ID 2: Level {s}\n", .{node.level_code});
    }

    // Count nodes
    std.debug.print("Total nodes: {d}\n", .{tree.countNodes()});
}
```

## HL Level Codes (837P/837I)

### 837P Professional Claims
- **20**: Billing Provider
- **22**: Subscriber (Patient/Insured)
- **23**: Patient (when different from subscriber)

### 837I Institutional Claims
- **20**: Billing Provider
- **22**: Subscriber (Patient/Insured)
- **23**: Patient (when different from subscriber)

## Segment Range Calculation

The tree builder automatically calculates which segments belong to each HL node:

1. **HL Node Start**: Index of the HL segment itself
2. **HL Node End**: Index of the next HL segment (or end of document)
3. **Segments**: All segments between start and end belong to that HL node

This allows efficient extraction of data for each hierarchical level.

### Example:
```
Index  Segment
  0    ISA
  1    GS
  2    ST
  3    BHT
  4    HL*1**20*1      <- Provider starts at index 4
  5    NM1*85...       <- Provider segment
  6    N3*123...       <- Provider segment
  7    HL*2*1*22*0     <- Subscriber starts at index 7 (provider ends)
  8    NM1*IL...       <- Subscriber segment
  9    CLM...          <- Subscriber segment
 10    SE              <- Document end (subscriber ends)
```

Provider node: `segment_start=4, segment_end=7` (segments 4, 5, 6)
Subscriber node: `segment_start=7, segment_end=10` (segments 7, 8, 9)

## Tree Structure

### Single Root (Typical)
```
HL 1 [20] Billing Provider
├── HL 2 [22] Subscriber 1
│   └── HL 3 [23] Patient 1
└── HL 4 [22] Subscriber 2
    └── HL 5 [23] Patient 2
```

### Multiple Roots (Rare)
```
HL 1 [20] Billing Provider 1
├── HL 2 [22] Subscriber 1
HL 10 [20] Billing Provider 2
└── HL 11 [22] Subscriber 2
```

## Error Handling

The tree builder validates:
- ✅ At least one HL segment exists
- ✅ All HL segments have required elements (ID, level code)
- ✅ Parent IDs reference existing nodes
- ✅ At least one root node exists

### Error Types
- `error.NoHLSegments` - No HL segments found in document
- `error.MissingHLID` - HL segment missing HL01 (ID)
- `error.MissingLevelCode` - HL segment missing HL03 (level)
- `error.ParentNotFound` - HL segment references non-existent parent
- `error.NoRootNodes` - No root HL segments found

## Test Coverage

**8 unit tests** covering:
- ✅ Single root tree construction
- ✅ Parent-child relationships
- ✅ Multiple children per node
- ✅ Segment range calculation
- ✅ Node finding by ID
- ✅ Counting nodes and descendants
- ✅ Finding nodes by level code
- ✅ Error on missing HL segments

All tests passing with Zig 0.15.

## Performance Characteristics

- **Two-Pass Algorithm**:
  1. First pass: Build node map and identify relationships
  2. Second pass: Construct tree from root nodes
- **O(n) Time Complexity**: Where n is the number of HL segments
- **O(n) Space Complexity**: Stores all nodes in tree structure
- **Efficient Lookups**: HashMap for O(1) node lookup during construction

## Integration with Schema Processing

The HL tree provides the foundation for schema-driven processing:

1. **Schema Lookup**: Use `level_code` to find correct schema section
2. **Segment Processing**: Use `segment_start/segment_end` to process correct segments
3. **Nested Arrays**: Use parent-child relationships to build nested JSON arrays
4. **Loop Detection**: Parent-child structure eliminates need for heuristic loop detection

## Files

- `hl_tree.zig`: Main implementation (8 tests)
- `test_hl_tree.zig`: Real-world 837P sample file testing
- `README.md`: This documentation

## Testing

```bash
# Run all unit tests
zig test src/x12_parser/hl_tree.zig

# Test with real 837P file
zig run src/x12_parser/test_hl_tree.zig
```

## License

Part of the zX12 project - X12 EDI parser for healthcare claims (837P/837I).
