// swift-tools-version:6.2
// A minimal agent harness — no external dependencies on purpose.
//
// Tests live in a real SwiftPM test target so `swift test` works as the CI
// entry point (it always rebuilds, avoiding the stale-binary trap of
// hand-rolled flags). The tests reach the executable's internals via
// `@testable import harness` — fine for a single-module learning project;
// the next growth step is splitting a library target out (executables
// themselves can't be imported without @testable).
import PackageDescription

let package = Package(
    name: "simple_harness",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "harness", path: "Sources/harness"),
        .testTarget(
            name: "HarnessTests",
            dependencies: [.target(name: "harness")],
            path: "Tests/HarnessTests"
        ),
    ]
)