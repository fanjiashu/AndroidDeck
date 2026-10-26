// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

final class DeckProjection: NSObject, NSWindowDelegate {
  let window: NSWindow
  let canvas = VideoCanvas(frame: .zero)
  lazy var viewport = ProjectionViewport(canvas: canvas)
  var onClose: (() -> Void)?
  init(screen: NSScreen, input: InputEngine, profile: Profile) {
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = "AndroidDeck · 投影（F11 全屏）"
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.acceptsMouseMovedEvents = true
    window.contentView = viewport
    canvas.input = input; canvas.profile = profile; canvas.showMarkers = false
    let exit = NSButton(title: "退出全屏 · Esc", target: self, action: #selector(exitFullscreen(_:)))
    exit.bezelStyle = .rounded; exit.frame = NSRect(x: 10, y: 7, width: 130, height: 30)
    viewport.controls.addSubview(exit)
    let hide = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "隐藏全屏工具栏")!, target: self, action: #selector(hideFullscreenControls(_:)))
    hide.bezelStyle = .rounded; hide.toolTip = "隐藏工具栏 · 移动鼠标显示 · ⌘⇧H 切换"
    hide.frame = NSRect(x: 150, y: 7, width: 32, height: 30)
    viewport.controls.addSubview(hide); viewport.controls.dismissButton = hide
    window.setFrame(screen.visibleFrame.insetBy(dx: 24, dy: 24), display: true)
  }
  func show() { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas) }
  func windowWillClose(_ notification: Notification) { canvas.input?.release(); onClose?() }
  func windowDidResignKey(_ notification: Notification) { canvas.input?.release() }
  @objc func exitFullscreen(_ sender: Any?) { window.toggleFullScreen(nil) }
  @objc func hideFullscreenControls(_ sender: Any?) { viewport.controls.hideNow() }
  func windowDidEnterFullScreen(_ notification: Notification) { canvas.input?.release(); viewport.full = true }
  func windowDidExitFullScreen(_ notification: Notification) { canvas.input?.release(); viewport.full = false }
  func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions { [.fullScreen, .autoHideDock, .autoHideMenuBar] }
}

extension AppDelegate {
  @objc func projectionMenu(_ sender: NSButton) {
    rootView.bottom.beginInteraction(); defer { rootView.bottom.endInteraction() }
    let menu = NSMenu()
    let phone = NSMenuItem(title: "手机 / 平板投到 Mac…", action: #selector(phoneProjectionHelp(_:)), keyEquivalent: "")
    phone.target = self; menu.addItem(phone); menu.addItem(.separator())
    for (index, screen) in NSScreen.screens.enumerated() {
      let item = NSMenuItem(title: "投影到 \(screen.localizedName)", action: #selector(openProjection(_:)), keyEquivalent: "")
      item.target = self; item.tag = index; item.isEnabled = ready; menu.addItem(item)
    }
    let close = NSMenuItem(title: "关闭投影窗口", action: #selector(closeProjection(_:)), keyEquivalent: "")
    close.target = self; close.isEnabled = projection != nil; menu.addItem(close)
    menu.addItem(.separator())
    let hint = NSMenuItem(title: "电视 / AirPlay：先在 macOS 连接显示器", action: nil, keyEquivalent: "")
    hint.isEnabled = false; menu.addItem(hint)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
  }
  @objc func phoneProjectionHelp(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "把 Android 手机投到 Mac"
    alert.informativeText = "1. 手机开启开发者选项 → USB 调试。\n2. 用数据线连接 Mac，在手机确认允许此电脑调试。\n3. 打开“设置 → 手机投屏”，刷新设备并连接所选手机。\n\n支持鼠标、键盘、自定义触控映射和全屏。投影清晰度在设置中选择；横竖屏跟随手机。"
    alert.addButton(withTitle: "刷新设备"); alert.addButton(withTitle: "关闭")
    if alert.runModal() == .alertFirstButtonReturn { setInspector(.settings); refreshDevices(nil) }
  }
  @objc func openProjection(_ sender: NSMenuItem) {
    guard ready, NSScreen.screens.indices.contains(sender.tag) else { return }
    input.release(); closeProjection(nil)
    let view = DeckProjection(screen: NSScreen.screens[sender.tag], input: input, profile: profile)
    view.canvas.dimensions = rootView.canvas.dimensions
    view.onClose = { [weak self, weak view] in if self?.projection === view { self?.projection = nil } }
    projection = view; view.show()
    framePresenter?.setProjection { [weak view] frame in view?.canvas.metal.submit(frame) }
  }
  @objc func closeProjection(_ sender: Any?) { framePresenter?.setProjection(nil); projection?.window.close(); projection = nil }
  func updateProjectionSize(width: Int, height: Int) {
    guard let canvas = projection?.canvas, canvas.dimensions.width != CGFloat(width) || canvas.dimensions.height != CGFloat(height) else { return }
    canvas.dimensions = CGSize(width: width, height: height); canvas.needsLayout = true
  }
}
