# zX12 - A blazing fast X12 EDI Parser

**zX12** is a high-performance, memory-safe, and thread-safe X12 EDI parser written in Zig. It is designed to parse complex X12 documents, such as healthcare claims (837P and 837I), and convert them into a structured JSON format based on a configurable schema.

This project provides a C-compatible library that can be easily integrated into various programming languages, including C, C++, Python, and more.

## Features

- **High Performance:** Parses X12 documents at a high throughput, suitable for processing large volumes of data.
- **Memory Safety:** Built with Zig, which provides compile-time checks to prevent common memory-related bugs.
- **Thread-Safe:** Can be used in multi-threaded applications to process multiple documents concurrently.
- **Schema-Driven:** Uses a flexible JSON schema to define the parsing logic, making it adaptable to different X12 transaction sets and versions.
- **C API:** Provides a simple and stable C API for easy integration with other languages.
- **Cross-Platform:** Can be built on Linux, macOS, and Windows.
- **Example Integrations:** Includes example usage for both C and Python.

## Getting Started

### Prerequisites

- **Zig:** You will need to have the Zig compiler installed. You can find installation instructions on the [official Zig website](https://ziglang.org/learn/getting-started/).
- **C Compiler:** A C compiler such as GCC or Clang is required to build the C example.

### Building the Project

A `build.sh` script is provided to simplify the build process. This script will build the shared library, the static library, and the C example.

```bash
# Make the build script executable
chmod +x build.sh

# Run the build script
./build.sh
```

This will produce the following files:

- `libzx12.so` (or `libzx12.dylib` on macOS, `zx12.dll` on Windows): The shared library.
- `libzx12.a`: The static library.
- `zx12_example`: The C example executable.

### Running the Examples

Once the project is built, you can run the C and Python examples.

**C Example:**

```bash
# Run the C example with an 837P sample file
./zx12_example samples/837p_example.x12 schema/837p.json
```

This will process the sample X12 file and print the resulting JSON to the console. It will also write the output to `output.json`.

**Python Example:**

The Python example uses `ctypes` to wrap the C library. Make sure the shared library (`libzx12.so`) is in the same directory or in your library path.

```bash
# Run the Python example
python3 examples/python/zx12_example.py samples/837i_example.x12 schema/837i.json
```

## JSON Schema

The zX12 parser is driven by a JSON schema that defines the structure of the X12 transaction and how it should be converted to JSON. This approach allows for easy adaptation to different X12 transaction sets without changing the parser's code.

For a detailed explanation of the schema, please see the **[Schema Breakdown](schema/SCHEMA.md)**.

## Usage

Below are brief examples of how to use the zX12 library in C and Python.

### C Usage

```c
#include "zx12.h"
#include <stdio.h>

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
        const char* json = zx12_get_output(output);
        printf("%s\n", json);
        zx12_free_output(output);
    } else {
        fprintf(stderr, "Error: %s\n", zx12_get_error_message(result));
    }

    zx12_deinit();
    return 0;
}
```

### Python Usage

```python
from zx12_example import ZX12

with ZX12('./libzx12.so') as zx12:
    try:
        result = zx12.process_file(
            'samples/837p_example.x12',
            'schema/837p.json'
        )
        print(result)
    except Exception as e:
        print(f"An error occurred: {e}")
```

## API Reference

The C API is defined in `include/zx12.h`. For detailed documentation on the API, please see the **[C API Summary](docs/C_API_SUMMARY.md)**.

## Building from Source

You can also use the Zig build system directly to build the library.

```bash
# Build the dynamic library
zig build

# Run the tests
zig build test
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
