// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MailFocus", platforms: [.macOS(.v14)], products: [
 .library(name: "MailFocusCore", targets: ["MailFocusCore"]),
 .executable(name: "MailFocus", targets: ["MailFocusApp"]),
 .executable(name: "MailFocusNativeHost", targets: ["MailFocusNativeHost"]),
 .executable(name: "BridgeFixture", targets: ["BridgeFixture"])
], targets: [
 .target(name: "MailFocusCore"),
 .executableTarget(name: "MailFocusApp", dependencies: ["MailFocusCore"], path: "macos/MailFocus", exclude: ["Info.plist", "Assets.xcassets"]),
 .executableTarget(name: "MailFocusNativeHost", dependencies: ["MailFocusCore"], path: "native-messaging/host"),
 .executableTarget(name: "BridgeFixture", dependencies: ["MailFocusCore"], path: "Tests/BridgeFixture"),
 .testTarget(name: "MailFocusTests", dependencies: ["MailFocusCore"], path: "macos/MailFocusTests")
])
