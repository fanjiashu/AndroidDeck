// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ReadyScheme {
  let id: String
  let title: String
  let origin: String
  let profile: Profile
}
enum ReadySchemeCatalogue {
  static let dnfPackage = "com.tencent.tmgp.dnf"
  static let dnfTitle = "推荐 · DNF标准布局"
  static let systemOverlays: Set<String> = ["com.android.permissioncontroller", "com.google.android.permissioncontroller", "com.android.systemui"]
  static func dnfStandard() -> Profile {
    var p = Profile.initial(for: dnfPackage)
    func point(_ code: String, _ label: String, _ x: Double, _ y: Double, _ mode: String = "tap") -> Binding {
      Binding(code: code, mode: mode, x: x / 1280, y: y / 720, label: label)
    }
    p.bindings = [
      point("KeyJ", "普攻", 1138, 632, "hold"),
      point("Space", "跳跃", 1186, 531), point("KeyC", "后跳", 1036, 668),
      point("KeyQ", "技能槽1", 735, 658), point("KeyE", "技能槽2", 839, 658),
      point("KeyR", "技能槽3", 940, 658), point("KeyF", "技能槽4", 976, 549),
      point("KeyG", "技能槽5", 1054, 459), point("KeyH", "技能槽6", 1164, 433),
      point("KeyV", "技能槽7", 1164, 330),
      point("KeyZ", "技能槽8", 914, 244), point("KeyX", "技能槽9", 988, 244),
      point("KeyT", "技能槽10", 1058, 244), point("KeyY", "技能槽11", 1130, 244),
      point("KeyU", "技能槽12", 1202, 244),
    ]
    let center = TouchPoint(x: 1052 / 1280, y: 358 / 720)
    for (index, vector) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)].enumerated() {
      let end = TouchPoint(x: center.x + vector.0 * 38 / 1280, y: center.y + vector.1 * 38 / 720)
      p.bindings.append(Binding(code: "Digit\(index + 1)", mode: "swipe", x: center.x, y: center.y,
        label: ["滑屏左上", "滑屏右上", "滑屏左下", "滑屏右下"][index], durationMs: 140,
        path: [GesturePoint(x: center.x, y: center.y, t: 0), GesturePoint(x: end.x, y: end.y, t: 0.5), GesturePoint(x: end.x, y: end.y, t: 1)]))
    }
    return p.withDefaultSoundKeys()
  }
  static func discover(package: String, current: Profile, width: Int, height: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ReadyScheme] {
    guard package.range(of: "^[A-Za-z][\\w]*(\\.[\\w]+)+$", options: .regularExpression) != nil else { return [] }
    var result: [ReadyScheme] = []
    if package == dnfPackage { result.append(ReadyScheme(id: "builtin.dnf.standard.v1", title: dnfTitle, origin: "内置 · 标准布局 16:9", profile: dnfStandard())) }
    for domain in ["com.netease.mumu.nemux", "com.netease.mumu.nemux-global"] {
      let folder = home.appendingPathComponent("Library/Application Support/\(domain)/keymap/keyboard/\(package)")
      guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
      for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" && !["selected.json", "customer.json", "cloud.json"].contains(file.lastPathComponent) {
        guard let data = try? Data(contentsOf: file), let imported = try? MuMuMappingImport.decode(data, current: current, keepJoystick: false, width: width, height: height), imported.skipped.isEmpty else { continue }
        var p = imported.profile
        let equivalents = ["Numpad1": "KeyJ", "Numpad2": "KeyK", "Numpad3": "KeyL", "Numpad4": "KeyM", "Numpad5": "KeyU", "Numpad6": "KeyI", "Numpad7": "KeyO", "Numpad8": "KeyP", "Numpad9": "Semicolon", "Numpad0": "Quote"]
        for index in p.bindings.indices { if let key = equivalents[p.bindings[index].code] { p.bindings[index].code = key } }
        guard (try? p.checked()) != nil else { continue }
        let base = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "customer-", with: "").replacingOccurrences(of: "cloud-", with: "")
        let name = String(base.prefix(22)) + (domain.hasSuffix("global") ? " · 国际版" : "")
        result.append(ReadyScheme(id: "mumu:\(domain):\(file.lastPathComponent)", title: "MuMu · \(name)", origin: "本机 MuMu · 主键盘适配", profile: p))
      }
    }
    return result
  }
  static func register(_ scheme: ReadyScheme, package: String, profiles: inout [String: Profile], preferences: inout Preferences) -> Bool {
    let key = MappingStore.key(package: package, scheme: scheme.title)
    var changed = false
    if profiles[key] == nil { profiles[key] = scheme.profile; changed = true }
    if preferences.readyDefaultsApplied?[package] != true {
      if preferences.readyDefaultsApplied == nil { preferences.readyDefaultsApplied = [:] }
      if preferences.profileSelections == nil { preferences.profileSelections = [:] }
      if (preferences.profileSelections?[package] ?? "").isEmpty { preferences.profileSelections![package] = scheme.title }
      preferences.readyDefaultsApplied![package] = true
      changed = true
    }
    return changed
  }
  static func foregroundPackage(in text: String) -> String? {
    guard let line = text.split(separator: "\n").first(where: { $0.contains("topResumedActivity=") || $0.contains("mResumedActivity:") }),
      let component = line.split(whereSeparator: { $0.isWhitespace }).first(where: { $0.contains("/") }),
      let package = component.split(separator: "/").first.map(String.init),
      package.range(of: "^[A-Za-z][\\w]*(\\.[\\w]+)+$", options: .regularExpression) != nil else { return nil }
    return package
  }
}

struct LayoutTransform {
  let a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
  func point(_ p: TouchPoint) -> TouchPoint { TouchPoint(x: a * p.x + b * p.y + tx, y: c * p.x + d * p.y + ty) }
  static func fit(source: [TouchPoint], target: [TouchPoint]) throws -> LayoutTransform {
    guard source.count == 3, target.count == 3 else { throw DeckError(message: "校准需要三个按钮中心") }
    let s1 = TouchPoint(x: source[1].x - source[0].x, y: source[1].y - source[0].y), s2 = TouchPoint(x: source[2].x - source[0].x, y: source[2].y - source[0].y)
    let t1 = TouchPoint(x: target[1].x - target[0].x, y: target[1].y - target[0].y), t2 = TouchPoint(x: target[2].x - target[0].x, y: target[2].y - target[0].y)
    let det = s1.x * s2.y - s2.x * s1.y, targetDet = t1.x * t2.y - t2.x * t1.y
    guard abs(det) > 0.005, abs(targetDet) > 0.005 else { throw DeckError(message: "三个按钮太接近或在同一直线上，请重新选择") }
    let a = (t1.x * s2.y - t2.x * s1.y) / det, b = (-t1.x * s2.x + t2.x * s1.x) / det
    let c = (t1.y * s2.y - t2.y * s1.y) / det, d = (-t1.y * s2.x + t2.y * s1.x) / det
    guard a.isFinite, b.isFinite, c.isFinite, d.isFinite, a * d - b * c > 0,
      (0.4...2.5).contains(hypot(a, c)), (0.4...2.5).contains(hypot(b, d)), abs(a * b + c * d) / max(0.001, hypot(a, c) * hypot(b, d)) < 0.65 else { throw DeckError(message: "校准方向、比例或倾斜不合理，请按提示点击同一组按钮") }
    return LayoutTransform(a: a, b: b, c: c, d: d, tx: target[0].x - a * source[0].x - b * source[0].y, ty: target[0].y - c * source[0].x - d * source[0].y)
  }
  func apply(_ profile: Profile) throws -> Profile {
    var result = profile
    func valid(_ p: TouchPoint) throws -> TouchPoint {
      let value = point(p); guard value.x.isFinite, value.y.isFinite, (0...1).contains(value.x), (0...1).contains(value.y) else { throw DeckError(message: "部分触点校准后超出屏幕，请调整校准点") }; return value
    }
    for index in result.bindings.indices where result.bindings[index].mode != "audio" {
      let p = try valid(TouchPoint(x: result.bindings[index].x, y: result.bindings[index].y))
      result.bindings[index].x = p.x; result.bindings[index].y = p.y
      if let path = result.bindings[index].path { result.bindings[index].path = try path.map { let p = try valid(TouchPoint(x: $0.x, y: $0.y)); return GesturePoint(x: p.x, y: p.y, t: $0.t) } }
    }
    return try result.checked()
  }
}
