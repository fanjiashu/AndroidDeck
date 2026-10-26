// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

extension AppDelegate {
  func verifyPresentationUI() {
    guard ready, runtime.owns(serial) else { return }
    guard root.path.hasPrefix("/private/tmp/AndroidDeck-verification-") else { showError("显示验证仅允许使用独立临时设备"); return }
    prefs.followForegroundApp = false
    var checks: [[String: Any]] = []
    var stages: [(String, () -> Void, () -> Bool)] = []
    let hongguo = "com.phoenix.read", dnf = ReadySchemeCatalogue.dnfPackage
    var switchPID: Int32?, switchSerial: String?, switchStream: ScrcpyTransport?
    var switchBegin = 0.0, switchDurations: [Double] = []
    for package in [hongguo, dnf] {
      for key in profiles.keys.filter({ $0 == package || $0.hasPrefix(package + "::") }) { profiles.removeValue(forKey: key) }
      prefs.profileSelections?.removeValue(forKey: package); prefs.readyDefaultsApplied?.removeValue(forKey: package)
      prefs.remoteDefaultsApplied?.removeValue(forKey: package); prefs.contentKinds?.removeValue(forKey: package)
      prefs.displayOptions?.removeValue(forKey: package)
      prefs.modeSchemeSelections?.removeValue(forKey: package + "::app"); prefs.modeSchemeSelections?.removeValue(forKey: package + "::game")
    }
    selectMappingPackage(hongguo)
    func launch(_ package: String) {
      let item = NSButton(title: package, target: nil, action: nil)
      item.identifier = NSUserInterfaceItemIdentifier(package); self.launchApp(item)
    }
    stages.append(("内置两款应用在全新设备中可打开", {}, { self.mappingPanel.applicationPackages.contains(hongguo) && self.mappingPanel.applicationPackages.contains(dnf) }))
    stages.append(("红果自动选择应用遥控和竖屏", {}, { self.activePackage == hongguo && self.contentKind == .app && self.activeScheme == AppInteraction.remoteTitle && !self.profile.joystick.enabled && self.input.height > self.input.width }))
    stages.append(("应用选择真正 4K 竖屏且原始帧正常", {
      self.resolutionPopup.selectItem(at: 3); self.changeDisplayOption(nil); self.applyResolution(nil)
    }, { !self.input.suspended && self.input.width == 2160 && self.input.height == 3840 && self.transport?.rawMode == true }))
    stages.append(("应用可单独切换横屏", {
      self.orientationPopup.selectItem(at: 2); self.changeDisplayOption(nil)
    }, { !self.input.suspended && self.input.width == 3840 && self.input.height == 2160 }))
    stages.append(("切入 DNF 保留安卓进程、画面连接及当前 4K，自动恢复游戏技能", {
      switchPID = self.runtime.child?.processIdentifier; switchSerial = self.serial; switchStream = self.transport
      switchBegin = ProcessInfo.processInfo.systemUptime; launch(dnf)
    }, {
      let passed = !self.busy && !self.input.suspended && self.activePackage == dnf && self.contentKind == .game
        && self.profile.bindings.count == 19 && self.input.width == 3840 && self.input.height == 2160
        && self.runtime.child?.processIdentifier == switchPID && self.serial == switchSerial && self.transport === switchStream
        && self.applyResolutionButton.isEnabled && self.displayOptions(package: dnf).size == .hd
      if passed { switchDurations.append((ProcessInfo.processInfo.systemUptime - switchBegin) * 1000) }
      return passed
    }))
    stages.append(("明确应用游戏的 720p 分辨率后才重启", { self.applyResolution(nil) }, {
      !self.input.suspended && self.runtime.child?.processIdentifier != switchPID && self.input.width == 1280 && self.input.height == 720
    }))
    stages.append(("游戏也可选择真正 4K", {
      self.resolutionPopup.selectItem(at: 3); self.changeDisplayOption(nil); self.applyResolution(nil)
    }, { !self.input.suspended && self.input.width == 3840 && self.input.height == 2160 && self.profile.bindings.count == 19 }))
    stages.append(("手动更正类型切换应用遥控", {
      self.kindPopup.selectItem(at: 1); self.changeContentKind(nil)
    }, { self.contentKind == .app && self.activeScheme == AppInteraction.remoteTitle && !self.profile.joystick.enabled }))
    stages.append(("返回自动类型恢复 DNF 原技能方案", {
      self.kindPopup.selectItem(at: 0); self.changeContentKind(nil)
    }, { self.contentKind == .game && self.activeScheme == ReadySchemeCatalogue.dnfTitle && self.profile.bindings.count == 19 && !self.input.suspended }))
    stages.append(("独立投影窗口共用画面和触控坐标", {
      let item = NSMenuItem(); item.tag = 0; self.openProjection(item)
    }, { self.projection != nil && self.projection!.canvas.input === self.input && self.projection!.canvas.dimensions == self.rootView.canvas.dimensions }))
    stages.append(("关闭投影后模拟器保持连接", { self.closeProjection(nil) }, { self.projection == nil && self.ready }))
    stages.append(("返回应用保留安卓进程和独立设置，自动恢复遥控键", {
      switchPID = self.runtime.child?.processIdentifier; switchStream = self.transport
      switchBegin = ProcessInfo.processInfo.systemUptime; launch(hongguo)
    }, {
      let passed = !self.busy && !self.input.suspended && self.activePackage == hongguo && self.activeScheme == AppInteraction.remoteTitle
        && self.input.width == 3840 && self.input.height == 2160 && self.runtime.child?.processIdentifier == switchPID && self.transport === switchStream
      if passed { switchDurations.append((ProcessInfo.processInfo.systemUptime - switchBegin) * 1000) }
      return passed
    }))
    stages.append(("应用可恢复竖屏并保存个人遥控方案", {
      self.orientationPopup.selectItem(at: 1); self.changeDisplayOption(nil)
      self.ensurePersonalMappingScheme()
    }, { self.input.width == 2160 && self.input.height == 3840 && !self.input.suspended && self.activeScheme == "我的方案" }))
    func execute(_ index: Int) {
      if index >= stages.count {
        self.rootView.savePreview(self.root.appendingPathComponent("data/presentation-preview.png"))
        let result: [String: Any] = ["checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "switchDurationsMs": switchDurations, "rawMetrics": self.transport?.metrics ?? [:], "log": self.logLines, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown"]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: self.root.appendingPathComponent("data/presentation-report.json"), options: .atomic)
        NSApp.terminate(nil); return
      }
      self.log("DISPLAY_TEST \(stages[index].0)")
      let progress: [String: Any] = ["stage": stages[index].0, "checks": checks, "package": self.activePackage, "width": self.input.width, "height": self.input.height, "rawMode": self.transport?.rawMode == true, "log": self.logLines]
      try? JSONSerialization.data(withJSONObject: progress, options: [.prettyPrinted, .sortedKeys]).write(to: self.root.appendingPathComponent("data/presentation-progress.json"), options: .atomic)
      stages[index].1()
      let deadline = ProcessInfo.processInfo.systemUptime + 100
      func waitForCondition() {
        let passed = self.ready && !self.busy && stages[index].2()
        if passed || ProcessInfo.processInfo.systemUptime >= deadline {
          checks.append(["name": stages[index].0, "passed": passed, "width": self.input.width, "height": self.input.height])
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) { execute(index + 1) }
        } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waitForCondition() } }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { waitForCondition() }
    }
    execute(0)
  }
}
