/**
 * zX12 - X12 EDI Parser Library
 * 
 * A high-performance X12 EDI parser that converts X12 documents to JSON format.
 * Supports 837P (Professional Claims) and 837I (Institutional Claims) with
 * hierarchical loop processing.
 * 
 * @version 1.0.0
 * @license MIT
 */

#ifndef ZX12_H
#define ZX12_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opaque handle to parsed X12 output.
 * Must be freed with zx12_free_output() after use.
 */
typedef struct ZX12_Output ZX12_Output;

/**
 * Error codes returned by zX12 functions.
 * All functions return 0 (ZX12_SUCCESS) on success.
 */
typedef enum {
    ZX12_SUCCESS = 0,           /**< Operation successful */
    ZX12_OUT_OF_MEMORY = 1,     /**< Memory allocation failed */
    ZX12_INVALID_ISA = 2,       /**< Invalid ISA segment (must be exactly 106 characters) */
    ZX12_FILE_NOT_FOUND = 3,    /**< X12 or schema file not found */
    ZX12_PARSE_ERROR = 4,       /**< X12 parsing error (invalid format) */
    ZX12_SCHEMA_LOAD_ERROR = 5, /**< Schema file loading error */
    ZX12_UNKNOWN_HL_LEVEL = 6,  /**< Unknown HL level code in schema */
    ZX12_PATH_CONFLICT = 7,     /**< JSON path conflict (structure mismatch) */
    ZX12_INVALID_ARGUMENT = 8,  /**< Invalid argument (null pointer, etc.) */
    ZX12_UNKNOWN_ERROR = 99     /**< Unknown error */
} ZX12_Error;

/**
 * Initialize the zX12 library.
 * 
 * Must be called before any other zX12 functions.
 * It is safe to call this function multiple times.
 * 
 * @return ZX12_SUCCESS on success, error code otherwise
 * 
 * @example
 * ```c
 * if (zx12_init() != ZX12_SUCCESS) {
 *     fprintf(stderr, "Failed to initialize zX12\n");
 *     return 1;
 * }
 * ```
 */
int zx12_init(void);

/**
 * Cleanup the zX12 library.
 * 
 * Should be called when done using the library.
 * After calling this function, zx12_init() must be called again
 * before using any other zX12 functions.
 * 
 * @example
 * ```c
 * zx12_deinit();
 * ```
 */
void zx12_deinit(void);

/**
 * Process an X12 document from a file and convert to JSON.
 * 
 * Opens and parses an X12 file using the specified schema, returning
 * a JSON representation. The output handle must be freed with
 * zx12_free_output() after use.
 * 
 * @param x12_file_path Path to the X12 file to process (null-terminated)
 * @param schema_path Path to the schema JSON file (null-terminated)
 * @param output_ptr Pointer to receive the output handle (must not be NULL)
 * @return ZX12_SUCCESS on success, error code otherwise
 * 
 * @example
 * ```c
 * ZX12_Output* output = NULL;
 * int result = zx12_process_document(
 *     "input.x12",
 *     "schema/837p.json",
 *     &output
 * );
 * 
 * if (result == ZX12_SUCCESS) {
 *     const char* json = zx12_get_output(output);
 *     printf("%s\n", json);
 *     zx12_free_output(output);
 * } else {
 *     fprintf(stderr, "Error: %s\n", zx12_get_error_message(result));
 * }
 * ```
 */
int zx12_process_document(
    const char* x12_file_path,
    const char* schema_path,
    ZX12_Output** output_ptr
);

/**
 * Process X12 document from a memory buffer and convert to JSON.
 * 
 * Parses X12 data from memory using the specified schema. The output
 * handle must be freed with zx12_free_output() after use.
 * 
 * @param x12_data Pointer to X12 data in memory
 * @param x12_length Length of X12 data in bytes
 * @param schema_path Path to schema JSON file (null-terminated)
 * @param output_ptr Pointer to receive the output handle (must not be NULL)
 * @return ZX12_SUCCESS on success, error code otherwise
 * 
 * @example
 * ```c
 * const char* x12_data = "ISA*00*...~";
 * size_t x12_len = strlen(x12_data);
 * 
 * ZX12_Output* output = NULL;
 * int result = zx12_process_from_memory(
 *     x12_data,
 *     x12_len,
 *     "schema/837p.json",
 *     &output
 * );
 * 
 * if (result == ZX12_SUCCESS) {
 *     const char* json = zx12_get_output(output);
 *     printf("%s\n", json);
 *     zx12_free_output(output);
 * }
 * ```
 */
int zx12_process_from_memory(
    const unsigned char* x12_data,
    size_t x12_length,
    const char* schema_path,
    ZX12_Output** output_ptr
);

/**
 * Get the JSON string from an output handle.
 * 
 * Returns a pointer to the null-terminated JSON string. The returned
 * string is valid until zx12_free_output() is called on the handle.
 * Do not attempt to free the returned pointer directly.
 * 
 * @param output Output handle from zx12_process_document() or zx12_process_from_memory()
 * @return Null-terminated JSON string, or NULL on error
 * 
 * @example
 * ```c
 * const char* json = zx12_get_output(output);
 * if (json) {
 *     printf("JSON: %s\n", json);
 * }
 * ```
 */
const char* zx12_get_output(ZX12_Output* output);

/**
 * Get the length of the JSON output.
 * 
 * Returns the length of the JSON string in bytes, excluding the
 * null terminator.
 * 
 * @param output Output handle from zx12_process_document() or zx12_process_from_memory()
 * @return Length of JSON string in bytes
 * 
 * @example
 * ```c
 * size_t length = zx12_get_output_length(output);
 * const char* json = zx12_get_output(output);
 * fwrite(json, 1, length, file);
 * ```
 */
size_t zx12_get_output_length(ZX12_Output* output);

/**
 * Free an output handle and its associated memory.
 * 
 * After calling this function, the output handle and any pointers
 * returned by zx12_get_output() are no longer valid.
 * 
 * @param output Output handle from zx12_process_document() or zx12_process_from_memory()
 * 
 * @example
 * ```c
 * zx12_free_output(output);
 * output = NULL; // Good practice
 * ```
 */
void zx12_free_output(ZX12_Output* output);

/**
 * Get the library version string.
 * 
 * Returns a null-terminated string containing the version number
 * in semantic versioning format (MAJOR.MINOR.PATCH).
 * 
 * @return Null-terminated version string (e.g., "1.0.0")
 * 
 * @example
 * ```c
 * printf("zX12 version: %s\n", zx12_get_version());
 * ```
 */
const char* zx12_get_version(void);

/**
 * Get a human-readable error message for an error code.
 * 
 * Converts an error code to a descriptive error message.
 * The returned string is static and does not need to be freed.
 * 
 * @param error_code Error code from a zx12 function
 * @return Null-terminated error message string
 * 
 * @example
 * ```c
 * int result = zx12_process_document(...);
 * if (result != ZX12_SUCCESS) {
 *     fprintf(stderr, "Error: %s\n", zx12_get_error_message(result));
 * }
 * ```
 */
const char* zx12_get_error_message(int error_code);

#ifdef __cplusplus
}
#endif

#endif /* ZX12_H */
