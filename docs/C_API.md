# zX12 C API

Complete C API for the zX12 X12 EDI parser library. Provides a simple interface for parsing X12 documents and converting them to JSON format.

## Features

- **Simple C Interface**: Easy-to-use C API with minimal functions
- **Memory Safe**: Proper memory management with clear ownership semantics
- **Thread-Safe**: Can be used from multiple threads (with separate contexts)
- **Cross-Language**: Works with C, C++, Python, Node.js, and any language with FFI support
- **Production Ready**: Robust error handling and comprehensive documentation

## Building

### Shared Library (Linux/macOS)

```bash
# Build shared library
zig build-lib src/main.zig -dynamic -lc -femit-bin=libzx12.so

# Or with specific target
zig build-lib src/main.zig -dynamic -lc -target x86_64-linux -femit-bin=libzx12.so
```

### Static Library

```bash
# Build static library
zig build-lib src/main.zig -static -lc -femit-bin=libzx12.a
```

### Windows DLL

```bash
# Build Windows DLL
zig build-lib src/main.zig -dynamic -lc -target x86_64-windows -femit-bin=zx12.dll
```

## C Usage

### Basic Example

```c
#include "zx12.h"
#include <stdio.h>

int main(void) {
    // Initialize library
    if (zx12_init() != ZX12_SUCCESS) {
        fprintf(stderr, "Failed to initialize\n");
        return 1;
    }

    // Process document
    ZX12_Output* output = NULL;
    int result = zx12_process_document(
        "input.x12",
        "schema/837p.json",
        &output
    );

    if (result != ZX12_SUCCESS) {
        fprintf(stderr, "Error: %s\n", zx12_get_error_message(result));
        zx12_deinit();
        return 1;
    }

    // Get JSON
    const char* json = zx12_get_output(output);
    printf("%s\n", json);

    // Cleanup
    zx12_free_output(output);
    zx12_deinit();
    return 0;
}
```

### Compile C Program

```bash
# Compile
gcc -o example examples/c/example.c -L. -lzx12 -I./include

# Run
LD_LIBRARY_PATH=. ./example samples/837p_example.x12 schema/837p.json
```

### Process from Memory

```c
#include "zx12.h"
#include <string.h>

void process_from_memory() {
    zx12_init();

    const char* x12_data = "ISA*00*...~";
    ZX12_Output* output = NULL;
    
    int result = zx12_process_from_memory(
        (const unsigned char*)x12_data,
        strlen(x12_data),
        "schema/837p.json",
        &output
    );

    if (result == ZX12_SUCCESS) {
        const char* json = zx12_get_output(output);
        size_t length = zx12_get_output_length(output);
        
        // Write to file
        FILE* f = fopen("output.json", "w");
        fwrite(json, 1, length, f);
        fclose(f);
        
        zx12_free_output(output);
    }

    zx12_deinit();
}
```

## Python Usage

### Installation

```bash
# Build shared library
zig build-lib src/main.zig -dynamic -lc -femit-bin=libzx12.so

# Run Python example
python3 examples/python/zx12_example.py samples/837p_example.x12 schema/837p.json
```

### Python Example

```python
from zx12_example import ZX12

# Use context manager for automatic cleanup
with ZX12('./libzx12.so') as zx12:
    print(f"Version: {zx12.get_version()}")
    
    # Process file
    result = zx12.process_file(
        'samples/837p_example.x12',
        'schema/837p.json'
    )
    
    # Result is a Python dict
    print(result['interchange']['control_number'])
```

### Python from String

```python
with ZX12() as zx12:
    x12_data = open('input.x12').read()
    result = zx12.process_string(x12_data, 'schema/837p.json')
    print(result)
```

## API Reference

### Functions

#### `zx12_init()`
Initialize the library. Must be called before any other functions.

**Returns:** `ZX12_SUCCESS` (0) on success, error code otherwise

#### `zx12_deinit()`
Cleanup the library. Call when done using zX12.

#### `zx12_process_document(x12_file, schema_file, output_ptr)`
Process X12 file and convert to JSON.

**Parameters:**
- `x12_file`: Path to X12 file (null-terminated string)
- `schema_file`: Path to schema JSON (null-terminated string)
- `output_ptr`: Pointer to receive output handle

**Returns:** `ZX12_SUCCESS` on success, error code otherwise

#### `zx12_process_from_memory(x12_data, x12_length, schema_file, output_ptr)`
Process X12 data from memory buffer.

**Parameters:**
- `x12_data`: Pointer to X12 data
- `x12_length`: Length of data in bytes
- `schema_file`: Path to schema JSON
- `output_ptr`: Pointer to receive output handle

**Returns:** `ZX12_SUCCESS` on success, error code otherwise

#### `zx12_get_output(output)`
Get JSON string from output handle.

**Parameters:**
- `output`: Output handle from process function

**Returns:** Null-terminated JSON string, valid until `zx12_free_output()` is called

#### `zx12_get_output_length(output)`
Get length of JSON output in bytes (excluding null terminator).

**Returns:** Length in bytes

#### `zx12_free_output(output)`
Free output handle and its memory. After this call, the handle and any returned pointers are invalid.

#### `zx12_get_version()`
Get library version string.

**Returns:** Version string (e.g., "1.0.0")

#### `zx12_get_error_message(error_code)`
Get human-readable error message for error code.

**Returns:** Error message string

### Error Codes

| Code | Name | Description |
|------|------|-------------|
| 0 | `ZX12_SUCCESS` | Operation successful |
| 1 | `ZX12_OUT_OF_MEMORY` | Memory allocation failed |
| 2 | `ZX12_INVALID_ISA` | Invalid ISA segment |
| 3 | `ZX12_FILE_NOT_FOUND` | File not found |
| 4 | `ZX12_PARSE_ERROR` | X12 parsing error |
| 5 | `ZX12_SCHEMA_LOAD_ERROR` | Schema loading error |
| 6 | `ZX12_UNKNOWN_HL_LEVEL` | Unknown HL level code |
| 7 | `ZX12_PATH_CONFLICT` | JSON path conflict |
| 8 | `ZX12_INVALID_ARGUMENT` | Invalid argument |
| 99 | `ZX12_UNKNOWN_ERROR` | Unknown error |

## Memory Management

### Ownership Rules

1. **Library Initialization**: Call `zx12_init()` once before use
2. **Output Handles**: Created by `zx12_process_*()` functions
3. **JSON Strings**: Owned by output handle, valid until `zx12_free_output()`
4. **Cleanup**: Always call `zx12_free_output()` and `zx12_deinit()`

### Example Pattern

```c
zx12_init();

ZX12_Output* output = NULL;
if (zx12_process_document(..., &output) == ZX12_SUCCESS) {
    const char* json = zx12_get_output(output);
    // Use json (don't free it)
    zx12_free_output(output);  // Frees json too
}

zx12_deinit();
```

## Thread Safety

- Each output handle is independent and thread-safe
- Multiple threads can call `zx12_process_*()` concurrently
- `zx12_init()` and `zx12_deinit()` are thread-safe but should only be called once

## Error Handling

Always check return codes:

```c
int result = zx12_process_document(file, schema, &output);
if (result != ZX12_SUCCESS) {
    fprintf(stderr, "Error: %s\n", zx12_get_error_message(result));
    // Handle error
}
```

## Performance

- Zero-copy where possible
- Minimal allocations
- ~10-20MB/s parsing throughput
- Memory usage: ~2-3x input file size

## Limitations

- ISA segment must be exactly 106 characters
- Requires schema JSON file
- Currently supports 837P and 837I transaction types
- Maximum file size: Limited by available memory

## Examples

See the `examples/` directory for complete examples:
- `examples/c/example.c` - C usage
- `examples/python/zx12_example.py` - Python bindings

## License

MIT License - See LICENSE file for details
