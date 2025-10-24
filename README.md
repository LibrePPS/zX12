# zX12 - X12 EDI Parser

**zX12** is a fast and flexible X12 EDI parser written in Zig with a C-compatible API. It transforms complex X12 documents (such as healthcare claims 837P and 837I) into structured JSON format using declarative, schema-driven parsing.

## Overview

The zX12 parser is designed to handle the full complexity of X12 EDI documents, including:

- **Hierarchical Structures** - HL (Hierarchical Level) segments with parent-child relationships
- **Nested Loops** - Multiple levels of nested non-hierarchical loops
- **Segment Groups** - Related segments (like NM1+N3+N4+REF) processed together
- **Composite Elements** - Extraction of sub-components from composite fields
- **Repeating Patterns** - Complex repeating element structures (e.g., HI segments)
- **Value Mapping** - Code-to-description translations defined in schema
- **Flexible Output** - Configurable JSON structure via schema

### Key Features

- **Schema-Driven:** JSON schemas define parsing logic, making it adaptable to different X12 transaction sets without code changes
- **C-Compatible API:** Simple, stable C API for integration with any language that supports FFI
- **Cross-Platform:** Builds on Linux, macOS (x86_64 and ARM64), and Windows
- **Multiple Language Support:** Includes Python bindings with pre-built wheels for multiple platforms
- **Declarative Configuration:** No code changes needed to support new transaction types - just update the schema

## Project Structure

```
zX12/
├── src/                    # Zig source code
│   ├── main.zig           # C API implementation
│   └── x12_parser/        # Core parser modules
├── include/               # C header files
│   └── zx12.h            # Public C API
├── python/                # Python package
│   └── zx12/             # Python module with bindings
├── schema/                # X12 schema definitions
│   ├── 837i.json         # Institutional claim schema
│   ├── 837p.json         # Professional claim schema
│   └── SCHEMA.md         # Schema documentation
├── samples/               # Example X12 files
├── examples/              # Usage examples
│   ├── c/                # C examples
│   └── python/           # Python examples
├── docs/                  # Additional documentation
├── build.zig             # Zig build configuration
└── pyproject.toml        # Python package configuration
```

## Getting Started

### Prerequisites

- **Zig Compiler:** Version 0.15.0 or later ([installation instructions](https://ziglang.org/learn/getting-started/))
- **C Compiler:** GCC, Clang, or MSVC (for building C examples)
- **Python:** 3.7+ (for Python bindings)
- **UV:** Astral UV package manager (for building Python wheels)

### Quick Start

#### 1. Build the Library

Using the provided build script (Linux/macOS):

```bash
chmod +x build.sh
./build.sh
```

Or using Zig directly:

```bash
# Build dynamic library with optimizations
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

#### 2. Run Examples

**C Example:**

```bash
# Build C example (after building library)
gcc -o zx12_example \
    examples/c/example.c \
    -L./zig-out/bin -lzx12 \
    -I./include \
    -Wl,-rpath,./zig-out/bin

# Run it
./zx12_example samples/837p_example.x12 schema/837p.json
```

**Python Example:**

```bash
python3 examples/python/zx12_example.py samples/837i_example.x12 schema/837i.json
```

## Building from Source

### Building the Zig Library

The zX12 library can be built using either the `build.sh` script or Zig directly.

#### Using build.sh (Recommended for Development)

The build script handles platform detection and builds both shared and static libraries:

```bash
./build.sh                  # Build library only
./build.sh --build-c-example  # Build library and C example
```

This produces:
- `zig-out/bin/libzx12.so` (Linux)
- `zig-out/bin/libzx12.dylib` (macOS)
- `zig-out/bin/zx12.dll` (Windows)
- `zig-out/bin/libzx12.a` (static library, all platforms)

#### Using Zig Build System

```bash
# Debug build (faster compilation, slower runtime)
zig build

# Release build with optimizations
zig build -Doptimize=ReleaseFast

# Release build with small binary size
zig build -Doptimize=ReleaseSmall

# Release build with safety checks
zig build -Doptimize=ReleaseSafe
```

**Build Options:**
- `ReleaseFast` - Maximum runtime performance (recommended for production)
- `ReleaseSmall` - Optimized for binary size
- `ReleaseSafe` - Optimizations with runtime safety checks
- `Debug` - No optimization, full debug info (default)

### Building the Python Wheel

The Python package includes pre-built binaries for:
- Linux (x86_64)
- macOS (x86_64 and ARM64/Apple Silicon)
- Windows (x86_64)

#### Prerequisites for Python Builds

1. Install UV package manager:
 - https://docs.astral.sh/uv/getting-started/installation/

2. Set the ZX12_PATH environment variable:
```bash
# Linux/macOS
export ZX12_PATH=/path/to/zX12

# Windows (PowerShell)
$env:ZX12_PATH = "C:\path\to\zX12"
```

#### Building the Wheel

```bash
# Build wheel for all platforms
uv build

# Output will be in ./dist/
# Example: dist/zx12-0.1.0-py3-none-any.whl
```

The build process:
1. Compiles the Zig library for multiple targets
2. Bundles platform-specific binaries
3. Packages everything into a wheel file

#### Installing the Wheel

```bash
# Install from built wheel
pip install dist/zx12-0.1.0-py3-none-any.whl

# Or install in development mode
pip install -e .
```

## Usage

### C API

The C API provides a simple interface for parsing X12 documents:

```c
#include "zx12.h"
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    // Initialize the library
    zx12_init();

    ZX12_Output* output = NULL;
    int result = zx12_process_document(
        "samples/837p_example.x12",
        "schema/837p.json",
        &output
    );

    if (result == ZX12_SUCCESS) {
        // Get JSON output
        const char* json = zx12_get_output(output);
        printf("%s\n", json);

        // Write to file
        FILE* fp = fopen("output.json", "w");
        if (fp) {
            fprintf(fp, "%s", json);
            fclose(fp);
        }

        // Clean up
        zx12_free_output(output);
    } else {
        fprintf(stderr, "Error: %s\n", zx12_get_error_message(result));
    }

    zx12_deinit();
    return 0;
}
```

**Compiling:**

```bash
gcc -o myapp myapp.c -L./zig-out/bin -lzx12 -I./include -Wl,-rpath,./zig-out/bin
```

### Python API

The Python bindings provide a high-level, Pythonic interface:

```python
from zx12 import ZX12Parser

# Create parser instance
parser = ZX12Parser()

# Parse X12 file to JSON
result = parser.parse_file(
    x12_path='samples/837i_example.x12',
    schema_path='schema/837i.json'
)

# Result is a Python dictionary
print(f"Transaction ID: {result['transaction']['id']}")
print(f"Billing Providers: {len(result['billing_providers'])}")

# Access nested data
for provider in result['billing_providers']:
    for subscriber in provider.get('subscribers', []):
        for patient in subscriber.get('patients', []):
            for claim in patient.get('claims', []):
                print(f"Claim ID: {claim['claim_id']}")
                print(f"Total Charge: {claim['total_charge']}")
```

**Using Context Manager:**

```python
from zx12 import ZX12Parser

with ZX12Parser() as parser:
    result = parser.parse_file('input.x12', 'schema.json')
    # Parser automatically cleaned up on exit
```

**Error Handling:**

```python
from zx12 import ZX12Parser, ZX12Error

try:
    parser = ZX12Parser()
    result = parser.parse_file('input.x12', 'schema.json')
except ZX12Error as e:
    print(f"Parsing failed: {e}")
except FileNotFoundError as e:
    print(f"File not found: {e}")
```

## Schema System

The parser uses JSON schemas to define how X12 segments are transformed into JSON. This allows supporting new transaction types without modifying code.

### Example Schema Snippet

```json
{
  "schema_version": "1.0.0",
  "transaction": {
    "id": "837P",
    "version": "005010X222A1",
    "type": "837",
    "description": "Health Care Claim: Professional"
  },
  "hierarchical_structure": {
    "output_array": "billing_providers",
    "levels": {
      "20": {
        "name": "Billing Provider",
        "segments": [
          {
            "id": "NM1",
            "qualifier": [0, "85"],
            "group": ["NM1", "N3", "N4", "REF"],
            "elements": [
              { "seg": "NM1", "pos": 2, "path": "organization_name" },
              { "seg": "N3", "pos": 0, "path": "address_line_1" },
              { "seg": "N4", "pos": 0, "path": "city" },
              { "seg": "N4", "pos": 1, "path": "state" }
            ]
          }
        ],
        "child_levels": ["22"]
      }
    }
  }
}
```

### Schema Documentation

For comprehensive schema documentation, see **[Schema Documentation](schema/SCHEMA.md)**, which covers:

- Parser behavior and conventions
- Element indexing and mapping
- Segment groups and qualifiers
- Hierarchical structures
- Non-hierarchical loops
- Repeating elements
- Common patterns
- Best practices
- Troubleshooting

## API Reference

### C API Functions

| Function | Description |
|----------|-------------|
| `zx12_init()` | Initialize the library (call once per process) |
| `zx12_deinit()` | Clean up library resources |
| `zx12_process_document()` | Parse an X12 file with a schema |
| `zx12_get_output()` | Get JSON string from output object |
| `zx12_free_output()` | Free output object and its resources |
| `zx12_get_error_message()` | Get human-readable error message |

**Return Codes:**
- `ZX12_SUCCESS` (0) - Operation successful
- `ZX12_ERROR_INVALID_ARGS` (1) - Invalid arguments
- `ZX12_ERROR_FILE_NOT_FOUND` (2) - File not found
- `ZX12_ERROR_PARSE_FAILED` (3) - Parse error
- `ZX12_ERROR_MEMORY` (4) - Memory allocation failed
- `ZX12_ERROR_SCHEMA_INVALID` (5) - Invalid schema
- `ZX12_ERROR_UNKNOWN` (99) - Unknown error

For detailed C API documentation, see **[C API Summary](docs/C_API_SUMMARY.md)**.

### Python API

The Python API is documented in the module docstrings:

```python
import zx12
help(zx12.ZX12Parser)
```

## Examples

### Example X12 Files

The `samples/` directory contains example X12 files:

- `837p_example.x12` - Professional health care claim
- `837i_example.x12` - Institutional health care claim

### Running Examples

**C Example:**

```bash
# After building the library and C example
./zx12_example samples/837p_example.x12 schema/837p.json
```

**Python Example:**

```bash
# Using the standalone example
python3 examples/python/zx12_example.py samples/837i_example.x12 schema/837i.json

# Or using the installed package
python3 -c "
from zx12 import ZX12Parser
parser = ZX12Parser()
result = parser.parse_file('samples/837i_example.x12', 'schema/837i.json')
print(result['transaction']['id'])
"
```

## Development

### Running Tests

```bash
# Run all Zig tests
zig build test

# Run tests with verbose output
zig build test -- --verbose
```

### Project Layout

- `src/x12_parser/` - Core parser implementation
  - `tokenizer.zig` - X12 tokenization
  - `x12_parser.zig` - Segment parsing
  - `hl_tree.zig` - Hierarchical structure
  - `schema.zig` - Schema loading and validation
  - `document_processor.zig` - Main processing logic
  - `json_builder.zig` - JSON output generation

### Adding New Transaction Types

1. Create a schema file in `schema/` (e.g., `schema/270.json`)
2. Define the transaction structure following the schema format
3. Test with sample X12 files
4. No code changes needed!

See [Schema Documentation](schema/SCHEMA.md) for details on schema structure.

## Supported Transaction Sets

Currently tested and supported:

- **837P** - Health Care Claim: Professional (005010X222A1)
- **837I** - Health Care Claim: Institutional (005010X223A2)

The schema system is designed to support any X12 transaction set. Additional schemas can be added without modifying the parser code.

## Troubleshooting

### Library Not Found (Linux/macOS)

If you get "library not found" errors:

```bash
# Add library path to LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$(pwd)/zig-out/bin

# Or copy library to system location
sudo cp zig-out/bin/libzx12.so /usr/local/lib/
sudo ldconfig
```

### Python Import Errors

If Python can't find the library:

```bash
# Make sure wheel is installed
pip install -e .

# Or set PYTHONPATH
export PYTHONPATH=$(pwd)/python:$PYTHONPATH
```

### Build Errors

If Zig build fails:

```bash
# Clean build cache
rm -rf zig-cache zig-out .zig-cache

# Rebuild
zig build -Doptimize=ReleaseFast
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Links

- **Documentation:** [Schema Documentation](schema/SCHEMA.md)
- **API Reference:** [C API Summary](docs/C_API_SUMMARY.md)
- **Repository:** [GitHub](https://github.com/LibrePPS/zX12)
- **Issues:** [Bug Tracker](https://github.com/LibrePPS/zX12/issues)

## Authors

- Jacob Wilson - [jjw07006@gmail.com](mailto:jjw07006@gmail.com)
- Josh Lankford - [lankford.josh@gmail.com](mailto:lankford.josh@gmail.com)

## Acknowledgments

Built with [Zig](https://ziglang.org/) - A general-purpose programming language and toolchain for maintaining robust, optimal, and reusable software.
