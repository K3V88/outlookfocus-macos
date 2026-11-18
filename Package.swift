// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "OutlookFocus", platforms: [.macOS(.v14)], products: [
 .library(name: "OutlookFocusCore", targets: ["OutlookFocusCore"]),
 .executable(name: "OutlookFocus", targets: ["OutlookFocusApp"]),
 .executable(name: "OutlookFocusNativeHost", targets: ["OutlookFocusNativeHost"]),
 .executable(name: "BridgeFixture", targets: ["BridgeFixture"])
], targets: [
 .target(name: "OutlookFocusCore"),
 .executableTarget(name: "OutlookFocusApp", dependencies: ["OutlookFocusCore"], path: "macos/OutlookFocus", exclude: ["Info.plist", "Assets.xcassets"]),
 .executableTarget(name: "OutlookFocusNativeHost", dependencies: ["OutlookFocusCore"], path: "native-messaging/host"),
 .executableTarget(name: "BridgeFixture", dependencies: ["OutlookFocusCore"], path: "Tests/BridgeFixture"),
 .testTarget(name: "OutlookFocusTests", dependencies: ["OutlookFocusCore"], path: "macos/OutlookFocusTests")
])
