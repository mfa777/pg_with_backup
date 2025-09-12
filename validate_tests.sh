#!/usr/bin/env bash
# Quick validation script for setupTests
set -euo pipefail

echo "=== Testing setupTests script validation ==="

cd "$(dirname "$0")"

# Test 1: Script syntax
echo "Test 1: Checking script syntax..."
if bash -n setupTests; then
    echo "PASS: setupTests syntax is valid"
else
    echo "FAIL: setupTests has syntax errors"
    exit 1
fi

# Test 2: Check if script is executable
echo "Test 2: Checking script permissions..."
if [[ -x setupTests ]]; then
    echo "PASS: setupTests is executable"
else
    echo "FAIL: setupTests is not executable"
    exit 1
fi

# Test 3: Check .env file exists
echo "Test 3: Checking .env file..."
if [[ -f .env ]]; then
    echo "PASS: .env file exists"
else
    echo "FAIL: .env file not found"
    exit 1
fi

# Test 4: Check docker-compose.yml is valid
echo "Test 4: Validating docker-compose.yml..."
if docker compose config >/dev/null 2>&1; then
    echo "PASS: docker-compose.yml is valid"
else
    echo "FAIL: docker-compose.yml has errors"
    exit 1
fi

# Test 5: Check test documentation exists
echo "Test 5: Checking test documentation..."
if [[ -f test_README.org ]]; then
    echo "PASS: test_README.org documentation exists"
else
    echo "FAIL: test_README.org documentation not found"
    exit 1
fi

echo "=== All validation tests passed ==="
echo ""
echo "To run the full test suite: ./setupTests"
echo "To run with cleanup: CLEANUP=1 ./setupTests"