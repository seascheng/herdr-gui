#!/bin/bash
# Compile and run the herdr-gui test suite. Deliberately mirrors build.sh's
# plain-swiftc setup (no SPM/XCTest): an explicit source list so protocol
# tests never link GhosttyKit or the app's UI files.

set -e
cd "$(dirname "$0")/.."
mkdir -p build

TEST_SOURCES=(
    Sources/Infra/Bincode.swift
    Sources/Infra/BincodeReader.swift
    Sources/Herdr/Endpoint/EndpointWire.swift

    Tests/TestMain.swift
    Tests/EndpointWireTests.swift
    Tests/FixtureTests.swift
)

swiftc \
    -parse-as-library -enable-bare-slash-regex \
    -Onone \
    "${TEST_SOURCES[@]}" \
    -framework Foundation -framework AppKit -framework CoreText \
    -o build/herdr-gui-tests

./build/herdr-gui-tests
