// swift-tools-version: 6.1
import PackageDescription

var targets: [Target] = [
    .target(
        name: "SQLiteSnapshotShims",
        path: "Sources/SQLiteSnapshotShims",
        publicHeadersPath: "."
    ),
    .target(
        name: "SwiftThreadingShim",
        path: "Sources/SwiftThreadingShim"
    ),
    // Core: storage-agnostic. Does NOT depend on GRDB/SQLite, so consumers who
    // use the in-memory or Codable backends link no database.
    .target(
        name: "SwiftUIQuery",
        dependencies: [
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "Crypto", package: "swift-crypto"),
            "SwiftThreadingShim"
        ]
    ),
    // GRDB-backed persistence. Only consumers who want SQLite link this + GRDB.
    .target(
        name: "SwiftUIQueryGRDB",
        dependencies: [
            "SwiftUIQuery",
            .product(name: "GRDB", package: "GRDB.swift"),
            "SQLiteSnapshotShims"
        ]
    ),
    .executableTarget(
        name: "TestApp",
        dependencies: ["SwiftUIQuery"],
        path: "Sources/TestApp"
    ),
    .testTarget(
        name: "SwiftUIQueryTests",
        dependencies: ["SwiftUIQuery", "SwiftUIQueryGRDB"]
    )
]

#if os(Linux)
targets.removeAll { $0.name == "TestApp" }
#endif

let package = Package(
    name: "SwiftUIQuery",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SwiftUIQuery", targets: ["SwiftUIQuery"]),
        .library(name: "SwiftUIQueryGRDB", targets: ["SwiftUIQueryGRDB"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.8.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.7.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
    ],
    targets: targets
)
