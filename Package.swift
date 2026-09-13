// swift-tools-version: 5.9

import PackageDescription

#if os(Linux)
let pendantKitExcludes = ["PendantClient.swift"]
#else
let pendantKitExcludes: [String] = []
#endif

var products: [Product] = [
    .library(name: "Domain", targets: ["Domain"]),
    .library(name: "PendantKit", targets: ["PendantKit"])
]

var targets: [Target] = [
    .target(name: "Domain", path: "Sources/Domain"),
    .target(
        name: "PendantKit",
        dependencies: ["Domain", .product(name: "Crypto", package: "swift-crypto")],
        path: "Sources/PendantKit",
        exclude: pendantKitExcludes
    ),
    .testTarget(name: "DomainTests", dependencies: ["Domain"], path: "Tests/DomainTests"),
    .testTarget(name: "PendantKitTests", dependencies: ["PendantKit", "Domain"], path: "Tests/PendantKitTests")
]

#if !os(Linux)
products.append(.executable(name: "LocalPendantApp", targets: ["LocalPendantApp"]))
targets.append(.executableTarget(
    name: "LocalPendantApp",
    dependencies: ["Domain", "PendantKit"],
    path: "Sources/LocalPendantApp"
))
#endif

let package = Package(
    name: "LocalPendant",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
    targets: targets
)
