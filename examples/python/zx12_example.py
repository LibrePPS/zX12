#!/usr/bin/env python3
"""
Python bindings for zX12 library

Usage:
    # Build the shared library first:
    zig build-lib src/main.zig -dynamic -lc -femit-bin=libzx12.so

    # Run the Python script:
    python3 examples/python/zx12_example.py samples/837p_example.x12 schema/837p.json
"""

import ctypes
import json
import sys
import os
import time
import statistics
from pathlib import Path

class ZX12Error(Exception):
    """Exception raised for zX12 errors"""
    pass

class ZX12:
    """Python wrapper for zX12 C library"""
    
    # Error codes (must match zx12.h)
    SUCCESS = 0
    OUT_OF_MEMORY = 1
    INVALID_ISA = 2
    FILE_NOT_FOUND = 3
    PARSE_ERROR = 4
    SCHEMA_LOAD_ERROR = 5
    UNKNOWN_HL_LEVEL = 6
    PATH_CONFLICT = 7
    INVALID_ARGUMENT = 8
    UNKNOWN_ERROR = 99
    
    def __init__(self, lib_path='./libzx12.so'):
        """
        Initialize zX12 library
        
        Args:
            lib_path: Path to libzx12.so shared library
        """
        # Load shared library
        self.lib = ctypes.CDLL(lib_path)
        
        # Define return types and argument types
        self.lib.zx12_init.restype = ctypes.c_int
        self.lib.zx12_init.argtypes = []
        
        self.lib.zx12_deinit.restype = None
        self.lib.zx12_deinit.argtypes = []
        
        self.lib.zx12_process_document.restype = ctypes.c_int
        self.lib.zx12_process_document.argtypes = [
            ctypes.c_char_p,  # x12_file_path
            ctypes.c_char_p,  # schema_path
            ctypes.POINTER(ctypes.c_void_p)  # output_ptr
        ]
        
        self.lib.zx12_process_from_memory.restype = ctypes.c_int
        self.lib.zx12_process_from_memory.argtypes = [
            ctypes.POINTER(ctypes.c_ubyte),  # x12_data
            ctypes.c_size_t,  # x12_length
            ctypes.c_char_p,  # schema_path
            ctypes.POINTER(ctypes.c_void_p)  # output_ptr
        ]
        
        self.lib.zx12_get_output.restype = ctypes.c_char_p
        self.lib.zx12_get_output.argtypes = [ctypes.c_void_p]
        
        self.lib.zx12_get_output_length.restype = ctypes.c_size_t
        self.lib.zx12_get_output_length.argtypes = [ctypes.c_void_p]
        
        self.lib.zx12_free_output.restype = None
        self.lib.zx12_free_output.argtypes = [ctypes.c_void_p]
        
        self.lib.zx12_get_version.restype = ctypes.c_char_p
        self.lib.zx12_get_version.argtypes = []
        
        self.lib.zx12_get_error_message.restype = ctypes.c_char_p
        self.lib.zx12_get_error_message.argtypes = [ctypes.c_int]
        
        # Initialize library
        result = self.lib.zx12_init()
        if result != self.SUCCESS:
            raise ZX12Error(f"Failed to initialize library: {self._get_error(result)}")
    
    def __del__(self):
        """Cleanup library on destruction"""
        if hasattr(self, 'lib'):
            self.lib.zx12_deinit()
    
    def __enter__(self):
        """Context manager support"""
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager cleanup"""
        self.__del__()
    
    def _get_error(self, error_code):
        """Get error message for error code"""
        msg = self.lib.zx12_get_error_message(error_code)
        return msg.decode('utf-8') if msg else f"Unknown error {error_code}"
    
    def get_version(self):
        """Get library version string"""
        version = self.lib.zx12_get_version()
        return version.decode('utf-8')
    
    def process_file(self, x12_file_path, schema_path):
        """
        Process X12 file and return JSON
        
        Args:
            x12_file_path: Path to X12 file
            schema_path: Path to schema JSON file
            
        Returns:
            dict: Parsed JSON data
            
        Raises:
            ZX12Error: If processing fails
        """
        output = ctypes.c_void_p()
        
        result = self.lib.zx12_process_document(
            x12_file_path.encode('utf-8'),
            schema_path.encode('utf-8'),
            ctypes.byref(output)
        )
        
        if result != self.SUCCESS:
            raise ZX12Error(self._get_error(result))
        
        try:
            # Get JSON string
            json_str = self.lib.zx12_get_output(output)
            if not json_str:
                raise ZX12Error("Failed to get output")
            
            # Decode and parse JSON
            json_data = json_str.decode('utf-8')
            return json.loads(json_data)
        finally:
            # Always free output
            self.lib.zx12_free_output(output)
    
    def process_string(self, x12_data, schema_path):
        """
        Process X12 data from string and return JSON
        
        Args:
            x12_data: X12 data as string
            schema_path: Path to schema JSON file
            
        Returns:
            dict: Parsed JSON data
            
        Raises:
            ZX12Error: If processing fails
        """
        x12_bytes = x12_data.encode('utf-8')
        x12_array = (ctypes.c_ubyte * len(x12_bytes))(*x12_bytes)
        output = ctypes.c_void_p()
        
        result = self.lib.zx12_process_from_memory(
            x12_array,
            len(x12_bytes),
            schema_path.encode('utf-8'),
            ctypes.byref(output)
        )
        
        if result != self.SUCCESS:
            raise ZX12Error(self._get_error(result))
        
        try:
            # Get JSON string
            json_str = self.lib.zx12_get_output(output)
            if not json_str:
                raise ZX12Error("Failed to get output")
            
            # Decode and parse JSON
            json_data = json_str.decode('utf-8')
            return json.loads(json_data)
        finally:
            # Always free output
            self.lib.zx12_free_output(output)


def benchmark(zx12, x12_file, schema_file, iterations=10000):
    """
    Benchmark parsing performance
    
    Args:
        zx12: ZX12 instance
        x12_file: Path to X12 file
        schema_file: Path to schema file
        iterations: Number of iterations to run
    """
    print(f"\n{'='*60}")
    print(f"PERFORMANCE BENCHMARK")
    print(f"{'='*60}")
    print(f"File: {x12_file}")
    print(f"Schema: {schema_file}")
    print(f"Iterations: {iterations:,}")
    print(f"{'='*60}\n")
    
    times = []
    
    # Warmup run (not counted)
    print("Warming up... ", end='', flush=True)
    _ = zx12.process_file(x12_file, schema_file)
    print("Done!")
    
    # Benchmark runs
    print(f"Running {iterations:,} iterations... ", end='', flush=True)
    for i in range(iterations):
        start = time.perf_counter()
        _ = zx12.process_file(x12_file, schema_file)
        end = time.perf_counter()
        times.append((end - start) * 1000)  # Convert to milliseconds
        
        # Progress indicator every 1000 iterations
        if (i + 1) % 1000 == 0:
            print(f"{i+1:,}...", end='', flush=True)
    
    print(" Done!\n")
    
    # Calculate statistics
    mean = statistics.mean(times)
    median = statistics.median(times)
    stdev = statistics.stdev(times) if len(times) > 1 else 0
    min_time = min(times)
    max_time = max(times)
    total_time = sum(times)
    
    # Calculate percentiles
    sorted_times = sorted(times)
    p50 = sorted_times[len(sorted_times) * 50 // 100]
    p95 = sorted_times[len(sorted_times) * 95 // 100]
    p99 = sorted_times[len(sorted_times) * 99 // 100]
    
    # Print results
    print(f"{'='*60}")
    print(f"RESULTS")
    print(f"{'='*60}")
    print(f"Total time:       {total_time:>12.2f} ms ({total_time/1000:.2f} seconds)")
    print(f"Mean time:        {mean:>12.4f} ms")
    print(f"Median time:      {median:>12.4f} ms")
    print(f"Std deviation:    {stdev:>12.4f} ms")
    print(f"Min time:         {min_time:>12.4f} ms")
    print(f"Max time:         {max_time:>12.4f} ms")
    print(f"{'='*60}")
    print(f"PERCENTILES")
    print(f"{'='*60}")
    print(f"50th percentile:  {p50:>12.4f} ms")
    print(f"95th percentile:  {p95:>12.4f} ms")
    print(f"99th percentile:  {p99:>12.4f} ms")
    print(f"{'='*60}")
    print(f"THROUGHPUT")
    print(f"{'='*60}")
    print(f"Parses/second:    {1000/mean:>12.2f}")
    print(f"Parses/minute:    {60000/mean:>12.2f}")
    print(f"{'='*60}\n")


def main():
    """Example usage"""
    # Parse arguments
    benchmark_mode = False
    benchmark_iterations = 10000
    args = sys.argv[1:]
    
    # Check for benchmark flag
    if '--benchmark' in args:
        benchmark_mode = True
        args.remove('--benchmark')
        
        # Check for custom iteration count
        for i, arg in enumerate(args):
            if arg.startswith('--iterations='):
                try:
                    benchmark_iterations = int(arg.split('=')[1])
                    args.pop(i)
                    break
                except (ValueError, IndexError):
                    print(f"Error: Invalid iterations value", file=sys.stderr)
                    sys.exit(1)
    
    if len(args) != 2:
        print(f"Usage: {sys.argv[0]} <x12_file> <schema_file> [--benchmark] [--iterations=N]", file=sys.stderr)
        print(f"\nExample:", file=sys.stderr)
        print(f"  {sys.argv[0]} samples/837p_example.x12 schema/837p.json", file=sys.stderr)
        print(f"  {sys.argv[0]} samples/837p_example.x12 schema/837p.json --benchmark", file=sys.stderr)
        print(f"  {sys.argv[0]} samples/837p_example.x12 schema/837p.json --benchmark --iterations=5000", file=sys.stderr)
        sys.exit(1)
    
    x12_file = args[0]
    schema_file = args[1]
    
    # Find library
    lib_path = './libzx12.so'
    if not os.path.exists(lib_path):
        lib_path = './zig-out/lib/libzx12.so'
    if not os.path.exists(lib_path):
        print(f"Error: libzx12.so not found", file=sys.stderr)
        print(f"Build it with: zig build-lib src/main.zig -dynamic -lc -femit-bin=libzx12.so", file=sys.stderr)
        sys.exit(1)
    
    try:
        # Use context manager for automatic cleanup
        with ZX12(lib_path) as zx12:
            print(f"zX12 version: {zx12.get_version()}")
            
            if benchmark_mode:
                # Run benchmark
                benchmark(zx12, x12_file, schema_file, benchmark_iterations)
            else:
                # Normal processing
                print(f"Processing: {x12_file}")
                print(f"Schema: {schema_file}")
                
                # Process file
                result = zx12.process_file(x12_file, schema_file)
                
                # Print formatted JSON
                print("\n=== JSON Output ===")
                print(json.dumps(result, indent=2))
                
                # Write to file
                output_file = "output.json"
                with open(output_file, 'w') as f:
                    json.dump(result, f, indent=2)
                print(f"\nOutput written to: {output_file}")
            
    except ZX12Error as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
