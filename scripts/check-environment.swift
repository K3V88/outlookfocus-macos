import AppKit
import Foundation

let workspace = NSWorkspace.shared
let result: [String: Any] = [
  "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
  "outlookInstalled": workspace.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook")
    != nil,
  "outlookRunning": !NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.microsoft.Outlook"
  ).isEmpty,
  "chromeInstalled": workspace.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil,
  "chromeRunning": !NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.google.Chrome"
  ).isEmpty,
]
let data = try JSONSerialization.data(
  withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
