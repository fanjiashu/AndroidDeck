// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

extension AppDelegate {
  func displayOptions(package: String) -> DeckDisplayOptions {
    if let saved = prefs.displayOptions?[package] { return saved }
    if package == "default", let runtime = runtime { return DeckDisplayOptions(resolution: runtime.resolution.rawValue, orientation: "automatic") }
    return DeckDisplayOptions()
  }
  var contentKind: DeckContentKind {
    AppInteraction.kind(package: activePackage, preferences: prefs,
      androidIsGame: androidGamePackages.contains(activePackage),
      gameScheme: readySchemes.contains { $0.id.hasPrefix("mumu:") && $0.profile.joystick.enabled })
  }
  func displaySpec(package: String) -> DeckDisplaySpec {
    let kind = AppInteraction.kind(package: package, preferences: prefs,
      androidIsGame: androidGamePackages.contains(package),
      gameScheme: package == activePackage && readySchemes.contains { $0.id.hasPrefix("mumu:") && $0.profile.joystick.enabled })
    return displayOptions(package: package).spec(kind: kind)
  }
  func renderPresentation() {
    let kind = contentKind
    input.wheelUsesTouch = kind == .app
    kindPopup.removeAllItems()
    kindPopup.addItems(withTitles: ["自动：\(kind.title)", "应用 · 遥控", "游戏 · 技能"])
    kindPopup.selectItem(at: prefs.contentKinds?[activePackage] == "app" ? 1 : prefs.contentKinds?[activePackage] == "game" ? 2 : 0)
    let options = displayOptions(package: activePackage)
    resolutionPopup.selectItem(at: DeckResolution.allCases.firstIndex(of: options.size) ?? 0)
    orientationPopup.selectItem(at: DeckOrientation.allCases.firstIndex(of: options.direction) ?? 0)
    let owned = ready && runtime?.owns(serial) == true
    kindPopup.isEnabled = settingsLoaded && !busy
    resolutionPopup.isEnabled = owned && !busy
    orientationPopup.isEnabled = owned && !busy
    resolutionPopup.toolTip = owned ? "每个游戏和应用分别保存；点击应用分辨率后改变 Android 实际分辨率" : "手机投影采用手机的实际分辨率；可在画面质量中调整传输清晰度"
    orientationPopup.toolTip = "默认游戏横屏、应用竖屏；选横/竖屏可固定方向，选跟随应用则由应用决定"
    let pending = owned && runtime.resolution != options.size
    applyResolutionButton?.isEnabled = pending && !busy
    let current = runtime?.resolution ?? options.size
    resolutionInfo.stringValue = pending ? "当前 \(current.width) × \(current.height) · 所选待应用\n切换应用保持运行，点应用分辨率后重启" : "当前 \(current.width) × \(current.height)\n切换应用保持 Android 运行"
    interactionHint.stringValue = kind == .game ? "游戏：方向 / 技能键位\n点选按钮即可修改按键" : "应用遥控：滚轮 / ↑ ↓ 翻页\nSpace 点击 · Esc 返回"
  }
  func prepareInteractionSchemes(package: String) {
    prepareReadySchemes(package: package)
    if contentKind == .app {
      if AppInteraction.registerRemote(package: package, profiles: &profiles, preferences: &prefs) {
        persistPreferences(); persistMappingCollection()
      }
      let remote = ReadyScheme(id: "builtin.app.remote.v1", title: AppInteraction.remoteTitle,
        origin: "内置 · 翻页 / 点击 / 声音", profile: AppInteraction.remoteProfile())
      readySchemes.insert(remote, at: 0)
    }
  }
  func requestDisplayForActivePackage(allowRestart: Bool = false) {
    renderPresentation()
    guard ready, let serial = serial, runtime.owns(serial) else { return }
    let package = activePackage, requested = displaySpec(package: package), connection = generation
    if runtime.resolution != requested.resolution, allowRestart {
      operation("切换分辨率并重启 Android…") { try self.restartDisplay(spec: requested, package: package) }
      return
    }
    // Android-internal foreground changes update controls without repeatedly rebooting the device.
    let spec = requested.using(runtime.resolution)
    guard lastRequestedDisplay != spec else { return }
    lastRequestedDisplay = spec; displayRevision += 1
    let revision = displayRevision
    input.suspended = true
    worker.async {
      let current = DispatchQueue.main.sync {
        self.ready && !self.quitting && self.serial == serial && self.generation == connection
          && self.activePackage == package && self.displayRevision == revision
      }
      guard current else { return }
      do {
        try self.runtime.applyDisplay(spec, serial: serial)
        DispatchQueue.main.async {
          guard self.generation == connection, self.displayRevision == revision else { return }
          self.displayAwaitingFrame = spec
          self.resumeInputForDisplay(width: self.input.width, height: self.input.height)
          DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard self.generation == connection, self.displayRevision == revision else { return }
            if self.displayAwaitingFrame != nil {
              self.status.stringValue = "画面尺寸尚未更新，请点重连后继续操作"
              self.lastRequestedDisplay = nil
            }
          }
        }
      } catch {
        DispatchQueue.main.async {
          guard self.generation == connection, self.displayRevision == revision else { return }
          self.lastRequestedDisplay = nil; self.displayAwaitingFrame = nil; self.input.suspended = false
          self.status.stringValue = "调整画面失败：\(error.localizedDescription)"
          self.log(self.status.stringValue)
        }
      }
    }
  }
  func resumeInputForDisplay(width: Int, height: Int) {
    guard let spec = displayAwaitingFrame,
      spec.rotation == nil || (spec.rotation == 1 ? width > height : height > width) else { return }
    if transport?.rawMode == true {
      guard min(width, height) == spec.width, max(width, height) == spec.height else { return }
    } else {
      guard abs(Double(max(width, height)) / Double(max(1, min(width, height))) - Double(spec.height) / Double(spec.width)) < 0.03 else { return }
    }
    input.suspended = false; displayAwaitingFrame = nil
  }
  @objc func changeContentKind(_ sender: Any?) {
    guard !busy, settingsLoaded else { return }
    input.release()
    let previousKind = contentKind
    if prefs.modeSchemeSelections == nil { prefs.modeSchemeSelections = [:] }
    prefs.modeSchemeSelections![activePackage + "::" + previousKind.rawValue] = activeScheme
    if prefs.contentKinds == nil { prefs.contentKinds = [:] }
    prefs.contentKinds![activePackage] = kindPopup.indexOfSelectedItem == 1 ? "app" : kindPopup.indexOfSelectedItem == 2 ? "game" : nil
    prepareInteractionSchemes(package: activePackage)
    let kind = contentKind
    let saved = prefs.modeSchemeSelections?[activePackage + "::" + kind.rawValue]
    if let saved = saved, MappingStore.schemes(package: activePackage, profiles: profiles).contains(saved) {
      selectMappingScheme(saved)
    } else if kind == .app {
      AppInteraction.registerRemote(package: activePackage, profiles: &profiles, preferences: &prefs, select: true)
      persistMappingCollection(); selectMappingScheme(AppInteraction.remoteTitle)
    } else {
      selectMappingScheme(readySchemes.first?.title ?? "")
    }
    persistPreferences(); requestDisplayForActivePackage()
  }
  @objc func changeDisplayOption(_ sender: Any?) {
    guard ready, !busy, runtime.owns(serial) else { return }
    var options = displayOptions(package: activePackage)
    options.resolution = DeckResolution.allCases[max(0, resolutionPopup.indexOfSelectedItem)].rawValue
    options.orientation = DeckOrientation.allCases[max(0, orientationPopup.indexOfSelectedItem)].rawValue
    if prefs.displayOptions == nil { prefs.displayOptions = [:] }
    prefs.displayOptions![activePackage] = options
    // Choosing a preference must not turn app browsing into a cold boot. The
    // apply button remains the explicit path to a physical resolution change.
    persistPreferences(); requestDisplayForActivePackage()
    window.makeFirstResponder(rootView.canvas)
  }
  @objc func applyResolution(_ sender: Any?) { guard ready, !busy else { return }; requestDisplayForActivePackage(allowRestart: true) }
  // Called only on the serialized operations queue after an explicit launch or display action.
  func restartDisplay(spec: DeckDisplaySpec, package: String) throws {
    DispatchQueue.main.sync {
      self.input.suspended = true; self.input.writer = nil; self.ready = false; self.serial = nil
      self.cancelLayoutCalibration(); self.rootView.canvas.cancelEditorGesture()
      self.updateControls()
    }
    transport?.close(); transport = nil
    runtime.stop(saveQuickBoot: false); runtime.resolution = spec.resolution
    let target = try runtime.start(allowQuickRestore: false)
    try distribution.installMissing(in: runtime, serial: target)
    try connectStream(target, package: package)
  }
}
