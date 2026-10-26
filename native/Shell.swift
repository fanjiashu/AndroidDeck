// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

enum DeckInspector { case none, settings, mappings }

final class DevicePlaceholder: NSView {
  let heading = label("你的 Android，随时继续。", 32)
  let message = label("正在读取应用和设备设置…", 13, muted)
  let action = NSButton(title: "启动 Android", target: nil, action: nil)
  let activity = NSProgressIndicator()
  private let stack = NSStackView()
  private var messageWidth: NSLayoutConstraint?
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 18
    layer?.masksToBounds = true
    let icon = NSImageView()
    icon.image = NSImage(named: NSImage.applicationIconName)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
    heading.font = .systemFont(ofSize: 32, weight: .semibold)
    heading.alignment = .center
    message.alignment = .center
    message.maximumNumberOfLines = 3
    message.lineBreakMode = .byWordWrapping
    messageWidth = message.widthAnchor.constraint(equalToConstant: 400); messageWidth?.isActive = true
    activity.style = .spinning; activity.controlSize = .regular
    action.isBordered = false; action.wantsLayer = true; action.layer?.cornerRadius = 10
    action.layer?.backgroundColor = DeckTheme.accent.cgColor; action.contentTintColor = DeckTheme.background
    action.controlSize = .large
    action.font = .systemFont(ofSize: 14, weight: .semibold)
    action.widthAnchor.constraint(equalToConstant: 184).isActive = true
    action.heightAnchor.constraint(equalToConstant: 40).isActive = true
    stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 20
    for view in [icon, heading, message, activity, action] { stack.addArrangedSubview(view) }
    addSubview(stack)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let width = min(440, max(240, bounds.width - 32))
    messageWidth?.constant = width - 24
    heading.font = .systemFont(ofSize: width < 400 ? 24 : 32, weight: .semibold)
    let height = mappingContentHeight(stack)
    stack.frame = NSRect(x: (bounds.width - width) / 2, y: max(30, (bounds.height - height) / 2 - 20), width: width, height: height)
  }
  override func draw(_ dirtyRect: NSRect) {
    let background = NSGradient(colors: [DeckTheme.surface, DeckTheme.background])!
    background.draw(in: bounds, angle: 90)
    let rect = NSRect(x: bounds.midX - 126, y: bounds.midY - 230, width: 252, height: 108)
    DeckTheme.accent.withAlphaComponent(0.07).setStroke()
    for offset in [CGFloat(0), 10, 20] {
      let path = NSBezierPath(roundedRect: rect.offsetBy(dx: offset, dy: -offset), xRadius: 18, yRadius: 18)
      path.lineWidth = 1; path.stroke()
    }
  }
  func update(title: String, detail: String, working: Bool, enabled: Bool) {
    heading.stringValue = title; message.stringValue = detail
    activity.isHidden = !working
    if working { activity.startAnimation(nil) } else { activity.stopAnimation(nil) }
    action.title = title.contains("失败") ? "重试启动" : "启动 Android"
    action.isEnabled = enabled && !working
    action.isHidden = working
    needsLayout = true
  }
}

extension AppDelegate {
  @objc func closeInspector(_ sender: Any?) { setInspector(.none); window.makeFirstResponder(rootView.canvas) }
  @objc func toggleSettings(_ sender: Any?) { setInspector(rootView.inspector == .settings ? .none : .settings) }
  @objc func toggleMappingPanel(_ sender: Any?) { setInspector(rootView.inspector == .mappings ? .none : .mappings) }
  func setInspector(_ value: DeckInspector) {
    input.release()
    if rootView.canvas.editing && value != .mappings {
      rootView.canvas.editing = false; cancelLayoutCalibration(); captureIndex = nil
      rootView.canvas.cancelEditorGesture(); renderProfile()
    }
    rootView.inspector = value
    settingsButton.state = value == .settings ? .on : .off
    mappingsButton.state = value == .mappings ? .on : .off
    rootView.needsLayout = true
    rootView.layoutSubtreeIfNeeded()
    if value != .none && !DeckTheme.reduceMotion {
      let views: [NSView] = [rootView.inspectorSurface, value == .settings ? rootView.settingsScroll : rootView.rightScroll]
      views.forEach { $0.alphaValue = 0 }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = DeckTheme.motion
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        views.forEach { $0.animator().alphaValue = 1 }
      }
    }
    if value == .settings { refreshDeviceInformation(nil) }
  }
  @objc func restartAndroid(_ sender: Any?) {
    guard settingsLoaded, !busy else { return }
    guard runtime.owns(serial) else { startClicked(nil); return }
    let package = activePackage == "default" ? resumePackage : activePackage
    let spec = displaySpec(package: package)
    operation("正在重新启动 Android…") { try self.restartDisplay(spec: spec, package: package) }
  }
  var resumePackage: String {
    let value = prefs.lastOpenedPackage ?? "default"
    return value.range(of: "^[A-Za-z][\\w]*(\\.[\\w]+)+$", options: .regularExpression) == nil ? "default" : value
  }
  func rememberApplication(_ package: String) {
    guard knownApps.contains(where: { $0.package == package }), prefs.lastOpenedPackage != package else { return }
    prefs.lastOpenedPackage = package; persistPreferences()
  }
  func updateShell() {
    rootView.displayReady = ready
    rootView.needsLayout = true
    fpsLabel.isHidden = !ready
    restartButton.isEnabled = settingsLoaded && !busy && runtime?.owns(serial) == true
    settingsButton.isEnabled = settingsLoaded
    mappingsButton.isEnabled = ready && !busy
    startButton.isHidden = ready
    deviceSummary.stringValue = ready ? "● 已连接   Android 14 · \(prefs.ramMb / 1024) GB" : busy ? "◌ 正在准备设备" : "○ 设备已关闭"
    deviceSummary.textColor = ready ? DeckTheme.accent : DeckTheme.secondary
    let package = prefs.lastOpenedPackage ?? "default"
    rootView.stageTitle.stringValue = ready ? AppInteraction.builtinNames[package] ?? knownApps.first(where: { $0.package == package })?.name ?? "Android 工作台" : "你的 Android 工作台"
    rootView.stageSubtitle.stringValue = ready ? (contentKind == .game ? "游戏模式  /  你的键位，随时切换" : "应用模式  /  滚轮翻页 · 键盘遥控") : "打开喜欢的应用，让大屏成为你的主场。"
    for row in appsBox.arrangedSubviews { (row as? DeckAppButton)?.selectedApp = row.identifier?.rawValue == prefs.lastOpenedPackage }
    let hasError = !startupError.isEmpty
    rootView.placeholder.update(title: busy ? "正在准备 Android" : hasError ? "启动未完成" : "Android 已关闭",
      detail: busy ? status.stringValue : hasError ? startupError : "应用和键位已保存，启动后继续使用。",
      working: busy, enabled: !busy && (settingsLoaded || hasError))
    rootView.placeholder.action.title = hasError ? "重试启动" : "启动 Android"
    showButton.isHidden = !ready || contentKind != .game && rootView.inspector != .mappings
  }
  func loadCachedApplications() {
    if let data = try? Data(contentsOf: root.appendingPathComponent("data/application-library.json")),
      let apps = try? JSONDecoder().decode([AndroidApp].self, from: data) { renderApps(apps); return }
    if let apps = try? distribution.manifest()?.apps { renderApps(apps.map { AndroidApp(package: $0.package, name: $0.name) }) }
  }
}
