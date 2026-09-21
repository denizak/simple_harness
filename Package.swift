// swift-tools-version:6.2
// A minimal agent harness — no external dependencies on purpose.
// Everything (HTTP client, tools, loop) is written from scratch so you can
// read every moving part.
import PackageDescription

let package = Package(
    name: "simple_harness",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "harness",
            path: "Sources/harness"
        )
    ]
)