// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ImportedMapping {
  let profile: Profile
  let skipped: [String]
}
enum MuMuMappingImport {
  static func code(_ raw: String) -> String? {
    let key = raw.uppercased()
    let names = [
      "LEFT_MOUSE": "MouseLeft", "RIGHT_MOUSE": "MouseRight", "MIDDLE_MOUSE": "MouseMiddle",
      "SPACE": "Space", "SPACEBAR": "Space", "ESC": "Escape", "ESCAPE": "Escape", "TAB": "Tab",
      "ENTER": "Enter", "RETURN": "Enter",
      "UP": "ArrowUp", "DOWN": "ArrowDown", "LEFT": "ArrowLeft", "RIGHT": "ArrowRight",
      "↑": "ArrowUp", "↓": "ArrowDown", "←": "ArrowLeft", "→": "ArrowRight",
      "LSHIFT": "ShiftLeft", "LCTRL": "ControlLeft", "LALT": "AltLeft", "BACKSPACE": "Backspace",
      "WHEEL_UP": "WheelUp", "WHEEL_DOWN": "WheelDown",
    ]
    if let value = names[key] { return value }
    if key.count == 1, key.first!.isLetter { return "Key" + key }
    if key.count == 1, key.first!.isNumber { return "Digit" + key }
    if key.count == 2, key.first == "N", key.last!.isNumber { return "Numpad" + String(key.last!) }
    if key.hasPrefix("F"), let n = Int(key.dropFirst()), (1...12).contains(n) { return "F\(n)" }
    if mappingCodes.contains(raw) { return raw }
    return nil
  }
  static func decode(_ data: Data, current: Profile, keepJoystick: Bool, width: Int, height: Int)
    throws -> ImportedMapping
  {
    guard data.count <= 1024 * 1024 else { throw DeckError(message: "映射文件超过 1 MB") }
    if let native = try? JSONDecoder().decode(Profile.self, from: data) {
      var result = native
      if keepJoystick { result.joystick = current.joystick }
      return ImportedMapping(profile: try result.checked(), skipped: [])
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let maps = object["keymaps"] as? [[String: Any]]
    else { throw DeckError(message: "请选择 AndroidDeck JSON 或 MuMu 的键位方案 JSON") }
    var profile = current
    profile.bindings = []
    var skipped: [String] = []
    for map in maps {
      let type = map["type"] as? String ?? "未知控件"
      let position = map["rel_work_position"] as? [String: Any] ?? [:]
      guard let x = position["rel_x"] as? Double, let y = position["rel_y"] as? Double else {
        skipped.append(type)
        continue
      }
      if type == "Swipehold" {
        if !keepJoystick {
          let fields = ["top_key", "left_key", "bottom_key", "right_key"]
          let keys = fields.compactMap {
            ((map[$0] as? [String: Any])?["text"] as? String).flatMap(code)
          }
          guard keys.count == 4 else {
            skipped.append(type)
            continue
          }
          profile.joystick.x = x
          profile.joystick.y = y
          profile.joystick.keys = keys
          profile.joystick.enabled = true
          profile.joystick.radius = max(
            0.01,
            min(
              0.3,
              (map["rel_radius"] as? Double ?? 0.06) * Double(width)
                / Double(max(1, min(width, height)))))
        }
        continue
      }
      guard ["Click", "Fire", "ClickRepeat"].contains(type),
        let raw = (map["key"] as? [String: Any])?["text"] as? String, let key = code(raw),
        key != "F11"
      else {
        skipped.append(type)
        continue
      }
      let icon = map["icon"] as? [String: Any] ?? [:]
      let label = icon["description"] as? String ?? ""
      profile.bindings.append(
        Binding(
          code: key, mode: type == "Fire" ? "hold" : type == "ClickRepeat" ? "repeat" : "tap",
          x: x, y: y, label: String((label.isEmpty ? keyLabel(key) : label).prefix(32)),
          visible: icon["visibility"] as? Bool))
    }
    guard !profile.bindings.isEmpty else { throw DeckError(message: "文件中没有可导入的单击、按住或连点控件") }
    let used = Set(
      profile.bindings.map(\.code) + (profile.joystick.enabled ? profile.joystick.keys : []))
    profile.shortcuts.removeAll { used.contains($0.code) }
    return ImportedMapping(profile: try profile.checked(), skipped: skipped)
  }
}
