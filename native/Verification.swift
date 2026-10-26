// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

extension AppDelegate {
  // Opt-in integration checks run only against our own TouchLab/AVD.
  func verifyNative(serial initial: String) throws -> [String: Any] {
    guard runtime.owns(initial), activePackage == "com.androiddeck.demo" else {
      throw DeckError(message: "验证仅用于本地触控试验场")
    }
    let foreground = try runtime.adbRun(["shell", "dumpsys", "activity", "activities"], serial: initial)
    guard ReadySchemeCatalogue.foregroundPackage(in: foreground) == "com.androiddeck.demo" else { throw DeckError(message: "前台应用已改变，触控验证停止") }
    var checks: [[String: Any]] = []
    func record(_ name: String, _ ok: Bool, _ detail: String = "") {
      checks.append(["name": name, "passed": ok, "detail": detail])
    }
    let originalRotation =
      (try? runtime.adbRun(
        ["shell", "settings", "get", "system", "user_rotation"], serial: initial)) ?? "0"
    let originalAuto =
      (try? runtime.adbRun(
        ["shell", "settings", "get", "system", "accelerometer_rotation"], serial: initial)) ?? "0"
    DispatchQueue.main.sync {
      self.input.release()
      self.busy = true
      self.updateControls()
      self.input.profile = .standard
      let p = self.rootView.canvas.profile
      let show = self.rootView.canvas.showMarkers
      let edit = self.rootView.canvas.editing
      self.rootView.canvas.profile = .standard
      self.rootView.canvas.showMarkers = false
      record("全局隐藏映射标记", self.rootView.canvas.markers().isEmpty)
      self.rootView.canvas.showMarkers = true
      self.rootView.canvas.profile.bindings[0].visible = false
      record("单独隐藏一个映射标记", self.rootView.canvas.markers().count == 2)
      self.rootView.canvas.editing = true
      record("编辑时恢复全部标记", self.rootView.canvas.markers().count == 3)
      self.rootView.canvas.profile = p
      self.rootView.canvas.showMarkers = show
      self.rootView.canvas.editing = edit
      self.input.key("KeyW", true)
      self.input.key("Space", true)
    }
    Thread.sleep(forTimeInterval: 0.3)
    DispatchQueue.main.sync { self.input.release() }
    Thread.sleep(forTimeInterval: 0.2)
    let firstEvents = try runtime.adbRun(
      ["shell", "cat", "/sdcard/Android/data/com.androiddeck.demo/files/touch-events.jsonl"],
      serial: initial)
    record("摇杆和动作键真实双指触控", firstEvents.contains("\"count\":2"))
    record(
      "释放后 Android 无残留触点", firstEvents.split(separator: "\n").last?.contains("\"active\":0") == true
    )
    for rotation in ["0", "1"] {
      DispatchQueue.main.sync { self.input.release() }
      let display = DeckDisplayOptions(resolution: runtime.resolution.rawValue,
        orientation: rotation == "0" ? "portrait" : "landscape").spec(kind: .game)
      try runtime.applyDisplay(display, serial: initial)
      var size = (0, 0)
      for _ in 0..<50 {
        DispatchQueue.main.sync { size = (self.input.width, self.input.height) }
        if size.0 > 0 && (size.0 > size.1) == (rotation == "1") { break }
        Thread.sleep(forTimeInterval: 0.1)
      }
      Thread.sleep(forTimeInterval: 0.4)
      _ = try runtime.adbRun(
        [
          "shell", "rm", "-f", "/sdcard/Android/data/com.androiddeck.demo/files/touch-events.jsonl",
        ], serial: initial)
      let points: [(Double, Double)] = [
        (0.05, 0.05), (0.95, 0.05), (0.5, 0.5), (0.05, 0.95), (0.95, 0.95),
      ]
      for point in points {
        DispatchQueue.main.sync { self.input.touch(0, 1, point.0, point.1) }
        Thread.sleep(forTimeInterval: 0.04)
        DispatchQueue.main.sync { self.input.touch(1, 1, point.0, point.1) }
        Thread.sleep(forTimeInterval: 0.04)
      }
      Thread.sleep(forTimeInterval: 0.2)
      let events = try runtime.adbRun(
        ["shell", "cat", "/sdcard/Android/data/com.androiddeck.demo/files/touch-events.jsonl"],
        serial: initial)
      let down = events.split(separator: "\n").compactMap { line -> [String: Any]? in
        guard
          let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          object["action"] as? String == "DOWN"
        else { return nil }
        return object
      }
      let correct =
        (size.0 > size.1) == (rotation == "1") && down.count == 5
        && down.enumerated().allSatisfy { i, event in
          guard let pointers = event["pointers"] as? [[String: Any]], let p = pointers.first,
            let x = p["x"] as? Int, let y = p["y"] as? Int
          else { return false }
          return abs(x - Int((points[i].0 * Double(size.0)).rounded())) <= 2
            && abs(y - Int((points[i].1 * Double(size.1)).rounded())) <= 2
        }
      record(
        rotation == "0" ? "竖屏中心及四角真实坐标" : "横屏中心及四角真实坐标", correct,
        "\(size.0) × \(size.1)，收到 \(down.count) 次 DOWN")
    }
    _ = try runtime.adbRun(
      ["shell", "settings", "put", "system", "user_rotation", originalRotation], serial: initial)
    _ = try runtime.adbRun(
      ["shell", "settings", "put", "system", "accelerometer_rotation", originalAuto],
      serial: initial)
    DispatchQueue.main.sync {
      self.input.release()
      self.fullscreen(nil)
    }
    Thread.sleep(forTimeInterval: 1.5)
    DispatchQueue.main.sync {
      record("原生全屏进入", self.rootView.full && self.window.styleMask.contains(.fullScreen))
      self.fullscreen(nil)
    }
    Thread.sleep(forTimeInterval: 1.5)
    DispatchQueue.main.sync {
      record("原生全屏退出", !self.rootView.full)
      self.rootView.savePreview(self.root.appendingPathComponent("data/verified-native.png"))
    }
    let probePath = "/sdcard/Android/data/com.androiddeck.demo/files/restart-probe.txt"
    let probe: String
    if let existing = try? runtime.adbRun(["shell", "cat", probePath], serial: initial) { probe = existing }
    else {
      let file = root.appendingPathComponent("data/native-restart-probe.txt")
      probe = UUID().uuidString
      try Data((probe + "\n").utf8).write(to: file)
      _ = try runtime.adbRun(["push", file.path, probePath], serial: initial)
    }
    try runtime.install(root.appendingPathComponent("assets/TouchLab.apk"), serial: initial)
    try runtime.launch("com.androiddeck.demo", serial: initial)
    record(
      "Swift 原生 APK 安装与启动",
      try runtime.adbRun(["shell", "pidof", "com.androiddeck.demo"], serial: initial).isEmpty
        == false)
    record("覆盖安装保留应用数据", try runtime.adbRun(["shell", "cat", probePath], serial: initial) == probe)
    transport?.close()
    transport = nil
    runtime.stop()
    runtime.ramMb = 8192
    let next = try runtime.start()
    try connectStream(next, package: "com.androiddeck.demo")
    let memory = try runtime.adbRun(["shell", "cat", "/proc/meminfo"], serial: next)
    let total =
      memory.split(separator: "\n").first(where: { $0.hasPrefix("MemTotal:") })?.split(
        whereSeparator: { $0.isWhitespace }).dropFirst().first.flatMap { Int($0) } ?? 0
    record("八 GB 运存真实生效", total > 7 * 1024 * 1024, "MemTotal \(total) KiB")
    record("重启保留应用数据", try runtime.adbRun(["shell", "cat", probePath], serial: next) == probe)
    record(
      "DNF 保留安装",
      try runtime.adbRun(["shell", "pm", "path", "com.tencent.tmgp.dnf"], serial: next).contains(
        "base.apk"))
    record("重启恢复原始帧直连", transport?.rawMode == true)
    DispatchQueue.main.sync {
      self.input.release()
      self.input.profile = self.profile
      self.busy = false
      self.updateControls()
    }
    runtime.ramMb = prefs.ramMb
    return [
      "checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true },
      "scene": "TouchLab",
    ]
  }
}
