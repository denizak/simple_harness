// swift-tools-version:6.2
// A minimal agent harness — no external dependencies on purpose.
//
// Package layout (the standard SwiftPM shape for testable apps):
//   HarnessCore    library: every moving part (types, tools, loop, client,
//                  config, compaction, sessions) — importable by tests
//   harness        thin executable: the REPL + CLI flags, delegating to
//                  HarnessCore
//   HarnessTests   swift-testing suite run by `swift test`
//
// Why the split: executables cannot be imported by test targets, and
// sourcekit-lsp's SwiftPM integration does not support test targets that
// depend on executable targets (its module graph reports phantom
// "cannot find" errors for symbols swiftc compiles clean). A library
// target fixes both: testable logic is importable, and the LSP resolves it.
import PackageDescription

let package = Package(
    name: "simple_harness",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HarnessCore", path: "Sources/HarnessCore"),
        .executableTarget(
            name: "harness",
            dependencies: ["HarnessCore"],
            path: "Sources/harness"
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["HarnessCore"],
            path: "Tests/HarnessTests"
        ),
    ]
)