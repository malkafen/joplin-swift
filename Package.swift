// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "JoplinNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JoplinNative", targets: ["JoplinNative"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "JoplinCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "JoplinNative",
            dependencies: [
                "JoplinCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(
            name: "JoplinCoreTests",
            dependencies: ["JoplinCore"]
        ),
        .testTarget(
            name: "JoplinNativeTests",
            dependencies: ["JoplinNative", "JoplinCore"]
        ),
    ]
)
