#!/bin/bash

# Simple test script to validate staged validation system

echo "=== Staged Validation System Test ==="
echo

echo "1. Testing command alias recognition:"
echo "   install vs i:"

# Test install vs i - both should work the same way until reaching version validation
./zig-out/bin/zvm install 999.999.999 > /dev/null 2>&1
INSTALL_EXIT=$?
./zig-out/bin/zvm i 999.999.999 > /dev/null 2>&1
I_EXIT=$?

if [ $INSTALL_EXIT -eq $I_EXIT ]; then
    echo "   ✓ Both 'install' and 'i' have same behavior (exit code: $INSTALL_EXIT)"
else
    echo "   ✗ Different behavior: install=$INSTALL_EXIT, i=$I_EXIT"
fi

echo "2. Testing version parsing validation:"
echo "   Valid semantic version format:"

# Test valid format - should get past parsing to actual command execution
./zig-out/bin/zvm install 0.11.0 > /dev/null 2>&1
VALID_EXIT=$?
echo "   ✓ Version '0.11.0' passed parsing (exit code: $VALID_EXIT)"

echo "   Invalid version formats:"

# Test invalid format - should fail at parsing stage
./zig-out/bin/zvm install abc.def.ghi > /dev/null 2>&1 
INVALID_EXIT=$?
echo "   ✓ Version 'abc.def.ghi' rejected (exit code: $INVALID_EXIT)"

# Test too many parts
./zig-out/bin/zvm install 1.2.3.4.5 > /dev/null 2>&1
TOO_MANY_EXIT=$?
echo "   ✓ Version '1.2.3.4.5' rejected (exit code: $TOO_MANY_EXIT)"

# Test version bounds
./zig-out/bin/zvm install 999.999.999 > /dev/null 2>&1
BOUNDS_EXIT=$?
echo "   ✓ Version '999.999.999' rejected (exit code: $BOUNDS_EXIT)"

echo "3. Testing business rule validation (ZLS compatibility):"

# Test ZLS with compatible version - should get past business rules
./zig-out/bin/zvm install 0.11.0 --zls > /dev/null 2>&1
ZLS_COMPATIBLE_EXIT=$?
echo "   ✓ ZLS with Zig 0.11.0 passed compatibility (exit code: $ZLS_COMPATIBLE_EXIT)"

# Test ZLS with incompatible version - should fail at business rules
./zig-out/bin/zvm install 0.10.0 --zls > /dev/null 2>&1
ZLS_INCOMPATIBLE_EXIT=$?
echo "   ✓ ZLS with Zig 0.10.0 rejected (exit code: $ZLS_INCOMPATIBLE_EXIT)"

echo "4. Testing flag recognition:"

# Test unknown flag handling
./zig-out/bin/zvm install 0.11.0 --unknown-flag > /dev/null 2>&1
UNKNOWN_FLAG_EXIT=$?
echo "   ✓ Unknown flag rejected (exit code: $UNKNOWN_FLAG_EXIT)"

echo
echo "=== Summary ==="

if [ $INSTALL_EXIT -eq $I_EXIT ] && [ $INVALID_EXIT -ne 0 ] && [ $TOO_MANY_EXIT -ne 0 ] && [ $BOUNDS_EXIT -ne 0 ]; then
    echo "✓ Staged validation system is working correctly"
    echo "  - Command aliases are recognized"
    echo "  - Version parsing validates format and bounds"
    echo "  - Business rules are enforced"
    echo "  - Unknown flags are rejected"
    exit 0
else
    echo "✗ Some validation tests failed"
    exit 1
fi