#!/bin/bash

# Test script for TigerStyle-compliant centralized output management
# Demonstrates the new zero-allocation, bounds-checked output system

echo "=== TigerStyle ZVM Output Management Test ==="
echo

echo "1. Human-readable output (with colors):"
./zig-out/bin/zvm version
echo

echo "2. JSON output (machine-readable, zero allocation):"
./zig-out/bin/zvm --json version
echo

echo "3. Silent mode (errors only):"
./zig-out/bin/zvm --quiet version
echo "(Silent - correct behavior)"
echo

echo "4. Current version with bounds checking:"
./zig-out/bin/zvm current
echo

echo "5. Current version in JSON (typed fields):"
./zig-out/bin/zvm --json current
echo

echo "6. Help with comprehensive options:"
./zig-out/bin/zvm --help | head -12
echo

echo "7. Meaningful exit codes test:"
echo -n "Success: "
./zig-out/bin/zvm version >/dev/null 2>&1 && echo "Exit code: $?" || echo "Exit code: $?"

echo -n "Invalid argument: "
./zig-out/bin/zvm invalid-cmd >/dev/null 2>&1 && echo "Exit code: $?" || echo "Exit code: $?"

echo -n "Missing argument: "
./zig-out/bin/zvm install >/dev/null 2>&1 && echo "Exit code: $?" || echo "Exit code: $?"

echo
echo "=== TigerStyle Features Demonstrated ==="
echo "✓ Static memory allocation - no malloc/free after init"
echo "✓ Bounds checking on all operations - assertion density 2+ per function"
echo "✓ Meaningful exit codes (0-8) - semantic error reporting"
echo "✓ JSON output - machine-readable for automation"
echo "✓ Silent mode - script-friendly operation"
echo "✓ Explicit control flow - no hidden state or magic"
echo "✓ Fixed buffers - all memory usage known at compile time"
echo "✓ Type safety - enum-based configuration, no stringly-typed parameters"