// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

extension AppDelegate {
  func prepareReadySchemes(package: String) {
    let current = profiles[package] ?? Profile.initial(for: package)
    readySchemes = ReadySchemeCatalogue.discover(package: package, current: current, width: input.width, height: input.height)
    guard let recommended = readySchemes.first else { return }
    if ReadySchemeCatalogue.register(recommended, package: package, profiles: &profiles, preferences: &prefs) {
      persistPreferences()
      persistMappingCollection()
    }
    activeScheme = prefs.profileSelections?[package] ?? ""
  }
  func persistMappingCollection() {
    do {
      let file = root.appendingPathComponent("data/profiles.json"), backup = root.appendingPathComponent("data/profiles-before-ready-schemes.json")
      if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: file, to: backup) }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(profiles).write(to: file, options: .atomic)
    } catch { showError(error.localizedDescription) }
  }
  func applyReadyScheme(_ scheme: ReadyScheme) {
    input.release(); cancelLayoutCalibration()
    let key = MappingStore.key(package: activePackage, scheme: scheme.title)
    profiles[key] = scheme.profile
    persistMappingCollection(); selectMappingScheme(scheme.title)
    status.stringValue = "已应用 \(scheme.title) · \(scheme.profile.bindings.count) 个操作"
  }
  func pollForegroundMapping() {
    guard ready, !busy, !rootView.canvas.editing, prefs.followForegroundApp != false, !foregroundPending, let serial = serial else { return }
    foregroundPending = true
    let connection = generation
    worker.async {
      let text = try? self.runtime.adbRun(["shell", "dumpsys", "activity", "activities"], serial: serial, timeout: 3)
      let package = text.flatMap { ReadySchemeCatalogue.foregroundPackage(in: $0) }
      DispatchQueue.main.async {
        self.foregroundPending = false
        guard self.ready, !self.busy, self.serial == serial, self.generation == connection,
          self.prefs.followForegroundApp != false, !self.rootView.canvas.editing,
          let package = package, !ReadySchemeCatalogue.systemOverlays.contains(package), package != self.activePackage else { return }
        self.selectMappingPackage(package)
        self.rememberApplication(package)
        self.status.stringValue = "已识别\(self.contentKind.title) · \(self.activeScheme.isEmpty ? "个人默认方案" : self.activeScheme)"
      }
    }
  }
  func beginLayoutCalibration() {
    input.release(); captureIndex = nil
    rootView.canvas.cancelEditorGesture()
    guard profile.bindings.filter({ $0.mode != "audio" }).count >= 3 else { showError("请先应用整套方案，再校准三个按钮中心"); return }
    let eligible = profile.bindings.filter { $0.mode != "audio" }
    let first = eligible.first!
    let second = eligible.max { hypot($0.x - first.x, $0.y - first.y) < hypot($1.x - first.x, $1.y - first.y) }!
    func area(_ b: Binding) -> Double { abs((second.x - first.x) * (b.y - first.y) - (second.y - first.y) * (b.x - first.x)) }
    let third = eligible.max { area($0) < area($1) }!
    guard area(third) > 0.005 else { showError("需要三个分散且不共线的按钮才能校准"); return }
    calibrationOriginal = profile; calibrationTargets = []
    calibrationSource = [first, second, third].map { ($0.label + "（" + keyLabel($0.code) + "）", TouchPoint(x: $0.x, y: $0.y)) }
    rootView.canvas.editing = true
    rootView.canvas.onCalibrationPoint = { [weak self] point in self?.receiveCalibrationPoint(point) }
    updateCalibrationPrompt(); renderProfile()
  }
  func updateCalibrationPrompt() {
    guard calibrationTargets.count < calibrationSource.count else { return }
    rootView.canvas.calibrationPrompt = "\(calibrationTargets.count + 1)/3 点击游戏按钮中心：\(calibrationSource[calibrationTargets.count].0) · Esc 取消"
    rootView.canvas.needsDisplay = true
  }
  func receiveCalibrationPoint(_ point: TouchPoint) {
    guard let original = calibrationOriginal else { return }
    calibrationTargets.append(point)
    if calibrationTargets.count < 3 { updateCalibrationPrompt(); return }
    rootView.canvas.onCalibrationPoint = nil
    do {
      let transform = try LayoutTransform.fit(source: calibrationSource.map(\.1), target: calibrationTargets)
      let calibrated = try transform.apply(original)
      rootView.canvas.profile = calibrated; rootView.canvas.calibrationPrompt = "校准预览 · 触点和滑屏轨迹已整体匹配"; rootView.canvas.needsDisplay = true
      let alert = NSAlert(); alert.messageText = "应用这次布局校准？"; alert.informativeText = "整套按钮和滑屏轨迹会按三个中心调整；当前移动摇杆保持原位置。"; alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
      if alert.runModal() == .alertFirstButtonReturn { commitMapping(calibrated) }
      cancelLayoutCalibration()
    } catch { cancelLayoutCalibration(); showError(error.localizedDescription) }
  }
  func cancelLayoutCalibration() {
    calibrationOriginal = nil; calibrationSource = []; calibrationTargets = []
    rootView.canvas.onCalibrationPoint = nil; rootView.canvas.calibrationPrompt = nil; rootView.canvas.profile = profile; rootView.canvas.needsDisplay = true
  }
}
