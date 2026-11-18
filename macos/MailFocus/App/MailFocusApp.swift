import AppKit
import SwiftUI

@main struct MailFocusApplication: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  var body: some Scene {
    Settings { SettingsView(model: delegate.model) }
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let model = AppModel()
  private var settings: NSWindowController?
  private var onboarding: NSWindowController?
  private var statusItem: NSStatusItem?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    model.openSettings = { [weak self] in self?.showSettings() }
    model.openOnboarding = { [weak self] in self?.showOnboarding() }
    configureStatusItem()
    model.start()
    showMainWindow()
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showMainWindow()
    return true
  }
  private func showMainWindow() {
    if model.preferences.onboardingComplete {
      showSettings()
    } else {
      showOnboarding()
    }
  }
  func applicationWillTerminate(_ notification: Notification) { model.stop() }
  private func configureStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "MailFocus")
    image?.isTemplate = true
    item.button?.image = image
    item.button?.toolTip = "MailFocus — Open Settings (right-click for quick actions)"
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item
  }
  @objc private func statusItemClicked() {
    guard NSApp.currentEvent?.type == .rightMouseUp else {
      showSettings()
      return
    }
    let menu = NSMenu()
    func add(_ title: String, action: Selector, key: String = "") {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = self
      menu.addItem(item)
    }
    add("Open MailFocus Settings…", action: #selector(openSettingsFromMenu), key: ",")
    add("Focus Apple Mail", action: #selector(focusMailFromMenu))
    add("Monitor Infomaniak Inbox", action: #selector(toggleMonitoringFromMenu))
    menu.items.last?.state = model.preferences.enabled ? .on : .off
    menu.addItem(.separator())
    add("Quit MailFocus", action: #selector(quitFromMenu), key: "q")
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil
  }
  @objc private func openSettingsFromMenu() { showSettings() }
  @objc private func focusMailFromMenu() { Task { await model.focusMail() } }
  @objc private func toggleMonitoringFromMenu() { model.preferences.enabled.toggle() }
  @objc private func quitFromMenu() { NSApp.terminate(nil) }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.makeFirstResponder(nil)
    model.saveEmailIfValid()
    return true
  }
  private func window<V: View>(title: String, view: V, size: NSSize) -> NSWindowController {
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.title = title
    window.setContentSize(size)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.center()
    window.isReleasedWhenClosed = false
    window.delegate = self
    return NSWindowController(window: window)
  }
  func showSettings() {
    if settings == nil {
      settings = window(
        title: "MailFocus Settings", view: SettingsView(model: model),
        size: NSSize(width: 690, height: 650))
    }
    settings?.showWindow(nil)
    settings?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
  func showOnboarding() {
    if onboarding == nil {
      onboarding = window(
        title: "Welcome to MailFocus",
        view: OnboardingView(model: model) { [weak self] in self?.onboarding?.close() },
        size: NSSize(width: 620, height: 470))
    }
    onboarding?.showWindow(nil)
    onboarding?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
}
