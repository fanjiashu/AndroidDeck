// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

extension AppDelegate {
  func verifyMarkerRendering() {
    let canvas = rootView.canvas, original = profile
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { showError("绘制验证画布创建失败"); return }
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = context
    context.cgContext.translateBy(x: 0, y: 720); context.cgContext.scaleBy(x: 1, y: -1)
    var maximumCache = 0
    let start = ProcessInfo.processInfo.systemUptime
    for iteration in 0..<20_000 {
      autoreleasepool {
        if iteration % 37 == 0 {
          var p = ReadySchemeCatalogue.dnfStandard()
          p.joystick.keys = iteration % 2 == 0 ? ["KeyW", "KeyA", "KeyS", "KeyD"] : ["ArrowUp", "ArrowLeft", "ArrowDown", "ArrowRight"]
          p.bindings[0].label = "普攻 中文箭头↑ \(iteration)"
          p.bindings[1].code = "Numpad1"
          canvas.profile = p
          canvas.calibrationPrompt = "校准 1/3 · 点击按钮中心 \(iteration)"
        }
        canvas.editing = iteration % 3 != 0
        canvas.showMarkers = iteration % 7 != 0
        canvas.videoRect = iteration % 2 == 0 ? CGRect(x: 0, y: 0, width: 1280, height: 720) : CGRect(x: 440, y: 0, width: 405, height: 720)
        context.cgContext.setFillColor(CGColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 1))
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        canvas.drawMarkers()
        maximumCache = max(maximumCache, canvas.markerText.count)
      }
    }
    canvas.profile = ReadySchemeCatalogue.dnfStandard(); canvas.editing = true; canvas.showMarkers = true
    canvas.videoRect = CGRect(x: 0, y: 0, width: 1280, height: 720); canvas.calibrationPrompt = "校准预览 · 中文与箭头 ↑ ← ↓ →"
    context.cgContext.setFillColor(CGColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 1)); context.cgContext.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
    canvas.drawMarkers()
    NSGraphicsContext.current = previous
    let result: [String: Any] = ["passed": maximumCache <= 130, "draws": 20_000, "maximumCachedLines": maximumCache, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start]
    do {
      try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("data/marker-render-report.json"))
      try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("data/marker-render-verified.png"))
    } catch { showError(error.localizedDescription) }
    canvas.profile = original; canvas.calibrationPrompt = nil
    if CommandLine.arguments.contains("--quit-after-render-test") { NSApp.terminate(nil) }
  }
  func verifyForegroundMapping() {
    guard ready, let serial = serial else { return }
    var checks: [[String: Any]] = []
    func record(_ name: String, _ condition: Bool) { checks.append(["name": name, "passed": condition]) }
    record("从 Android 前台自动识别 DNF 并加载完整方案", activePackage == ReadySchemeCatalogue.dnfPackage && activeScheme == ReadySchemeCatalogue.dnfTitle && profile.bindings.count == 19)
    worker.async {
      do { try self.runtime.launch("com.androiddeck.demo", serial: serial) } catch { self.showError(error.localizedDescription); return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        record("Android 内切换应用自动隔离键位", self.activePackage == "com.androiddeck.demo" && self.profile.bindings.count == 2)
        self.worker.async {
          do { try self.runtime.launch(ReadySchemeCatalogue.dnfPackage, serial: serial) } catch { self.showError(error.localizedDescription); return }
          DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            record("返回 DNF 自动恢复推荐方案", self.activePackage == ReadySchemeCatalogue.dnfPackage && self.activeScheme == ReadySchemeCatalogue.dnfTitle && self.profile.bindings.count == 19)
            let result: [String: Any] = ["checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true }]
            do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: self.root.appendingPathComponent("data/mapping-follow-report.json")) } catch { self.showError(error.localizedDescription) }
            NSApp.terminate(nil)
          }
        }
      }
    }
  }
  func verifyMappingEditor() {
    guard ready else { return }
    var checks: [[String: Any]] = []
    func record(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
    func event(_ type: NSEvent.EventType, _ point: TouchPoint) -> NSEvent {
      let canvas = rootView.canvas
      let local = NSPoint(
        x: canvas.videoRect.minX + point.x * canvas.videoRect.width,
        y: canvas.videoRect.minY + point.y * canvas.videoRect.height)
      return NSEvent.mouseEvent(
        with: type, location: canvas.convert(local, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    input.release()
    selectMappingPackage("com.tencent.tmgp.dnf")
    record("进入 DNF 自动加载整套键位", activeScheme == ReadySchemeCatalogue.dnfTitle && profile.bindings.count == 19)
    record("原有默认方案仍可选", profiles[ReadySchemeCatalogue.dnfPackage] != nil && MappingStore.schemes(package: activePackage, profiles: profiles).contains(""))
    let original = profile
    let originalCount = profile.bindings.count
    rootView.canvas.editing = true
    rootView.canvas.tool = "tap"
    rootView.canvas.mouseDown(with: event(.leftMouseDown, TouchPoint(x: 0.42, y: 0.36)))
    rootView.canvas.mouseUp(with: event(.leftMouseUp, TouchPoint(x: 0.42, y: 0.36)))
    record(
      "任意屏幕位置创建触点",
      profile.bindings.count == originalCount + 1 && abs(profile.bindings.last!.x - 0.42) < 1e-9
        && abs(profile.bindings.last!.y - 0.36) < 1e-9)
    captureMappingCode("KeyB")
    record("新触点捕获按键", profile.bindings.last?.code == "KeyB")
    mappingPanel.name.stringValue = "界面测试触点"
    mappingPanel.nameChanged(nil)
    record("编辑触点名称", profile.bindings.last?.label == "界面测试触点")
    rootView.canvas.tool = "swipe"
    rootView.canvas.mouseDown(with: event(.leftMouseDown, TouchPoint(x: 0.25, y: 0.35)))
    Thread.sleep(forTimeInterval: 0.025)
    rootView.canvas.mouseDragged(with: event(.leftMouseDragged, TouchPoint(x: 0.45, y: 0.5)))
    Thread.sleep(forTimeInterval: 0.025)
    rootView.canvas.mouseUp(with: event(.leftMouseUp, TouchPoint(x: 0.7, y: 0.65)))
    record(
      "拖动画面录制轨迹",
      profile.bindings.last?.mode == "swipe" && (profile.bindings.last?.path?.count ?? 0) >= 3
        && profile.bindings.last?.path?.last?.t == 1)
    captureMappingCode("KeyK")
    let beforeMove = profile.bindings.last!
    var candidate = profile
    candidate.bindings[candidate.bindings.count - 1].move(to: TouchPoint(x: 0.35, y: 0.4))
    commitMapping(candidate)
    record(
      "整体平移轨迹保持形状",
      abs(
        (profile.bindings.last!.path!.last!.x - profile.bindings.last!.x)
          - (beforeMove.path!.last!.x - beforeMove.x)) < 1e-9)
    undoMapping()
    record("撤销轨迹修改", profile.bindings.last?.x == beforeMove.x)
    activeScheme = "自动验证方案"
    saveProfile()
    selectMappingScheme("")
    selectMappingScheme("自动验证方案")
    record("命名方案保存和切换", activeScheme == "自动验证方案" && profile.bindings.contains { $0.code == "KeyK" })
    selectMappingPackage("com.androiddeck.demo")
    record("不同 APK 的方案隔离", !profile.bindings.contains { $0.code == "KeyK" })
    selectMappingPackage("com.tencent.tmgp.dnf")
    selectMappingScheme("自动验证方案")
    record("切回 APK 恢复选择的方案", profile.bindings.contains { $0.code == "KeyK" })
    rootView.canvas.tool = "select"
    rootView.canvas.selectedBinding = 0
    let beforeDrag = profile.bindings[0]
    let offset = TouchPoint(x: 8 / Double(rootView.canvas.videoRect.width), y: 5 / Double(rootView.canvas.videoRect.height))
    let start = TouchPoint(x: beforeDrag.x + offset.x, y: beforeDrag.y + offset.y)
    let destination = TouchPoint(x: start.x - 0.04, y: start.y - 0.03)
    rootView.canvas.mouseDown(with: event(.leftMouseDown, start))
    rootView.canvas.mouseDragged(with: event(.leftMouseDragged, destination))
    rootView.canvas.mouseUp(with: event(.leftMouseUp, destination))
    record("拖动键位保持鼠标抓取偏移", abs(profile.bindings[0].x - (beforeDrag.x - 0.04)) < 1e-9 && abs(profile.bindings[0].y - (beforeDrag.y - 0.03)) < 1e-9)
    record("拖动后侧栏坐标同步更新", mappingPanel.x.stringValue == String(format: "%.1f", profile.bindings[0].x * 100))
    let beforeBlank = profile.bindings.count
    rootView.canvas.mouseDown(with: event(.leftMouseDown, TouchPoint(x: 0.4, y: 0.15)))
    rootView.canvas.mouseUp(with: event(.leftMouseUp, TouchPoint(x: 0.4, y: 0.15)))
    record("选取工具点击空白处直接创建触点", profile.bindings.count == beforeBlank + 1 && captureIndex == profile.bindings.count - 1)
    captureMappingCode("Escape")
    let clickBinding = profile.bindings[0]
    rootView.canvas.mouseDown(with: event(.leftMouseDown, TouchPoint(x: clickBinding.x, y: clickBinding.y)))
    rootView.canvas.mouseUp(with: event(.leftMouseUp, TouchPoint(x: clickBinding.x, y: clickBinding.y)))
    record("单击已有技能直接等待按键", captureIndex == 0 && rootView.canvas.bindingPrompt?.contains("直接按新键") == true)
    let otherCode = profile.bindings[1].code, previousCode = profile.bindings[0].code
    captureMappingCode(otherCode)
    record("按已有技能键直接交换且无重复", profile.bindings[0].code == otherCode && profile.bindings[1].code == previousCode && (try? profile.checked()) != nil)
    beginQuickKeyCapture(0); captureMappingCode("KeyW")
    record("移动键冲突保留设键提示", captureIndex == 0 && rootView.canvas.bindingPrompt?.contains("请再按一个键") == true)
    captureMappingCode("Escape")
    let recommended = profiles[MappingStore.key(package: activePackage, scheme: ReadySchemeCatalogue.dnfTitle)]!
    selectMappingScheme(ReadySchemeCatalogue.dnfTitle)
    rootView.canvas.editing = false; editMapping(nil)
    record("编辑推荐键位自动复制个人方案", activeScheme == "我的方案" && profiles[mappingKey]!.controlsEqual(recommended))
    beginQuickKeyCapture(0); captureMappingCode("KeyB")
    record("个人方案修改保留推荐方案", profiles[MappingStore.key(package: activePackage, scheme: ReadySchemeCatalogue.dnfTitle)]!.controlsEqual(recommended) && profile.bindings[0].code == "KeyB")
    selectMappingScheme(ReadySchemeCatalogue.dnfTitle)
    selectMappingScheme("我的方案")
    record("个人习惯方案可以切换恢复", profile.bindings[0].code == "KeyB")
    let dragPoint = TouchPoint(x: profile.bindings[0].x, y: profile.bindings[0].y)
    rootView.canvas.mouseDown(with: event(.leftMouseDown, dragPoint))
    rootView.canvas.mouseDragged(with: event(.leftMouseDragged, TouchPoint(x: dragPoint.x - 0.03, y: dragPoint.y - 0.02)))
    rootView.canvas.mouseUp(with: event(.leftMouseUp, TouchPoint(x: dragPoint.x - 0.03, y: dragPoint.y - 0.02)))
    record("拖动调整位置不会误进入设键", captureIndex == nil)
    beginLayoutCalibration()
    record("整体校准提供三个按钮提示", calibrationSource.count == 3 && rootView.canvas.onCalibrationPoint != nil && rootView.canvas.calibrationPrompt?.contains("1/3") == true)
    let cancel = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    _ = handleKey(cancel)
    record("Esc 取消布局校准且保留方案", calibrationOriginal == nil && rootView.canvas.onCalibrationPoint == nil)
    rootView.canvas.editing = true
    renderProfile()
    record(
      "编辑时显示隐藏键位和轨迹",
      rootView.canvas.markers().count == profile.bindings.count + (profile.joystick.enabled ? 1 : 0)
    )
    var large = original
    large.bindings = []
    let used = Set(large.joystick.keys + large.shortcuts.map(\.code) + ["F11"])
    for code in mappingCodes.sorted().filter({ !used.contains($0) }).prefix(40) {
      large.bindings.append(Binding(code: code, mode: "tap", x: 0.5, y: 0.5, label: code))
    }
    record("大量触点方案通过验证", (try? large.checked()) != nil)
    profile = large
    input.profile = profile
    renderProfile()
    record("触点选择列表支持滚动方案", mappingPanel.binding.numberOfItems == large.bindings.count)
    profile = MappingStore.resolve(package: activePackage, scheme: activeScheme, profiles: profiles)
    input.profile = profile
    renderProfile()
    captureIndex = -22
    captureMappingCode("F10")
    record("声音按键可自定义", profile.shortcuts.contains { $0.code == "F10" && $0.keycode == 164 })
    do {
      let encoded = try JSONEncoder().encode(profile)
      let imported = try MuMuMappingImport.decode(
        encoded, current: profile, keepJoystick: false, width: input.width, height: input.height)
      record("方案导出导入保真", imported.profile.controlsEqual(profile))
      let result: [String: Any] = [
        "checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true },
      ]
      try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("data/mapping-editor-ui-report.json"))
      rootView.savePreview(root.appendingPathComponent("data/mapping-editor-ui.png"))
      log("MAPPING_UI_TEST_DONE \(result["passed"]!)")
      if CommandLine.arguments.contains("--quit-after-ui-test") { NSApp.terminate(nil) }
    } catch { showError(error.localizedDescription) }
  }
}
