// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import CryptoKit

struct DeckError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
struct Joystick: Codable, Equatable {
  var enabled: Bool
  var x: Double
  var y: Double
  var radius: Double
  var keys: [String]
  var visible: Bool?
}
struct Binding: Codable, Equatable {
  var code: String
  var mode: String
  var x: Double
  var y: Double
  var label: String
  var visible: Bool?
  var durationMs: Int?
  var intervalMs: Int?
  var path: [GesturePoint]?
  var scale: Double?
  var rotation: Double?
  var radius: Double?
  var audioAction: String?
}
struct Shortcut: Codable, Equatable {
  var code: String
  var keycode: UInt32
}
struct Profile: Codable {
  var version: Int
  var joystick: Joystick
  var bindings: [Binding]
  var shortcuts: [Shortcut]
  var joystickPresetVersion: Int?
  var soundPresetVersion: Int?
  static let standard = Profile(
    version: 1,
    joystick: Joystick(
      enabled: true, x: 0.22, y: 0.73, radius: 0.09, keys: ["KeyW", "KeyA", "KeyS", "KeyD"],
      visible: nil),
    bindings: [
      Binding(code: "Space", mode: "hold", x: 0.8, y: 0.73, label: "动作", visible: nil),
      Binding(code: "KeyF", mode: "tap", x: 0.72, y: 0.5, label: "交互", visible: nil),
    ],
    shortcuts: [
      Shortcut(code: "Escape", keycode: 4), Shortcut(code: "F2", keycode: 3),
      Shortcut(code: "F3", keycode: 187), Shortcut(code: "F4", keycode: 24),
      Shortcut(code: "F5", keycode: 25), Shortcut(code: "F6", keycode: 164),
    ])
  static func initial(for package: String) -> Profile {
    var profile = standard
    if package == "com.tencent.tmgp.dnf" {
      profile.joystick.x = 0.15625
      profile.joystickPresetVersion = 1
    } else if package != "com.androiddeck.demo" {
      profile.joystick.enabled = false
      profile.bindings = []
    }
    return profile
  }
  func migrateJoystick(for package: String) -> Profile {
    guard package == "com.tencent.tmgp.dnf", joystickPresetVersion == nil else { return self }
    var result = self
    // Only the generic, previously shipped center is eligible; user-calibrated positions stay intact.
    if abs(joystick.x - Profile.standard.joystick.x) < 1e-9,
      abs(joystick.y - Profile.standard.joystick.y) < 1e-9
    {
      result.joystick.x = Profile.initial(for: package).joystick.x
    }
    result.joystickPresetVersion = 1
    return result
  }
  func withDefaultSoundKeys() -> Profile {
    guard soundPresetVersion == nil else { return self }
    var result = self
    var used = Set(
      bindings.map(\.code) + shortcuts.map(\.code) + (joystick.enabled ? joystick.keys : []))
    for (code, keycode) in [("F4", UInt32(24)), ("F5", UInt32(25)), ("F6", UInt32(164))] {
      if !result.shortcuts.contains(where: { $0.keycode == keycode }), !used.contains(code) {
        result.shortcuts.append(Shortcut(code: code, keycode: keycode))
        used.insert(code)
      }
    }
    result.soundPresetVersion = 1
    return result
  }
  func checked() throws -> Profile {
    guard version == 1, bindings.count <= 64, shortcuts.count <= 20,
      joystick.keys.count == 4, Set(joystick.keys).count == 4,
      joystick.x.isFinite, joystick.y.isFinite, (0...1).contains(joystick.x),
      (0...1).contains(joystick.y),
      joystick.radius.isFinite, (0.01...0.3).contains(joystick.radius)
    else { throw DeckError(message: "映射文件格式错误") }
    var used = Set<String>()
    let keys =
      (joystick.enabled ? joystick.keys : []) + bindings.map(\.code) + shortcuts.map(\.code)
    for key in keys {
      guard mappingCodes.contains(key), key != "F11", used.insert(key).inserted else {
        throw DeckError(message: "按键无效、重复或占用全屏键：\(key)")
      }
    }
    for b in bindings {
      guard mappingModes.map(\.0).contains(b.mode), b.x.isFinite, b.y.isFinite,
        (0...1).contains(b.x),
        (0...1).contains(b.y), b.label.count <= 32
      else { throw DeckError(message: "触点配置错误") }
      try b.validateGesture()
    }
    for s in shortcuts {
      guard [3, 4, 187, 24, 25, 164, 26, 66, 67, 82].contains(s.keycode) else {
        throw DeckError(message: "系统快捷键不支持")
      }
    }
    return self
  }
  func rebinding(_ index: Int, to code: String) throws -> Profile {
    guard bindings.indices.contains(index), mappingCodes.contains(code), code != "F11" else { throw DeckError(message: "该按键不能用于触点") }
    guard !(joystick.enabled && joystick.keys.contains(code)), !shortcuts.contains(where: { $0.code == code }) else { throw DeckError(message: "\(keyLabel(code)) 已用于方向或系统操作，请选择其它键") }
    var result = self
    let old = result.bindings[index].code
    if let other = result.bindings.firstIndex(where: { $0.code == code }), other != index { result.bindings[other].code = old }
    result.bindings[index].code = code
    return try result.checked()
  }
}
struct Preferences: Codable {
  var version = 1
  var ramMb = 6144
  var showMappings = true
  var streamSize: Int?
  var streamFps: Int?
  var streamBitrate: Int?
  var profileSelections: [String: String]?
  var mediaVolumePercent: Int?
  var lastAudibleVolumePercent: Int?
  var followForegroundApp: Bool?
  var readyDefaultsApplied: [String: Bool]?
  var contentKinds: [String: String]?
  var displayOptions: [String: DeckDisplayOptions]?
  var remoteDefaultsApplied: [String: Bool]?
  var modeSchemeSelections: [String: String]?
  var lastOpenedPackage: String?
  var size: Int { streamSize ?? 960 }
  var fps: Int { streamFps ?? 45 }
  var bitrate: Int { streamBitrate ?? 4_000_000 }
  func checked() -> Preferences {
    var result = self
    if ![6144, 8192].contains(ramMb) { result.ramMb = 6144 }
    if ![960, 1280].contains(size) { result.streamSize = 960 }
    if !(15...60).contains(fps) { result.streamFps = 45 }
    if !(1_000_000...12_000_000).contains(bitrate) { result.streamBitrate = 4_000_000 }
    if !(0...100).contains(mediaVolumePercent ?? 80) { result.mediaVolumePercent = 80 }
    return result
  }
}
struct AndroidApp: Codable {
  let package: String
  let name: String
  var isGame = false
}
let physicalCodes: [UInt16: String] = [
  0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG", 6: "KeyZ", 7: "KeyX", 8: "KeyC",
  9: "KeyV", 11: "KeyB", 12: "KeyQ", 13: "KeyW", 14: "KeyE", 15: "KeyR", 16: "KeyY", 17: "KeyT",
  18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 22: "Digit6", 23: "Digit5", 25: "Digit9",
  26: "Digit7", 28: "Digit8", 29: "Digit0", 31: "KeyO", 32: "KeyU", 34: "KeyI", 35: "KeyP",
  37: "KeyL", 38: "KeyJ", 40: "KeyK", 45: "KeyN", 46: "KeyM", 49: "Space", 53: "Escape", 48: "Tab",
  36: "Enter", 51: "Backspace", 56: "ShiftLeft", 60: "ShiftRight", 59: "ControlLeft",
  62: "ControlRight", 58: "AltLeft", 61: "AltRight", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
  96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
  123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
  116: "PageUp", 121: "PageDown",
  24: "Equal", 27: "Minus", 33: "BracketLeft", 30: "BracketRight", 41: "Semicolon", 39: "Quote",
  43: "Comma", 47: "Period", 44: "Slash", 42: "Backslash", 50: "Backquote",
  65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd", 75: "NumpadDivide", 76: "NumpadEnter",
  78: "NumpadSubtract", 81: "NumpadEqual", 82: "Numpad0", 83: "Numpad1", 84: "Numpad2",
  85: "Numpad3", 86: "Numpad4", 87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 91: "Numpad8",
  92: "Numpad9",
]
func keyLabel(_ value: String) -> String {
  [
    "Space": "SPACE", "Escape": "Esc", "ArrowUp": "↑", "ArrowDown": "↓", "ArrowLeft": "←",
    "ArrowRight": "→",
    "PageUp": "PgUp", "PageDown": "PgDn",
    "MouseLeft": "左键", "MouseRight": "右键", "MouseMiddle": "中键", "WheelUp": "滚轮↑",
    "WheelDown": "滚轮↓",
    "Minus": "-", "Equal": "=", "BracketLeft": "[", "BracketRight": "]", "Semicolon": ";",
    "Quote": "'",
    "Comma": ",", "Period": ".", "Slash": "/", "Backslash": "\\", "Backquote": "`",
  ][value]
    ?? value.replacingOccurrences(of: "Key", with: "").replacingOccurrences(of: "Digit", with: "")
    .replacingOccurrences(of: "Numpad", with: "Num ")
}
extension Data {
  mutating func be<T: FixedWidthInteger>(_ value: T) {
    var n = value.bigEndian
    Swift.withUnsafeBytes(of: &n) { append(contentsOf: $0) }
  }
  func integer<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
    self[offset..<offset + MemoryLayout<T>.size].reduce(0) { ($0 << 8) | T($1) }
  }
}

final class InputEngine {
  var profile = Profile.standard { didSet { if !profile.controlsEqual(oldValue) { release() } } }
  var enabled = true { didSet { if !enabled { release() } } }
  var suspended = false { willSet { if newValue && !suspended { release() } } }
  var width = 720
  var height = 1280
  var writer: ((Data) -> Void)? { willSet { release() } }
  var wheelUsesTouch = false { didSet { if wheelUsesTouch != oldValue { resetWheel() } } }
  var wheelPending: Binding?
  var wheelAccumulated = 0.0
  var wheelLastEvent = 0.0
  var onContactChange: (() -> Void)?
  var onAudioAction: ((String) -> Void)?
  private(set) var pressed = Set<String>()
  private(set) var contacts: [Int: (Double, Double)] = [:]
  private var heldKeys = Set<UInt32>()
  private var joystickTimer: Timer?
  private var joystickGeneration = 0
  private var joystickTarget: (Double, Double)?
  var actions: [Int: TouchActivity] = [:]
  var actionTimer: Timer?
  var actionGeneration = 0
  var actionSequence = 0
  private func stopJoystickTimer() {
    joystickGeneration += 1
    joystickTimer?.invalidate()
    joystickTimer = nil
    joystickTarget = nil
  }
  private func startJoystickTimer() {
    guard joystickTimer == nil else { return }
    let generation = joystickGeneration
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      guard let self = self, self.joystickGeneration == generation, self.enabled,
        self.contacts[100] != nil, let point = self.joystickTarget
      else { return }
      self.touch(2, 100, point.0, point.1)
    }
    joystickTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  deinit {
    joystickTimer?.invalidate()
    actionTimer?.invalidate()
  }
  func touch(_ action: UInt8, _ id: Int, _ x: Double, _ y: Double) {
    guard !suspended, let write = writer, x.isFinite, y.isFinite else { return }
    if action == 0 {
      guard contacts[id] == nil, contacts.count < 10 else { return }
    } else {
      guard contacts[id] != nil else { return }
    }
    let nx = max(0, min(1, x))
    let ny = max(0, min(1, y))
    let previous = contacts[id]
    var d = Data([2, action])
    d.be(Int64(id))
    d.be(UInt32(max(0, min(width - 1, Int((nx * Double(width)).rounded())))))
    d.be(UInt32(max(0, min(height - 1, Int((ny * Double(height)).rounded())))))
    d.be(UInt16(width))
    d.be(UInt16(height))
    d.be(UInt16(action == 1 ? 0 : 65535))
    d.be(UInt32(0))
    d.be(UInt32(0))
    if action == 1 { contacts.removeValue(forKey: id) } else { contacts[id] = (nx, ny) }
    write(d)
    if action == 1 || previous == nil || previous!.0 != nx || previous!.1 != ny {
      onContactChange?()
    }
  }
  func androidKey(_ code: UInt32, _ down: Bool) {
    guard !suspended, let write = writer else { return }
    var d = Data([0, down ? 0 : 1])
    d.be(code)
    d.be(UInt32(0))
    d.be(UInt32(0))
    write(d)
  }
  func clickKey(_ code: UInt32) {
    androidKey(code, true)
    androidKey(code, false)
  }
  func key(_ code: String, _ down: Bool) {
    let sound =
      profile.bindings.contains { $0.code == code && $0.mode == "audio" }
      || profile.shortcuts.contains { $0.code == code && [24, 25, 164].contains($0.keycode) }
    guard !suspended, enabled || sound, writer != nil, pressed.contains(code) != down else { return }
    if down { pressed.insert(code) } else { pressed.remove(code) }
    let j = profile.joystick
    if j.enabled, j.keys.contains(code) {
      if !j.keys.contains(where: { pressed.contains($0) }) {
        stopJoystickTimer()
        if let point = contacts[100] { touch(1, 100, point.0, point.1) }
        return
      }
      if contacts[100] == nil { touch(0, 100, j.x, j.y) }
      var dx =
        Double(pressed.contains(j.keys[3]) ? 1 : 0) - Double(pressed.contains(j.keys[1]) ? 1 : 0)
      var dy =
        Double(pressed.contains(j.keys[2]) ? 1 : 0) - Double(pressed.contains(j.keys[0]) ? 1 : 0)
      let length = max(1, hypot(dx, dy))
      dx /= length
      dy /= length
      let r = j.radius * Double(min(width, height))
      let point = (j.x + dx * r / Double(width), j.y + dy * r / Double(height))
      joystickTarget = point
      touch(2, 100, point.0, point.1)
      if contacts[100] != nil { startJoystickTimer() }
      return
    }
    if let i = profile.bindings.firstIndex(where: { $0.code == code }) {
      let b = profile.bindings[i]
      if down {
        startBinding(b, index: i)
      } else if b.mode == "hold" || b.mode == "repeat" || b.mode == "audio" {
        cancelBinding(index: i)
      }
      return
    }
    if let s = profile.shortcuts.first(where: { $0.code == code }) {
      if let action = [UInt32(24): "volumeUp", UInt32(25): "volumeDown", UInt32(164): "mute"][
        s.keycode]
      {
        let index = 64 + profile.shortcuts.firstIndex(where: { $0.code == code })!
        if down {
          startBinding(
            Binding(code: code, mode: "audio", x: 0.5, y: 0.5, label: "声音", audioAction: action),
            index: index)
        } else {
          cancelBinding(index: index)
        }
        return
      }
      androidKey(s.keycode, down)
      if down { heldKeys.insert(s.keycode) } else { heldKeys.remove(s.keycode) }
    }
  }
  func release() {
    resetWheel()
    actionGeneration += 1
    actionTimer?.invalidate()
    actionTimer = nil
    actions.removeAll()
    stopJoystickTimer()
    for (id, p) in contacts { touch(1, id, p.0, p.1) }
    for key in heldKeys { androidKey(key, false) }
    contacts.removeAll()
    heldKeys.removeAll()
    pressed.removeAll()
  }
  func resize(width: Int, height: Int) {
    guard self.width != width || self.height != height else { return }
    self.width = width
    self.height = height
    release()
  }
  func text(_ text: String) {
    guard !suspended else { return }
    let bytes = Data(text.prefix(1000).utf8)
    var d = Data([1])
    d.be(UInt32(bytes.count))
    d.append(bytes)
    writer?(d)
  }
  func scroll(_ x: Double, _ y: Double, _ h: Double, _ v: Double) {
    guard !suspended else { return }
    var d = Data([3])
    d.be(UInt32(max(0, min(width - 1, Int(x * Double(width))))))
    d.be(UInt32(max(0, min(height - 1, Int(y * Double(height))))))
    d.be(UInt16(width))
    d.be(UInt16(height))
    d.be(Int16(max(-32768, min(32767, Int(h * 2048)))))
    d.be(Int16(max(-32768, min(32767, Int(v * 2048)))))
    d.be(UInt32(0))
    writer?(d)
  }
}

final class AndroidRuntime {
  static let storageCapacityGB = 100
  let root: URL
  let sdk: URL
  let adb: URL
  var ramMb = 6144
  var mediaVolumePercent = 80
  var child: Process?
  var ownedSerial: String?
  var grpcPort: Int?
  var grpcToken: String?
  var appliedDisplay: DeckDisplaySpec?
  var resolution = DeckResolution.hd
  private var resolvedActivities: [String: String] = [:]
  var bootElapsedMs = 0.0
  // Saving/restoring a RAM snapshot adds multi-GB writes and raises host memory pressure.
  var quickBootEnabled = false
  private var lifecycleLock: Int32 = -1
  private var quickRestoreClone: URL?
  private var quickExpectedMarker: String?
  private var quickKey = ""
  var quickBoot: QuickBootStore { QuickBootStore(root: root) }
  func bootCompatibilityKey() throws -> String {
    var text = "arm64|\(ProcessInfo.processInfo.operatingSystemVersionString)|\(ramMb)|4|\(resolution.rawValue)|host|resampling0|v1|\(EGLCompatibility.fingerprint)|storage\(Self.storageCapacityGB)"
    for name in ["emulator/source.properties", "system-images/android-34/default/arm64-v8a/source.properties"] {
      text += (try? String(contentsOf: sdk.appendingPathComponent(name), encoding: .utf8)) ?? "missing"
    }
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  var log: ((String) -> Void)?
  var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["ANDROID_SDK_ROOT"] = sdk.path
    env["ANDROID_HOME"] = sdk.path
    env["ANDROID_EMULATOR_LAUNCHER_DIR"] = sdk.appendingPathComponent("emulator").path
    env["ANDROID_AVD_HOME"] = root.appendingPathComponent("data/avd").path
    env["ANDROID_EMULATOR_HOME"] = root.appendingPathComponent("data/emulator").path
    env["ANDROID_USER_HOME"] = root.appendingPathComponent("data/android").path
    return env
  }
  init(root: URL) {
    self.root = root
    sdk = root.appendingPathComponent(".runtime/sdk")
    adb = sdk.appendingPathComponent("platform-tools/adb")
    // Older builds did not save a last-opened package. Keep their actual screen size on normal launch.
    if let config = try? String(contentsOf: root.appendingPathComponent("data/avd/AndroidDeck.avd/config.ini"), encoding: .utf8),
      let line = config.split(separator: "\n").first(where: { $0.hasPrefix("hw.lcd.width=") }),
      let width = Int(line.dropFirst("hw.lcd.width=".count)),
      let saved = DeckResolution.allCases.first(where: { $0.width == width }) { resolution = saved }
  }
  var emulator: URL {
    let packaged = sdk.appendingPathComponent("emulator/emulator-bin")
    return FileManager.default.isExecutableFile(atPath: packaged.path) ? packaged : sdk.appendingPathComponent("emulator/emulator")
  }
  func run(_ exe: URL, _ args: [String], timeout: Double = 25) throws -> String {
    let p = Process()
    let out = Pipe()
    let err = Pipe()
    let done = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let lock = NSLock()
    var stdout = Data()
    var stderr = Data()
    p.executableURL = exe
    p.arguments = args
    p.environment = environment
    p.standardOutput = out
    p.standardError = err
    p.terminationHandler = { _ in done.signal() }
    try p.run()
    group.enter()
    DispatchQueue.global().async {
      let bytes = out.fileHandleForReading.readDataToEndOfFile()
      lock.lock()
      stdout = bytes
      lock.unlock()
      group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
      let bytes = err.fileHandleForReading.readDataToEndOfFile()
      lock.lock()
      stderr = bytes
      lock.unlock()
      group.leave()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      p.terminate()
      if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
      group.wait()
      throw DeckError(message: "命令超时")
    }
    group.wait()
    let a = String(decoding: stdout, as: UTF8.self)
    let b = String(decoding: stderr, as: UTF8.self)
    guard p.terminationStatus == 0 else {
      let message = (a + "\n" + b).trimmingCharacters(in: .whitespacesAndNewlines)
      throw DeckError(message: message.isEmpty ? "\(exe.lastPathComponent) 命令失败（\(p.terminationStatus)）" : String(message.suffix(1800)))
    }
    return a.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func adbRun(_ args: [String], serial: String? = nil, timeout: Double = 25) throws -> String {
    try run(adb, (serial.map { ["-s", $0] } ?? []) + args, timeout: timeout)
  }
  func devices() throws -> [String] {
    try adbRun(["devices"]).split(separator: "\n").dropFirst().compactMap { line in
      let parts = line.split(whereSeparator: { $0.isWhitespace })
      return parts.count >= 2 && parts[1] == "device" ? String(parts[0]) : nil
    }
  }
  func owns(_ serial: String?) -> Bool { child?.isRunning == true && serial == ownedSerial }
  func prepareExactTouch(serial: String) throws {
    guard owns(serial) else { return }
    let value = try adbRun(["shell", "getprop", "ro.input.resampling"], serial: serial)
    if value == "0" { return }
    // Android 14 extrapolates stationary injected fingers and can freeze them at a wrong coordinate.
    // This write-once property must be prepared on our AOSP guest before game InputConsumers are created.
    guard value.isEmpty else { throw DeckError(message: "精确触控属性已被其他设置占用，请重新启动 Android") }
    _ = try adbRun(["shell", "su", "0", "setprop", "ro.input.resampling", "0"], serial: serial)
    guard try adbRun(["shell", "getprop", "ro.input.resampling"], serial: serial) == "0" else {
      throw DeckError(message: "精确触控初始化失败，请查看模拟器日志")
    }
    log?("精确触控已就绪")
  }
  func screenshotOrientation(serial: String, previous: Int?) throws -> Int? {
    guard owns(serial) else { return nil }
    let text = try adbRun(["shell", "dumpsys", "input"], serial: serial, timeout: 2)
    guard
      let line = text.split(separator: "\n").first(where: {
        $0.contains("Viewport INTERNAL: displayId=0,")
      }),
      let suffix = line.components(separatedBy: "orientation=").dropFirst().first,
      let character = suffix.first, let orientation = Int(String(character)),
      (0...3).contains(orientation)
    else { return nil }
    if previous != orientation {
      let vectors = ["0:9.81:0", "9.81:0:0", "0:-9.81:0", "-9.81:0:0"]
      _ = try adbRun(
        ["emu", "sensor", "set", "acceleration", vectors[orientation]], serial: serial, timeout: 2)
    }
    return orientation
  }
  func createAVD() throws {
    let home = root.appendingPathComponent("data/avd")
    let dir = home.appendingPathComponent("AndroidDeck.avd")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for relative in ["data/emulator", "data/android"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }
    let image = sdk.appendingPathComponent("system-images/android-34/default/arm64-v8a").path
    try "avd.ini.encoding=UTF-8\npath=\(dir.path)\ntarget=android-34\n".write(
      to: home.appendingPathComponent("AndroidDeck.ini"), atomically: true, encoding: .utf8)
    let lines = [
      "AvdId=AndroidDeck", "avd.ini.displayname=AndroidDeck · Android 14", "avd.ini.encoding=UTF-8",
      "abi.type=arm64-v8a", "hw.cpu.arch=arm64", "hw.cpu.ncore=4", "hw.ramSize=\(ramMb)",
      "hw.lcd.width=\(resolution.width)", "hw.lcd.height=\(resolution.height)", "hw.lcd.density=\(resolution.density)", "hw.gpu.enabled=yes",
      "hw.gpu.mode=host", "hw.keyboard=yes", "hw.mainKeys=no", "hw.dPad=no", "hw.trackBall=no",
      "hw.audioInput=yes", "hw.audioOutput=yes", "hw.camera.back=none", "hw.camera.front=none",
      "hw.battery=yes", "hw.sensors.orientation=yes", "disk.dataPartition.size=\(Self.storageCapacityGB)G",
      "tag.id=default", "tag.display=Default Android System Image", "image.sysdir.1=\(image)/",
      "showDeviceFrame=no", "skin.name=\(resolution.width)x\(resolution.height)", "skin.dynamic=yes", "fastboot.forceColdBoot=\(quickBootEnabled ? "no" : "yes")",
      "PlayStore.enabled=false", "runtime.network.latency=none", "runtime.network.speed=full",
    ]
    try (lines.joined(separator: "\n") + "\n").write(
      to: dir.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
  }
  func start(allowQuickRestore: Bool = true) throws -> String {
    if let p = child, p.isRunning, let s = ownedSerial { return s }
    let begun = ProcessInfo.processInfo.systemUptime
    if lifecycleLock < 0 {
      let file = root.appendingPathComponent("data/androiddeck-lifecycle.lock")
      let fd = Darwin.open(file.path, O_CREAT | O_RDWR, 0o600)
      guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        if fd >= 0 { Darwin.close(fd) }
        throw DeckError(message: "此 Android 设备已由另一个窗口使用，请先关闭旧窗口")
      }
      lifecycleLock = fd
    }
    defer {
      if child == nil && lifecycleLock >= 0 { flock(lifecycleLock, LOCK_UN); Darwin.close(lifecycleLock); lifecycleLock = -1 }
    }
    let existing = try devices()
    for device in existing where device.hasPrefix("emulator-") {
      let path = try? adbRun(["emu", "avd", "path"], serial: device, timeout: 3)
      if path?.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) == quickBoot.avd.path {
        throw DeckError(message: "此 Android 设备仍在另一个窗口运行，请先关闭旧窗口")
      }
    }
    if try quickBoot.recoverInterruptedRestore() { log?("已还原上次中断的快速恢复，设备数据已保留") }
    try createAVD()
    quickKey = try bootCompatibilityKey()
    quickExpectedMarker = nil; quickRestoreClone = nil
    if quickBootEnabled && allowQuickRestore, let record = quickBoot.eligible(key: quickKey) {
      do { quickRestoreClone = try quickBoot.cloneBeforeRestore(); quickExpectedMarker = record.marker }
      catch { log?("磁盘保护未就绪，使用普通启动：\(error.localizedDescription)") }
    }
    quickBoot.invalidate()
    let port =
      stride(from: 5580, through: 5680, by: 2).first { !existing.contains("emulator-\($0)") }
      ?? 5580
    let serial = "emulator-\(port)"
    var socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { throw DeckError(message: "无法分配画面直连端口") }
    defer { if socketFD >= 0 { Darwin.close(socketFD) } }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
    }
    guard bound == 0, result == 0 else { throw DeckError(message: "画面直连端口分配失败") }
    let rawPort = Int(UInt16(bigEndian: address.sin_port))
    // Token auth forces the emulator to bind loopback (verified in its startup log).
    Darwin.close(socketFD)
    socketFD = -1
    let p = Process()
    p.executableURL = emulator
    p.environment = environment
    p.arguments = [
      "-avd", "AndroidDeck", "-port", String(port), "-memory", String(ramMb), "-no-window",
      "-no-boot-anim", "-gpu", "host", "-no-metrics", "-netdelay", "none",
      "-netspeed", "full",
      "-grpc", String(rawPort), "-grpc-use-token",
    ]
    if quickBootEnabled {
      p.arguments! += ["-snapshot", QuickBootStore.name, "-no-snapshot-save"]
      if quickExpectedMarker == nil { p.arguments!.append("-no-snapshot-load") }
    } else { p.arguments!.append("-no-snapshot") }
    let file = root.appendingPathComponent("data/native-emulator.log")
    if !FileManager.default.fileExists(atPath: file.path) {
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    let fd = try FileHandle(forWritingTo: file)
    let startupLogOffset = try fd.seekToEnd()
    p.standardOutput = fd
    p.standardError = fd
    try p.run()
    try fd.close()
    child = p
    ownedSerial = serial
    log?("启动 Android · \(ramMb/1024) GB · M4 硬件图形")
    do {
      for _ in 0..<180 {
        guard p.isRunning else { throw DeckError(message: "模拟器启动失败，请查看 native-emulator.log") }
        if quickExpectedMarker != nil {
          let reader = try FileHandle(forReadingFrom: file)
          defer { try? reader.close() }
          try reader.seek(toOffset: startupLogOffset)
          let output = try reader.read(upToCount: 512 * 1024) ?? Data()
          if snapshotRestoreFailed(in: String(decoding: output, as: UTF8.self)) {
            throw DeckError(message: "SDK 无法读取快速启动状态")
          }
          if ProcessInfo.processInfo.systemUptime - begun > 25 {
            throw DeckError(message: "快速恢复超过可接受的等待时间")
          }
        }
        if (try? adbRun(["shell", "getprop", "sys.boot_completed"], serial: serial, timeout: 2))
          == "1"
        {
          if let marker = quickExpectedMarker {
            let restored = try adbRun(["shell", "cat", QuickBootStore.guestMarker], serial: serial)
            guard restored == marker else { throw DeckError(message: "快速恢复的数据校验未通过") }
          }
          _ = try? adbRun(
            ["shell", "settings", "put", "secure", "immersive_mode_confirmations", "confirmed"],
            serial: serial)
          _ = try? adbRun(["shell", "input", "keyevent", "82"], serial: serial)
          try prepareExactTouch(serial: serial)
          try prepareEGLCompatibility(serial: serial)
          _ = try setMediaVolume(percent: mediaVolumePercent, serial: serial)
          let discovery = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Caches/TemporaryItems/avd/running/pid_\(p.processIdentifier).ini")
          if let ini = try? String(contentsOf: discovery, encoding: .utf8),
            let line = ini.split(separator: "\n").first(where: { $0.hasPrefix("grpc.token=") })
          {
            grpcPort = rawPort
            grpcToken = String(line.dropFirst("grpc.token=".count)).trimmingCharacters(
              in: .whitespacesAndNewlines)
          }
          log?(grpcToken == nil ? "未读取到原始画面授权，将使用兼容视频" : "原始画面授权已就绪")
          bootElapsedMs = (ProcessInfo.processInfo.systemUptime - begun) * 1000
          log?(String(format: "Android 启动用时 %.1f 秒", bootElapsedMs / 1000))
          if let backup = quickRestoreClone { try quickBoot.discardClone(backup) }
          quickRestoreClone = nil; quickExpectedMarker = nil
          return serial
        }
        Thread.sleep(forTimeInterval: 1)
      }
      throw DeckError(message: "Android 启动超时")
    } catch {
      let backup = quickRestoreClone
      stop(saveQuickBoot: false, failedRestore: backup != nil)
      if let backup = backup {
        try quickBoot.restoreClone(backup)
        quickRestoreClone = nil; quickExpectedMarker = nil
        log?("快速恢复未完成（\(error.localizedDescription)），保护副本已还原，改为普通启动")
        return try start(allowQuickRestore: false)
      }
      throw error
    }
  }
  func stop(saveQuickBoot: Bool = true, failedRestore: Bool = false) {
    guard let p = child else { return }
    child = nil
    quickBoot.invalidate()
    var savedMarker: String?
    if quickBootEnabled && saveQuickBoot && p.isRunning, let serial = ownedSerial {
      do {
        let marker = UUID().uuidString
        let local = root.appendingPathComponent("data/quickboot-marker.txt")
        try Data((marker + "\n").utf8).write(to: local, options: .atomic)
        _ = try adbRun(["push", local.path, QuickBootStore.guestMarker], serial: serial)
        _ = try adbRun(["shell", "sync"], serial: serial, timeout: 15)
        _ = try adbRun(["emu", "avd", "stop"], serial: serial)
        let before = try adbRun(["emu", "avd", "status"], serial: serial)
        guard before.contains("stopped") else { throw DeckError(message: "设备未暂停") }
        log?("正在保存快速启动状态…")
        let result = try adbRun(["emu", "avd", "snapshot", "save", QuickBootStore.name], serial: serial, timeout: 90)
        let after = try adbRun(["emu", "avd", "status"], serial: serial)
        guard result.contains("OK"), after.contains("stopped") else { throw DeckError(message: "快速启动保存未完成") }
        savedMarker = marker
      } catch { log?("快速启动未保存，下次使用普通启动") }
    }
    if p.isRunning {
      if failedRestore {
        // Only a failed restore with a verified disk clone uses this path.
        // Its partly restored VM must not sync or checkpoint the protected data.
        kill(p.processIdentifier, SIGKILL); p.waitUntilExit()
      } else {
        if savedMarker == nil, let s = ownedSerial { _ = try? adbRun(["shell", "sync"], serial: s, timeout: 10) }
        p.terminate()
        for _ in 0..<80 {
          if !p.isRunning { break }
          Thread.sleep(forTimeInterval: 0.1)
        }
      }
      if p.isRunning {
        savedMarker = nil
        kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
      }
    }
    if p.terminationStatus == 0, let marker = savedMarker { try? quickBoot.checkpoint(key: quickKey, marker: marker) }
    if lifecycleLock >= 0 { flock(lifecycleLock, LOCK_UN); Darwin.close(lifecycleLock); lifecycleLock = -1 }
    ownedSerial = nil
    grpcPort = nil
    grpcToken = nil
    appliedDisplay = nil
  }
  func component(_ package: String, serial: String) throws -> String {
    guard package.range(of: "^[A-Za-z][\\w]*(\\.[\\w]+)+$", options: .regularExpression) != nil
    else { throw DeckError(message: "包名无效") }
    if let cached = resolvedActivities[serial + "::" + package] { return cached }
    let value = try adbRun(
      [
        "shell", "cmd", "package", "resolve-activity", "--brief", "-a",
        "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", package,
      ], serial: serial)
    guard
      let result = value.split(separator: "\n").first(where: {
        $0.range(of: "^[\\w.]+/[\\w.$]+$", options: .regularExpression) != nil
      })
    else { throw DeckError(message: "此应用没有可启动主界面") }
    resolvedActivities[serial + "::" + package] = String(result)
    return String(result)
  }
  func launch(_ package: String, serial: String) throws {
    let begun = ProcessInfo.processInfo.systemUptime
    try prepareEGLCompatibility(serial: serial)
    for attempt in 0..<2 {
      let c = try component(package, serial: serial)
      let output = try adbRun(["shell", "am", "start", "-W", "-n", c], serial: serial, timeout: 45)
      if !output.contains("Error type"), !output.contains("Error:") {
        log?(String(format: "打开 %@ 用时 %.2f 秒", package, ProcessInfo.processInfo.systemUptime - begun)); return
      }
      resolvedActivities.removeValue(forKey: serial + "::" + package)
      if attempt == 1 { throw DeckError(message: output) }
    }
  }
  func apps(serial: String) throws -> [AndroidApp] {
    let lines = try adbRun(["shell", "pm", "list", "packages", "-3"], serial: serial).split(
      separator: "\n")
    return lines.compactMap { line in
      let p = line.replacingOccurrences(of: "package:", with: "")
      guard (try? component(p, serial: serial)) != nil else { return nil }
      return AndroidApp(
        package: p,
        name: AppInteraction.builtinNames[p] ?? String(p.split(separator: ".").last ?? "应用"),
        isGame: AppInteraction.androidGameMetadata((try? adbRun(["shell", "dumpsys", "package", p], serial: serial, timeout: 5)) ?? "")
      )
    }
  }
  func install(_ file: URL, serial: String) throws {
    guard file.pathExtension.lowercased() == "apk" else { throw DeckError(message: "请选择 APK 安装包") }
    _ = try adbRun(["install", "-r", file.path], serial: serial, timeout: 180)
    resolvedActivities = resolvedActivities.filter { !$0.key.hasPrefix(serial + "::") }
  }
}
