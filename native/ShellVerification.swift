// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

extension AppDelegate {
  func verifyFullscreenChrome() {
    guard root.path.hasPrefix("/private/tmp/AndroidDeck-fullscreen-") else { showError("全屏验证只允许独立测试目录"); return }
    var checks: [[String: Any]] = []
    func record(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
    rootView.displayReady = true
    rootView.canvas.isHidden = false
    rootView.bottom.hideDelay = 0.35
    fullscreen(nil)
    func waitForFullScreen() {
      guard rootView.full else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitForFullScreen() }; return }
      rootView.layoutSubtreeIfNeeded()
      record("全屏画面覆盖整个内容区域", rootView.canvas.frame == rootView.bounds && rootView.top.isHidden && rootView.leftScroll.isHidden && rootView.canvas.layer?.cornerRadius == 0)
      record("工具栏浮在画面内而非占用布局", rootView.canvas.frame.contains(rootView.bottom.frame))
      rootView.bottom.reveal()
      record("进入全屏可见工具栏", !rootView.bottom.isHidden)
      rootView.bottom.hideNow()
      record("点击隐藏立即移除整排全屏按钮", rootView.bottom.isHidden && rootView.bottom.dismissButton?.isHidden == false)
      rootView.bottom.toggleVisibility()
      record("快捷切换可重新显示整排按钮", !rootView.bottom.isHidden)
      rootView.bottom.toggleVisibility()
      record("快捷切换可再次隐藏整排按钮", rootView.bottom.isHidden)
      rootView.bottom.reveal()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
        record("停止操作后自动隐藏工具栏", self.rootView.bottom.isHidden)
        self.rootView.bottom.pointerActivity(at: NSPoint(x: -1, y: -1))
        record("移动鼠标会重新显示工具栏", !self.rootView.bottom.isHidden)
        self.rootView.bottom.pointerActivity(at: NSPoint(x: 20, y: 20))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
          record("鼠标停在工具栏上不自动隐藏", !self.rootView.bottom.isHidden)
          self.rootView.bottom.pointerActivity(at: NSPoint(x: -1, y: -1))
          self.rootView.bottom.beginInteraction()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            record("打开菜单期间保持可见", !self.rootView.bottom.isHidden)
            self.rootView.bottom.endInteraction()
            self.fullscreen(nil)
            func waitForWindow() {
              guard !self.rootView.full else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitForWindow() }; return }
              self.rootView.layoutSubtreeIfNeeded()
              record("退出全屏恢复窗口工具栏和布局", !self.rootView.bottom.isHidden && !self.rootView.top.isHidden && !self.rootView.leftScroll.isHidden && self.window.titleVisibility == .hidden)
              record("普通窗口不显示全屏隐藏按钮", self.rootView.bottom.dismissButton?.isHidden == true)
              let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
              try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: self.root.appendingPathComponent("data/fullscreen-report.json"))
              RunLoop.main.perform { NSApp.terminate(nil) }
            }
            waitForWindow()
          }
        }
      }
    }
    waitForFullScreen()
  }
  func writeStartupReport() {
    let report: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
      "pid": getpid(), "ready": ready && !busy, "rawMode": transport?.rawMode == true,
      "mappedFrames": transport?.mappedMode == true,
      "startupMs": firstReadyMs, "bootMs": runtime.bootElapsedMs,
      "width": input.width, "height": input.height, "resolution": runtime.resolution.rawValue,
      "package": activePackage, "inspectorCollapsed": rootView.inspector == .none,
      "apps": knownApps.map(\.package), "logs": logLines]
    try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("data/startup-report.json"), options: .atomic)
    if CommandLine.arguments.contains("--quit-after-startup") { RunLoop.main.perform { NSApp.terminate(nil) } }
  }
  func verifyShellLifecycle() {
    guard root.path.hasPrefix("/private/tmp/AndroidDeck-") else { showError("启动验证只允许独立设备"); return }
    var checks: [[String: Any]] = []
    func record(_ title: String, _ passed: Bool) { checks.append(["name": title, "passed": passed]) }
    let startupMs = firstReadyMs
    func wait(_ condition: @escaping () -> Bool, then: @escaping () -> Void, deadline: Double = ProcessInfo.processInfo.systemUptime + 120) {
      if condition() || ProcessInfo.processInfo.systemUptime > deadline { then() }
      else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { wait(condition, then: then, deadline: deadline) } }
    }
    wait({ self.ready && !self.busy }, then: {
      record("普通打开自动启动Android", self.ready && self.transport != nil)
      record("重启按钮明确且可用", self.restartButton.isEnabled && self.restartButton.title.contains("重新启动"))
      record("默认画面不被编辑面板占用", self.rootView.inspector == .none && !self.rootView.canvas.isHidden)
      record("已安装应用库正常载入", self.knownApps.contains { $0.package == "com.phoenix.read" })
      self.rootView.savePreview(self.root.appendingPathComponent("data/shell-running-preview.png"))
      self.stopClicked(nil)
      wait({ !self.ready && !self.busy }, then: {
        record("关闭后显示可用的重新进入口", !self.rootView.placeholder.isHidden && self.startButton.isEnabled && self.rootView.placeholder.action.isEnabled)
        let resumeBegin = ProcessInfo.processInfo.systemUptime
        self.startClicked(nil)
        wait({ self.ready && !self.busy }, then: {
          record("停止后可再次启动且恢复画面", self.ready && self.transport?.rawMode == true)
          let restartMs = (ProcessInfo.processInfo.systemUptime - resumeBegin) * 1000
          let resumeBootMs = self.runtime.bootElapsedMs
          self.worker.async {
            let before = try? self.runtime.adbRun(["shell", "cat", "/proc/sys/kernel/random/boot_id"], serial: self.serial)
            DispatchQueue.main.async {
              self.restartAndroid(nil)
              wait({ self.ready && !self.busy }, then: {
                self.worker.async {
                  let after = try? self.runtime.adbRun(["shell", "cat", "/proc/sys/kernel/random/boot_id"], serial: self.serial)
                  DispatchQueue.main.async {
                    record("重新启动按钮真正重启Android系统", before != nil && after != nil && before != after && self.ready && self.transport?.rawMode == true)
                    let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "startupMs": startupMs, "restartMs": restartMs, "bootMs": resumeBootMs, "coldRestartBootMs": self.runtime.bootElapsedMs, "logs": self.logLines]
                    try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: self.root.appendingPathComponent("data/shell-lifecycle-report.json"))
                    RunLoop.main.perform { NSApp.terminate(nil) }
                  }
                }
              })
            }
          }
        })
      })
    })
  }
  func verifyShellPreview() {
    var checks: [[String: Any]] = []
    func record(_ title: String, _ passed: Bool) { checks.append(["name": title, "passed": passed]) }
    rootView.layoutSubtreeIfNeeded()
    record("普通未启动状态的启动按钮可点击", settingsLoaded && !busy && startButton.isEnabled)
    record("中央显示明确启动入口而非黑屏", !rootView.placeholder.isHidden && rootView.placeholder.action.isEnabled)
    record("默认收起复杂设置和键位编辑", rootView.inspector == .none && rootView.rightScroll.isHidden && rootView.settingsScroll.isHidden)
    toggleSettings(nil); rootView.layoutSubtreeIfNeeded()
    record("设置面板可展开且组件完整", !rootView.settingsScroll.isHidden && ramPopup.superview != nil && resolutionPopup.superview != nil)
    toggleMappingPanel(nil); rootView.layoutSubtreeIfNeeded()
    record("设置和键位面板互斥", rootView.settingsScroll.isHidden && !rootView.rightScroll.isHidden)
    setInspector(.none); rootView.layoutSubtreeIfNeeded()
    record("左侧应用库可在设备关闭时显示", !knownApps.isEmpty && !rootView.leftScroll.isHidden)
    rootView.savePreview(root.appendingPathComponent("data/shell-idle-preview.png"))
    let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
    try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("data/shell-preview-report.json"))
    RunLoop.main.perform { NSApp.terminate(nil) }
  }
}
