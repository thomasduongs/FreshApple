// swift-tools-version: 5.9
// FreshApple: use only idevice to avoid colliding libimobiledevice C symbols.
import PackageDescription
let package = Package(
    name: "MinimuxerGateway",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "DeviceGatewayAPI", targets: ["DeviceGatewayAPI"]),
        .library(name: "IdeviceGateway", targets: ["IdeviceGateway"])
    ],
    dependencies: [.package(path: "../Common")],
    targets: [
        .binaryTarget(name: "IDevice",
            url: "https://github.com/SideStore/idevice/releases/download/v0.1.66-ss-61c2704/idevice-xcframework-v0.1.66-ss-61c2704.zip#DeviceGateway",
            checksum: "6f32b32ca43d3f28c145742da926cc279d312abd99abe55c79f875e2d6d5e162"),
        .target(name: "DeviceGatewayAPI",
            dependencies: [.product(name: "MinimuxerCommon", package: "Common")],
            path: ".", exclude: ["idevice", "libimobiledevice"],
            sources: ["BaseDeviceGateway.swift", "DeviceGatewayAPI.swift", "DeviceGatewayError.swift", "DeviceGatewayLogging.swift"]),
        .target(name: "IdeviceGateway",
            dependencies: ["DeviceGatewayAPI", .product(name: "MinimuxerCommon", package: "Common"), "IDevice"],
            path: "idevice")
    ])
