# zX12 JSON Schema Documentation

This document provides comprehensive documentation for the zX12 JSON schema system. The schema defines how X12 EDI documents are parsed and transformed into structured JSON output. This guide covers schema structure, parser behavior, design patterns, and best practices.

## Table of Contents

1. [Overview](#overview)
2. [Parser Behavior & Conventions](#parser-behavior--conventions)
3. [Schema Structure](#schema-structure)
4. [Element Mapping](#element-mapping)
5. [Segment Definitions](#segment-definitions)
6. [Groups and Qualifiers](#groups-and-qualifiers)
7. [Hierarchical Structure](#hierarchical-structure)
8. [Non-Hierarchical Loops](#non-hierarchical-loops)
9. [Repeating Elements](#repeating-elements)
10. [Common Patterns](#common-patterns)
11. [Best Practices](#best-practices)
12. [Troubleshooting](#troubleshooting)

---

## Overview

The zX12 schema is a declarative JSON configuration that instructs the parser how to transform X12 EDI segments into structured JSON. It handles:

- Segment-to-JSON mapping
- Hierarchical structures (HL segments)
- Nested loops and sub-loops
- Composite element extraction
- Value transformations and mappings
- Segment grouping (e.g., NM1 + N3 + N4 + REF)

**Key Schema Files:**
- `schema/837i.json` - Institutional Health Care Claim (837I)
- `schema/837p.json` - Professional Health Care Claim (837P)

---

## Parser Behavior & Conventions

### Critical: Element Indexing

**The most important concept to understand:** The parser stores segment data with the segment ID at `elements[0]`, and all subsequent data elements follow.

For example, the X12 segment:
```
NM1*IL*1*DOE*JANE*A***MI*1008716534
```

Is stored internally as:
```
elements[0] = "NM1"
elements[1] = "IL"
elements[2] = "1"
elements[3] = "DOE"
elements[4] = "JANE"
elements[5] = "A"
elements[6] = ""
elements[7] = ""
elements[8] = "MI"
elements[9] = "1008716534"
```

**Schema Position Convention:**

When you specify `pos: 0` in the schema, the parser accesses `elements[pos + 1]`, meaning:
- Schema `pos: 0` → `elements[1]` → First data element
- Schema `pos: 1` → `elements[2]` → Second data element
- Schema `pos: 8` → `elements[9]` → Ninth data element

**Example:**

```json
{
  "id": "NM1",
  "elements": [
    { "pos": 0, "path": "entity_identifier", "expect": "IL" },
    { "pos": 1, "path": "entity_type", "map": { "1": "Person", "2": "Organization" } },
    { "pos": 2, "path": "last_name" },
    { "pos": 3, "path": "first_name" }
  ]
}
```

For segment `NM1*IL*1*DOE*JANE`, this maps to:
```json
{
  "entity_identifier": "IL",
  "entity_type": "Person",
  "last_name": "DOE",
  "first_name": "JANE"
}
```

### Processing Order

The parser processes documents in this order:

1. **Transaction Header** (`transaction_header`)
2. **Sequential Sections** (`sequential_sections`) - Non-hierarchical sections at the start
3. **Hierarchical Structure** (`hierarchical_structure`) - Main HL-based hierarchy
4. **Transaction Trailer** (`transaction_trailer`)

Within each hierarchical level or loop:

1. **Group Pass** - Process segments with `group` definitions first
2. **Individual Segment Pass** - Process remaining segments
3. **Nested Loops** - Process nested loops with explicit boundaries

### Segment Processing Rules

- **Processed Segments Map**: Segments are marked as processed to prevent double-processing
- **Group Priority**: Grouped segments are processed first to claim all group members
- **Boundary Enforcement**: Nested loops receive explicit start/end boundaries
- **No Premature Breaking**: Parent loops don't stop when encountering nested loop triggers (segments may appear after nested loops)

---

## Schema Structure

### Top-Level Keys

```json
{
  "schema_version": "1.0.0",
  "transaction": { /* Transaction metadata */ },
  "transaction_header": { /* Header segments */ },
  "transaction_trailer": { /* Trailer segments */ },
  "sequential_sections": [ /* Non-hierarchical sections */ ],
  "hierarchical_structure": { /* HL-based hierarchy */ }
}
```

### 1. `transaction`

Metadata about the X12 transaction set:

```json
"transaction": {
  "id": "837I",
  "version": "005010X223A2",
  "type": "837",
  "description": "Health Care Claim: Institutional"
}
```

- `id`: Transaction set identifier
- `version`: Implementation guide version
- `type`: Base transaction type
- `description`: Human-readable description

### 2. `transaction_header`

Defines segments at the beginning of every transaction (ISA, GS, ST, BHT):

```json
"transaction_header": {
  "segments": [
    {
      "id": "ISA",
      "elements": [
        { "pos": 0, "path": "interchange.auth_info_qualifier", "expect": "00" },
        { "pos": 1, "path": "interchange.auth_info", "transform": ["trim"] }
      ]
    }
  ]
}
```

### 3. `transaction_trailer`

Defines segments at the end of every transaction (SE, GE, IEA):

```json
"transaction_trailer": {
  "segments": [
    { "id": "SE", "elements": [...] },
    { "id": "GE", "elements": [...] },
    { "id": "IEA", "elements": [...] }
  ]
}
```

### 4. `sequential_sections`

Non-hierarchical sections that appear in sequence (e.g., Submitter, Receiver):

```json
"sequential_sections": [
  {
    "name": "Submitter",
    "output_path": "submitter",
    "trigger": { "segment": "NM1", "qualifier": [0, "41"] },
    "segments": [
      {
        "id": "NM1",
        "elements": [
          { "pos": 0, "path": "entity_identifier", "expect": "41" },
          { "pos": 2, "path": "organization_name" }
        ]
      },
      {
        "id": "PER",
        "multiple": true,
        "output_array": "contacts",
        "elements": [...]
      }
    ]
  }
]
```

**Fields:**
- `name`: Descriptive name
- `output_path`: JSON key where data is stored
- `trigger`: Segment and qualifier that marks section start
  - `segment`: Segment ID
  - `qualifier`: `[position, value]` to match
- `segments`: Segment definitions in this section

### 5. `hierarchical_structure`

The main HL-based hierarchy (most complex part):

```json
"hierarchical_structure": {
  "output_array": "billing_providers",
  "levels": {
    "20": {
      "name": "Billing Provider",
      "segments": [...],
      "child_levels": ["22"]
    },
    "22": {
      "name": "Subscriber",
      "output_array": "subscribers",
      "segments": [...],
      "child_levels": ["23"],
      "non_hierarchical_loops": [...]
    }
  }
}
```

**Fields:**
- `output_array`: Top-level array name for root HL instances
- `levels`: Object keyed by HL level code
  - `name`: Descriptive name
  - `output_array`: Array name for multiple instances under parent (optional)
  - `segments`: Segment definitions
  - `child_levels`: Array of valid child HL codes
  - `non_hierarchical_loops`: Nested loops within this level

---

## Element Mapping

Element mapping objects define how segment elements are extracted and stored.

### Basic Structure

```json
{
  "pos": 0,
  "path": "field_name",
  "expect": "expected_value",
  "map": { "X": "Mapped Value" },
  "transform": ["trim"],
  "optional": true,
  "composite": [0]
}
```

### Field Reference

#### `pos` (required)
Zero-based position in the segment data (parser adds 1 when accessing).

```json
{ "pos": 0, "path": "qualifier" }  // Accesses elements[1]
{ "pos": 5, "path": "zip_code" }   // Accesses elements[6]
```

#### `path` (required)
Dot-notation path where value is stored in JSON output. Use empty string `""` for flattening.

```json
{ "pos": 0, "path": "interchange.sender_id" }
{ "pos": 1, "path": "name" }
{ "pos": 2, "path": "" }  // Flatten: use qualifier as key, this as value
```

#### `expect` (optional)
Expected value for validation. Useful for trigger segments.

```json
{ "pos": 0, "path": "entity_type", "expect": "IL" }
```

#### `map` (optional)
Value translation mapping (code to human-readable).

```json
{
  "pos": 1,
  "path": "entity_type",
  "map": {
    "1": "Person",
    "2": "Organization"
  }
}
```

For segment with `*1*`, outputs:
```json
{ "entity_type": "Person" }
```

#### `transform` (optional)
Array of transformations to apply.

```json
{ "pos": 1, "path": "auth_info", "transform": ["trim"] }
```

Available transformations:
- `trim`: Remove leading/trailing whitespace

#### `optional` (optional)
If true, element may be missing without error.

```json
{ "pos": 5, "path": "middle_name", "optional": true }
```

#### `composite` (optional)
Array of component indices to extract from composite elements (`:` delimited).

For segment: `SV2*0305:HC:22505*HC:22505:J2270*100`

```json
{
  "pos": 0,
  "path": "procedure_code",
  "composite": [1]  // Extracts "22505" from "0305:HC:22505"
}
```

Component extraction example:
```
Raw value: "0305:HC:22505"
Split by ':' → ["0305", "HC", "22505"]
composite: [1] → "HC"
composite: [2] → "22505"
```

#### `seg` (optional)
Used in grouped segments to specify which segment this element comes from.

```json
{
  "id": "NM1",
  "group": ["NM1", "N3", "N4", "REF"],
  "elements": [
    { "seg": "NM1", "pos": 2, "path": "name" },
    { "seg": "N3", "pos": 0, "path": "address_line_1" },
    { "seg": "N4", "pos": 0, "path": "city" }
  ]
}
```

---

## Segment Definitions

### Basic Segment

```json
{
  "id": "BHT",
  "elements": [
    { "pos": 0, "path": "hierarchical_structure_code" },
    { "pos": 1, "path": "transaction_set_purpose_code" },
    { "pos": 2, "path": "reference_identification" }
  ]
}
```

### Optional Segment

```json
{
  "id": "PWK",
  "optional": true,
  "elements": [...]
}
```

### Multiple Segment (Repeating)

```json
{
  "id": "DTP",
  "multiple": true,
  "elements": [
    { "pos": 0, "path": "date_qualifier" },
    { "pos": 1, "path": "date_format" },
    { "pos": 2, "path": "date" }
  ]
}
```

With `multiple: true`, creates an array of objects.

### Multiple with Output Array

```json
{
  "id": "PER",
  "multiple": true,
  "output_array": "contacts",
  "elements": [...]
}
```

Stores multiple instances in a named array: `{ "contacts": [...] }`

### Multiple with Qualifier Mapping

Used for segments that appear multiple times with different qualifiers creating separate fields:

```json
{
  "id": "REF",
  "multiple": true,
  "elements": [
    {
      "pos": 0,
      "map": {
        "EI": "employer_id",
        "SY": "ssn",
        "F8": "originating_reference"
      }
    },
    { "pos": 1, "path": "" }
  ]
}
```

For segments:
```
REF*EI*123456789
REF*SY*987654321
```

Outputs:
```json
{
  "employer_id": "123456789",
  "ssn": "987654321"
}
```

**Note:** The empty `path: ""` on the second element causes value flattening.

---

## Groups and Qualifiers

### Groups

Groups define segments that travel together (e.g., name and address information).

**Important:** `group` is an **array of segment IDs**, not a boolean.

```json
{
  "id": "NM1",
  "qualifier": [0, "85"],
  "group": ["NM1", "N3", "N4", "REF", "PER"],
  "elements": [
    { "seg": "NM1", "pos": 0, "path": "entity_identifier", "expect": "85" },
    { "seg": "NM1", "pos": 2, "path": "organization_name" },
    { "seg": "N3", "pos": 0, "path": "address_line_1" },
    { "seg": "N4", "pos": 0, "path": "city" },
    { "seg": "N4", "pos": 1, "path": "state" },
    { "seg": "REF", "pos": 0, "path": "reference_id_qualifier" },
    { "seg": "REF", "pos": 1, "path": "reference_id" }
  ]
}
```

**How Groups Work:**

1. Parser processes grouped segments **first** in a dedicated pass
2. All segments in the group are "claimed" and marked as processed
3. Elements use `seg` field to specify which group member they extract from
4. Group members must appear consecutively in the X12 file

**Processing Example:**

For X12:
```
NM1*85*2*BEST MEDICAL ASSOCIATES LLC*****XX*0123456789
N3*222 HEALTHY STREET*SUITE 200
N4*HERNDON*VA*201714444*USA
REF*EI*123401234
```

The group creates a single object:
```json
{
  "entity_identifier": "85",
  "organization_name": "BEST MEDICAL ASSOCIATES LLC",
  "address_line_1": "222 HEALTHY STREET",
  "city": "HERNDON",
  "state": "VA",
  "reference_id_qualifier": "EI",
  "reference_id": "123401234"
}
```

### Qualifiers

Qualifiers distinguish different uses of the same segment type (like different NM1 entities).

```json
{
  "id": "NM1",
  "qualifier": [0, "IL"],
  "elements": [
    { "pos": 0, "path": "entity_identifier", "expect": "IL" },
    { "pos": 2, "path": "last_name" }
  ]
}
```

**Qualifier Format:** `[position, expected_value]`

- `position`: Element position to check (0-based schema position)
- `expected_value`: Value that must match

**Common NM1 Qualifiers:**

- `"41"` - Submitter
- `"40"` - Receiver
- `"85"` - Billing Provider
- `"IL"` - Insured/Subscriber
- `"PR"` - Payer
- `"QC"` - Patient
- `"82"` - Rendering Provider
- `"72"` - Attending Physician

### Multiple NM1 Groups with Qualifiers

```json
{
  "id": "NM1",
  "multiple": true,
  "group": ["NM1", "N3", "N4", "REF"],
  "elements": [
    {
      "seg": "NM1",
      "pos": 0,
      "path": "entity_type",
      "map": {
        "71": "attending_physician",
        "72": "operating_physician",
        "82": "rendering_provider"
      }
    },
    { "seg": "NM1", "pos": 2, "path": "name" },
    { "seg": "N3", "pos": 0, "path": "address" }
  ]
}
```

Creates separate objects keyed by the mapped qualifier value.

---

## Hierarchical Structure

The `hierarchical_structure` defines HL-based hierarchies using the `HL` segment.

### HL Segment Format

```
HL*id*parent_id*level_code*children_flag
```

Example:
```
HL*1**20*1       // Billing Provider (level 20), has children
HL*2*1*22*0      // Subscriber (level 22), parent is 1, no children
HL*3*2*23*0      // Patient (level 23), parent is 2, no children
```

### Level Definition

```json
"hierarchical_structure": {
  "output_array": "billing_providers",
  "levels": {
    "20": {
      "name": "Billing Provider",
      "segments": [
        { "id": "PRV", "optional": true, "elements": [...] },
        {
          "id": "NM1",
          "qualifier": [0, "85"],
          "group": ["NM1", "N3", "N4", "REF"],
          "elements": [...]
        }
      ],
      "child_levels": ["22"]
    },
    "22": {
      "name": "Subscriber",
      "output_array": "subscribers",
      "segments": [...],
      "child_levels": ["23"],
      "non_hierarchical_loops": [...]
    },
    "23": {
      "name": "Patient",
      "output_array": "patients",
      "segments": [...],
      "child_levels": [],
      "non_hierarchical_loops": [
        {
          "name": "Claims",
          "trigger": "CLM",
          "output_array": "claims",
          "segments": [...]
        }
      ]
    }
  }
}
```

### Level Fields

- `code`: HL level code (key in `levels` object)
- `name`: Descriptive name
- `output_array`: Array name for storing multiple instances (optional for root)
- `segments`: Segment definitions for this level
- `child_levels`: Array of valid child HL codes
- `non_hierarchical_loops`: Loops nested within this level

### Nesting Example

For 837I transaction:

```
Level 20 (Billing Provider)
  └─ Level 22 (Subscriber)
       └─ Level 23 (Patient)
            └─ CLM Loop (Claims)
                 └─ LX Loop (Service Lines)
                      └─ LIN Loop (Drug Identification)
                      └─ SVD Loop (Line Adjudication)
```

JSON output structure:
```json
{
  "billing_providers": [
    {
      "subscribers": [
        {
          "patients": [
            {
              "claims": [
                {
                  "service_lines": [
                    {
                      "drug_identification": [...],
                      "line_adjudication": [...]
                    }
                  ]
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

---

## Non-Hierarchical Loops

Loops that are triggered by a specific segment (not HL) and can repeat.

### Basic Loop

```json
{
  "name": "Claims",
  "trigger": "CLM",
  "output_array": "claims",
  "segments": [
    {
      "id": "CLM",
      "elements": [
        { "pos": 0, "path": "claim_id" },
        { "pos": 1, "path": "total_charge" }
      ]
    },
    {
      "id": "DTP",
      "multiple": true,
      "elements": [...]
    }
  ]
}
```

**Fields:**
- `name`: Descriptive name
- `trigger`: Segment ID that starts each loop instance
- `output_array`: Array name for storing loop instances
- `segments`: Segment definitions within the loop
- `nested_loops`: Sub-loops within this loop (optional)

### Nested Loops

Loops can contain nested loops:

```json
{
  "name": "Claims",
  "trigger": "CLM",
  "output_array": "claims",
  "segments": [...],
  "nested_loops": [
    {
      "name": "Service Lines",
      "trigger": "LX",
      "output_array": "service_lines",
      "segments": [
        {
          "id": "LX",
          "elements": [{ "pos": 0, "path": "line_number" }]
        },
        {
          "id": "SV2",
          "elements": [...]
        }
      ],
      "nested_loops": [
        {
          "name": "Drug Identification",
          "trigger": "LIN",
          "output_array": "drug_identification",
          "segments": [...]
        }
      ]
    }
  ]
}
```

### Loop Boundaries

The parser enforces strict boundaries for nested loops:

1. **Instance Boundary**: Loop instance ends at next trigger of same loop
2. **Nested Boundary**: Parent loop passes explicit end index to nested loops
3. **Processed Tracking**: Segments processed by nested loops are marked

**Example Processing:**

```
CLM*ABC0001*100     ← Claim 1 starts
DTP*434*D8*20190101
LX*1                ← Service Line 1 starts
SV2*...
LIN*...             ← Drug ID nested in Service Line 1
LX*2                ← Service Line 2 starts (ends Service Line 1)
SV2*...
CLM*ABC0002*200     ← Claim 2 starts (ends Claim 1)
```

Boundaries:
- Claim 1: segments 0-7
- Claim 2: segments 8+
- Service Line 1: segments 2-4
- Service Line 2: segments 5-7

---

## Repeating Elements

For segments with repeating composite element patterns (like HI - Health Care Information).

### Structure

```json
{
  "id": "HI",
  "multiple": true,
  "optional": true,
  "repeating_elements": {
    "all": true,
    "separator": ":",
    "patterns": [
      {
        "when_qualifier": ["ABK", "ABF"],
        "output_array": "diagnosis_codes",
        "fields": [
          { "component": 0, "name": "qualifier" },
          { "component": 1, "name": "code" }
        ]
      },
      {
        "when_qualifier": ["BF", "BR"],
        "output_array": "procedure_codes",
        "fields": [
          { "component": 0, "name": "qualifier" },
          { "component": 1, "name": "code" },
          { "component": 2, "name": "modifier_1" }
        ]
      }
    ]
  }
}
```

### Fields

- `all`: Process all elements in segment (true) or specific positions
- `separator`: Delimiter for composite components (typically `:`)
- `patterns`: Array of pattern definitions

**Pattern Fields:**
- `when_qualifier`: Array of qualifier values to match (component 0)
- `output_array`: Array name for this pattern's data
- `fields`: Component mappings
  - `component`: 0-based component index within composite
  - `name`: JSON field name

### Example

For segment:
```
HI*ABK:I10*ABF:E11.9*BF:87.44:1:2
```

Components:
- `ABK:I10` → splits to `["ABK", "I10"]`
- `ABF:E11.9` → splits to `["ABF", "E11.9"]`
- `BF:87.44:1:2` → splits to `["BF", "87.44", "1", "2"]`

Output:
```json
{
  "diagnosis_codes": [
    { "qualifier": "ABK", "code": "I10" },
    { "qualifier": "ABF", "code": "E11.9" }
  ],
  "procedure_codes": [
    { "qualifier": "BF", "code": "87.44", "modifier_1": "1", "modifier_2": "2" }
  ]
}
```

---

## Common Patterns

### Pattern 1: Entity Identification (NM1 Group)

**Use Case:** Identifying a person or organization with address and references.

```json
{
  "id": "NM1",
  "qualifier": [0, "85"],
  "group": ["NM1", "N3", "N4", "REF", "PER"],
  "elements": [
    { "seg": "NM1", "pos": 0, "path": "entity_identifier", "expect": "85" },
    { "seg": "NM1", "pos": 1, "path": "entity_type", "map": { "1": "Person", "2": "Organization" } },
    { "seg": "NM1", "pos": 2, "path": "name" },
    { "seg": "N3", "pos": 0, "path": "address_line_1" },
    { "seg": "N3", "pos": 1, "path": "address_line_2" },
    { "seg": "N4", "pos": 0, "path": "city" },
    { "seg": "N4", "pos": 1, "path": "state" },
    { "seg": "N4", "pos": 2, "path": "zip_code" },
    { "seg": "REF", "pos": 0, "path": "reference_qualifier" },
    { "seg": "REF", "pos": 1, "path": "reference_id" },
    { "seg": "PER", "pos": 1, "path": "contact_name" },
    { "seg": "PER", "pos": 3, "path": "phone" }
  ]
}
```

### Pattern 2: Multiple References (REF with Qualifier Mapping)

**Use Case:** Different types of reference numbers creating separate fields.

```json
{
  "id": "REF",
  "multiple": true,
  "elements": [
    {
      "pos": 0,
      "map": {
        "EI": "employer_id",
        "SY": "ssn",
        "F8": "originating_reference",
        "G2": "provider_commercial_number"
      }
    },
    { "pos": 1, "path": "" }
  ]
}
```

### Pattern 3: Date/Time Patterns (DTP)

**Use Case:** Multiple dates with qualifiers.

```json
{
  "id": "DTP",
  "multiple": true,
  "elements": [
    {
      "pos": 0,
      "path": "qualifier",
      "map": {
        "434": "statement_date",
        "435": "admission_date",
        "096": "discharge_date"
      }
    },
    {
      "pos": 1,
      "path": "format",
      "map": {
        "D8": "CCYYMMDD",
        "RD8": "Date Range"
      }
    },
    { "pos": 2, "path": "date" }
  ]
}
```

### Pattern 4: Service Line with Nested Loops

**Use Case:** Service lines containing drug identification and adjudication.

```json
{
  "name": "Service Lines",
  "trigger": "LX",
  "output_array": "service_lines",
  "segments": [
    {
      "id": "LX",
      "elements": [{ "pos": 0, "path": "line_number" }]
    },
    {
      "id": "SV2",
      "elements": [
        { "pos": 0, "path": "procedure_code", "composite": [1] },
        { "pos": 1, "path": "line_charge" }
      ]
    }
  ],
  "nested_loops": [
    {
      "name": "Drug Identification",
      "trigger": "LIN",
      "output_array": "drug_identification",
      "segments": [
        {
          "id": "LIN",
          "elements": [
            { "pos": 1, "path": "product_id_qualifier" },
            { "pos": 2, "path": "product_id" }
          ]
        }
      ]
    },
    {
      "name": "Line Adjudication",
      "trigger": "SVD",
      "output_array": "line_adjudication",
      "segments": [
        {
          "id": "SVD",
          "elements": [
            { "pos": 0, "path": "payer_id" },
            { "pos": 1, "path": "paid_amount" }
          ]
        }
      ]
    }
  ]
}
```

### Pattern 5: Diagnosis Codes (HI with Repeating Elements)

**Use Case:** Multiple diagnosis codes in composite format.

```json
{
  "id": "HI",
  "multiple": true,
  "optional": true,
  "repeating_elements": {
    "all": true,
    "separator": ":",
    "patterns": [
      {
        "when_qualifier": ["ABK", "ABF", "ABJ"],
        "output_array": "diagnosis_codes",
        "fields": [
          { "component": 0, "name": "qualifier" },
          { "component": 1, "name": "code" }
        ]
      }
    ]
  }
}
```

---

## Best Practices

### 1. Element Position Mapping

**Always remember:** Schema `pos` is 0-based, but parser accesses `elements[pos + 1]`.

✅ **Correct:**
```json
{ "pos": 0, "path": "qualifier" }  // Accesses first data element
```

❌ **Incorrect:**
```json
{ "pos": 1, "path": "qualifier" }  // Would skip first element
```

### 2. Group Definitions

**Always use array for `group` field:**

✅ **Correct:**
```json
{
  "group": ["NM1", "N3", "N4", "REF"]
}
```

❌ **Incorrect:**
```json
{
  "group": true  // Type error!
}
```

### 3. Segment Qualifiers

**Use qualifiers to distinguish segment instances:**

```json
// Billing Provider NM1
{
  "id": "NM1",
  "qualifier": [0, "85"],
  "elements": [...]
}

// Subscriber NM1
{
  "id": "NM1",
  "qualifier": [0, "IL"],
  "elements": [...]
}
```

### 4. Nested Loop Boundaries

**Let the parser handle boundaries** - don't try to manually limit segments. The parser:
- Tracks processed segments
- Calculates boundaries per instance
- Prevents overlap between siblings

### 5. Composite Elements

**Check X12 specification for composite structure:**

For `SV2*0305:HC:22505*...`:
```json
{
  "pos": 0,
  "path": "procedure_code",
  "composite": [1]  // Extracts "HC"
}
```

### 6. Value Flattening

**Use empty path for qualifier-driven field names:**

```json
{
  "id": "REF",
  "multiple": true,
  "elements": [
    { "pos": 0, "map": { "EI": "employer_id" } },
    { "pos": 1, "path": "" }  // Flatten: use mapped qualifier as key
  ]
}
```

### 7. Optional vs Required

**Mark segments as optional when appropriate:**

```json
{
  "id": "PWK",
  "optional": true,  // Won't error if missing
  "elements": [...]
}
```

### 8. Schema Testing

**Test schema changes with real X12 data:**

1. Modify schema
2. Run parser with sample X12
3. Verify JSON output structure
4. Check for infinite loops or missing data
5. Validate element positions match expected values

---

## Troubleshooting

### Issue: Wrong Element Values

**Symptom:** JSON contains incorrect or shifted values.

**Cause:** Incorrect `pos` values in schema.

**Solution:** Remember parser indexing - schema `pos: 0` = `elements[1]`.

```json
// For segment: NM1*IL*1*DOE*JANE
{ "pos": 0, "path": "entity" }     // "IL" ✓
{ "pos": 1, "path": "type" }       // "1" ✓
{ "pos": 2, "path": "last_name" }  // "DOE" ✓
```

### Issue: Segments Not Grouped

**Symptom:** N3, N4 appear as separate entries instead of with NM1.

**Cause:** Missing or incorrect `group` definition.

**Solution:** Define group array and use `seg` field:

```json
{
  "id": "NM1",
  "group": ["NM1", "N3", "N4"],
  "elements": [
    { "seg": "NM1", "pos": 2, "path": "name" },
    { "seg": "N3", "pos": 0, "path": "address" }
  ]
}
```

### Issue: Infinite Loop

**Symptom:** Parser hangs or runs forever.

**Cause:** Nested loop boundary calculation error or trigger mismatch.

**Solution:**
1. Verify `trigger` matches actual segment ID
2. Check nested loop structure is correct
3. Ensure no circular references in `child_levels`

### Issue: Missing Nested Loop Data

**Symptom:** Nested loop array is empty.

**Cause:** 
- Wrong trigger segment
- Segments processed by parent before nested loop runs
- Boundary calculation issue

**Solution:**
1. Verify trigger segment ID is correct
2. Check if segments are in a group at parent level
3. Review X12 file structure

### Issue: Duplicate Data

**Symptom:** Same segment data appears multiple times.

**Cause:** Segment matched by multiple definitions without proper qualifiers.

**Solution:** Add qualifiers to distinguish segment uses:

```json
// Separate different NM1 types
{ "id": "NM1", "qualifier": [0, "85"], "elements": [...] },  // Billing Provider
{ "id": "NM1", "qualifier": [0, "IL"], "elements": [...] }   // Subscriber
```

### Issue: Composite Extraction Fails

**Symptom:** Empty or wrong value from composite element.

**Cause:** Incorrect component index or wrong separator.

**Solution:**
1. Verify composite separator (usually `:`)
2. Check component indices (0-based)
3. Manually split the value to verify structure

```
Value: "HC:87654:1:2"
Components: ["HC", "87654", "1", "2"]
Index 0: "HC"
Index 1: "87654"
Index 2: "1"
```

### Issue: Empty Output Array

**Symptom:** Expected array field is missing or empty.

**Cause:** 
- Loop trigger never found
- Segments outside loop boundary
- `output_array` name mismatch

**Solution:**
1. Verify trigger segment exists in X12
2. Check loop is in correct hierarchical level
3. Confirm `output_array` name is correct

---

## Conclusion

The zX12 schema system provides powerful, declarative control over X12 parsing. Key takeaways:

1. **Understand element indexing** - Schema `pos` vs. parser `elements` array
2. **Use groups effectively** - Combine related segments with `group` arrays
3. **Leverage qualifiers** - Distinguish segment uses with `qualifier` field
4. **Structure hierarchies carefully** - HL levels and nested loops
5. **Test thoroughly** - Validate with real X12 data

For questions or issues, refer to the schema examples in `schema/837i.json` and `schema/837p.json`, which demonstrate all these patterns in production use.