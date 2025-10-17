# zX12 JSON Schema Breakdown

This document provides a detailed breakdown of the JSON schema used by the zX12 parser. The schema defines how an X12 EDI document is parsed and converted into a JSON object. This schema is designed to be flexible and handle the complexities of X12 transactions, including hierarchical structures, loops, and composite elements.

The two main schema files provided in this repository are `837i.json` (Institutional Health Care Claim) and `837p.json` (Professional Health Care Claim).

## Top-Level Structure

The JSON schema has the following top-level keys:

- `schema_version`: The version of the schema file.
- `transaction`: Contains metadata about the X12 transaction set.
- `transaction_header`: Defines the segments that make up the header of the transaction.
- `transaction_trailer`: Defines the segments that make up the trailer of the transaction.
- `sequential_sections`: Defines non-hierarchical sections that appear in a specific sequence.
- `hierarchical_structure`: Defines the main hierarchical (HL) structure of the X12 document.

---

### 1. `transaction`

This object contains basic information about the X12 transaction set being defined.

**Example:**
```json
"transaction": {
  "id": "837I",
  "version": "005010X223A2",
  "type": "837",
  "description": "Health Care Claim: Institutional"
}
```

- `id`: The transaction set ID (e.g., "837I", "837P").
- `version`: The version of the transaction set (e.g., "005010X223A2").
- `type`: The type of the transaction (e.g., "837").
- `description`: A human-readable description of the transaction.

---

### 2. `transaction_header` and `transaction_trailer`

These sections define the segments that appear at the beginning and end of every transaction.

**Structure:**
```json
"transaction_header": {
  "segments": [
    {
      "id": "ISA",
      "elements": [
        { "pos": 0, "path": "interchange.auth_info_qualifier", "expect": "00" },
        { "pos": 1, "path": "interchange.auth_info", "transform": ["trim"] },
        ...
      ]
    },
    ...
  ]
}
```

- `segments`: An array of segment objects.
  - `id`: The segment ID (e.g., "ISA", "GS", "ST").
  - `elements`: An array of element objects that define how to map the data from the segment to the output JSON.
    - `pos`: The 0-based position of the element within the segment.
    - `path`: The JSON path where the element's value will be stored in the output.
    - `expect`: (Optional) An expected value for the element. If the element's value does not match, it can be flagged as an error.
    - `transform`: (Optional) An array of transformations to apply to the element's value (e.g., `trim`).
    - `map`: (Optional) A key-value map to translate the element's value into a more descriptive string.

---

### 3. `sequential_sections`

This section is used for parts of the X12 document that are sequential but not part of the main `HL` hierarchy. A common use case is for the Submitter and Receiver loops at the beginning of a transaction.

**Structure:**
```json
"sequential_sections": [
  {
    "name": "Submitter",
    "output_path": "submitter",
    "trigger": { "segment": "NM1", "qualifier": [0, "41"] },
    "segments": [
      {
        "id": "NM1",
        "elements": [ ... ]
      },
      {
        "id": "PER",
        "multiple": true,
        "output_array": "contacts",
        "elements": [ ... ]
      }
    ]
  }
]
```

- `name`: A descriptive name for the section.
- `output_path`: The JSON key under which this section's data will be stored.
- `trigger`: An object that defines the segment that marks the beginning of this section.
  - `segment`: The ID of the trigger segment (e.g., "NM1").
  - `qualifier`: An array `[position, value]` that specifies a qualifying value in the trigger segment (e.g., `[0, "41"]` means the element at position 0 must be "41").
- `segments`: An array of segment objects to be parsed within this section.
  - `multiple`: (Optional) If `true`, the segment can appear multiple times.
  - `output_array`: (Optional) If `multiple` is true, this is the name of the JSON array that will store the multiple occurrences.

---

### 4. `hierarchical_structure`

This is the most complex part of the schema and defines the main hierarchical structure of the X12 document, which is based on `HL` (Hierarchical Level) segments.

**Structure:**
```json
"hierarchical_structure": {
  "output_array": "billing_providers",
  "levels": {
    "20": {
      "name": "Billing Provider",
      "segments": [ ... ],
      "child_levels": ["22"]
    },
    "22": {
      "name": "Subscriber",
      "output_array": "subscribers",
      "segments": [ ... ],
      "child_levels": ["23"],
      "non_hierarchical_loops": [ ... ]
    },
    ...
  }
}
```

- `output_array`: The name of the top-level array in the JSON output that will contain the root-level items of the hierarchy.
- `levels`: An object where each key is an `HL` level code (e.g., "20", "22", "23").
  - `name`: A descriptive name for the level.
  - `output_array`: (Optional) If this level can have multiple instances under a single parent, this is the name of the array to store them in.
  - `segments`: An array of segment objects to be parsed within this level.
  - `child_levels`: An array of `HL` level codes that are expected to be children of this level.
  - `non_hierarchical_loops`: (Optional) Defines loops that are not based on the `HL` structure but are nested within a hierarchical level (e.g., `CLM` loops within a patient level).

#### `non_hierarchical_loops`

This section is for loops that are not driven by `HL` segments but are triggered by another segment (like `CLM` or `LX`).

**Structure:**
```json
"non_hierarchical_loops": [
  {
    "name": "Claims",
    "trigger": "CLM",
    "output_array": "claims",
    "segments": [ ... ],
    "nested_loops": [ ... ]
  }
]
```

- `name`: A descriptive name for the loop.
- `trigger`: The segment ID that marks the beginning of each iteration of the loop.
- `output_array`: The name of the JSON array to store the loop's data.
- `segments`: The segments to be parsed within each iteration of the loop.
- `nested_loops`: (Optional) Allows for defining loops within loops (e.g., `LX` service line loops within a `CLM` claim loop).

#### `repeating_elements`

Some segments, like the `HI` (Health Care Information) segment, use a repeating structure of composite elements. The `repeating_elements` object is designed to handle this.

**Structure:**
```json
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
    ...
  ]
}
```

- `all`: If `true`, all elements in the segment are considered for this repeating pattern.
- `separator`: The character that separates components within a composite element (e.g., `:`).
- `patterns`: An array of patterns to apply.
  - `when_qualifier`: An array of qualifier values. The pattern is applied if the first component of the composite element matches one of these values.
  - `output_array`: The name of the JSON array to store the parsed data.
  - `fields`: An array that maps the components of the composite element to JSON field names.
    - `component`: The 0-based index of the component.
    - `name`: The name of the JSON field.

---

This schema provides a powerful and declarative way to define the parsing logic for complex X12 documents, allowing the zX12 parser to be easily configured for different transaction sets and versions.
