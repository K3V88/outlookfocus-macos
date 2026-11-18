import AppKit
import SwiftUI

@main struct OutlookFocusApplication: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  var body: some Scene {
    MenuBarExtra("OutlookFocus", systemImage: "envelope.badge") {
      MenuContent(model: delegate.model)
    }
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()
  private var settings: NSWindowController?
  private var onboarding: NSWindowController?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    model.openSettings = { [weak self] in self?.showSettings() }
    model.openOnboarding = { [weak self] in self?.showOnboarding() }
    model.start()
    if !model.preferences.onboardingComplete { showOnboarding() }
  }
  func applicationWillTerminate(_ notification: Notification) { model.stop() }
  private func window<V: View>(title: String, view: V, size: NSSize) -> NSWindowController {
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.title = title
    window.setContentSize(size)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.center()
    window.isReleasedWhenClosed = false
    return NSWindowController(window: window)
  }
  func showSettings() {
    if settings == nil {
      settings = window(
        title: "OutlookFocus Settings", view: SettingsView(model: model),
        size: NSSize(width: 690, height: 650))
    }
    settings?.showWindow(nil)
    settings?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
  func showOnboarding() {
    if onboarding == nil {
      onboarding = window(
        title: "Welcome to OutlookFocus",
        view: OnboardingView(model: model) { [weak self] in self?.onboarding?.close() },
        size: NSSize(width: 620, height: 470))
    }
    onboarding?.showWindow(nil)
    onboarding?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
}
