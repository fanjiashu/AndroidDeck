// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum DeckContentKind: String {
  case app, game
  var title: String { self == .game ? "游戏" : "应用" }
}
enum DeckResolution: String, CaseIterable {
  case hd, fullHD, quadHD, ultraHD
  var width: Int { self == .hd ? 720 : self == .fullHD ? 1080 : self == .quadHD ? 1440 : 2160 }
  var height: Int { width * 16 / 9 }
  var density: Int { width / 3 }
  var title: String { self == .ultraHD ? "4K · 3840 × 2160" : "\(width) × \(height)" }
}
enum DeckOrientation: String, CaseIterable {
  case automatic, portrait, landscape, followApp
  var title: String {
    switch self {
    case .automatic: return "默认（按应用类型）"
    case .portrait: return "竖屏"
    case .landscape: return "横屏"
    case .followApp: return "跟随应用旋转"
    }
  }
}
struct DeckDisplayOptions: Codable, Equatable {
  var resolution = "hd"
  var orientation = "automatic"
  var size: DeckResolution { DeckResolution(rawValue: resolution) ?? .hd }
  var direction: DeckOrientation { DeckOrientation(rawValue: orientation) ?? .automatic }
  func spec(kind: DeckContentKind) -> DeckDisplaySpec {
    let direction = self.direction == .automatic ? (kind == .game ? DeckOrientation.landscape : .portrait) : self.direction
    return DeckDisplaySpec(width: size.width, height: size.height, density: size.density,
      rotation: direction == .followApp ? nil : direction == .landscape ? 1 : 0)
  }
}
struct DeckDisplaySpec: Equatable {
  let width: Int, height: Int, density: Int
  let rotation: Int?
  var resolution: DeckResolution { DeckResolution.allCases.first { $0.width == width && $0.height == height } ?? .hd }
  func using(_ resolution: DeckResolution) -> DeckDisplaySpec {
    DeckDisplaySpec(width: resolution.width, height: resolution.height, density: resolution.density, rotation: rotation)
  }
}

enum AppInteraction {
  static let remoteTitle = "内置 · 应用遥控"
  static let knownGames: Set<String> = ["com.tencent.tmgp.dnf", "com.androiddeck.demo", "com.tencent.tmgp.sgame", "com.tencent.tmgp.pubgmhd", "com.tencent.ig"]
  static let builtinNames: [String: String] = [
    "com.androiddeck.demo": "触控试验场", "com.tencent.tmgp.dnf": "地下城与勇士：起源",
    "com.phoenix.read": "红果短剧", "com.tencent.tmgp.sgame": "王者荣耀",
    "com.tencent.tmgp.pubgmhd": "和平精英",
  ]
  static func kind(package: String, preferences: Preferences, androidIsGame: Bool = false, gameScheme: Bool = false) -> DeckContentKind {
    if let override = preferences.contentKinds?[package], let kind = DeckContentKind(rawValue: override) { return kind }
    if knownGames.contains(package) { return .game }
    if package == "com.phoenix.read" { return .app }
    return androidIsGame || gameScheme ? .game : .app
  }
  static func androidGameMetadata(_ text: String) -> Bool {
    text.range(of: #"(?m)^\s*(?:appCategory|category)=0(?:\s|$)"#, options: .regularExpression) != nil
      || text.range(of: #"(?m)^\s*(?:flags|privateFlags)=\[[^\n\]]*\bIS_GAME\b"#, options: .regularExpression) != nil
  }
  static func remoteProfile() -> Profile {
    var p = Profile.standard
    p.joystick.enabled = false
    p.joystick.visible = false
    func page(_ code: String, _ label: String, _ start: Double, _ end: Double) -> Binding {
      Binding(code: code, mode: "swipe", x: 0.5, y: start, label: label, visible: false, durationMs: 280,
        path: [GesturePoint(x: 0.5, y: start, t: 0), GesturePoint(x: 0.5, y: end, t: 1)])
    }
    p.bindings = [
      page("ArrowUp", "上一页", 0.3, 0.75), page("ArrowDown", "下一页", 0.75, 0.3),
      Binding(code: "Space", mode: "tap", x: 0.5, y: 0.5, label: "点击 / 暂停", visible: false),
      page("PageUp", "上一页（PgUp）", 0.3, 0.75), page("PageDown", "下一页（PgDn）", 0.75, 0.3),
      Binding(code: "Enter", mode: "tap", x: 0.5, y: 0.5, label: "点击（Enter）", visible: false)
    ]
    return p.withDefaultSoundKeys()
  }
  @discardableResult static func registerRemote(package: String, profiles: inout [String: Profile], preferences: inout Preferences, select: Bool = false) -> Bool {
    let key = MappingStore.key(package: package, scheme: remoteTitle)
    var changed = false
    if profiles[key] == nil { profiles[key] = remoteProfile(); changed = true }
    if preferences.remoteDefaultsApplied?[package] != true || select {
      if preferences.remoteDefaultsApplied == nil { preferences.remoteDefaultsApplied = [:] }
      if preferences.profileSelections == nil { preferences.profileSelections = [:] }
      // An existing default may be deliberately empty; only a fresh package is auto-selected.
      if select || (profiles[package] == nil && (preferences.profileSelections?[package] ?? "").isEmpty) {
        preferences.profileSelections![package] = remoteTitle
      }
      preferences.remoteDefaultsApplied![package] = true; changed = true
    }
    return changed
  }
}

extension AndroidRuntime {
  func applyDisplay(_ spec: DeckDisplaySpec, serial: String) throws {
    guard owns(serial), appliedDisplay != spec else { return }
    guard resolution == spec.resolution else { throw DeckError(message: "改变物理分辨率需要重启 Android") }
    if appliedDisplay == nil {
      // Drop legacy logical overrides; the AVD itself now owns the real GPU framebuffer size.
      _ = try adbRun(["shell", "wm", "size", "reset"], serial: serial)
      _ = try adbRun(["shell", "wm", "density", "reset"], serial: serial)
    }
    if appliedDisplay == nil || appliedDisplay?.rotation != spec.rotation {
      _ = try adbRun(["shell", "wm", "set-ignore-orientation-request", spec.rotation == nil ? "false" : "true"], serial: serial)
      _ = try adbRun(["shell", "wm", "fixed-to-user-rotation", spec.rotation == nil ? "disabled" : "enabled"], serial: serial)
      if let rotation = spec.rotation {
        _ = try adbRun(["shell", "wm", "user-rotation", "lock", String(rotation)], serial: serial)
      } else {
        _ = try adbRun(["shell", "wm", "user-rotation", "free"], serial: serial)
      }
      _ = try adbRun(["shell", "settings", "put", "system", "accelerometer_rotation", spec.rotation == nil ? "1" : "0"], serial: serial)
      if let rotation = spec.rotation {
        _ = try adbRun(["shell", "settings", "put", "system", "user_rotation", String(rotation)], serial: serial)
      }
    }
    appliedDisplay = spec
  }
}
