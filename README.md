# zX12 - X12 EDI Parser in Zig

zX12 is a library for parsing X12 EDI (Electronic Data Interchange) documents, with a specialized focus on healthcare claim formats (837P, 837I, 837D). 
## Features

- Parse standard X12 EDI documents
- Specialized support for healthcare claims (837)
    - Professional claims (837P)
    - Institutional claims (837I)
    - Dental claims (837D)
- Extract structured data from complex EDI files
- Clean JSON output for easy integration with web services
- C-compatible API for use from other languages with Arena allocation
## Installation

```bash
git clone https://github.com/jjw07006/zX12.git
cd zX12
zig build
```

## Usage

### Basic X12 Document Parsing
- Keep in mind the parser does minimal allocations, so the contents of the X12 document needs to outlive the Zig X12 Document structure and Claim837 structure.

```zig
const std = @import("std");
const x12 = @import("parser.zig");

pub fn main() !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Input X12 document
        const data = "ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER      *210101*1200*^*00501*000000001*0*P*:~...";

        // Parse document
        var document = x12.X12Document.init(allocator);
        defer document.deinit();
        try document.parse(data);

        // Access segments and elements
        if (document.getSegment("ST")) |st_segment| {
                std.debug.print("Transaction type: {s}\n", .{st_segment.elements.items[0].value});
        }
}
```

### Parsing 837 Healthcare Claims

```zig
const std = @import("std");
const x12 = @import("parser.zig");
const claim837 = @import("claim837.zig");

pub fn main() !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Input X12 document (837 claim)
        const data = "ISA*00*..."; // (837 claim data)

        // Parse X12 document
        var document = x12.X12Document.init(allocator);
        defer document.deinit();
        try document.parse(data);

        // Parse as 837 healthcare claim
        var claim = claim837.Claim837.init(allocator);
        defer claim.deinit();
        try claim.parse(&document);

        // Access claim data
        std.debug.print("Claim type: {s}\n", .{@tagName(claim.transaction_type)});
        std.debug.print("Sender: {s}\n", .{claim.sender_id});
        std.debug.print("Billing provider: {s}\n", .{claim.billing_provider.last_name});
        
        // Convert to JSON
        const json = try std.json.stringifyAlloc(allocator, claim, .{});
        defer allocator.free(json);
        std.debug.print("JSON: {s}\n", .{json});
}
```

## API Reference

### X12Document

The core parser for X12 documents:

- `init(allocator)` - Initialize a new X12Document
- `parse(data)` - Parse a raw X12 document
- `getSegment(id)` - Get the first segment with the specified ID
- `getSegments(id, allocator)` - Get all segments with the specified ID

### Claim837

Specialized parser for 837 healthcare claims:

- `init(allocator)` - Initialize a new 837 claim parser
- `parse(document)` - Parse an X12 document as an 837 claim
- `transaction_type` - Type of claim (professional, institutional, dental)
- `billing_provider` - Information about the billing provider
- `subscriber_loops` - List of subscriber information, patients, and claims

## License

[MIT License](https://opensource.org/licenses/MIT)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
