# JSON Builder Module

## Overview
The JSON builder module provides a flexible, memory-efficient way to construct JSON output with lazy array allocation and path-based access. Arrays are only created when data is actually pushed to them, minimizing memory overhead for sparse hierarchical structures.

## Key Components

### Data Structures

#### `JsonValue`
Union type representing any JSON value:
- `null_value`: void
- `bool_value`: bool
- `number`: f64
- `string`: []const u8 (owned)
- `array`: *JsonArray
- `object`: *JsonObject

Each value owns its memory and implements `deinit()` for cleanup.

#### `JsonArray`
Dynamically-sized array of JSON values:
- `items`: std.ArrayList(JsonValue) - Array contents
- `allocator`: std.mem.Allocator - For memory management

**Methods:**
- `init(allocator) -> JsonArray` - Create empty array
- `deinit()` - Free all array contents recursively
- `append(value)` - Add value to array
- `len() -> usize` - Get current length

#### `JsonObject`
Key-value map for JSON objects:
- `fields`: StringHashMap(JsonValue) - Object fields
- `allocator`: std.mem.Allocator - For memory management

**Methods:**
- `init(allocator) -> JsonObject` - Create empty object
- `deinit()` - Free all fields recursively
- `put(key, value)` - Set field value
- `get(key) -> ?JsonValue` - Get field value (immutable)
- `getPtr(key) -> ?*JsonValue` - Get mutable field pointer

#### `JsonBuilder`
Main builder with path-based access:
- `root`: JsonObject - Root object
- `allocator`: std.mem.Allocator - For memory management

**Methods:**
- `init(allocator) -> JsonBuilder` - Create new builder
- `deinit()` - Free all contents recursively
- `set(path, value)` - Set value at dot-separated path
- `get(path) -> ?JsonValue` - Get value at path (immutable)
- `getOrCreateArray(path) -> *JsonArray` - Get or create array at path
- `pushToArray(path, object)` - Push object to array (creates if needed)
- `stringify(output, allocator)` - Serialize to JSON string

### Path-Based Access

The builder uses dot-separated paths for nested access:
- `"name"` → `{ "name": "..." }`
- `"person.name.first"` → `{ "person": { "name": { "first": "..." } } }`
- `"provider.subscribers"` → `{ "provider": { "subscribers": [...] } }`

Intermediate objects are created automatically as needed.

## Lazy Array Allocation

Arrays are **only** created when:
1. First call to `getOrCreateArray(path)`
2. First call to `pushToArray(path, obj)`

This is critical for 837 claims where:
- Not all providers have subscribers
- Not all subscribers have claims
- Not all claims have service lines

Without lazy allocation, the JSON would contain many empty `[]` arrays. With lazy allocation, arrays only exist when they have data.

## Usage Examples

### Basic Object Creation

```zig
var builder = JsonBuilder.init(allocator);
defer builder.deinit();

// Set simple values
const name = try allocator.dupe(u8, "John Doe");
try builder.set("name", JsonValue{ .string = name });
try builder.set("age", JsonValue{ .number = 30 });
try builder.set("active", JsonValue{ .bool_value = true });
```

### Nested Objects

```zig
// Automatically creates intermediate objects
const first = try allocator.dupe(u8, "John");
try builder.set("person.name.first", JsonValue{ .string = first });

const last = try allocator.dupe(u8, "Doe");
try builder.set("person.name.last", JsonValue{ .string = last });

// Result: { "person": { "name": { "first": "John", "last": "Doe" } } }
```

### Arrays with Lazy Allocation

```zig
// Array doesn't exist yet - builder root is empty

// First push creates the array
var provider1 = try allocator.create(JsonObject);
provider1.* = JsonObject.init(allocator);
const npi1 = try allocator.dupe(u8, "1234567890");
try provider1.put("npi", JsonValue{ .string = npi1 });

try builder.pushToArray("providers", provider1);

// Now array exists with 1 item

// Second push adds to existing array
var provider2 = try allocator.create(JsonObject);
provider2.* = JsonObject.init(allocator);
const npi2 = try allocator.dupe(u8, "0987654321");
try provider2.put("npi", JsonValue{ .string = npi2 });

try builder.pushToArray("providers", provider2);

// Now array has 2 items
```

### Nested Arrays

```zig
// Create provider with nested claims array
var claim = try allocator.create(JsonObject);
claim.* = JsonObject.init(allocator);
const claim_id = try allocator.dupe(u8, "CLAIM-001");
try claim.put("claim_id", JsonValue{ .string = claim_id });

// This creates: provider.claims array if it doesn't exist
try builder.pushToArray("provider.claims", claim);
```

### Serialization

```zig
var output = std.ArrayList(u8){};
defer output.deinit(allocator);

try builder.stringify(&output, allocator);

// Write to file
const file = try std.fs.cwd().createFile("output.json", .{});
defer file.close();
try file.writeAll(output.items);

// Or print to stdout
std.debug.print("{s}\n", .{output.items});
```

## 837 Processing Pattern

For X12 837 claims, the typical pattern is:

```zig
var builder = JsonBuilder.init(allocator);
defer builder.deinit();

// Set header fields
try builder.set("interchange.sender_id", ...);
try builder.set("functional_group.date", ...);

// For each provider HL
var provider_obj = try allocator.create(JsonObject);
provider_obj.* = JsonObject.init(allocator);
try provider_obj.put("npi", ...);

// Add provider to root array
try builder.pushToArray("billing_providers", provider_obj);

// For each subscriber HL under this provider
var subscriber_obj = try allocator.create(JsonObject);
subscriber_obj.* = JsonObject.init(allocator);
try subscriber_obj.put("member_id", ...);

// IMPORTANT: This requires navigating back to provider object
// We'll need to track current provider/subscriber context
// This will be handled by the document processor
```

## Memory Management

### Ownership Rules

1. **JsonBuilder owns root**: Calling `builder.deinit()` frees everything
2. **Strings are owned**: Always duplicate strings before passing to builder
3. **Objects are owned**: Objects passed to `pushToArray()` are owned by the array
4. **Values are owned**: Values passed to `set()` or `put()` are owned by the parent

### Memory Leak Prevention

```zig
// ✓ CORRECT - string is owned by builder
const name = try allocator.dupe(u8, "John");
try builder.set("name", JsonValue{ .string = name });
// Don't free name - builder owns it now

// ✗ INCORRECT - will double-free
const name = try allocator.dupe(u8, "John");
try builder.set("name", JsonValue{ .string = name });
allocator.free(name); // DON'T DO THIS!

// ✗ INCORRECT - will use-after-free
var temp_buffer: [100]u8 = undefined;
const name = std.fmt.bufPrint(&temp_buffer, "John", .{}) catch unreachable;
try builder.set("name", JsonValue{ .string = name });
// temp_buffer will be freed when it goes out of scope!
```

### Testing Memory Leaks

All tests use `std.testing.allocator` which detects memory leaks:

```zig
test "no memory leaks" {
    const allocator = testing.allocator;
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();
    
    // ... use builder ...
    
    // If deinit() doesn't free everything, test will fail
}
```

## Test Coverage

The module includes 9 comprehensive tests:
1. **create empty JSON builder** - Basic initialization
2. **set simple string value** - Simple field setting
3. **set nested object path** - Path parsing and object creation
4. **create and access array** - Manual array creation
5. **push to array with path** - Lazy array creation
6. **nested array path** - Multi-level array paths
7. **stringify simple object** - Basic serialization
8. **stringify nested object** - Nested structure serialization
9. **stringify with array** - Array serialization

All tests pass with zero memory leaks.

## Design Decisions

### Why Lazy Arrays?

In X12 documents:
- 80% of providers might have 1 subscriber, 20% have multiple
- 60% of subscribers might have 1 claim, 40% have multiple  
- Some claims have 0 service lines (summary only)

Pre-allocating all arrays would waste memory. Lazy allocation creates arrays only when needed.

### Why Path-Based Access?

Schema element mappings use paths like `"subscriber.name.last"`. Path-based access allows direct mapping from schema to JSON without navigating intermediate objects manually.

### Why Owned Strings?

JSON strings must live as long as the JsonBuilder. If we borrowed strings from X12 segments, we'd need to keep the entire X12Document alive. Owned strings let us free the X12 document after processing.

### Why Not Use std.json?

Zig's standard library JSON module is designed for parsing JSON, not building it programmatically. It doesn't support:
- Lazy array allocation
- Path-based nested access
- Incremental construction

Our custom builder is optimized for the X12 → JSON transformation workflow.

## Performance Considerations

### Memory Overhead

- Each JsonValue: ~24 bytes (union + tag)
- Each JsonObject: ~48 bytes (HashMap overhead)
- Each JsonArray: ~32 bytes (ArrayList overhead)
- Strings: length + 1 byte per character

For a typical 837P with:
- 100 providers × 2 subscribers × 3 claims × 5 service lines = 3,000 objects
- Average 20 fields per object = 60,000 values
- Total memory: ~2-3 MB

### Time Complexity

- `set(path, value)`: O(depth) where depth is path levels
- `get(path)`: O(depth)
- `pushToArray(path, obj)`: O(depth + 1) for push
- `stringify()`: O(n) where n is total values

### Optimization Opportunities

For future optimization:
- **String interning**: Common keys like "name", "date" appear thousands of times
- **Arena allocation**: Allocate all JSON structures in single arena for faster bulk free
- **Streaming output**: Write JSON directly to file instead of building in memory

## Integration with Document Processor

The document processor will use JsonBuilder like this:

```zig
// Create builder
var builder = JsonBuilder.init(allocator);
defer builder.deinit();

// Process header segments
try processHeaderSegments(&builder, document, schema);

// Process sequential sections
try processSequentialSections(&builder, document, schema);

// Process hierarchical structure
try processHierarchy(&builder, tree, document, schema);

// Process trailer segments
try processTrailerSegments(&builder, document, schema);

// Serialize and write
var output = std.ArrayList(u8){};
defer output.deinit(allocator);
try builder.stringify(&output, allocator);
try file.writeAll(output.items);
```

Each processing function builds its portion of the JSON using path-based access and lazy arrays.
