#!/usr/bin/env bash
# Quick validation script for test setup
set -euo pipefail

echo "=== Testing test setup validation ==="

cd "$(dirname "$0")/.."

# Test 1: Script syntax
echo "Test 1: Checking script syntax..."
if bash -n test/run-tests.sh; then
    echo "PASS: test/run-tests.sh syntax is valid"
else
    echo "FAIL: test/run-tests.sh has syntax errors"
    exit 1
fi

# Test 2: Check if script is executable
echo "Test 2: Checking script permissions..."
if [[ -x test/run-tests.sh ]]; then
    echo "PASS: test/run-tests.sh is executable"
else
    echo "FAIL: test/run-tests.sh is not executable"
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
if [[ -f test/README.org ]]; then
    echo "PASS: test/README.org documentation exists"
else
    echo "FAIL: test/README.org documentation not found"
    exit 1
fi

echo "=== All validation tests passed ==="
echo ""
echo "To run the full test suite: ./test/run-tests.sh"
echo "To run with cleanup: CLEANUP=1 ./test/run-tests.sh"