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
    .systemLibrary(name: "COpus", pkgConfig: "opus", providers: [.apt(["libopus-dev"]), .brew(["opus"])]),
    .target(name: "Domain", path: "Sources/Domain"),
    .target(
        name: "PendantKit",
        dependencies: ["Domain", "COpus", .product(name: "Crypto", package: "swift-crypto")],
        path: "Sources/PendantKit",
        exclude: pendantKitExcludes
    ),
    .testTarget(name: "DomainTests", dependencies: ["Domain"], path: "Tests/DomainTests"),
    .testTarget(name: "PendantKitTests", dependencies: ["PendantKit", "Domain", "COpus"], path: "Tests/PendantKitTests")
]

#if !os(Linux)
products.append(.executable(name: "LessLimitlessApp", targets: ["LessLimitlessApp"]))
targets.append(.executableTarget(
    name: "LessLimitlessApp",
    dependencies: ["Domain", "PendantKit"],
    path: "Sources/LessLimitlessApp"
))
#endif

let package = Package(
    name: "LessLimitless",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
    targets: targets
)
