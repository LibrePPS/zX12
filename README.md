# zX12 - Schema-Based X12 EDI Parser in Zig

zX12 is a library for parsing X12 EDI (Electronic Data Interchange) documents with a flexible schema-based approach. While it has specialized support for healthcare claim formats (837P, 837I, 837D), the new schema system allows parsing virtually any X12 format.

> ⚠️ **Work in Progress**: This library is actively under development. APIs may change, and additional features are being added regularly.

## Features

- **Schema-based parsing** for maximum flexibility
- Parse any X12 EDI document with a matching schema
- Extract structured data with JSON schemas
- Clean JSON output for easy integration with web services
- Customizable field mapping and transformations
- C-compatible API for use from other languages

## Installation

```bash
git clone https://github.com/jjw07006/zX12.git
cd zX12
zig build
```

## Usage

### Schema-Based X12 Document Parsing

Our new schema-based approach allows for greater flexibility when parsing X12 documents:

```zig
const std = @import("std");
const x12 = @import("parser.zig");
const schema_parser = @import("schema_parser.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1. Load the schema file
    const schema_json = try loadFile(allocator, "./schema/837p.json");

    // 2. Load the X12 document
    const x12_data = try loadFile(allocator, "./samples/837p_example.x12");

    // 3. Parse the schema
    var schema = try schema_parser.Schema.fromJson(allocator, schema_json);
    defer schema.deinit();

    // 4. Parse the X12 document
    var document = x12.X12Document.init(allocator);
    defer document.deinit();
    try document.parse(x12_data);

    // 5. Use schema to parse the document
    var result = try schema_parser.parseWithSchema(allocator, &document, &schema);
    defer result.deinit();

    // 6. Convert to JSON string for output
    const json_output = try std.json.stringifyAlloc(allocator, result.value, .{.whitespace = .indent_2});
    defer allocator.free(json_output);
    
    std.debug.print("JSON: {s}\n", .{json_output});
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size + 1;

    return try file.reader().readAllAlloc(allocator, file_size);
}
```

### Basic X12 Document Parsing

The original direct parsing approach is still available:

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

> Note: The parser does minimal allocations, so the contents of the X12 document needs to outlive the Zig X12 Document structure.

## Schema Structure

Schemas are defined in JSON format with segments, elements, and field mappings:

```json
{
    "id": "837P",
    "description": "Health Care Claim: Professional",
    "version": "005010X222A1",
    "transaction_type": "837",
    "header": {
        "segments": [
            {
                "id": "ISA",
                "required": true,
                "elements": [
                    {
                        "position": 0,
                        "path": "interchange.auth_info_qualifier",
                        "expected_value": "00"
                    },
                    {
                        "position": 1,
                        "path": "interchange.auth_info",
                        "transform": ["trim_whitespace"]
                    }
                ]
            }
        ]
    },
    "loops": [
        {
            "id": "2000A",
            "name": "Billing Provider Loop",
            "trigger": {
                "segment_id": "HL",
                "element_position": 3,
                "value": "20"
            },
            "segments": [
                {
                    "id": "NM1",
                    "required": true,
                    "elements": [
                        {
                            "position": 1,
                            "path": "billing_provider.entity_type",
                            "value_mappings": [
                                {"value": "1", "mapped_value": "person"},
                                {"value": "2", "mapped_value": "organization"}
                            ]
                        },
                        {
                            "position": 2,
                            "path": "billing_provider.last_name"
                        }
                    ]
                }
            ],
            "loops": [
                // Nested loops
            ]
        }
    ]
}
```

### Handling Special Segments

Some segments like HI (diagnosis codes) need special handling with element patterns:

```json
{
    "id": "HI",
    "required": false,
    "process_all_elements": true,
    "element_patterns": [
        {
            "qualifier_position": 0,
            "qualifier_values": ["ABK", "ABF"],
            "target_collection": "diagnosis_codes",
            "component_mappings": [
                {
                    "component_position": 0,
                    "target_field": "qualifier"
                },
                {
                    "component_position": 1,
                    "target_field": "code"
                }
            ]
        }
    ]
}
```

## Schema Features

### Field Mappings

Map X12 element values to meaningful field names:

```json
{
  "position": 1,
  "path": "billing_provider.entity_type"
}
```

### Value Transformations

Apply transformations to field values:

```json
{
  "position": 1,
  "path": "interchange.auth_info",
  "transform": ["trim_whitespace"]
}
```

### Value Mappings

Map cryptic codes to meaningful values:

```json
{
  "position": 1,
  "path": "billing_provider.entity_type",
  "value_mappings": [
    {"value": "1", "mapped_value": "person"},
    {"value": "2", "mapped_value": "organization"}
  ]
}
```

### Composite Elements

Handle composite elements like diagnosis codes:

```json
{
  "component_mappings": [
    {
      "component_position": 0,
      "target_field": "qualifier"
    },
    {
      "component_position": 1,
      "target_field": "code"
    }
  ]
}
```

## Example X12 and JSON Output

### Input X12 Document (837P Example)

```
ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER      *210101*1200*^*00501*000000001*0*P*:~
GS*HC*SENDER*RECEIVER*20230101*1200*1*X*005010X222A1~
ST*837*0001*005010X222A1~
BHT*0019*00*CLAIM123*20230101*1200*CH~
NM1*41*2*ABC MEDICAL GROUP*****XX*1234567890~
N3*123 MAIN STREET*SUITE 100~
N4*ANYTOWN*CA*90210~
REF*EI*123456789~
PER*IC*JOHN DOE*TE*5551234567*FX*5559876543~
HL*1**20*1~
NM1*85*2*ABC MEDICAL GROUP*****XX*1234567890~
N3*123 MAIN STREET*SUITE 100~
N4*ANYTOWN*CA*90210~
HL*2*1*22*0~
SBR*P*18*******MC~
NM1*IL*1*SMITH*JOHN*A***MI*123456789A~
N3*456 OAK AVENUE~
N4*ANYTOWN*CA*90210~
DMG*D8*19500101*M~
NM1*PR*2*MEDICARE*****PI*12345~
N3*PO BOX 4567~
N4*MEDICARE CITY*CA*99999~
CLM*CLAIM123*500.50***11:B:1*Y*A*Y*Y~
HI*ABK:I10*ABF:J20.9*ABF:E11.9~
LX*1~
SV1*HC:99213*250.00*UN*1***1~
DTP*472*D8*20230101~
LX*2~
SV1*HC:85025*100.50*UN*1***1~
DTP*472*D8*20230101~
LX*3~
SV1*HC:J3301*150.00*UN*2***1~
DTP*472*D8*20230101~
SE*35*0001~
GE*1*1~
IEA*1*000000001~
```

### Output JSON

```json
{
    "interchange": {
        "auth_info_qualifier": "00",
        "auth_info": "",
        "security_qualifier": "00",
        "security_info": "",
        "sender_id_qualifier": "mutually_defined",
        "sender_id": "SENDER",
        "receiver_id_qualifier": "mutually_defined",
        "receiver_id": "RECEIVER",
        "date": "210101",
        "time": "1200",
        "repetition_separator": "^",
        "version_number": "00501",
        "control_number": "000000001",
        "ack_requested": "0",
        "usage_indicator": "production"
    },
    "functional_group": {
        "functional_id_code": "HC",
        "sender_code": "SENDER",
        "receiver_code": "RECEIVER",
        "date": "20230101",
        "time": "1200",
        "control_number": "1",
        "responsible_agency_code": "X",
        "version": "005010X222A1"
    },
    "transaction_set": {
        "id": "837",
        "control_number": "0001",
        "implementation_convention_reference": "005010X222A1"
    },
    "beginning_of_hierarchical_transaction": {
        "hierarchy_code": "0019",
        "transaction_type_code": "original",
        "reference_id": "CLAIM123",
        "date": "20230101",
        "time": "1200",
        "claim_type": "chargeable"
    },
    "1000A": {
        "submitter": {
            "entity_type_qualifier": "41",
            "entity_type": "organization",
            "last_name": "ABC MEDICAL GROUP",
            "first_name": "",
            "id_code_qualifier": "XX",
            "id": "1234567890"
        },
        "PER": [
            {
                "submitter_contact": {
                    "contact_function_code": "information_contact",
                    "name": "JOHN DOE",
                    "comm_number_qualifier": "telephone",
                    "comm_number": "5551234567"
                }
            }
        ]
    },
    "2000A": [
        {
            "billing_provider": {
                "hierarchical_id": "1",
                "hierarchical_parent_id": "",
                "hierarchical_level_code": "20",
                "hierarchical_child_code": "1",
                "entity_type_qualifier": "85",
                "entity_type": "organization",
                "last_name": "ABC MEDICAL GROUP",
                "first_name": "",
                "middle_name": "",
                "name_prefix": "",
                "id_code_qualifier": "npi",
                "id": "1234567890",
                "address1": "123 MAIN STREET",
                "address2": "SUITE 100",
                "city": "ANYTOWN",
                "state": "CA",
                "zip": "90210"
            },
            "2000B": [
                {
                    "subscriber": {
                        "hierarchical_id": "2",
                        "hierarchical_parent_id": "1",
                        "hierarchical_level_code": "22",
                        "hierarchical_child_code": "0",
                        "payer_responsibility": "primary",
                        "individual_relationship": "self",
                        "reference_identification": "",
                        "policy_name": "",
                        "insurance_type": "MC",
                        "entity_type_qualifier": "IL",
                        "entity_type": "person",
                        "last_name": "SMITH",
                        "first_name": "JOHN",
                        "middle_name": "A",
                        "id_code_qualifier": "member_id",
                        "id": "123456789A",
                        "address1": "123 MAIN STREET",
                        "address2": "SUITE 100",
                        "city": "ANYTOWN",
                        "state": "CA",
                        "zip": "90210",
                        "date_qualifier": "date_format_CCYYMMDD",
                        "birth_date": "19500101",
                        "gender": "male"
                    },
                    "2300": [
                        {
                            "claim": {
                                "claim_id": "CLAIM123",
                                "total_charges": "500.50",
                                "place_of_service": "B",
                                "frequency_code": "Y"
                            },
                            "diagnosis_codes": [
                                {
                                    "qualifier": "ABK",
                                    "code": "I10"
                                },
                                {
                                    "qualifier": "ABF",
                                    "code": "J20.9"
                                },
                                {
                                    "qualifier": "ABF",
                                    "code": "E11.9"
                                }
                            ],
                            "2400": [
                                {
                                    "service_line": {
                                        "line_number": "1",
                                        "procedure_code": "99213",
                                        "procedure_qualifier": "hcpcs_cpt",
                                        "charge_amount": "250.00",
                                        "unit_basis": "unit",
                                        "service_units": "1",
                                        "place_of_service": "",
                                        "diagnosis_pointers": "1",
                                        "date_qualifier": "472",
                                        "date_format_qualifier": "CCYYMMDD",
                                        "service_date": "20230101"
                                    }
                                },
                                {
                                    "service_line": {
                                        "line_number": "2",
                                        "procedure_code": "85025",
                                        "procedure_qualifier": "hcpcs_cpt",
                                        "charge_amount": "100.50",
                                        "unit_basis": "unit",
                                        "service_units": "1",
                                        "place_of_service": "",
                                        "diagnosis_pointers": "1",
                                        "date_qualifier": "472",
                                        "date_format_qualifier": "CCYYMMDD",
                                        "service_date": "20230101"
                                    }
                                },
                                {
                                    "service_line": {
                                        "line_number": "3",
                                        "procedure_code": "J3301",
                                        "procedure_qualifier": "hcpcs_cpt",
                                        "charge_amount": "150.00",
                                        "unit_basis": "unit",
                                        "service_units": "2",
                                        "place_of_service": "",
                                        "diagnosis_pointers": "1",
                                        "date_qualifier": "472",
                                        "date_format_qualifier": "CCYYMMDD",
                                        "service_date": "20230101"
                                    }
                                }
                            ]
                        }
                    ]
                }
            ]
        }
    ]
}
```

## API Reference

### X12Document

The core parser for X12 documents:

- `init(allocator)` - Initialize a new X12Document
- `parse(data)` - Parse a raw X12 document
- `getSegment(id)` - Get the first segment with the specified ID
- `getSegments(id, allocator)` - Get all segments with the specified ID

### Schema

The schema-based parser:

- `fromJson(allocator, json_string)` - Create a schema from JSON definition
- `parseWithSchema(allocator, document, schema)` - Parse an X12 document using a schema

### Legacy Claim837 (Still Available)

Specialized parser for 837 healthcare claims:

- `init(allocator)` - Initialize a new 837 claim parser
- `parse(document)` - Parse an X12 document as an 837 claim
- `transaction_type` - Type of claim (professional, institutional, dental)
- `billing_provider` - Information about the billing provider
- `subscriber_loops` - List of subscriber information, patients, and claims

## Roadmap 🚧

We're actively working on improving zX12. Upcoming features include:

- Additional schema examples for common document types
- Better error handling and validation
- Schema validation tools
- Performance optimizations

## License

[MIT License](https://opensource.org/licenses/MIT)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
```