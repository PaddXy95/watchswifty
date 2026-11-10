// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "watchswifty",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.3"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.1.1"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.14.4"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.4"),
        .package(url: "https://github.com/vapor/swift-openapi-vapor", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        .package(url: "https://github.com/elementary-swift/elementary.git", exact: "0.9.0"),
        .package(url: "https://github.com/elementary-swift/elementary-htmx.git", exact: "0.7.0"),
        .package(url: "https://github.com/PaddXy95/SwiftySMTPClient.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.8.0"),
    ],
    targets: [
        // Types and server protocol generated from openapi.yaml (the App API's single source).
        .target(
            name: "WatchSwiftyAPI",
            dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Elementary", package: "elementary"),
                .product(name: "ElementaryHTMX2", package: "elementary-htmx"),
                .target(name: "WatchSwiftyAPI"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "SwiftySMTPClient", package: "SwiftySMTPClient"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "JWTKit", package: "jwt-kit"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Elementary", package: "elementary"),
                .product(name: "SwiftySMTPClient", package: "SwiftySMTPClient"),
                .product(name: "JWTKit", package: "jwt-kit"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
    ]
}
