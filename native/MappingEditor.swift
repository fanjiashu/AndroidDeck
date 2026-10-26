// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

let editorTools: [(String, String)] =
  [("select", "点选设键 / 拖动")] + mappingModes + [("joystick", "方向摇杆")]

final class MappingPanel: NSStackView {
  weak var owner: AppDelegate?
  let application = NSPopUpButton(), scheme = NSPopUpButton(), tool = NSPopUpButton(),
    binding = NSPopUpButton()
  let name = NSTextField(), mode = NSPopUpButton(), key = NSButton(),
    visible = NSButton(checkboxWithTitle: "显示此键位", target: nil, action: nil)
  let details = column(), gestureFields = column(), repeatFields = column(), pinchFields = column(),
    rotationFields = column(), endpointFields = column(), audioFields = column()
  let duration = NSTextField(), interval = NSTextField(), scale = NSTextField(),
    angle = NSTextField(), radius = NSTextField(), x = NSTextField(), y = NSTextField(),
    endX = NSTextField(), endY = NSTextField()
  let audio = NSPopUpButton(),
    joystick = NSButton(checkboxWithTitle: "启用摇杆", target: nil, action: nil),
    joystickVisible = NSButton(checkboxWithTitle: "显示摇杆", target: nil, action: nil)
  let joystickPreset = NSPopUpButton(),
    joystickRadius = NSSlider(value: 9, minValue: 1, maxValue: 30, target: nil, action: nil)
  var joystickKeys: [NSButton] = []
  let volume = NSSlider(value: 80, minValue: 0, maxValue: 100, target: nil, action: nil),
    volumeText = label("游戏音量 · 80%", 11, muted)
  var soundKeys: [NSButton] = []
  var selectedIndex: Int?
  var applicationPackages: [String] = ["default"]
  var schemeNames: [String] = [""]
  let edit = NSButton(), undo = NSButton()
  let readyPicker = NSPopUpButton(), readyInfo = label("检查匹配方案…", 10, muted)
  let follow = NSButton(checkboxWithTitle: "进入应用自动加载键位", target: nil, action: nil)
  override init(frame: NSRect) {
    super.init(frame: frame)
    orientation = .vertical
    alignment = .leading
    spacing = 10
    func add(_ view: NSView) { addArrangedSubview(view) }
    func row(_ title: String, _ fields: [NSView]) -> NSStackView {
      let row = NSStackView()
      row.orientation = .horizontal
      row.spacing = 4
      if !title.isEmpty {
        let l = label(title, 11, muted)
        l.widthAnchor.constraint(equalToConstant: 54).isActive = true
        row.addArrangedSubview(l)
      }
      for field in fields { row.addArrangedSubview(field) }
      return row
    }
    func field(_ value: NSTextField, _ tag: Int) -> NSTextField {
      value.tag = tag
      value.target = self
      value.action = #selector(parameterChanged(_:))
      value.widthAnchor.constraint(equalToConstant: 66).isActive = true
      value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      return value
    }
    add(DeckTheme.section("应用与方案", detail: "每个应用，保留一套熟悉的操作"))
    application.target = self
    application.action = #selector(applicationChanged(_:))
    add(application)
    scheme.target = self
    scheme.action = #selector(schemeChanged(_:))
    add(scheme)
    follow.target = self; follow.action = #selector(followChanged(_:)); add(follow)
    add(readyPicker); add(readyInfo)
    add(row("", [button("应用整套键位", self, #selector(applyReady(_:))), button("整体校准", self, #selector(calibrate(_:)))]))
    add(
      row(
        "",
        [
          button("新建个人方案", self, #selector(saveScheme(_:))),
          button("删除方案", self, #selector(deleteScheme(_:))),
        ]))
    add(DeckTheme.section("触控映射", detail: "点画面上的按钮，再按对应键盘按键"))
    edit.title = "点选设键"
    edit.bezelStyle = .rounded
    edit.target = self
    edit.action = #selector(editChanged(_:))
    add(edit)
    tool.addItems(withTitles: editorTools.map(\.1))
    tool.target = self
    tool.action = #selector(toolChanged(_:))
    add(tool)
    add(label("点技能 → 按键 → 完成；改动自动保存\n拖动调整位置 · 个人方案可随时切换", 10, muted))
    binding.target = self
    binding.action = #selector(selectionChanged(_:))
    add(binding)
    add(details)
    name.placeholderString = "操作名称"
    name.target = self
    name.action = #selector(nameChanged(_:))
    name.widthAnchor.constraint(equalToConstant: 238).isActive = true
    details.addArrangedSubview(name)
    key.bezelStyle = .rounded
    key.target = self
    key.action = #selector(capture(_:))
    mode.addItems(withTitles: mappingModes.map(\.1))
    mode.target = self
    mode.action = #selector(modeChanged(_:))
    details.addArrangedSubview(row("", [key, mode]))
    details.addArrangedSubview(row("位置 %", [field(x, 0), field(y, 1)]))
    gestureFields.addArrangedSubview(row("时长 ms", [field(duration, 2)]))
    details.addArrangedSubview(gestureFields)
    repeatFields.addArrangedSubview(row("间隔 ms", [field(interval, 3)]))
    details.addArrangedSubview(repeatFields)
    pinchFields.addArrangedSubview(row("倍率", [field(scale, 4)]))
    details.addArrangedSubview(pinchFields)
    rotationFields.addArrangedSubview(row("角度 °", [field(angle, 5)]))
    details.addArrangedSubview(rotationFields)
    let radiusRow = row("半径 %", [field(radius, 6)])
    radiusRow.identifier = NSUserInterfaceItemIdentifier("gestureRadius")
    details.addArrangedSubview(radiusRow)
    endpointFields.addArrangedSubview(row("终点 %", [field(endX, 7), field(endY, 8)]))
    endpointFields.addArrangedSubview(button("重新录制轨迹", self, #selector(recordPath(_:))))
    details.addArrangedSubview(endpointFields)
    audio.addItems(withTitles: ["音量增大", "音量减小", "静音切换"])
    audio.target = self
    audio.action = #selector(audioChanged(_:))
    audioFields.addArrangedSubview(audio)
    details.addArrangedSubview(audioFields)
    visible.target = self
    visible.action = #selector(visibilityChanged(_:))
    details.addArrangedSubview(visible)
    details.addArrangedSubview(
      row(
        "",
        [
          button("预览手势", self, #selector(preview(_:))), button("停止", self, #selector(stop(_:))),
          button("删除", self, #selector(deleteBinding(_:))),
        ]))
    undo.title = "撤销修改"
    undo.bezelStyle = .rounded
    undo.target = self
    undo.action = #selector(undoChanged(_:))
    add(undo)
    add(DeckTheme.section("方向摇杆"))
    joystick.target = self
    joystick.action = #selector(joystickChanged(_:))
    joystickVisible.target = self
    joystickVisible.action = #selector(joystickChanged(_:))
    add(row("", [joystick, joystickVisible]))
    joystickPreset.addItems(withTitles: ["W / A / S / D", "↑ / ← / ↓ / →", "自定义方向键"])
    joystickPreset.target = self
    joystickPreset.action = #selector(joystickPresetChanged(_:))
    add(joystickPreset)
    for i in 0..<4 {
      let b = button("", self, #selector(captureJoystick(_:)))
      b.tag = i
      joystickKeys.append(b)
    }
    add(row("", joystickKeys))
    joystickRadius.target = self
    joystickRadius.action = #selector(joystickRadiusChanged(_:))
    add(joystickRadius)
    add(
      row(
        "",
        [
          button("导入方案", self, #selector(importChanged(_:))),
          button("导出方案", self, #selector(exportChanged(_:))),
        ]))
    add(button("重置当前方案", self, #selector(resetChanged(_:))))
    add(DeckTheme.section("声音与快捷键"))
    add(volumeText)
    volume.target = self
    volume.action = #selector(volumeChanged(_:))
    add(volume)
    add(
      row(
        "",
        [
          button("−", self, #selector(volumeDown(_:))), button("静音", self, #selector(mute(_:))),
          button("+", self, #selector(volumeUp(_:))),
        ]))
    for i in 0..<3 {
      let b = button("", self, #selector(captureSound(_:)))
      b.tag = i
      soundKeys.append(b)
    }
    add(row("", soundKeys))
    add(label("触控板支持双指缩放和旋转\n滚轮、鼠标键也可绑定 · F11 全屏", 10, muted))
    for popup in [application, scheme, readyPicker, tool, binding, joystickPreset] {
      popup.widthAnchor.constraint(equalToConstant: 264).isActive = true
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  func refresh() {
    guard let owner = owner else { return }
    application.selectItem(at: applicationPackages.firstIndex(of: owner.activePackage) ?? 0)
    follow.state = owner.prefs.followForegroundApp == false ? .off : .on
    readyPicker.removeAllItems(); readyPicker.addItems(withTitles: owner.readySchemes.isEmpty ? ["暂无匹配方案"] : owner.readySchemes.map(\.title))
    readyPicker.isEnabled = !owner.readySchemes.isEmpty
    readyInfo.stringValue = owner.readySchemes.isEmpty ? "此应用需导入或配置方案" : "匹配 \(owner.readySchemes.count) 套 · 可直接应用"
    let names = MappingStore.schemes(package: owner.activePackage, profiles: owner.profiles)
    schemeNames = names
    scheme.removeAllItems()
    scheme.addItems(withTitles: names.map { $0.isEmpty ? "默认方案" : $0 })
    scheme.selectItem(at: names.firstIndex(of: owner.activeScheme) ?? 0)
    binding.removeAllItems()
    binding.addItems(
      withTitles: owner.profile.bindings.map {
        "\(keyLabel($0.code)) · \($0.label.isEmpty ? $0.modeTitle : $0.label)"
      })
    if let index = selectedIndex, owner.profile.bindings.indices.contains(index) {
      binding.selectItem(at: index)
    } else {
      selectedIndex = owner.profile.bindings.isEmpty ? nil : 0
      binding.selectItem(at: 0)
    }
    owner.rootView.canvas.selectedBinding = selectedIndex
    edit.title = owner.rootView.canvas.editing ? "完成设键" : "点选设键"
    tool.isEnabled = owner.rootView.canvas.editing
    edit.isEnabled = owner.ready && !owner.busy
    undo.isEnabled = !owner.mappingUndo.isEmpty
    joystick.state = owner.profile.joystick.enabled ? .on : .off
    joystickVisible.state = owner.profile.joystick.visible == false ? .off : .on
    joystickRadius.doubleValue = owner.profile.joystick.radius * 100
    let keys = owner.profile.joystick.keys
    joystickPreset.selectItem(
      at: keys == ["KeyW", "KeyA", "KeyS", "KeyD"]
        ? 0 : keys == ["ArrowUp", "ArrowLeft", "ArrowDown", "ArrowRight"] ? 1 : 2)
    for i in 0..<4 { joystickKeys[i].title = keyLabel(keys[i]) }
    for (i, code) in [UInt32(24), 25, 164].enumerated() {
      soundKeys[i].title =
        (owner.profile.shortcuts.first { $0.keycode == code }.map { keyLabel($0.code) } ?? "未设")
        + [" +", " −", " 静音"][i]
    }
    refreshDetails()
  }
  func refreshDetails() {
    guard let owner = owner, let index = selectedIndex,
      owner.profile.bindings.indices.contains(index)
    else {
      details.isHidden = true
      return
    }
    details.isHidden = false
    let b = owner.profile.bindings[index]
    name.stringValue = b.label
    name.delegate = owner
    key.title = "绑定 " + keyLabel(b.code)
    mode.selectItem(at: mappingModes.firstIndex { $0.0 == b.mode } ?? 0)
    x.stringValue = String(format: "%.1f", b.x * 100)
    y.stringValue = String(format: "%.1f", b.y * 100)
    duration.integerValue = b.durationMs ?? 300
    interval.integerValue = b.intervalMs ?? 100
    scale.doubleValue = b.scale ?? 2
    angle.doubleValue = b.rotation ?? 90
    radius.doubleValue = (b.radius ?? 0.08) * 100
    endX.doubleValue = (b.path?.last?.x ?? b.x) * 100
    endY.doubleValue = (b.path?.last?.y ?? b.y) * 100
    gestureFields.isHidden = !["swipe", "pinch", "rotate"].contains(b.mode)
    repeatFields.isHidden = !["repeat", "audio"].contains(b.mode)
    pinchFields.isHidden = b.mode != "pinch"
    rotationFields.isHidden = b.mode != "rotate"
    endpointFields.isHidden = b.mode != "swipe"
    audioFields.isHidden = b.mode != "audio"
    details.arrangedSubviews.first { $0.identifier?.rawValue == "gestureRadius" }?.isHidden = ![
      "pinch", "rotate",
    ].contains(b.mode)
    audio.selectItem(
      at: ["volumeUp", "volumeDown", "mute"].firstIndex(of: b.audioAction ?? "volumeUp") ?? 0)
    visible.state = b.visible == false ? .off : .on
    owner.rootView.needsLayout = true
    owner.rootView.canvas.needsDisplay = true
  }
  func change(_ block: (inout Binding) -> Void) {
    guard let owner = owner, let index = selectedIndex,
      owner.profile.bindings.indices.contains(index)
    else { return }
    var candidate = owner.profile
    block(&candidate.bindings[index])
    owner.commitMapping(candidate)
  }
  func refreshApplications(_ apps: [AndroidApp]) {
    guard let owner = owner else { return }
    applicationPackages = ["default"] + apps.map(\.package)
    application.removeAllItems()
    application.addItems(withTitles: ["全局 / 未指定应用"] + apps.map(\.name))
    application.selectItem(at: applicationPackages.firstIndex(of: owner.activePackage) ?? 0)
  }
  @objc func applicationChanged(_ sender: Any?) {
    guard let owner = owner, applicationPackages.indices.contains(application.indexOfSelectedItem)
    else { return }
    owner.selectMappingPackage(applicationPackages[application.indexOfSelectedItem])
    owner.prefs.followForegroundApp = false; owner.persistPreferences(); refresh()
  }
  @objc func schemeChanged(_ sender: Any?) {
    guard schemeNames.indices.contains(scheme.indexOfSelectedItem) else { return }
    owner?.selectMappingScheme(schemeNames[scheme.indexOfSelectedItem])
  }
  @objc func saveScheme(_ sender: Any?) { owner?.saveMappingScheme() }
  @objc func deleteScheme(_ sender: Any?) { owner?.deleteMappingScheme() }
  @objc func editChanged(_ sender: Any?) { owner?.editMapping(sender) }
  @objc func toolChanged(_ sender: Any?) {
    guard let owner = owner else { return }
    owner.input.release()
    owner.cancelLayoutCalibration()
    owner.rootView.canvas.tool = editorTools[tool.indexOfSelectedItem].0
    owner.rootView.canvas.replacingBinding = nil
  }
  @objc func selectionChanged(_ sender: Any?) {
    selectedIndex = binding.indexOfSelectedItem
    owner?.rootView.canvas.selectedBinding = selectedIndex
    refreshDetails()
  }
  @objc func capture(_ sender: Any?) {
    if let index = selectedIndex {
      owner?.captureIndex = index
      owner?.captureMouseEnabled = true
      key.title = "按键 / 点击鼠标…"
      owner?.input.release()
    }
  }
  @objc func nameChanged(_ sender: Any?) { change { $0.label = name.stringValue } }
  @objc func modeChanged(_ sender: Any?) {
    change { $0.setMode(mappingModes[mode.indexOfSelectedItem].0) }
  }
  @objc func parameterChanged(_ sender: NSTextField) {
    guard let value = Double(sender.stringValue), value.isFinite else {
      owner?.showError("请输入有效数值")
      refreshDetails()
      return
    }
    change { b in
      switch sender.tag {
      case 0: b.move(to: TouchPoint(x: value / 100, y: b.y))
      case 1: b.move(to: TouchPoint(x: b.x, y: value / 100))
      case 2: b.durationMs = Int(value)
      case 3: b.intervalMs = Int(value)
      case 4: b.scale = value
      case 5: b.rotation = value
      case 6: b.radius = value / 100
      case 7: if b.path != nil { b.path![b.path!.count - 1].x = value / 100 }
      case 8: if b.path != nil { b.path![b.path!.count - 1].y = value / 100 }
      default: break
      }
    }
  }
  @objc func recordPath(_ sender: Any?) {
    guard let owner = owner, let index = selectedIndex else { return }
    owner.input.release()
    owner.rootView.canvas.editing = true
    owner.rootView.canvas.tool = "swipe"
    owner.rootView.canvas.replacingBinding = index
    tool.selectItem(at: editorTools.firstIndex { $0.0 == "swipe" }!)
    owner.renderProfile()
  }
  @objc func audioChanged(_ sender: Any?) {
    change { $0.audioAction = ["volumeUp", "volumeDown", "mute"][audio.indexOfSelectedItem] }
  }
  @objc func visibilityChanged(_ sender: Any?) { change { $0.visible = visible.state == .on } }
  @objc func preview(_ sender: Any?) {
    guard let owner = owner, owner.ready, let index = selectedIndex else { return }
    owner.input.release()
    owner.input.startBinding(owner.profile.bindings[index], index: index, preview: true)
  }
  @objc func stop(_ sender: Any?) { owner?.input.release() }
  @objc func deleteBinding(_ sender: Any?) {
    guard let owner = owner, let index = selectedIndex else { return }
    var p = owner.profile
    p.bindings.remove(at: index)
    selectedIndex = nil
    owner.commitMapping(p)
  }
  @objc func undoChanged(_ sender: Any?) { owner?.undoMapping() }
  @objc func joystickChanged(_ sender: Any?) {
    guard let owner = owner else { return }
    var p = owner.profile
    p.joystick.enabled = joystick.state == .on
    p.joystick.visible = joystickVisible.state == .on
    owner.commitMapping(p)
  }
  @objc func joystickPresetChanged(_ sender: Any?) {
    guard let owner = owner, joystickPreset.indexOfSelectedItem < 2 else { return }
    var p = owner.profile
    p.joystick.keys =
      joystickPreset.indexOfSelectedItem == 0
      ? ["KeyW", "KeyA", "KeyS", "KeyD"] : ["ArrowUp", "ArrowLeft", "ArrowDown", "ArrowRight"]
    owner.commitMapping(p)
  }
  @objc func captureJoystick(_ sender: NSButton) {
    owner?.input.release()
    owner?.captureIndex = -10 - sender.tag
    sender.title = "按键…"
  }
  @objc func joystickRadiusChanged(_ sender: Any?) {
    guard let owner = owner else { return }
    var p = owner.profile
    p.joystick.radius = joystickRadius.doubleValue / 100
    owner.commitMapping(p)
  }
  @objc func importChanged(_ sender: Any?) { owner?.importProfile(sender) }
  @objc func exportChanged(_ sender: Any?) { owner?.exportProfile(sender) }
  @objc func resetChanged(_ sender: Any?) { owner?.resetProfile(sender) }
  @objc func volumeChanged(_ sender: Any?) { owner?.setGameVolume(Int(volume.doubleValue)) }
  @objc func volumeDown(_ sender: Any?) { owner?.adjustGameAudio("volumeDown") }
  @objc func volumeUp(_ sender: Any?) { owner?.adjustGameAudio("volumeUp") }
  @objc func mute(_ sender: Any?) { owner?.adjustGameAudio("mute") }
  @objc func captureSound(_ sender: NSButton) {
    owner?.input.release()
    owner?.captureIndex = -20 - sender.tag
    sender.title = "按键…"
  }
  @objc func followChanged(_ sender: Any?) { owner?.prefs.followForegroundApp = follow.state == .on; owner?.persistPreferences() }
  @objc func applyReady(_ sender: Any?) { guard let owner = owner, owner.readySchemes.indices.contains(readyPicker.indexOfSelectedItem) else { return }; owner.applyReadyScheme(owner.readySchemes[readyPicker.indexOfSelectedItem]) }
  @objc func calibrate(_ sender: Any?) { owner?.beginLayoutCalibration() }
}

extension AppDelegate {
  var mappingKey: String { MappingStore.key(package: activePackage, scheme: activeScheme) }
  func beginQuickKeyCapture(_ index: Int) {
    guard profile.bindings.indices.contains(index) else { return }
    input.release(); captureIndex = index; captureMouseEnabled = false
    mappingPanel.selectedIndex = index; rootView.canvas.selectedBinding = index
    mappingPanel.key.title = "直接按新键…"
    rootView.canvas.bindingPrompt = "已选 \(profile.bindings[index].label) · 直接按新键 · Esc 取消"
    rootView.canvas.needsDisplay = true
  }
  func ensurePersonalMappingScheme() {
    guard activeScheme.isEmpty || readySchemes.contains(where: { $0.title == activeScheme }) else { return }
    let name = "我的方案", key = MappingStore.key(package: activePackage, scheme: name)
    if profiles[key] == nil { profiles[key] = profile; persistMappingCollection() }
    selectMappingScheme(name)
  }
  func commitMapping(_ candidate: Profile) {
    do {
      let valid = try candidate.checked()
      mappingUndo.append(profile)
      if mappingUndo.count > 20 { mappingUndo.removeFirst() }
      captureIndex = nil
      profile = valid
      saveProfile()
    } catch {
      showError(error.localizedDescription)
      mappingPanel.refreshDetails()
    }
  }
  func undoMapping() {
    guard let previous = mappingUndo.popLast() else { return }
    input.release()
    profile = previous
    saveProfile()
  }
  func selectMappingPackage(_ package: String) {
    input.release()
    cancelLayoutCalibration()
    captureIndex = nil
    activePackage = package
    prepareInteractionSchemes(package: package)
    rootView.canvas.cancelEditorGesture()
    activeScheme = prefs.profileSelections?[package] ?? ""
    if !MappingStore.schemes(package: package, profiles: profiles).contains(activeScheme) {
      activeScheme = ""
    }
    profile = MappingStore.resolve(package: package, scheme: activeScheme, profiles: profiles)
    mappingUndo = []
    mappingPanel.selectedIndex = nil
    input.profile = profile
    renderProfile()
    requestDisplayForActivePackage()
  }
  func selectMappingScheme(_ name: String) {
    input.release()
    cancelLayoutCalibration()
    captureIndex = nil
    activeScheme = name
    rootView.canvas.cancelEditorGesture()
    profile = MappingStore.resolve(package: activePackage, scheme: name, profiles: profiles)
    mappingUndo = []
    mappingPanel.selectedIndex = nil
    input.profile = profile
    if prefs.profileSelections == nil { prefs.profileSelections = [:] }
    prefs.profileSelections![activePackage] = name
    persistPreferences()
    renderProfile()
  }
  func saveMappingScheme() {
    input.release()
    let alert = NSAlert()
    alert.messageText = "新建个人方案"
    alert.informativeText = "复制当前键位，保存一套符合自己习惯的方案。"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "方案名称"
    alert.accessoryView = field
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 32, name != "默认方案",
      !MappingStore.schemes(package: activePackage, profiles: profiles).contains(name)
    else {
      showError("名称为空、过长或已存在")
      return
    }
    activeScheme = name
    saveProfile()
    selectMappingScheme(name)
  }
  func deleteMappingScheme() {
    guard !activeScheme.isEmpty else {
      showError("默认方案可重置；不能删除")
      return
    }
    input.release()
    profiles.removeValue(forKey: mappingKey)
    selectMappingScheme("")
    saveProfile()
  }
  func createMapping(
    mode: String, point: TouchPoint, path: [GesturePoint]? = nil, duration: Int? = nil,
    replacing: Int? = nil
  ) {
    if mode == "joystick" {
      var p = profile
      p.joystick.enabled = true
      p.joystick.x = point.x
      p.joystick.y = point.y
      commitMapping(p)
      return
    }
    var p = profile
    if let index = replacing, p.bindings.indices.contains(index) {
      p.bindings[index].x = point.x
      p.bindings[index].y = point.y
      p.bindings[index].mode = "swipe"
      p.bindings[index].path = path
      p.bindings[index].durationMs = duration
      mappingPanel.selectedIndex = index
      commitMapping(p)
      return
    }
    guard p.bindings.count < 64 else {
      showError("每套方案最多 64 个触点")
      return
    }
    let used = Set(
      p.bindings.map(\.code) + (p.joystick.enabled ? p.joystick.keys : []) + p.shortcuts.map(\.code)
    )
    let preferred =
      [
        "KeyG", "KeyQ", "KeyE", "KeyR", "KeyT", "KeyZ", "KeyX", "KeyC", "KeyV", "KeyB", "KeyJ",
        "KeyK", "KeyL",
      ] + mappingCodes.sorted()
    guard let code = preferred.first(where: { $0 != "F11" && !used.contains($0) }) else {
      showError("可用按键已全部占用")
      return
    }
    var b = Binding(
      code: code, mode: mode, x: point.x, y: point.y,
      label: mappingModes.first { $0.0 == mode }?.1 ?? "触点", path: path)
    if mode == "swipe" { b.durationMs = duration ?? 300 }
    p.bindings.append(b)
    mappingPanel.selectedIndex = p.bindings.count - 1
    commitMapping(p)
    captureIndex = mappingPanel.selectedIndex
    captureMouseEnabled = false
    mappingPanel.key.title = "按一个键绑定…"
    rootView.canvas.bindingPrompt = "触点已放置 · 直接按键设置 · Esc 取消"
  }
  func captureMappingCode(_ code: String) {
    guard let target = captureIndex else { return }
    captureMouseEnabled = false
    if code == "Escape" {
      captureIndex = nil
      rootView.canvas.bindingPrompt = "点下一技能继续设键 · 拖动调整位置"
      renderProfile()
      return
    }
    var candidate = profile
    if target >= 0, candidate.bindings.indices.contains(target) {
      do { candidate = try candidate.rebinding(target, to: code) }
      catch { rootView.canvas.bindingPrompt = error.localizedDescription + " · 请再按一个键"; rootView.canvas.needsDisplay = true; return }
    } else if (-13 ... -10).contains(target), physicalCodes.values.contains(code) {
      candidate.joystick.keys[-10 - target] = code
    } else if (-22 ... -20).contains(target) {
      let soundCode = [UInt32(24), 25, 164][-20 - target]
      if code == "Backspace" {
        candidate.shortcuts.removeAll { $0.keycode == soundCode }
      } else if let index = candidate.shortcuts.firstIndex(where: { $0.keycode == soundCode }) {
        candidate.shortcuts[index].code = code
      } else {
        candidate.shortcuts.append(Shortcut(code: code, keycode: soundCode))
      }
    } else {
      captureIndex = nil
      renderProfile()
      return
    }
    commitMapping(candidate)
    rootView.canvas.bindingPrompt = rootView.canvas.editing ? "已设 \(keyLabel(code)) · 点下一技能继续 · 完成设键后使用" : nil
  }
}
