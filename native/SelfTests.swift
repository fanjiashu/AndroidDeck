// SPDX-License-Identifier: GPL-3.0-only
import CoreVideo
import Foundation

@main struct NativeSelfTests {
  static func main() throws {
    var passed: [String] = []
    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
      guard condition() else {
        FileHandle.standardError.write(Data("FAILED: \(name)\n".utf8))
        exit(1)
      }
      passed.append(name)
    }
    let input = InputEngine()
    var packets: [Data] = []
    input.writer = { packets.append($0) }
    input.key("KeyW", true)
    input.key("Space", true)
    check("摇杆与动作键使用双触点", input.contacts.count == 2)
    let count = packets.count
    input.key("Space", true)
    check("重复按键不重复按下", packets.count == count)
    input.key("KeyD", true)
    let position = input.contacts[100]!
    check(
      "斜向归一化半径", abs(hypot((position.0 - 0.22) * 720, (position.1 - 0.73) * 1280) - 64.8) < 0.001)
    input.release()
    check("释放全部触点和按键", input.contacts.isEmpty && input.pressed.isEmpty)
    input.key("KeyF", true)
    check("单次点击立即按下并保留短按", input.contacts.count == 1)
    input.key("KeyF", false)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
    check("单次点击短按后自动抬起", input.contacts.isEmpty && input.actionTimer == nil)
    input.release()
    packets = []
    input.width = 1280
    input.height = 720
    input.touch(0, 1, 1, 1)
    check(
      "横屏坐标与边缘限制",
      packets[0].integer(10, UInt32.self) == 1279 && packets[0].integer(14, UInt32.self) == 719
        && packets[0].integer(18, UInt16.self) == 1280)
    input.release()
    input.key("F2", true)
    input.release()
    check("释放 Android 系统键", packets.last?.prefix(2) == Data([0, 1]))
    func pump(_ duration: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: duration)) }
    func touchPackets() -> [Data] { packets.filter { $0.first == 2 } }
    for (code, direction) in [
      ("KeyW", (0, -1)), ("KeyA", (-1, 0)), ("KeyS", (0, 1)), ("KeyD", (1, 0)),
    ] {
      packets = []
      input.key(code, true)
      input.key(code, false)
      let events = touchPackets()
      let expectedX = UInt32((0.22 * 1280 + Double(direction.0) * 64.8).rounded())
      let expectedY = UInt32((0.73 * 720 + Double(direction.1) * 64.8).rounded())
      check(
        "即时方向 \(code)",
        events.map { $0[1] } == [0, 2, 1] && events[1].integer(10, UInt32.self) == expectedX
          && events[1].integer(14, UInt32.self) == expectedY)
      check("松开保持末次坐标 \(code)", events[2].subdata(in: 10..<18) == events[1].subdata(in: 10..<18))
    }
    packets = []
    input.key("KeyW", true)
    pump(0.18)
    check("长按持续发送拖动事件", touchPackets().filter { $0[1] == 2 }.count >= 4)
    input.key("KeyS", true)
    check("相反方向保持单触点并回中", input.contacts.count == 1 && abs(input.contacts[100]!.1 - 0.73) < 1e-9)
    input.key("KeyS", false)
    check("松开相反方向恢复原方向", input.contacts[100]!.1 < 0.73)
    input.key("KeyD", true)
    input.key("KeyW", false)
    check("换向复用同一触点", touchPackets().filter { $0[1] == 0 }.count == 1 && input.contacts.count == 1)
    input.key("Space", true)
    input.key("KeyD", false)
    check("释放摇杆保留动作长按", input.contacts.count == 1 && input.contacts[10] != nil)
    input.release()
    let stopped = packets.count
    pump(0.12)
    check("释放后没有延迟移动事件", packets.count == stopped && input.contacts.isEmpty)
    input.key("KeyW", true)
    input.release()
    input.key("KeyD", true)
    pump(0.08)
    check("新手势没有旧方向回调", input.contacts[100]!.0 > 0.22 && abs(input.contacts[100]!.1 - 0.73) < 1e-9)
    input.release()
    let dnf = Profile.standard.migrateJoystick(for: "com.tencent.tmgp.dnf")
    check(
      "DNF 旧默认中心校正",
      dnf.joystick.x == 0.15625 && dnf.joystick.y == 0.73 && dnf.joystick.radius == 0.09
        && dnf.joystickPresetVersion == 1)
    let profileEncoder = JSONEncoder()
    profileEncoder.outputFormatting = .sortedKeys
    let dnfBindings = try profileEncoder.encode(dnf.bindings)
    let defaultBindings = try profileEncoder.encode(Profile.standard.bindings)
    check(
      "迁移保留绑定及按键",
      dnfBindings == defaultBindings && dnf.joystick.keys == Profile.standard.joystick.keys)
    var custom = Profile.standard
    custom.joystick.x = 0.18
    custom.joystick.y = 0.81
    check(
      "保留 DNF 自定义中心",
      custom.migrateJoystick(for: "com.tencent.tmgp.dnf").joystick.x == 0.18
        && custom.migrateJoystick(for: "com.tencent.tmgp.dnf").joystick.y == 0.81)
    custom = dnf
    custom.joystick.x = 0.22
    check("中心迁移只执行一次", custom.migrateJoystick(for: "com.tencent.tmgp.dnf").joystick.x == 0.22)
    check("其他应用预设保持原样", Profile.initial(for: "com.androiddeck.demo").joystick.x == 0.22)
    let gestures = InputEngine()
    gestures.resize(width: 1280, height: 720)
    var gesturePackets: [Data] = []
    gestures.writer = { gesturePackets.append($0) }
    var gestureProfile = Profile.standard
    gestureProfile.bindings = [
      Binding(
        code: "KeyG", mode: "swipe", x: 0.2, y: 0.3, label: "滑动", durationMs: 180,
        path: [
          GesturePoint(x: 0.2, y: 0.3, t: 0), GesturePoint(x: 0.5, y: 0.5, t: 0.5),
          GesturePoint(x: 0.8, y: 0.6, t: 1),
        ]),
      Binding(code: "KeyQ", mode: "repeat", x: 0.7, y: 0.7, label: "连点", intervalMs: 60),
      Binding(
        code: "KeyE", mode: "pinch", x: 0.5, y: 0.5, label: "缩放", durationMs: 180, scale: 2,
        radius: 0.1),
      Binding(
        code: "KeyR", mode: "rotate", x: 0.5, y: 0.5, label: "旋转", durationMs: 180, rotation: 90,
        radius: 0.1),
      Binding(code: "KeyJ", mode: "hold", x: 0.8, y: 0.8, label: "按住"),
      Binding(code: "MouseMiddle", mode: "tap", x: 0.4, y: 0.4, label: "鼠标"),
    ]
    gestures.profile = try gestureProfile.checked()
    gestures.key("KeyG", true)
    gestures.key("KeyG", false)
    check("滑动快速松键仍完成单次手势", gestures.contacts[10] != nil)
    pump(0.24)
    check(
      "滑动按时释放并到达终点",
      gestures.contacts.isEmpty && gesturePackets.last?.integer(10, UInt32.self) == 1024
        && gesturePackets.last?.integer(14, UInt32.self) == 432)
    gesturePackets = []
    gestures.key("KeyQ", true)
    pump(0.22)
    gestures.key("KeyQ", false)
    check(
      "连点产生独立点击",
      gesturePackets.filter { $0.count == 32 && $0[1] == 0 }.count >= 3 && gestures.contacts.isEmpty
    )
    let repeatStopped = gesturePackets.count
    pump(0.12)
    check("松开停止连点", gesturePackets.count == repeatStopped)
    gesturePackets = []
    gestures.key("KeyE", true)
    check(
      "缩放原子获取两个触点",
      gestures.contacts.count == 2 && gestures.contacts[12] != nil && gestures.contacts[1002] != nil
    )
    gestures.key("KeyE", false)
    pump(0.25)
    let pinchMoves = gesturePackets.filter { $0[1] == 2 }
    check(
      "双指缩放扩大距离并释放",
      pinchMoves.count > 4 && gestures.contacts.isEmpty
        && pinchMoves.last?.integer(10, UInt32.self) == 784)
    gesturePackets = []
    gestures.key("KeyR", true)
    gestures.key("KeyR", false)
    pump(0.25)
    check(
      "双指旋转到指定角度",
      gestures.contacts.isEmpty
        && gesturePackets.filter { $0[1] == 2 }.last?.integer(14, UInt32.self) == 432)
    gestures.key("KeyW", true)
    gestures.key("KeyE", true)
    check("摇杆与双指手势共存", gestures.contacts.count == 3)
    gestures.release()
    let cancelled = gesturePackets.count
    pump(0.25)
    check("取消后无迟到手势帧", gesturePackets.count == cancelled && gestures.contacts.isEmpty)
    for id in 2000..<2009 { gestures.touch(0, id, 0.2, 0.2) }
    gestures.key("KeyE", true)
    check(
      "容量不足不注入半个双指手势",
      gestures.contacts.count == 9 && gestures.contacts[12] == nil && gestures.contacts[1002] == nil
    )
    gestures.release()
    gestures.key("KeyJ", true)
    var presentation = gestures.profile
    presentation.bindings[4].visible = false
    presentation.bindings[4].label = "改名"
    gestures.profile = presentation
    check("隐藏和改名不改变按住触点", gestures.contacts[14] != nil)
    presentation.bindings[4].x = 0.6
    gestures.profile = presentation
    check("改位置释放旧触点", gestures.contacts.isEmpty)
    gestures.profile = gestureProfile
    gestures.key("KeyG", true)
    gestures.key("KeyG", false)
    pump(0.04)
    gestures.resize(width: 720, height: 1280)
    let resized = gesturePackets.count
    pump(0.2)
    check("旋转和尺寸改变取消全部手势", gestures.contacts.isEmpty && gesturePackets.count == resized)
    gestures.key("MouseMiddle", true)
    gestures.key("MouseMiddle", false)
    check("鼠标映射快速松开仍完成短按", gestures.contacts[15] != nil)
    pump(0.11)
    check("鼠标按钮映射为点击", gestures.contacts.isEmpty)
    gesturePackets = []
    gestures.key("MouseMiddle", true); gestures.key("MouseMiddle", false)
    pump(0.02)
    gestures.key("MouseMiddle", true); gestures.key("MouseMiddle", false)
    check("同键快速重按不截断未完成短按", gesturePackets.filter { $0[1] == 0 }.count == 1 && gestures.contacts[15] != nil)
    pump(0.10)
    check("合并短按只抬起一次", gesturePackets.filter { $0[1] == 1 }.count == 1 && gestures.contacts.isEmpty)
    gestures.key("MouseMiddle", true); gestures.key("MouseMiddle", false)
    gestures.release()
    gestures.touch(0, 15, 0.6, 0.6)
    let reusedCount = gesturePackets.count
    pump(0.13)
    check("取消短按后旧计时不会释放复用触点", gestures.contacts[15] != nil && gesturePackets.count == reusedCount)
    gestures.release()
    for id in 2000..<2010 { gestures.touch(0, id, 0.2, 0.2) }
    gestures.key("MouseMiddle", true); gestures.key("MouseMiddle", false)
    check("容量不足不留下短按活动", gestures.actions.isEmpty && gestures.contacts.count == 10)
    gestures.release()
    gesturePackets = []
    gestures.key("KeyQ", true)
    pump(0.16)
    let repeatActions = gesturePackets.map { $0[1] }
    gestures.key("KeyQ", false)
    check("连点每个按下前都有独立抬起", repeatActions.enumerated().allSatisfy { $0.element != 0 || $0.offset == 0 || repeatActions[$0.offset - 1] == 1 })
    let pulseStopped = gesturePackets.count
    pump(0.12)
    check("停止连点取消尚未完成的短按", gesturePackets.count == pulseStopped && gestures.contacts.isEmpty)
    var moved = gestureProfile.bindings[0]
    moved.move(to: TouchPoint(x: 0.9, y: 0.9))
    check(
      "移动轨迹限制整体平移并保持形状",
      abs((moved.path![2].x - moved.path![0].x) - 0.6) < 1e-9
        && moved.path!.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
    var malformed = gestureProfile
    malformed.bindings[0].path![1].t = 0
    check("拒绝逆序轨迹时间", (try? malformed.checked()) == nil)
    malformed = gestureProfile
    malformed.bindings[2].scale = .nan
    check("拒绝非法双指倍率", (try? malformed.checked()) == nil)
    let encodedGesture = try profileEncoder.encode(gestureProfile)
    let decodedGesture = try JSONDecoder().decode(Profile.self, from: encodedGesture).checked()
    check("所有手势配置导出导入保真", decodedGesture.controlsEqual(gestureProfile))
    let schemeProfiles = ["com.test.app": custom, "com.test.app::手势方案": gestureProfile]
    check(
      "按应用独立解析命名方案",
      MappingStore.resolve(package: "com.test.app", scheme: "手势方案", profiles: schemeProfiles)
        .controlsEqual(gestureProfile))
    check(
      "方案丢失回退用户默认配置",
      MappingStore.resolve(package: "com.test.app", scheme: "missing", profiles: schemeProfiles)
        .joystick.x == custom.joystick.x)
    var soundActions: [String] = []
    gestures.onAudioAction = { soundActions.append($0) }
    gestures.key("F4", true)
    pump(0.35)
    gestures.key("F4", false)
    check("音量按键长按持续调节", soundActions.filter { $0 == "volumeUp" }.count >= 3)
    let audioStopped = soundActions.count
    pump(0.18)
    check("松开停止音量按键", soundActions.count == audioStopped)
    gestures.enabled = false
    gestures.key("F6", true)
    gestures.key("F6", false)
    check("声音按键独立于触控映射开关", soundActions.last == "mute")
    let volumeState = try MediaVolume(output: "[V] volume is 12 in range [0..15]")
    check(
      "媒体音量解析和比例正确",
      volumeState.value == 12 && volumeState.maximum == 15 && volumeState.percent == 80)
    var oldSound = Profile.standard
    oldSound.shortcuts.removeAll { $0.keycode == 164 }
    check(
      "旧方案补齐静音键",
      oldSound.withDefaultSoundKeys().shortcuts.contains { $0.keycode == 164 && $0.code == "F6" })
    oldSound.bindings.append(Binding(code: "F6", mode: "tap", x: 0.5, y: 0.5, label: "用户键"))
    check("声音默认键不覆盖用户绑定", !oldSound.withDefaultSoundKeys().shortcuts.contains { $0.keycode == 164 })
    let mumuFixture: [String: Any] = [
      "keymaps": [
        [
          "type": "Click", "key": ["text": "N1"],
          "rel_work_position": ["rel_x": 0.6, "rel_y": 0.7],
        ],
        [
          "type": "Fire", "key": ["text": "left_mouse"],
          "rel_work_position": ["rel_x": 0.8, "rel_y": 0.8],
        ],
      ]
    ]
    let mumu = try MuMuMappingImport.decode(
      JSONSerialization.data(withJSONObject: mumuFixture), current: Profile.standard,
      keepJoystick: true, width: 1280, height: 720)
    check(
      "MuMu 单击和鼠标按住转换",
      mumu.profile.bindings[0].code == "Numpad1" && mumu.profile.bindings[1].code == "MouseLeft"
        && mumu.profile.bindings[1].mode == "hold")
    check("导入 MuMu 可保留当前摇杆", mumu.profile.joystick == Profile.standard.joystick)
    var profile = Profile.standard
    profile.bindings[0].code = "KeyW"
    check("拒绝重复映射", (try? profile.checked()) == nil)
    profile = .standard
    profile.bindings[0].x = .nan
    check("拒绝非有限坐标", (try? profile.checked()) == nil)
    var prefs = Preferences()
    prefs.ramMb = 4096
    check("运存下限为六 GB", prefs.checked().ramMb == 6144)
    let readyDNF = try ReadySchemeCatalogue.dnfStandard().checked()
    let swapped = try readyDNF.rebinding(0, to: "KeyQ")
    check("改用已有技能键自动交换", swapped.bindings[0].code == "KeyQ" && swapped.bindings[3].code == "KeyJ" && swapped.bindings[0].x == readyDNF.bindings[0].x)
    check("自由设键不占用移动键", (try? readyDNF.rebinding(0, to: "KeyW")) == nil)
    check("自由设键保留系统全屏键", (try? readyDNF.rebinding(0, to: "F11")) == nil)
    check("DNF 整套方案包含普攻和全部技能槽", readyDNF.bindings.count == 19 && readyDNF.bindings.filter { $0.label.hasPrefix("技能槽") }.count == 12)
    input.profile = readyDNF
    input.key("KeyW", true); input.key("KeyJ", true)
    check("整套方案普攻可与移动同时长按", input.contacts.count == 2 && input.pressed.contains("KeyJ"))
    input.key("KeyJ", false)
    check("松开普攻保留移动触点", input.contacts.count == 1 && input.contacts[100] != nil)
    input.release()
    let readyScheme = ReadyScheme(id: "test.dnf", title: ReadySchemeCatalogue.dnfTitle, origin: "内置", profile: readyDNF)
    var readyMaps = [ReadySchemeCatalogue.dnfPackage: custom]
    var readyPreferences = Preferences()
    check("首次匹配自动注册完整方案", ReadySchemeCatalogue.register(readyScheme, package: ReadySchemeCatalogue.dnfPackage, profiles: &readyMaps, preferences: &readyPreferences))
    check("首次匹配保留原有配置", readyMaps[ReadySchemeCatalogue.dnfPackage]!.controlsEqual(custom) && readyPreferences.profileSelections?[ReadySchemeCatalogue.dnfPackage] == readyScheme.title)
    readyPreferences.profileSelections![ReadySchemeCatalogue.dnfPackage] = ""
    check("自动匹配不覆盖之后的手动方案选择", !ReadySchemeCatalogue.register(readyScheme, package: ReadySchemeCatalogue.dnfPackage, profiles: &readyMaps, preferences: &readyPreferences) && readyPreferences.profileSelections?[ReadySchemeCatalogue.dnfPackage] == "")
    readyPreferences = Preferences(); readyPreferences.profileSelections = [ReadySchemeCatalogue.dnfPackage: "我的方案"]
    _ = ReadySchemeCatalogue.register(readyScheme, package: ReadySchemeCatalogue.dnfPackage, profiles: &readyMaps, preferences: &readyPreferences)
    check("自动匹配保留已选的命名方案", readyPreferences.profileSelections?[ReadySchemeCatalogue.dnfPackage] == "我的方案")
    check("解析 Android 14 前台包名", ReadySchemeCatalogue.foregroundPackage(in: "topResumedActivity=ActivityRecord{29f785a u0 com.tencent.tmgp.dnf/.DNFMainActivity t68}") == ReadySchemeCatalogue.dnfPackage)
    check("解析旧版前台包名", ReadySchemeCatalogue.foregroundPackage(in: "mResumedActivity: ActivityRecord{123 u0 com.androiddeck.demo/.TouchLab t8}") == "com.androiddeck.demo")
    check("拒绝不完整前台记录", ReadySchemeCatalogue.foregroundPackage(in: "mResumedActivity: null") == nil)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("deck-ready-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let catalogue = ReadySchemeCatalogue.discover(package: ReadySchemeCatalogue.dnfPackage, current: custom, width: 1280, height: 720, home: scratch)
    check("DNF 无外部方案时仍有整套预设", catalogue.count == 1 && catalogue[0].profile.controlsEqual(readyDNF))
    check("其他应用不会误用 DNF 模板", ReadySchemeCatalogue.discover(package: "com.example.unknown", current: custom, width: 1280, height: 720, home: scratch).isEmpty)
    check("拒绝目录逃逸包名", ReadySchemeCatalogue.discover(package: "../com.tencent.tmgp.dnf", current: custom, width: 1280, height: 720, home: scratch).isEmpty)
    let muMuFolder = scratch.appendingPathComponent("Library/Application Support/com.netease.mumu.nemux/keymap/keyboard/com.example.ready")
    try FileManager.default.createDirectory(at: muMuFolder, withIntermediateDirectories: true)
    var portable = Profile.initial(for: "com.example.ready")
    portable.bindings = [Binding(code: "Numpad1", mode: "tap", x: 0.8, y: 0.7, label: "技能")]
    try profileEncoder.encode(portable).write(to: muMuFolder.appendingPathComponent("customer-方案.json"))
    let discovered = ReadySchemeCatalogue.discover(package: "com.example.ready", current: portable, width: 1280, height: 720, home: scratch)
    check("按包名发现本机兼容方案并适配主键盘", discovered.count == 1 && discovered[0].profile.bindings.first?.code == "KeyJ")
    let completeMuMu: [String: Any] = ["keymaps": [
      ["type": "Click", "key": ["text": "N1"], "rel_work_position": ["rel_x": 0.8, "rel_y": 0.7]],
      ["type": "Swipehold", "rel_work_position": ["rel_x": 0.17, "rel_y": 0.74], "rel_radius": 0.05,
        "top_key": ["text": "W"], "left_key": ["text": "A"], "bottom_key": ["text": "S"], "right_key": ["text": "D"]]
    ]]
    try JSONSerialization.data(withJSONObject: completeMuMu).write(to: muMuFolder.appendingPathComponent("customer-方案.json"))
    let withMovement = ReadySchemeCatalogue.discover(package: "com.example.ready", current: portable, width: 1280, height: 720, home: scratch)
    check("现成 MuMu 方案同时载入移动摇杆", withMovement.count == 1 && withMovement[0].profile.joystick.enabled && withMovement[0].profile.joystick.x == 0.17)
    var unsupported = completeMuMu; var unsupportedMaps = unsupported["keymaps"] as! [[String: Any]]
    unsupportedMaps.append(["type": "Aim", "key": ["text": "N2"], "rel_work_position": ["rel_x": 0.4, "rel_y": 0.4]])
    unsupported["keymaps"] = unsupportedMaps
    try JSONSerialization.data(withJSONObject: unsupported).write(to: muMuFolder.appendingPathComponent("customer-方案.json"))
    check("包含未支持控件的外部方案不自动应用", ReadySchemeCatalogue.discover(package: "com.example.ready", current: portable, width: 1280, height: 720, home: scratch).isEmpty)
    let anchors = [TouchPoint(x: 0.2, y: 0.2), TouchPoint(x: 0.8, y: 0.2), TouchPoint(x: 0.2, y: 0.8)]
    let identity = try LayoutTransform.fit(source: anchors, target: anchors)
    let unchanged = try identity.apply(readyDNF)
    check("相同布局校准保持方案", unchanged.controlsEqual(readyDNF))
    let shifted = anchors.map { TouchPoint(x: $0.x * 0.8 + 0.05, y: $0.y * 0.9 + 0.03) }
    let transformed = try LayoutTransform.fit(source: anchors, target: shifted).apply(readyDNF)
    let oldPath = readyDNF.bindings.last!.path!, newPath = transformed.bindings.last!.path!
    check("整体校准同步变换滑屏路径", abs(newPath.last!.x - (oldPath.last!.x * 0.8 + 0.05)) < 1e-9 && newPath.last!.t == oldPath.last!.t)
    check("整体校准保留已调好的摇杆", transformed.joystick == readyDNF.joystick)
    check("拒绝共线校准点", (try? LayoutTransform.fit(source: anchors, target: [anchors[0], anchors[1], TouchPoint(x: 0.5, y: 0.2)])) == nil)
    check("拒绝反向镜像校准", (try? LayoutTransform.fit(source: anchors, target: [anchors[0], anchors[2], anchors[1]])) == nil)
    let outside = LayoutTransform(a: 1, b: 0, c: 0, d: 1, tx: 0.4, ty: 0)
    check("拒绝校准后触点超出屏幕", (try? outside.apply(readyDNF)) == nil)
    let remote = try AppInteraction.remoteProfile().checked()
    check("王者荣耀与和平精英自动识别为游戏", AppInteraction.kind(package: "com.tencent.tmgp.sgame", preferences: Preferences()) == .game && AppInteraction.kind(package: "com.tencent.tmgp.pubgmhd", preferences: Preferences()) == .game)
    check("四款内置应用有完整中文名称", ["com.tencent.tmgp.dnf", "com.phoenix.read", "com.tencent.tmgp.sgame", "com.tencent.tmgp.pubgmhd"].allSatisfy { AppInteraction.builtinNames[$0] != nil })
    input.release(); input.profile = remote; input.wheelUsesTouch = true
    for (width, height) in [(720, 1280), (1280, 720), (2160, 3840), (3840, 2160)] {
      input.resize(width: width, height: height); packets = []
      input.wheel(0.5, 0.5, deltaX: 0, deltaY: -1); pump(0.3)
      let wheelPackets = touchPackets()
      check("\(width)x\(height) 滚轮向下触发完整触摸翻页", wheelPackets.first?[1] == 0 && wheelPackets.last?[1] == 1 && wheelPackets.last!.integer(14, UInt32.self) < wheelPackets.first!.integer(14, UInt32.self) && input.contacts.isEmpty && !packets.contains { $0.first == 3 })
    }
    packets = []
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: 1); pump(0.3)
    check("滚轮向上使用相反触摸方向", touchPackets().last!.integer(14, UInt32.self) > touchPackets().first!.integer(14, UInt32.self))
    packets = []
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: -1)
    let firstWheelToken = input.actions[InputEngine.wheelActionIndex]!.token
    for _ in 0..<50 { input.wheel(0.5, 0.5, deltaX: 0, deltaY: -1) }
    check("连续滚轮不重启或打断当前触摸", touchPackets().filter { $0[1] == 0 }.count == 1 && input.actions[InputEngine.wheelActionIndex]?.token == firstWheelToken)
    pump(0.6)
    check("滚轮突发最多合并为两次完整滑动", touchPackets().filter { $0[1] == 0 }.count == 2 && input.contacts.isEmpty && input.wheelPending == nil)
    packets = []
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: -2, precise: true)
    check("触控板细小抖动不会直接翻页", packets.isEmpty)
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: -18, precise: true); pump(0.3)
    check("触控板累计距离触发一次触摸翻页", touchPackets().filter { $0[1] == 0 }.count == 1 && input.contacts.isEmpty)
    packets = []
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: -50, precise: true, momentum: true)
    check("应用忽略惯性尾部避免连续跳页", packets.isEmpty)
    var customWheel = remote
    customWheel.bindings.append(Binding(code: "WheelDown", mode: "tap", x: 0.12, y: 0.34, label: "自定滚轮"))
    input.profile = try customWheel.checked(); packets = []
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: -1); pump(0.12)
    check("个人滚轮映射优先于应用翻页", touchPackets().count == 2 && touchPackets()[0].integer(10, UInt32.self) == UInt32((0.12 * Double(input.width)).rounded()))
    input.enabled = false; packets = []
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: -1); pump(0.3)
    check("关闭键盘映射后滚轮仍能直接触摸翻页", touchPackets().first?[1] == 0 && touchPackets().last?[1] == 1)
    input.enabled = true; input.profile = remote; packets = []
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: -1); input.wheel(0.5, 0.5, deltaX: 0, deltaY: -1)
    input.suspended = true; let cancelledWheelCount = packets.count; pump(0.35)
    check("应用或画面切换会取消滚轮队列并释放手指", input.contacts.isEmpty && input.wheelPending == nil && packets.count == cancelledWheelCount)
    input.suspended = false; input.wheelUsesTouch = false; input.profile = .standard; packets = []
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: -1)
    check("游戏继续使用原生滚轮事件", packets.count == 1 && packets.first?.first == 3)
    packets = []
    input.wheel(0.5, 0.5, deltaX: 0, deltaY: .nan)
    check("无效滚轮数据不注入Android", packets.isEmpty)
    input.wheelUsesTouch = false
    check("应用遥控包含翻页点击及系统声音键", !remote.joystick.enabled && remote.bindings.count == 6 && remote.shortcuts.contains { $0.keycode == 24 })
    check("应用遥控默认隐藏触点", remote.bindings.allSatisfy { $0.visible == false })
    check("向上键执行上一页的向下滑动", remote.bindings[0].path!.first!.y < remote.bindings[0].path!.last!.y)
    check("向下键执行下一页的向上滑动", remote.bindings[1].path!.first!.y > remote.bindings[1].path!.last!.y)
    input.profile = remote; packets = []
    input.key("ArrowDown", true); input.key("ArrowDown", false); pump(0.35)
    let pagePackets = touchPackets()
    check("真实遥控协议完成滑动并抬起", pagePackets.first?[1] == 0 && pagePackets.last?[1] == 1 && input.contacts.isEmpty && pagePackets.last!.integer(14, UInt32.self) < pagePackets.first!.integer(14, UInt32.self))
    input.key("Space", true); input.suspended = true
    check("切换画面先抬起触点", touchPackets().last?[1] == 1 && input.contacts.isEmpty)
    let beforeSuspension = packets.count
    input.key("ArrowUp", true); input.touch(0, 0, 0.5, 0.5); input.clickKey(4)
    check("画面切换期间不注入旧坐标", packets.count == beforeSuspension)
    input.suspended = false; input.key("Space", true); pump(0.11); input.release()
    check("恢复画面后点击仍可使用", packets.count > beforeSuspension && input.contacts.isEmpty)
    var presentationPrefs = Preferences()
    check("自动识别 DNF 为游戏红果为应用", AppInteraction.kind(package: "com.tencent.tmgp.dnf", preferences: presentationPrefs) == .game && AppInteraction.kind(package: "com.phoenix.read", preferences: presentationPrefs) == .app)
    check("未知包名默认应用且不会按 tmgp 前缀猜测", AppInteraction.kind(package: "com.tencent.tmgp.unknown", preferences: presentationPrefs) == .app)
    check("Android 游戏分类和 MuMu 方向方案识别", AppInteraction.kind(package: "com.test.game", preferences: presentationPrefs, androidIsGame: true) == .game && AppInteraction.kind(package: "com.test.game", preferences: presentationPrefs, gameScheme: true) == .game)
    check("Android 分类解析不匹配子串", AppInteraction.androidGameMetadata("  category=0\n") && !AppInteraction.androidGameMetadata("  category=01\n") && !AppInteraction.androidGameMetadata("activity text IS_GAME"))
    presentationPrefs.contentKinds = ["com.tencent.tmgp.dnf": "app"]
    check("用户可以覆盖自动分类", AppInteraction.kind(package: "com.tencent.tmgp.dnf", preferences: presentationPrefs) == .app)
    var remoteProfiles: [String: Profile] = [:]
    AppInteraction.registerRemote(package: "com.test.app", profiles: &remoteProfiles, preferences: &presentationPrefs)
    check("新应用直接选用遥控", presentationPrefs.profileSelections?["com.test.app"] == AppInteraction.remoteTitle)
    remoteProfiles["com.existing.app"] = Profile.initial(for: "com.existing.app")
    AppInteraction.registerRemote(package: "com.existing.app", profiles: &remoteProfiles, preferences: &presentationPrefs)
    check("不覆盖已有空白自定义方案", presentationPrefs.profileSelections?["com.existing.app"] == nil && remoteProfiles["com.existing.app"]!.bindings.isEmpty)
    presentationPrefs.profileSelections?["com.test.app"] = "我的方案"
    AppInteraction.registerRemote(package: "com.test.app", profiles: &remoteProfiles, preferences: &presentationPrefs)
    check("再次进入应用保留个人方案", presentationPrefs.profileSelections?["com.test.app"] == "我的方案")
    check("默认方向按类型区分", DeckDisplayOptions().spec(kind: .app).rotation == 0 && DeckDisplayOptions().spec(kind: .game).rotation == 1)
    for size in DeckResolution.allCases {
      var options = DeckDisplayOptions(); options.resolution = size.rawValue
      let spec = options.spec(kind: .game)
      check("\(size.rawValue) 使用实际分辨率及相同逻辑密度", spec.width * 16 == spec.height * 9 && spec.width / spec.density == 3 && spec.width * spec.height * 4 < rawFrameByteLimit)
    }
    var options = DeckDisplayOptions(); options.orientation = "followApp"
    check("应用可跟随自身旋转", options.spec(kind: .app).rotation == nil)
    presentationPrefs.displayOptions = ["com.test.app": options, "com.test.game": DeckDisplayOptions(resolution: "fullHD", orientation: "landscape")]
    let decodedPresentation = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(presentationPrefs))
    check("应用和游戏显示配置独立持久化", decodedPresentation.displayOptions?["com.test.app"]?.direction == .followApp && decodedPresentation.displayOptions?["com.test.game"]?.size == .fullHD)
    let fm = FileManager.default, fixture = fm.temporaryDirectory.appendingPathComponent("deck-distribution-tests-" + UUID().uuidString)
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }
    check("EGL 修正拒绝未知驱动字节", (try? EGLCompatibility.correctedDriver(Data(repeating: 0, count: 140000))) == nil)
    check("EGL 修正拒绝截断驱动", (try? EGLCompatibility.correctedDriver(EGLCompatibility.before)) == nil)
    check("EGL 校验值解析拒绝错误输出", (try? EGLCompatibility.checksum(in: "sha256sum: permission denied")) == nil)
    check("EGL 校验值解析保留完整 SHA256", (try? EGLCompatibility.checksum(in: EGLCompatibility.originalSHA256 + "  /vendor/driver.so")) == EGLCompatibility.originalSHA256)
    let deviceProps = "[ro.product.model]: [Android SDK]\n[ro.build.version.release]: [14]\n[ro.build.version.sdk]: [34]\n[ro.product.cpu.abi]: [arm64-v8a]"
    let deviceMemory = "MemTotal: 6000000 kB\nMemFree: 100000 kB\nMemAvailable: 3000000 kB\n"
    let deviceDisk = "Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/block/dm-37 103000000 30000000 73000000 30% /vendor/lib64/egl/libEGL_emulation.so"
    let deviceInfo = try AndroidDeviceInformation.parse(properties: deviceProps, memory: deviceMemory, disk: deviceDisk, cpus: "0-3")
    check("设备信息读取数据盘绑定挂载显示的真实容量", deviceInfo.diskTotal == 103000000 * 1024 && deviceInfo.diskAvailable == 73000000 * 1024)
    check("可用内存采用 MemAvailable 包含可回收缓存", deviceInfo.memoryAvailable == 3000000 * 1024 && deviceInfo.memoryUsed == 3000000 * 1024)
    check("设备系统版本架构和CPU核数来自安卓", deviceInfo.androidVersion == "14" && deviceInfo.apiLevel == 34 && deviceInfo.architecture == "arm64-v8a" && deviceInfo.cpuCount == 4)
    check("设备信息拒绝内存缺失数据", (try? AndroidDeviceInformation.parse(properties: deviceProps, memory: "", disk: deviceDisk, cpus: "0-3")) == nil)
    check("设备信息拒绝容量乘法溢出", (try? AndroidDeviceInformation.parse(properties: deviceProps, memory: deviceMemory, disk: "/dev/block/data 9223372036854775807 0 0 0% /data", cpus: "0-3")) == nil)
    let externalEGL = AndroidRuntime(root: fixture.appendingPathComponent("external-egl"))
    try externalEGL.prepareEGLCompatibility(serial: "external-phone")
    check("外接设备不执行 EGL 修正或创建缓存", !fm.fileExists(atPath: externalEGL.root.path))
    if let path = ProcessInfo.processInfo.environment["ANDROIDDECK_EGL_TEST_DRIVER"] {
      let original = try Data(contentsOf: URL(fileURLWithPath: path))
      let corrected = try EGLCompatibility.correctedDriver(original)
      check("真实 EGL 驱动修正结果匹配独立验证的 SHA256", EGLCompatibility.digest(corrected) == EGLCompatibility.correctedSHA256)
      check("EGL 修正只改变已验证的指令范围", original.count == corrected.count && original.prefix(EGLCompatibility.offset) == corrected.prefix(EGLCompatibility.offset) && original.suffix(from: EGLCompatibility.offset + 8) == corrected.suffix(from: EGLCompatibility.offset + 8))
      let repeated = try EGLCompatibility.correctedDriver(corrected)
      check("重复 EGL 修正保持字节不变", repeated == corrected)
      var damaged = original; damaged[0] ^= 1
      check("EGL 修正拒绝被改写的原始驱动", (try? EGLCompatibility.correctedDriver(damaged)) == nil)
    }
    let seed = fixture.appendingPathComponent("seed"), fresh = fixture.appendingPathComponent("fresh")
    for path in [".runtime/sdk/emulator", ".runtime/sdk/platform-tools", "assets", "Apps"] {
      try fm.createDirectory(at: seed.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    for path in [".runtime/sdk/emulator/emulator", ".runtime/sdk/platform-tools/adb"] {
      let file = seed.appendingPathComponent(path); try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    try Data("scrcpy fixture".utf8).write(to: seed.appendingPathComponent("assets/scrcpy-server"))
    let apk = seed.appendingPathComponent("Apps/test.apk"); try Data("abc".utf8).write(to: apk)
    let hash = try RuntimeDistribution.digest(apk)
    check("APK 流式 SHA256 校验正确", hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    var manifest = RuntimeSeedManifest(version: 1, apps: [BuiltinApplication(package: "com.test.builtin", name: "test", file: "Apps/test.apk", versionCode: 1, sha256: hash)])
    let manifestFile = seed.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: manifestFile)
    let distribution = RuntimeDistribution(seed: seed)
    try distribution.prepare(at: fresh)
    check("首次离线准备 SDK 和空白用户设置", fm.isExecutableFile(atPath: fresh.appendingPathComponent(".runtime/sdk/emulator/emulator").path) && fm.fileExists(atPath: fresh.appendingPathComponent("data/settings.json").path) && !fm.fileExists(atPath: fresh.appendingPathComponent("Apps").path))
    let userFile = fresh.appendingPathComponent("data/user-marker"); try Data("keep".utf8).write(to: userFile)
    try distribution.prepare(at: fresh)
    let retained = try Data(contentsOf: userFile)
    check("二次启动保留已有用户数据", retained == Data("keep".utf8))
    manifest = RuntimeSeedManifest(version: 1, apps: [BuiltinApplication(package: "com.test.builtin", name: "test", file: "Apps/../../outside.apk", versionCode: 1, sha256: hash)])
    try JSONEncoder().encode(manifest).write(to: manifestFile)
    check("拒绝内置 APK 路径逃逸", (try? distribution.manifest()) == nil)
    manifest = RuntimeSeedManifest(version: 1, apps: [])
    try JSONEncoder().encode(manifest).write(to: manifestFile)
    try fm.createSymbolicLink(at: seed.appendingPathComponent(".runtime/escape"), withDestinationURL: fixture)
    let rejected = fixture.appendingPathComponent("rejected")
    check("拒绝 SDK 外部链接且不留下半成品", (try? distribution.prepare(at: rejected)) == nil && !fm.fileExists(atPath: rejected.path))
    let external = AndroidRuntime(root: fixture)
    try external.applyDisplay(DeckDisplayOptions().spec(kind: .game), serial: "real-phone")
    check("外接手机不自动改写分辨率设置", external.appliedDisplay == nil)
    let quick = QuickBootStore(root: fixture.appendingPathComponent("quick"))
    let snapshot = quick.avd.appendingPathComponent("snapshots/\(QuickBootStore.name)")
    try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
    let userDisk = quick.avd.appendingPathComponent("userdata.img")
    let latestUserData = Data("latest user data".utf8)
    try latestUserData.write(to: userDisk)
    try Data("hw.lcd.width=2160\nhw.lcd.height=3840\n".utf8).write(to: quick.avd.appendingPathComponent("config.ini"))
    check("旧版本正常打开保留真实4K分辨率", AndroidRuntime(root: quick.root).resolution == .ultraHD)
    try Data("snapshot".utf8).write(to: snapshot.appendingPathComponent("snapshot.pb"))
    try Data("ram".utf8).write(to: snapshot.appendingPathComponent("ram.bin"))
    try quick.checkpoint(key: "profile-a", marker: "generation-a")
    check("快速启动只接受完整且匹配的配置", quick.eligible(key: "profile-a") != nil && quick.eligible(key: "profile-b") == nil)
    try Data("configuration".utf8).write(to: quick.avd.appendingPathComponent("config.ini"))
    check("非磁盘临时配置不使有效快照失效", quick.eligible(key: "profile-a") != nil)
    let attributes = try fm.attributesOfItem(atPath: userDisk.path)
    try Data("stale user data!".utf8).write(to: userDisk)
    try fm.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: userDisk.path)
    check("磁盘内容变化即使时间相同也拒绝恢复", quick.eligible(key: "profile-a") == nil)
    try latestUserData.write(to: userDisk)
    try quick.checkpoint(key: "profile-a", marker: "generation-a")
    quick.invalidate()
    check("开始恢复前撤销旧快照资格", quick.eligible(key: "profile-a") == nil)
    let protected = try quick.cloneBeforeRestore()
    try Data("failed restore".utf8).write(to: userDisk)
    let recovered = try quick.recoverInterruptedRestore(), protectedData = try Data(contentsOf: userDisk)
    check("进程中断后恢复磁盘保护副本", recovered && protectedData == latestUserData && !fm.fileExists(atPath: protected.path))
    let beforeMove = try quick.cloneBeforeRestore()
    try fm.moveItem(at: quick.avd, to: beforeMove.appendingPathComponent("failed-restore.avd"))
    let recoveredMissingDirectory = try quick.recoverInterruptedRestore(), afterMissing = try Data(contentsOf: userDisk)
    check("目录切换中断仍能恢复完整磁盘", recoveredMissingDirectory && afterMissing == latestUserData)
    let afterMove = try quick.cloneBeforeRestore()
    try fm.moveItem(at: quick.avd, to: afterMove.appendingPathComponent("failed-restore.avd"))
    try fm.moveItem(at: afterMove.appendingPathComponent("AndroidDeck.avd"), to: quick.avd)
    let recoveredFinishedMove = try quick.recoverInterruptedRestore()
    check("目录已恢复时可完成中断的恢复记录", recoveredFinishedMove && !fm.fileExists(atPath: quick.recoveryFile.path))
    let corrupted = try quick.cloneBeforeRestore()
    try Data("corrupt backup".utf8).write(to: corrupted.appendingPathComponent("AndroidDeck.avd/userdata.img"))
    let rejectedRecovery = try? quick.recoverInterruptedRestore(), intactData = try Data(contentsOf: userDisk)
    check("保护副本校验失败时保留原设备和现场", rejectedRecovery == nil && intactData == latestUserData && fm.fileExists(atPath: corrupted.path))
    try fm.removeItem(at: corrupted); try fm.removeItem(at: quick.recoveryFile)
    try JSONEncoder().encode(QuickBootRecovery(folder: "../../outside", files: [:])).write(to: quick.recoveryFile)
    check("恢复记录拒绝目录逃逸", (try? quick.recoverInterruptedRestore()) == nil)
    try fm.removeItem(at: quick.recoveryFile)
    manifest = RuntimeSeedManifest(version: 1, apps: [BuiltinApplication(package: "com.test.builtin", name: "test", file: "Apps/test.apk", versionCode: 1, sha256: hash)])
    try JSONEncoder().encode(manifest).write(to: manifestFile)
    let fakeADB = fresh.appendingPathComponent(".runtime/sdk/platform-tools/adb")
    let script = #"""
      #!/bin/sh
      case "$3:$4:$5" in
        shell:pm:list) echo package:com.existing.app; if [ -f "$0.installed" ]; then echo package:com.test.builtin; fi ;;
        shell:pm:path) if [ -f "$0.installed" ]; then echo package:/data/app/fake.apk; else exit 1; fi ;;
        install:-r:*) touch "$0.installed"; echo install >> "$0.calls" ;;
        *) exit 1 ;;
      esac
      """#
    try Data((script + "\n").utf8).write(to: fakeADB)
    let owned = AndroidRuntime(root: fresh), child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]; try child.run()
    defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
    owned.child = child; owned.ownedSerial = "test-owned"
    try distribution.installMissing(in: owned, serial: "test-owned")
    let callsFile = URL(fileURLWithPath: fakeADB.path + ".calls")
    let firstCalls = try String(contentsOf: callsFile, encoding: .utf8).split(separator: "\n").count
    check("缺失包的 pm path 退出码不再阻断首次安装", firstCalls == 1)
    try distribution.installMissing(in: owned, serial: "test-owned")
    let secondCalls = try String(contentsOf: callsFile, encoding: .utf8).split(separator: "\n").count
    check("内置应用已存在时不重新安装", secondCalls == 1)
    var image = Data([10, 6, 8, 1, 24, 2, 32, 1, 34, 8])
    image.append(Data([1, 2, 3, 255, 4, 5, 6, 255]))
    let raw = try RawImage(image)
    check("RGBA 协议与完整像素", raw.width == 2 && raw.height == 1 && raw.pixels.count == 8)
    var wrongPixel: CVPixelBuffer?
    _ = CVPixelBufferCreate(nil, 1, 1, kCVPixelFormatType_32BGRA, nil, &wrongPixel)
    check("拒绝像素缓冲区尺寸不匹配", (try? copyRawPixels(raw, into: wrongPixel!)) == nil)
    var pixel: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    check(
      "Metal BGRA 像素内存可分配",
      CVPixelBufferCreate(nil, 2, 1, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixel)
        == kCVReturnSuccess)
    try copyRawPixels(raw, into: pixel!)
    CVPixelBufferLockBaseAddress(pixel!, .readOnly)
    let channels = CVPixelBufferGetBaseAddress(pixel!)!.assumingMemoryBound(to: UInt8.self)
    check(
      "RGBA 转 BGRA 通道正确",
      channels[0] == 3 && channels[1] == 2 && channels[2] == 1 && channels[3] == 255)
    CVPixelBufferUnlockBaseAddress(pixel!, .readOnly)
    check("单次转换不改写原始 RGBA 数据", raw.pixels == Data([1, 2, 3, 255, 4, 5, 6, 255]))
    var scopedMessage = Data([10, 6, 8, 1, 24, 4, 32, 4, 34, 64])
    scopedMessage.append(Data(0..<64))
    var sharedPixelAddress = false, scopedValid = false
    try scopedMessage.withUnsafeBytes { bytes in
      try RawImage.withBorrowedImage(bytes) { image in
        scopedValid = image.width == 4 && image.height == 4 && image.pixels == Data(0..<64)
        image.pixels.withUnsafeBytes { pixels in sharedPixelAddress = pixels.baseAddress == bytes.baseAddress!.advanced(by: 10) }
      }
    }
    check("限定作用域内读取原始像素不创建大型副本", sharedPixelAddress && scopedValid)
    let ownedImage = try RawImage(scopedMessage)
    scopedMessage[10] = 99
    check("普通解码继续保留独立且不可变的像素", ownedImage.pixels.first == 0)
    let mappedMetadata = Data([10, 6, 8, 1, 24, 2, 32, 1])
    var mappedPixels = Data([1, 2, 3, 255, 4, 5, 6, 255])
    var mappedAddressMatches = false, mappedSequenceMatches = false
    try mappedPixels.withUnsafeBytes { bytes in
      try RawImage.withMappedImage(mappedMetadata, pixels: bytes, sequence: 42) { image in
        mappedSequenceMatches = image.sequence == 42 && image.width == 2 && image.height == 1
        try copyRawPixels(image, into: pixel!)
      }
      check("共享画面拒绝像素范围不足", (try? RawImage.withMappedImage(mappedMetadata,
        pixels: UnsafeRawBufferPointer(rebasing: bytes[0..<4]), sequence: 0) { _ in }) == nil)
      check("共享画面拒绝同时携带普通像素的响应", (try? RawImage.withMappedImage(image, pixels: bytes, sequence: 0) { _ in }) == nil)
    }
    try Data(0..<64).withUnsafeBytes { bytes in
      try RawImage.withMappedImage(Data([10, 6, 8, 1, 24, 4, 32, 4]), pixels: bytes, sequence: 43) { image in
        image.pixels.withUnsafeBytes { mappedAddressMatches = $0.baseAddress == bytes.baseAddress }
      }
    }
    check("共享像素仅在受控作用域读取，不复制整个帧", mappedAddressMatches && mappedSequenceMatches)
    mappedPixels[2] = 99
    CVPixelBufferLockBaseAddress(pixel!, .readOnly)
    check("下一次共享写入不改变已拥有的显示帧", CVPixelBufferGetBaseAddress(pixel!)!.assumingMemoryBound(to: UInt8.self)[0] == 3)
    CVPixelBufferUnlockBaseAddress(pixel!, .readOnly)
    var renders = 0, metadataChanges = 0, projectedFrames = 0
    let presenter = FramePresenter(render: { _ in renders += 1 }, changed: { _, _ in metadataChanges += 1 })
    for _ in 0..<1000 { presenter.submit(pixel!) }
    check("相同尺寸帧不向主线程重复排队元数据", renders == 1000 && metadataChanges == 1)
    presenter.setProjection { _ in projectedFrames += 1 }; presenter.submit(pixel!)
    check("投影复用最新像素而不增加元数据任务", projectedFrames == 1 && metadataChanges == 1)
    presenter.close(); presenter.submit(pixel!)
    check("关闭流后旧帧不能覆盖新画面", renders == 1001 && projectedFrames == 1)
    check("拒绝截断像素", (try? RawImage(Data(image.dropLast()))) == nil)
    let inactive = try RawImage(Data([10, 0]))
    check("屏幕未唤醒的初始空帧不会误判为损坏", inactive.inactive)
    func varintBytes(_ value: Int) -> Data {
      var n = value, result = Data()
      repeat { result.append(UInt8(n & 127) | (n > 127 ? 128 : 0)); n >>= 7 } while n > 0
      return result
    }
    var uhdFormat = Data([8, 1, 24]); uhdFormat.append(varintBytes(3840)); uhdFormat.append(32); uhdFormat.append(varintBytes(2160))
    var uhdMessage = Data([10]); uhdMessage.append(varintBytes(uhdFormat.count)); uhdMessage.append(uhdFormat); uhdMessage.append(34)
    let uhdBytes = 3840 * 2160 * 4
    uhdMessage.append(varintBytes(uhdBytes)); uhdMessage.append(Data(repeating: 0, count: uhdBytes))
    let uhdImage = try RawImage(uhdMessage)
    check("完整 4K 帧可解析而不触发旧缓冲上限", uhdImage.width == 3840 && uhdImage.height == 2160 && uhdImage.pixels.count == uhdBytes)
    check("拒绝整数溢出", (try? ProtoFields(Data([8] + Array(repeating: 255, count: 10)))) == nil)
    check("SDK 明确快照错误会立即触发保护回退", snapshotRestoreFailed(in: "Failed to load snapshot 'AndroidDeckQuick'"))
    check("损坏虚拟机状态不会继续等待安卓启动", snapshotRestoreFailed(in: "Missing section footer for goldfish_address_space"))
    check("普通冷启动日志不被误认为恢复失败", !snapshotRestoreFailed(in: "Loading snapshot 'AndroidDeckQuick'... Boot completed in 1800 ms"))
    let result: [String: Any] = ["passed": passed, "count": passed.count]
    print(
      String(
        decoding: try JSONSerialization.data(
          withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
}
