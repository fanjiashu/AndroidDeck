// SPDX-License-Identifier: GPL-3.0-only
import Foundation

let mappingModes: [(String, String)] = [
  ("tap", "点击"), ("hold", "按住"), ("repeat", "连点"), ("swipe", "滑动轨迹"), ("pinch", "双指缩放"),
  ("rotate", "双指旋转"),
  ("audio", "声音键"),
]
let mouseCodes: Set<String> = ["MouseLeft", "MouseRight", "MouseMiddle", "WheelUp", "WheelDown"]
var mappingCodes: Set<String> { Set(physicalCodes.values).union(mouseCodes) }

struct GesturePoint: Codable, Equatable {
  var x: Double
  var y: Double
  var t: Double
}
struct TouchPoint: Equatable {
  var x: Double
  var y: Double
  var clipped: TouchPoint { TouchPoint(x: max(0, min(1, x)), y: max(0, min(1, y))) }
}
extension Binding {
  var duration: Double { Double(durationMs ?? 300) / 1000 }
  var interval: Double { Double(intervalMs ?? 100) / 1000 }
  var fingerCount: Int { mode == "audio" ? 0 : ["pinch", "rotate"].contains(mode) ? 2 : 1 }
  var modeTitle: String { mappingModes.first { $0.0 == mode }?.1 ?? mode }
  func validateGesture() throws {
    guard (50...5000).contains(durationMs ?? 300), (50...1000).contains(intervalMs ?? 100),
      (scale ?? 2).isFinite, (0.25...4).contains(scale ?? 2),
      (rotation ?? 90).isFinite, (-360...360).contains(rotation ?? 90),
      (radius ?? 0.08).isFinite, (0.01...0.4).contains(radius ?? 0.08)
    else { throw DeckError(message: "手势参数超出范围") }
    if let points = path {
      guard points.count >= 2, points.count <= 256, abs(points[0].t) < 1e-9,
        abs(points.last!.t - 1) < 1e-9
      else { throw DeckError(message: "滑动轨迹需要 2–256 个有序点") }
      var previous = -1.0
      for point in points {
        guard point.x.isFinite, point.y.isFinite, point.t.isFinite,
          (0...1).contains(point.x), (0...1).contains(point.y), (0...1).contains(point.t),
          point.t > previous
        else { throw DeckError(message: "滑动轨迹坐标或时间无效") }
        previous = point.t
      }
      guard abs(points[0].x - x) < 1e-9, abs(points[0].y - y) < 1e-9 else {
        throw DeckError(message: "轨迹起点必须与触点位置一致")
      }
    }
    if mode == "swipe", path == nil { throw DeckError(message: "请拖动画面录制滑动轨迹") }
    if let action = audioAction, !["volumeUp", "volumeDown", "mute"].contains(action) {
      throw DeckError(message: "声音动作无效")
    }
  }
  func points(at fraction: Double, width: Int, height: Int) -> [TouchPoint] {
    let t = max(0, min(1, fraction))
    if mode == "swipe", let path = path {
      if t >= 1 { return [TouchPoint(x: path.last!.x, y: path.last!.y)] }
      let end = path.firstIndex { $0.t > t } ?? path.count - 1
      let a = path[max(0, end - 1)]
      let b = path[end]
      let phase = (t - a.t) / max(1e-9, b.t - a.t)
      return [TouchPoint(x: a.x + (b.x - a.x) * phase, y: a.y + (b.y - a.y) * phase).clipped]
    }
    if mode == "pinch" || mode == "rotate" {
      let base = (radius ?? 0.08) * Double(min(width, height))
      let distance = mode == "pinch" ? base * (1 + ((scale ?? 2) - 1) * t) : base
      let angle = mode == "rotate" ? (rotation ?? 90) * .pi / 180 * t : 0
      let dx = cos(angle) * distance / Double(max(1, width))
      let dy = sin(angle) * distance / Double(max(1, height))
      return [TouchPoint(x: x - dx, y: y - dy).clipped, TouchPoint(x: x + dx, y: y + dy).clipped]
    }
    return [TouchPoint(x: x, y: y)]
  }
  mutating func move(to point: TouchPoint) {
    var dx = point.x - x
    var dy = point.y - y
    if let points = path {
      dx = max(-points.map(\.x).min()!, min(1 - points.map(\.x).max()!, dx))
      dy = max(-points.map(\.y).min()!, min(1 - points.map(\.y).max()!, dy))
      path = points.map { GesturePoint(x: $0.x + dx, y: $0.y + dy, t: $0.t) }
    }
    x += dx
    y += dy
  }
  mutating func setMode(_ value: String) {
    mode = value
    if value == "swipe", path == nil {
      path = [GesturePoint(x: x, y: y, t: 0), GesturePoint(x: min(1, x + 0.15), y: y, t: 1)]
    } else if value != "swipe" {
      path = nil
    }
  }
}
extension Profile {
  func controlsEqual(_ other: Profile) -> Bool {
    var a = joystick
    var b = other.joystick
    a.visible = nil
    b.visible = nil
    func controls(_ binding: Binding) -> Binding {
      var result = binding
      result.visible = nil
      result.label = ""
      return result
    }
    return a == b && shortcuts == other.shortcuts
      && bindings.map(controls) == other.bindings.map(controls)
  }
}

enum MappingStore {
  static func key(package: String, scheme: String) -> String {
    scheme.isEmpty ? package : package + "::" + scheme
  }
  static func schemes(package: String, profiles: [String: Profile]) -> [String] {
    let prefix = package + "::"
    return [""]
      + profiles.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
      .sorted()
  }
  static func resolve(package: String, scheme: String, profiles: [String: Profile]) -> Profile {
    (try? profiles[key(package: package, scheme: scheme)]?.checked())
      ?? (try? profiles[package]?.checked()) ?? Profile.initial(for: package)
  }
}

struct TouchActivity {
  let binding: Binding
  let ids: [Int]
  let started: Double
  let token: Int
  var nextClick: Double
  var expires: Double?
  var pressUntil: Double?
}
extension InputEngine {
  func startBinding(_ binding: Binding, index: Int, preview: Bool = false) {
    guard writer != nil,
      (0..<64).contains(index) || binding.mode == "audio" && (64..<84).contains(index)
        || index == Self.wheelActionIndex && binding.mode == "swipe" && ["WheelUp", "WheelDown"].contains(binding.code),
      (try? binding.validateGesture()) != nil
    else { return }
    if binding.mode == "tap", actions[index]?.binding.mode == "tap" { return }
    cancelBinding(index: index)
    var action = binding
    if preview && action.mode == "hold" {
      action.mode = "swipe"
      action.durationMs = 600
      action.path = [
        GesturePoint(x: action.x, y: action.y, t: 0), GesturePoint(x: action.x, y: action.y, t: 1),
      ]
    }
    let now = ProcessInfo.processInfo.systemUptime
    let ids =
      action.fingerCount == 0
      ? [] : action.fingerCount == 2 ? [10 + index, 1000 + index] : [10 + index]
    var pressUntil: Double?
    if action.mode == "audio" {
      emitAudioAction(action.audioAction ?? "volumeUp")
      if (action.audioAction ?? "volumeUp") == "mute" { return }
    } else if action.mode == "tap" || action.mode == "repeat" {
      if beginClick(action, id: ids[0]) {
        pressUntil = ProcessInfo.processInfo.systemUptime + clickDuration(action)
      } else if action.mode == "tap" { return }
    } else {
      guard contacts.count + ids.count <= 10, ids.allSatisfy({ contacts[$0] == nil }) else {
        return
      }
      for (i, point) in action.points(at: 0, width: width, height: height).enumerated() {
        touch(0, ids[i], point.x, point.y)
      }
      guard ids.allSatisfy({ contacts[$0] != nil }) else {
        for id in ids { if let p = contacts[id] { touch(1, id, p.0, p.1) } }
        return
      }
    }
    actionSequence += 1
    actions[index] = TouchActivity(
      binding: action, ids: ids, started: now, token: actionSequence,
      nextClick: now + action.interval,
      expires: preview && ["repeat", "audio"].contains(action.mode) ? now + 0.6 : nil,
      pressUntil: pressUntil)
    ensureActionTimer()
  }
  func clickDuration(_ binding: Binding) -> Double {
    binding.mode == "repeat" ? min(0.08, max(1.0 / 60, binding.interval / 2)) : 0.08
  }
  @discardableResult func beginClick(_ binding: Binding, id: Int) -> Bool {
    guard contacts.count < 10, contacts[id] == nil else { return false }
    touch(0, id, binding.x, binding.y)
    return contacts[id] != nil
  }
  func cancelBinding(index: Int) {
    if let action = actions.removeValue(forKey: index) {
      for id in action.ids { if let point = contacts[id] { touch(1, id, point.0, point.1) } }
    } else if let point = contacts[10 + index] {
      touch(1, 10 + index, point.0, point.1)
    }
    stopIdleActionTimer()
  }
  func ensureActionTimer() {
    guard actionTimer == nil, actions.values.contains(where: { $0.binding.mode != "hold" }) else {
      return
    }
    let generation = actionGeneration
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      guard let self = self, self.actionGeneration == generation else { return }
      self.advanceActions()
    }
    actionTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  func stopIdleActionTimer() {
    if !actions.values.contains(where: { $0.binding.mode != "hold" }) {
      actionTimer?.invalidate()
      actionTimer = nil
      actionGeneration += 1
    }
  }
  func advanceActions() {
    let now = ProcessInfo.processInfo.systemUptime
    for (index, snapshot) in Array(actions) {
      guard actions[index]?.token == snapshot.token else { continue }
      if let expiry = snapshot.expires, now >= expiry {
        cancelBinding(index: index)
        continue
      }
      if snapshot.binding.mode == "audio" {
        if now >= snapshot.nextClick {
          emitAudioAction(snapshot.binding.audioAction ?? "volumeUp")
          actions[index]?.nextClick = now + max(0.15, snapshot.binding.interval)
        }
      } else if snapshot.binding.mode == "tap" {
        if let deadline = snapshot.pressUntil, now >= deadline { cancelBinding(index: index) }
      } else if snapshot.binding.mode == "repeat" {
        if let deadline = snapshot.pressUntil {
          if now >= deadline {
            for id in snapshot.ids { if let p = contacts[id] { touch(1, id, p.0, p.1) } }
            if actions[index]?.token == snapshot.token { actions[index]?.pressUntil = nil }
          }
          // Keep UP and the following DOWN on distinct timer ticks.
          continue
        }
        if now >= snapshot.nextClick {
          if beginClick(snapshot.binding, id: snapshot.ids[0]), actions[index]?.token == snapshot.token {
            actions[index]?.pressUntil = ProcessInfo.processInfo.systemUptime + clickDuration(snapshot.binding)
          }
          if actions[index]?.token == snapshot.token { actions[index]?.nextClick = ProcessInfo.processInfo.systemUptime + snapshot.binding.interval }
        }
      } else if snapshot.binding.mode != "hold" {
        let fraction = min(1, (now - snapshot.started) / snapshot.binding.duration)
        let points = snapshot.binding.points(at: fraction, width: width, height: height)
        for (i, point) in points.enumerated() {
          guard actions[index]?.token == snapshot.token else { break }
          if let previous = contacts[snapshot.ids[i]],
            previous.0 != point.x || previous.1 != point.y
          {
            touch(2, snapshot.ids[i], point.x, point.y)
          }
        }
        if fraction >= 1 { cancelBinding(index: index) }
      }
    }
    advanceWheel()
  }
  func emitAudioAction(_ action: String) {
    if let callback = onAudioAction {
      callback(action)
    } else if let code = ["volumeUp": UInt32(24), "volumeDown": UInt32(25), "mute": UInt32(164)][
      action]
    {
      clickKey(code)
    }
  }
}
