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
    Sources/Herdr/Endpoint/EndpointHandshake.swift
    Sources/Herdr/Endpoint/EndpointSession.swift
    Sources/Herdr/Endpoint/EndpointClient.swift
    Sources/Herdr/Endpoint/EndpointModel.swift
    Sources/Herdr/HerdrModel.swift
    Sources/Infra/UnixSocket.swift
    Sources/Terminal/CellCanvas/CellTheme.swift
    Sources/Terminal/CellCanvas/CellInputMapper.swift
    Sources/Terminal/CellCanvas/CellSurfaceView.swift

    Tests/TestMain.swift
    Tests/CellSurfaceLogicTests.swift
    Tests/CellThemeTests.swift
    Tests/CellInputMapperTests.swift
    Tests/EndpointModelTests.swift
    Tests/EndpointSessionTests.swift
    Tests/EndpointHandshakeTests.swift
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
