/**
 * Example C program demonstrating zX12 library usage
 * 
 * Compile with:
 *   zig build-lib src/main.zig -dynamic -lc
 *   gcc -o example examples/c/example.c -L. -lmain -I./include
 *   LD_LIBRARY_PATH=. ./example samples/837p_example.x12 schema/837p.json
 * 
 * Or create a shared library:
 *   zig build-lib src/main.zig -dynamic -lc -femit-bin=libzx12.so
 *   gcc -o example examples/c/example.c -L. -lzx12 -I./include
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zx12.h"

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <x12_file> <schema_file>\n", argv[0]);
        fprintf(stderr, "\nExample:\n");
        fprintf(stderr, "  %s samples/837p_example.x12 schema/837p.json\n", argv[0]);
        return 1;
    }

    const char* x12_file = argv[1];
    const char* schema_file = argv[2];

    // Initialize library
    printf("Initializing zX12 library version %s...\n", zx12_get_version());
    int result = zx12_init();
    if (result != ZX12_SUCCESS) {
        fprintf(stderr, "Failed to initialize zX12: %s\n", zx12_get_error_message(result));
        return 1;
    }

    // Process X12 document
    printf("Processing: %s\n", x12_file);
    printf("Schema: %s\n", schema_file);
    
    ZX12_Output* output = NULL;
    result = zx12_process_document(x12_file, schema_file, &output);

    if (result != ZX12_SUCCESS) {
        fprintf(stderr, "Error processing document: %s\n", zx12_get_error_message(result));
        zx12_deinit();
        return 1;
    }

    // Get JSON output
    const char* json = zx12_get_output(output);
    size_t length = zx12_get_output_length(output);

    if (json == NULL) {
        fprintf(stderr, "Failed to get output\n");
        zx12_free_output(output);
        zx12_deinit();
        return 1;
    }

    // Print JSON
    printf("\n=== JSON Output (%zu bytes) ===\n", length);
    printf("%s\n", json);

    // Optionally write to file
    const char* output_file = "output.json";
    FILE* f = fopen(output_file, "w");
    if (f) {
        fwrite(json, 1, length, f);
        fclose(f);
        printf("\nOutput written to: %s\n", output_file);
    }

    // Cleanup
    zx12_free_output(output);
    zx12_deinit();

    printf("\nProcessing complete!\n");
    return 0;
}
