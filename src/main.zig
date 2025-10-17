const std = @import("std");
const document_processor = @import("x12_parser/document_processor.zig");

// ============================================================================
// C API for X12 Document Processing
// ============================================================================

/// Opaque handle to processed JSON output
pub const ZX12_Output = opaque {};

/// Error codes returned by C API functions
pub const ZX12_Error = enum(c_int) {
    Success = 0,
    OutOfMemory = 1,
    InvalidISA = 2,
    FileNotFound = 3,
    ParseError = 4,
    SchemaLoadError = 5,
    UnknownHLLevel = 6,
    PathConflict = 7,
    InvalidArgument = 8,
    UnknownError = 99,
};

/// Convert Zig error to C error code
fn errorToCode(err: anyerror) ZX12_Error {
    return switch (err) {
        error.OutOfMemory => .OutOfMemory,
        error.InvalidISA => .InvalidISA,
        error.FileNotFound => .FileNotFound,
        error.ParseError => .ParseError,
        error.SchemaLoadError => .SchemaLoadError,
        error.UnknownHLLevel => .UnknownHLLevel,
        error.PathConflict => .PathConflict,
        else => .UnknownError,
    };
}

/// Global allocator for C API (uses C allocator for simplicity and thread-safety)
fn getGlobalAllocator() std.mem.Allocator {
    // Use c_allocator when linking with libc, otherwise use page_allocator for tests
    if (@import("builtin").link_libc) {
        return std.heap.c_allocator;
    } else {
        return std.heap.page_allocator;
    }
}

/// Initialize the zX12 library
/// Must be called before any other functions
/// Returns 0 on success, error code otherwise
export fn zx12_init() c_int {
    // Nothing to do with c_allocator
    return @intFromEnum(ZX12_Error.Success);
}

/// Cleanup the zX12 library
/// Should be called when done using the library
export fn zx12_deinit() void {
    // Nothing to do with c_allocator
}

/// Process an X12 document and convert to JSON
///
/// @param x12_file_path Path to the X12 file to process (null-terminated C string)
/// @param schema_path Path to the schema JSON file (null-terminated C string)
/// @param output_ptr Pointer to receive the output handle (must not be null)
/// @return 0 on success, error code otherwise
///
/// Example:
///   ZX12_Output* output = NULL;
///   int result = zx12_process_document("input.x12", "schema/837p.json", &output);
///   if (result == 0) {
///     const char* json = zx12_get_output(output);
///     printf("%s\n", json);
///     zx12_free_output(output);
///   }
export fn zx12_process_document(
    x12_file_path: [*:0]const u8,
    schema_path: [*:0]const u8,
    output_ptr: *?*ZX12_Output,
) c_int {
    const allocator = getGlobalAllocator();

    // Convert C strings to Zig slices
    const x12_path = std.mem.span(x12_file_path);
    const schema_file = std.mem.span(schema_path);

    // Open X12 file
    const x12_file = std.fs.cwd().openFile(x12_path, .{}) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    defer x12_file.close();

    // Process document
    var json_output = document_processor.processDocument(
        allocator,
        x12_file,
        schema_file,
    ) catch |err| {
        return @intFromEnum(errorToCode(err));
    };

    // Get the data from ArrayList
    const length = json_output.items.len;

    // Allocate buffer with room for null terminator
    const data = allocator.alloc(u8, length + 1) catch {
        json_output.deinit(allocator);
        return @intFromEnum(ZX12_Error.OutOfMemory);
    };

    // Copy data and add null terminator
    @memcpy(data[0..length], json_output.items);
    data[length] = 0;

    // Free the ArrayList
    json_output.deinit(allocator);

    // Create output handle
    const handle = allocator.create(OutputHandle) catch {
        allocator.free(data);
        return @intFromEnum(ZX12_Error.OutOfMemory);
    };

    handle.* = .{
        .data = data,
        .length = length,
    };

    output_ptr.* = @ptrCast(handle);
    return @intFromEnum(ZX12_Error.Success);
}

// Internal structure to store output with length
const OutputHandle = struct {
    data: []u8,
    length: usize,
};

/// Get the JSON string from the output handle
///
/// @param output Output handle from zx12_process_document
/// @return Null-terminated JSON string, or NULL on error
///
/// The returned string is valid until zx12_free_output is called
export fn zx12_get_output(output: *ZX12_Output) ?[*:0]const u8 {
    const handle: *OutputHandle = @ptrCast(@alignCast(output));
    // The data is already null-terminated from dupe
    return @ptrCast(handle.data.ptr);
}

/// Get the length of the JSON output (excluding null terminator)
///
/// @param output Output handle from zx12_process_document
/// @return Length of JSON string in bytes
export fn zx12_get_output_length(output: *ZX12_Output) usize {
    const handle: *OutputHandle = @ptrCast(@alignCast(output));
    return handle.length;
}

/// Free the output handle and its associated memory
///
/// @param output Output handle from zx12_process_document
export fn zx12_free_output(output: *ZX12_Output) void {
    const allocator = getGlobalAllocator();
    const handle: *OutputHandle = @ptrCast(@alignCast(output));
    allocator.free(handle.data);
    allocator.destroy(handle);
}

/// Process X12 document from memory buffer
///
/// @param x12_data Pointer to X12 data in memory
/// @param x12_length Length of X12 data in bytes
/// @param schema_path Path to schema JSON file (null-terminated C string)
/// @param output_ptr Pointer to receive the output handle (must not be null)
/// @return 0 on success, error code otherwise
export fn zx12_process_from_memory(
    x12_data: [*]const u8,
    x12_length: usize,
    schema_path: [*:0]const u8,
    output_ptr: *?*ZX12_Output,
) c_int {
    // Write X12 data to temporary file
    const temp_filename = "temp_zx12_input.x12";
    const file = std.fs.cwd().createFile(temp_filename, .{}) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    defer file.close();
    defer std.fs.cwd().deleteFile(temp_filename) catch {};

    const x12_slice = x12_data[0..x12_length];
    file.writeAll(x12_slice) catch |err| {
        return @intFromEnum(errorToCode(err));
    };

    // Process using file-based function
    return zx12_process_document(temp_filename, schema_path, output_ptr);
}

/// Get the version string of the zX12 library
///
/// @return Null-terminated version string
export fn zx12_get_version() [*:0]const u8 {
    return "1.0.0";
}

/// Get error message for an error code
///
/// @param error_code Error code from zx12 function
/// @return Null-terminated error message string
export fn zx12_get_error_message(error_code: c_int) [*:0]const u8 {
    const code: ZX12_Error = @enumFromInt(error_code);
    return switch (code) {
        .Success => "Success",
        .OutOfMemory => "Out of memory",
        .InvalidISA => "Invalid ISA segment (must be exactly 106 characters)",
        .FileNotFound => "File not found",
        .ParseError => "X12 parsing error",
        .SchemaLoadError => "Schema loading error",
        .UnknownHLLevel => "Unknown HL level code in schema",
        .PathConflict => "JSON path conflict (trying to overwrite non-object with object)",
        .InvalidArgument => "Invalid argument (library not initialized or null pointer)",
        .UnknownError => "Unknown error",
    };
}

// ============================================================================
// Test the C API
// ============================================================================

test "C API initialization" {
    const result = zx12_init();
    try std.testing.expectEqual(@as(c_int, 0), result);
    defer zx12_deinit();
}

test "C API version" {
    const version = zx12_get_version();
    const version_slice = std.mem.span(version);
    try std.testing.expectEqualStrings("1.0.0", version_slice);
}

test "C API error messages" {
    const msg = zx12_get_error_message(@intFromEnum(ZX12_Error.InvalidISA));
    const msg_slice = std.mem.span(msg);
    try std.testing.expect(msg_slice.len > 0);
}

// Note: The C API tests are skipped because they require linking with libc
// For actual C API testing, compile with `-lc` flag:
//   zig test src/main.zig -lc
//
// test "C API process document" {
//     _ = zx12_init();
//     defer zx12_deinit();
//
//     var output: ?*ZX12_Output = null;
//     const result = zx12_process_document(
//         "samples/837p_example.x12",
//         "schema/837p.json",
//         &output,
//     );
//
//     try std.testing.expectEqual(@as(c_int, 0), result);
//     try std.testing.expect(output != null);
//
//     if (output) |out| {
//         const json_ptr = zx12_get_output(out);
//         try std.testing.expect(json_ptr != null);
//
//         if (json_ptr) |json| {
//             const json_slice = std.mem.span(json);
//             try std.testing.expect(json_slice.len > 0);
//             try std.testing.expect(std.mem.indexOf(u8, json_slice, "interchange") != null);
//         }
//
//         zx12_free_output(out);
//     }
// }
//
// test "C API process from memory" {
//     _ = zx12_init();
//     defer zx12_deinit();
//
//     const x12_data = "ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *231016*1430*^*00501*000000001*0*P*:~" ++
//         "GS*HC*SENDER*RECEIVER*20231016*1430*1*X*005010X222A1~" ++
//         "ST*837*0001*005010X222A1~" ++
//         "BHT*0019*00*123456*20231016*1430*CH~" ++
//         "SE*4*0001~" ++
//         "GE*1*1~" ++
//         "IEA*1*000000001~";
//
//     var output: ?*ZX12_Output = null;
//     const result = zx12_process_from_memory(
//         x12_data.ptr,
//         x12_data.len,
//         "schema/837p.json",
//         &output,
//     );
//
//     try std.testing.expectEqual(@as(c_int, 0), result);
//     try std.testing.expect(output != null);
//
//     if (output) |out| {
//         const json_ptr = zx12_get_output(out);
//         try std.testing.expect(json_ptr != null);
//         zx12_free_output(out);
//     }
// }

// ============================================================================
// Example C Usage
// ============================================================================

// The following would be the C header file (zx12.h):
//
// #ifndef ZX12_H
// #define ZX12_H
//
// #include <stddef.h>
//
// #ifdef __cplusplus
// extern "C" {
// #endif
//
// // Opaque handle to output
// typedef struct ZX12_Output ZX12_Output;
//
// // Error codes
// typedef enum {
//     ZX12_SUCCESS = 0,
//     ZX12_OUT_OF_MEMORY = 1,
//     ZX12_INVALID_ISA = 2,
//     ZX12_FILE_NOT_FOUND = 3,
//     ZX12_PARSE_ERROR = 4,
//     ZX12_SCHEMA_LOAD_ERROR = 5,
//     ZX12_UNKNOWN_HL_LEVEL = 6,
//     ZX12_PATH_CONFLICT = 7,
//     ZX12_INVALID_ARGUMENT = 8,
//     ZX12_UNKNOWN_ERROR = 99
// } ZX12_Error;
//
// // Initialize library
// int zx12_init(void);
//
// // Cleanup library
// void zx12_deinit(void);
//
// // Process X12 document from file
// int zx12_process_document(
//     const char* x12_file_path,
//     const char* schema_path,
//     ZX12_Output** output_ptr
// );
//
// // Process X12 document from memory
// int zx12_process_from_memory(
//     const unsigned char* x12_data,
//     size_t x12_length,
//     const char* schema_path,
//     ZX12_Output** output_ptr
// );
//
// // Get JSON output string
// const char* zx12_get_output(ZX12_Output* output);
//
// // Get JSON output length
// size_t zx12_get_output_length(ZX12_Output* output);
//
// // Free output
// void zx12_free_output(ZX12_Output* output);
//
// // Get library version
// const char* zx12_get_version(void);
//
// // Get error message
// const char* zx12_get_error_message(int error_code);
//
// #ifdef __cplusplus
// }
// #endif
//
// #endif // ZX12_H

// Example C usage:
//
// #include "zx12.h"
// #include <stdio.h>
// #include <stdlib.h>
//
// int main(void) {
//     // Initialize library
//     if (zx12_init() != ZX12_SUCCESS) {
//         fprintf(stderr, "Failed to initialize zX12\n");
//         return 1;
//     }
//
//     // Process document
//     ZX12_Output* output = NULL;
//     int result = zx12_process_document(
//         "input.x12",
//         "schema/837p.json",
//         &output
//     );
//
//     if (result != ZX12_SUCCESS) {
//         fprintf(stderr, "Error: %s\n", zx12_get_error_message(result));
//         zx12_deinit();
//         return 1;
//     }
//
//     // Get JSON output
//     const char* json = zx12_get_output(output);
//     size_t length = zx12_get_output_length(output);
//
//     printf("JSON output (%zu bytes):\n%s\n", length, json);
//
//     // Write to file
//     FILE* f = fopen("output.json", "w");
//     if (f) {
//         fwrite(json, 1, length, f);
//         fclose(f);
//     }
//
//     // Cleanup
//     zx12_free_output(output);
//     zx12_deinit();
//
//     return 0;
// }
