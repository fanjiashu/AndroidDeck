// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

extension AppDelegate {
  func verifyDesignPreview() {
    guard root.path.hasPrefix("/private/tmp/AndroidDeck-design-") else { showError("设计验证只用于独立预览目录"); return }
    var checks: [[String: Any]] = []
    func record(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
    let packages = ["com.phoenix.read", "com.tencent.tmgp.dnf", "com.tencent.tmgp.pubgmhd", "com.tencent.tmgp.sgame"]
    renderApps(packages.map { AndroidApp(package: $0, name: AppInteraction.builtinNames[$0]!, isGame: AppInteraction.knownGames.contains($0)) })
    ready = false; busy = false; updateControls()
    let states: [(String, CGFloat, CGFloat, DeckInspector)] = [
      ("idle-960", 960, 680, .none), ("idle-1320", 1320, 860, .none),
      ("idle-1920", 1920, 1080, .none), ("settings-960", 960, 680, .settings),
      ("settings-1320", 1320, 860, .settings), ("mapping-960", 960, 680, .mappings),
      ("mapping-1320", 1320, 860, .mappings)
    ]
    for (name, width, height, inspector) in states {
      rootView.inspector = .none
      window.setContentSize(NSSize(width: width, height: height)); rootView.layoutSubtreeIfNeeded()
      let canvasBefore = rootView.canvas.frame
      rootView.inspector = inspector; rootView.needsLayout = true; rootView.layoutSubtreeIfNeeded()
      record("\(name)：主画面与工具栏不越界", rootView.bounds.contains(rootView.canvas.frame) && rootView.bounds.contains(rootView.bottom.frame))
      record("\(name)：应用按钮完整且名称可访问", appsBox.arrangedSubviews.allSatisfy { ($0 as? NSButton)?.title.isEmpty == false && $0.frame.width >= 220 })
      if inspector != .none {
        record("\(name)：面板与顶部操作不重叠", !rootView.inspectorSurface.frame.intersects(rootView.top.frame))
        record("\(name)：右侧面板可关闭且可滚动", rootView.inspectorClose.action != nil && (inspector == .settings ? rootView.settingsScroll.hasVerticalScroller : rootView.rightScroll.hasVerticalScroller))
      }
      if width < 1240 && inspector != .none { record("\(name)：浮层不改变触控画面坐标", rootView.canvas.frame == canvasBefore) }
      rootView.savePreview(root.appendingPathComponent("data/design-\(name).png"))
    }
    rootView.inspector = .none; window.setContentSize(NSSize(width: 1320, height: 860))
    busy = true; updateControls(); rootView.layoutSubtreeIfNeeded()
    record("启动中不允许重复操作", !startButton.isEnabled && !installButton.isEnabled && appsBox.arrangedSubviews.allSatisfy { ($0 as? NSButton)?.isEnabled == false })
    rootView.savePreview(root.appendingPathComponent("data/design-loading.png"))
    busy = false; ready = true; prefs.lastOpenedPackage = "com.phoenix.read"; activePackage = "com.phoenix.read"
    updateControls(); rootView.layoutSubtreeIfNeeded()
    record("运行中隐藏重复的启动入口", startButton.isHidden)
    record("当前应用有明确选中反馈", appsBox.arrangedSubviews.compactMap { $0 as? DeckAppButton }.filter(\.selectedApp).count == 1)
    record("主标题显示当前应用", rootView.stageTitle.stringValue == "红果短剧")
    rootView.savePreview(root.appendingPathComponent("data/design-running-shell.png"))
    rootView.full = true; rootView.layoutSubtreeIfNeeded()
    record("全屏画面覆盖内容区域且没有侧栏", rootView.canvas.frame == rootView.bounds && rootView.leftScroll.isHidden && rootView.top.isHidden && rootView.inspectorSurface.isHidden)
    rootView.full = false
    let result: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown", "passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks,
      "reviewDimensions": ["排版", "留白", "视觉层级", "色彩", "动效", "微交互", "响应式", "原创性"], "syntheticPreview": true]
    try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("data/design-review.json"))
    ready = false; NSApp.terminate(nil)
  }
}
