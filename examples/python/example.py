import sys
import json
import time
import statistics
import gc
from zx12 import ZX12, ZX12Error

# Try to import psutil for memory tracking
try:
    import psutil

    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False
    print("Note: Install 'psutil' for memory usage tracking: pip install psutil\n")


def benchmark(zx12, x12_file, schema_file, iterations=10000, track_times=True):
    """
    Benchmark parsing performance with pre-loaded schema

    Args:
        zx12: ZX12 instance
        x12_file: Path to X12 file
        schema_file: Path to schema file
        iterations: Number of iterations to run
        track_times: Whether to track individual iteration times (uses memory)
    """
    print(f"\n{'=' * 60}")
    print(f"PERFORMANCE BENCHMARK")
    print(f"{'=' * 60}")
    print(f"File: {x12_file}")
    print(f"Schema: {schema_file}")
    print(f"Iterations: {iterations:,}")
    print(f"{'=' * 60}\n")

    times = []
    memory_samples = []

    # Get process for memory tracking
    if PSUTIL_AVAILABLE:
        process = psutil.Process()
        # Force garbage collection for accurate initial measurement
        gc.collect()
        initial_memory = process.memory_info().rss / 1024 / 1024  # Convert to MB
        print(f"Initial memory usage: {initial_memory:.2f} MB\n")

    # Load schema once for all iterations
    print("Loading schema... ", end="", flush=True)
    with zx12.load_schema(schema_file) as schema:
        print("Done!")

        if PSUTIL_AVAILABLE:
            gc.collect()
            schema_loaded_memory = process.memory_info().rss / 1024 / 1024
            print(
                f"Memory after schema load: {schema_loaded_memory:.2f} MB (+{schema_loaded_memory - initial_memory:.2f} MB)\n"
            )

        # Warmup run (not counted)
        print("Warming up... ", end="", flush=True)
        _ = zx12.process_file_with_schema(x12_file, schema)
        print("Done!")

        if PSUTIL_AVAILABLE:
            gc.collect()
            warmup_memory = process.memory_info().rss / 1024 / 1024
            print(f"Memory after warmup: {warmup_memory:.2f} MB\n")

        # Benchmark runs
        if not track_times:
            print(f"Note: Running without time tracking to test for memory leaks\n")
        print(f"Running {iterations:,} iterations... ", end="", flush=True)
        sample_interval = max(1, iterations // 20)  # Sample memory ~20 times during run

        start_time = time.perf_counter()
        for i in range(iterations):
            if track_times:
                start = time.perf_counter()
            _ = zx12.process_file_with_schema(x12_file, schema)
            if track_times:
                end = time.perf_counter()
                times.append((end - start) * 1000)  # Convert to milliseconds

            # Memory sampling
            if PSUTIL_AVAILABLE and i % sample_interval == 0:
                current_memory = process.memory_info().rss / 1024 / 1024
                memory_samples.append(current_memory)

            # Progress indicator every 1000 iterations
            if (i + 1) % 1000 == 0:
                print(f"{i + 1:,}...", end="", flush=True)

        end_time = time.perf_counter()
        print(" Done!\n")

    # Final memory measurement
    if PSUTIL_AVAILABLE:
        gc.collect()
        final_memory = process.memory_info().rss / 1024 / 1024

    # Calculate statistics
    if track_times and times:
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
        print(f"{'=' * 60}")
        print(f"RESULTS")
        print(f"{'=' * 60}")
        print(
            f"Total time:       {total_time:>12.2f} ms ({total_time / 1000:.2f} seconds)"
        )
        print(f"Mean time:        {mean:>12.4f} ms")
        print(f"Median time:      {median:>12.4f} ms")
        print(f"Std deviation:    {stdev:>12.4f} ms")
        print(f"Min time:         {min_time:>12.4f} ms")
        print(f"Max time:         {max_time:>12.4f} ms")
        print(f"{'=' * 60}")
        print(f"PERCENTILES")
        print(f"{'=' * 60}")
        print(f"50th percentile:  {p50:>12.4f} ms")
        print(f"95th percentile:  {p95:>12.4f} ms")
        print(f"99th percentile:  {p99:>12.4f} ms")
        print(f"{'=' * 60}")
        print(f"THROUGHPUT")
        print(f"{'=' * 60}")
        print(f"Parses/second:    {1000 / mean:>12.2f}")
        print(f"Parses/minute:    {60000 / mean:>12.2f}")
        print(f"{'=' * 60}")
    else:
        # When not tracking times, just show overall throughput
        total_elapsed = (end_time - start_time) * 1000  # Convert to ms
        avg_time = total_elapsed / iterations
        print(f"{'=' * 60}")
        print(f"RESULTS (No detailed timing)")
        print(f"{'=' * 60}")
        print(
            f"Total time:       {total_elapsed:>12.2f} ms ({total_elapsed / 1000:.2f} seconds)"
        )
        print(f"Avg time:         {avg_time:>12.4f} ms")
        print(f"{'=' * 60}")
        print(f"THROUGHPUT")
        print(f"{'=' * 60}")
        print(f"Parses/second:    {1000 / avg_time:>12.2f}")
        print(f"Parses/minute:    {60000 / avg_time:>12.2f}")
        print(f"{'=' * 60}")

    # Print memory statistics
    if PSUTIL_AVAILABLE:
        print(f"MEMORY USAGE")
        print(f"{'=' * 60}")
        print(f"Initial memory:   {initial_memory:>12.2f} MB")
        print(
            f"After schema:     {schema_loaded_memory:>12.2f} MB (+{schema_loaded_memory - initial_memory:.2f} MB)"
        )
        print(f"After warmup:     {warmup_memory:>12.2f} MB")
        print(f"Final memory:     {final_memory:>12.2f} MB")
        print(f"Peak memory:      {max(memory_samples):>12.2f} MB")
        print(f"Memory delta:     {final_memory - initial_memory:>12.2f} MB")

        # Estimate expected memory from times list
        if track_times:
            expected_times_memory = (
                (iterations * 32) / 1024 / 1024
            )  # ~32 bytes per float with overhead
            print(
                f"Expected (times): {expected_times_memory:>12.2f} MB (estimated for {iterations:,} floats)"
            )
        print(f"{'=' * 60}")

        # Check for potential memory leak
        memory_growth = final_memory - warmup_memory

        # Adjust for expected times list memory
        if track_times:
            adjusted_growth = memory_growth - expected_times_memory
            print(f"Memory growth:    {memory_growth:>12.2f} MB")
            print(
                f"Adjusted growth:  {adjusted_growth:>12.2f} MB (excluding times list)"
            )
            memory_growth = adjusted_growth

        if abs(memory_growth) < 1.0:  # Less than 1 MB growth
            print(f"✓ No significant memory leak detected")
        elif memory_growth > 0:
            growth_per_iteration = memory_growth / iterations * 1000  # KB per iteration
            print(
                f"⚠ Memory increased by {memory_growth:.2f} MB (~{growth_per_iteration:.2f} KB/iteration)"
            )
            if track_times:
                print(
                    f"  Note: Run with --no-timing to exclude times list from analysis"
                )
        else:
            print(f"✓ Memory decreased/stable (adjusted: {memory_growth:.2f} MB)")
        print(f"{'=' * 60}")
    else:
        print(f"MEMORY TRACKING")
        print(f"{'=' * 60}")
        print(f"Install 'psutil' for memory usage tracking:")
        print(f"  pip install psutil")
        print(f"{'=' * 60}")

    print()


def demonstrate_usage_options(zx12, x12_file, schema_file):
    """
    Demonstrate the three different ways to use the library
    """
    print(f"\n{'=' * 60}")
    print("USAGE EXAMPLES")
    print(f"{'=' * 60}\n")

    # Option 1: Old API - Convenience (loads schema each time)
    print("Option 1: Convenience API (loads schema each time)")
    print("-" * 60)
    print("Code:")
    print("  result = zx12.process_file('input.x12', 'schema/837p.json')")
    print("\nExecuting...")
    result1 = zx12.process_file(x12_file, schema_file)
    print(f"✓ Success! Parsed {len(json.dumps(result1))} bytes of JSON\n")

    # Option 2: Context Manager - Recommended for multiple documents
    print("Option 2: Context Manager (recommended for batch processing)")
    print("-" * 60)
    print("Code:")
    print("  with zx12.load_schema('schema/837p.json') as schema:")
    print("      result1 = zx12.process_file_with_schema('input1.x12', schema)")
    print("      result2 = zx12.process_file_with_schema('input2.x12', schema)")
    print("  # Schema automatically freed when exiting context")
    print("\nExecuting...")
    with zx12.load_schema(schema_file) as schema:
        result2 = zx12.process_file_with_schema(x12_file, schema)
        # Simulate processing multiple files
        result3 = zx12.process_file_with_schema(x12_file, schema)
    print("✓ Success! Processed 2 documents with pre-loaded schema\n")

    # Option 3: Manual Management - Most control
    print("Option 3: Manual Management (explicit control)")
    print("-" * 60)
    print("Code:")
    print("  schema = zx12.load_schema('schema/837p.json')")
    print("  result1 = zx12.process_file_with_schema('input1.x12', schema)")
    print("  result2 = zx12.process_file_with_schema('input2.x12', schema)")
    print("  schema.free()  # Explicitly free when done")
    print("\nExecuting...")
    schema = zx12.load_schema(schema_file)
    result4 = zx12.process_file_with_schema(x12_file, schema)
    result5 = zx12.process_file_with_schema(x12_file, schema)
    schema.free()
    print(f"✓ Success! Processed 2 documents and freed schema explicitly\n")

    # Bonus: Process from string/memory
    print("Bonus: Process from memory with pre-loaded schema")
    print("-" * 60)
    print("Code:")
    print("  with zx12.load_schema('schema/837p.json') as schema:")
    print("      result = zx12.process_string_with_schema(x12_data, schema)")
    print("\nExecuting...")
    # Read X12 file into string
    with open(x12_file, "r") as f:
        x12_data = f.read()
    with zx12.load_schema(schema_file) as schema:
        result6 = zx12.process_string_with_schema(x12_data, schema)
    print(f"✓ Success! Processed X12 data from memory\n")

    print(f"{'=' * 60}")
    print("All examples completed successfully!")
    print(f"{'=' * 60}\n")

    # Return the first result for display
    return result1


def main():
    """Example usage"""
    # Parse arguments
    benchmark_mode = False
    examples_mode = False
    benchmark_iterations = 10000
    no_timing = False
    args = sys.argv[1:]

    # Check for flags
    if "--benchmark" in args:
        benchmark_mode = True
        args.remove("--benchmark")

    if "--examples" in args:
        examples_mode = True
        args.remove("--examples")

    if "--no-timing" in args:
        no_timing = True
        args.remove("--no-timing")

    # Check for custom iteration count
    for i, arg in enumerate(args):
        if arg.startswith("--iterations="):
            try:
                benchmark_iterations = int(arg.split("=")[1])
                args.pop(i)
                break
            except (ValueError, IndexError):
                print(f"Error: Invalid iterations value", file=sys.stderr)
                sys.exit(1)

    if len(args) != 2:
        print(
            f"Usage: {sys.argv[0]} <x12_file> <schema_file> [OPTIONS]",
            file=sys.stderr,
        )
        print("\nOptions:", file=sys.stderr)
        print(
            "  --examples              Show usage examples for all API styles",
            file=sys.stderr,
        )
        print(f"  --benchmark             Run performance benchmark", file=sys.stderr)
        print(
            f"  --iterations=N          Number of benchmark iterations (default: 10000)",
            file=sys.stderr,
        )
        print(
            f"  --no-timing             Skip timing collection (for pure memory leak testing)",
            file=sys.stderr,
        )
        print("\nExamples:", file=sys.stderr)
        print(
            f"  {sys.argv[0]} samples/837p_example.x12 schema/837p.json",
            file=sys.stderr,
        )
        print(
            f"  {sys.argv[0]} samples/837p_example.x12 schema/837p.json --examples",
            file=sys.stderr,
        )
        print(
            f"  {sys.argv[0]} samples/837p_example.x12 schema/837p.json --benchmark",
            file=sys.stderr,
        )
        print(
            f"  {sys.argv[0]} samples/837p_example.x12 schema/837p.json --benchmark --iterations=5000",
            file=sys.stderr,
        )
        sys.exit(1)

    x12_file = args[0]
    schema_file = args[1]

    try:
        # Use context manager for automatic cleanup
        with ZX12() as zx12:
            print(f"zX12 version: {zx12.get_version()}")

            if benchmark_mode:
                # Run benchmark with pre-loaded schema
                benchmark(
                    zx12,
                    x12_file,
                    schema_file,
                    benchmark_iterations,
                    track_times=not no_timing,
                )
            elif examples_mode:
                # Show usage examples
                result = demonstrate_usage_options(zx12, x12_file, schema_file)
                # Print first result as sample
                print("Sample output from first example:")
                print(json.dumps(result, indent=2)[:500] + "...")
            else:
                # Normal processing using convenience API
                print(f"Processing: {x12_file}")
                print(f"Schema: {schema_file}")

                # Process file
                result = zx12.process_file(x12_file, schema_file)

                # Print formatted JSON
                print("\n=== JSON Output ===")
                print(json.dumps(result, indent=2))

                # Write to file
                output_file = "output.json"
                with open(output_file, "w") as f:
                    json.dump(result, f, indent=2)
                print(f"\nOutput written to: {output_file}")

    except ZX12Error as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        import traceback

        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
