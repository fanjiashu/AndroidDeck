// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

@main struct GestureIntegration {
  static func main() throws {
    guard CommandLine.arguments.count >= 3 else { throw DeckError(message: "需要项目目录和设备 serial") }
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let serial = CommandLine.arguments[2]
    let runtime = AndroidRuntime(root: root)
    let input = InputEngine()
    let transport = ScrcpyTransport(
      runtime: runtime, serial: serial, preferences: Preferences(), direct: false, controlOnly: true
    )
    let file = "/sdcard/Android/data/com.androiddeck.demo/files/touch-events.jsonl"
    var checks: [[String: Any]] = []
    var logs: [String: [[String: Any]]] = [:]
    let rotation = try runtime.adbRun(
      ["shell", "settings", "get", "system", "user_rotation"], serial: serial)
    let auto = try runtime.adbRun(
      ["shell", "settings", "get", "system", "accelerometer_rotation"], serial: serial)
    func pump(_ duration: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: duration)) }
    func record(_ name: String, _ ok: Bool) { checks.append(["name": name, "passed": ok]) }
    func reset() throws {
      input.release()
      pump(0.08)
      _ = try runtime.adbRun(["shell", "rm", "-f", file], serial: serial)
    }
    func events(_ key: String) throws -> [[String: Any]] {
      FileHandle.standardError.write(Data("GESTURE_CASE \(key)\n".utf8))
      let raw = try runtime.adbRun(["shell", "cat", file], serial: serial)
      let values = raw.split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
      logs[key] = values
      return values
    }
    func lastPoint(_ event: [String: Any]?) -> (Int, Int)? {
      guard let points = event?["pointers"] as? [[String: Any]], let point = points.last,
        let x = point["x"] as? Int, let y = point["y"] as? Int
      else { return nil }
      return (x, y)
    }
    transport.onError = { FileHandle.standardError.write(Data(("STREAM_ERROR " + $0 + "\n").utf8)) }
    try transport.start()
    input.writer = { transport.send($0) }
    defer {
      input.release()
      pump(0.05)
      transport.close()
      _ = try? runtime.adbRun(
        ["shell", "settings", "put", "system", "user_rotation", rotation], serial: serial)
      _ = try? runtime.adbRun(
        ["shell", "settings", "put", "system", "accelerometer_rotation", auto], serial: serial)
      try? runtime.launch("com.tencent.tmgp.dnf", serial: serial)
    }
    _ = try runtime.adbRun(["shell", "am", "force-stop", "com.androiddeck.demo"], serial: serial)
    try runtime.launch("com.androiddeck.demo", serial: serial)
    _ = try runtime.adbRun(["shell", "cmd", "statusbar", "collapse"], serial: serial)
    pump(1.2)
    let windows = try runtime.adbRun(["shell", "dumpsys", "window"], serial: serial)
    guard
      windows.split(separator: "\n").contains(where: {
        $0.contains("mCurrentFocus=") && $0.contains("com.androiddeck.demo")
      })
    else { throw DeckError(message: "触控测试窗口未获得焦点") }
    let viewports = try runtime.adbRun(["shell", "dumpsys", "input"], serial: serial)
    let line =
      viewports.split(separator: "\n").first { $0.contains("Viewport INTERNAL: displayId=0,") }
      ?? ""
    let expression = try NSRegularExpression(pattern: "deviceSize=\\[([0-9]+), ([0-9]+)\\]")
    let text = String(line)
    guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let wr = Range(match.range(at: 1), in: text), let hr = Range(match.range(at: 2), in: text),
      let width = Int(text[wr]), let height = Int(text[hr])
    else { throw DeckError(message: "无法读取实际触控屏幕尺寸") }
    input.resize(width: width, height: height)
    let w = Double(width)
    let h = Double(height)
    let fingerRadius = Double(min(width, height)) * 0.1
    var profile = Profile.standard
    profile.bindings = [
      Binding(code: "KeyY", mode: "tap", x: 0.35, y: 0.4, label: "点击"),
      Binding(code: "KeyJ", mode: "hold", x: 0.8, y: 0.8, label: "按住"),
      Binding(code: "KeyQ", mode: "repeat", x: 0.7, y: 0.7, label: "连点", intervalMs: 80),
      Binding(
        code: "KeyG", mode: "swipe", x: 0.2, y: 0.3, label: "轨迹", durationMs: 300,
        path: [
          GesturePoint(x: 0.2, y: 0.3, t: 0), GesturePoint(x: 0.5, y: 0.5, t: 0.5),
          GesturePoint(x: 0.8, y: 0.6, t: 1),
        ]),
      Binding(
        code: "KeyE", mode: "pinch", x: 0.5, y: 0.5, label: "缩放", durationMs: 300, scale: 2,
        radius: 0.1),
      Binding(
        code: "KeyR", mode: "rotate", x: 0.5, y: 0.5, label: "旋转", durationMs: 300, rotation: 90,
        radius: 0.1),
    ]
    input.profile = try profile.checked()
    try reset()
    input.key("KeyY", true)
    input.key("KeyY", false)
    pump(0.12)
    let tap = try events("tap")
    record(
      "任意位置单击",
      tap.map { $0["action"] as? String ?? "" } == ["DOWN", "UP"]
        && lastPoint(tap.last).map {
          $0.0 == Int((0.35 * w).rounded()) && $0.1 == Int((0.4 * h).rounded())
        } == true)
    record("单击保留实际按压时间", (tap.last?["time"] as? Int ?? 0) - (tap.first?["time"] as? Int ?? 0) >= 60)
    try reset()
    input.key("KeyJ", true)
    pump(0.2)
    input.key("KeyJ", false)
    pump(0.12)
    let hold = try events("hold")
    record(
      "长按保持到松键",
      hold.first?["action"] as? String == "DOWN" && hold.last?["active"] as? Int == 0
        && ((hold.last?["time"] as? Int ?? 0) - (hold.first?["time"] as? Int ?? 0)) >= 180)
    try reset()
    input.key("KeyQ", true)
    pump(0.42)
    input.key("KeyQ", false)
    pump(0.1)
    let repeatEvents = try events("repeat")
    pump(0.15)
    let repeatedAfter = try events("repeatAfter")
    record(
      "连续点击且松键停止",
      repeatEvents.filter { $0["action"] as? String == "DOWN" }.count >= 4
        && repeatEvents.count == repeatedAfter.count && repeatEvents.last?["active"] as? Int == 0)
    var lastUp: Int?, releaseGaps: [Int] = [], pressSpans: [Int] = [], lastDown: Int?
    for event in repeatEvents {
      let time = event["time"] as? Int ?? 0
      if event["action"] as? String == "DOWN" { if let previous = lastUp { releaseGaps.append(time - previous) }; lastDown = time }
      if event["action"] as? String == "UP" { if let previous = lastDown { pressSpans.append(time - previous) }; lastUp = time }
    }
    record("连点包含按压时长和独立释放间隔", !releaseGaps.isEmpty && releaseGaps.allSatisfy { $0 >= 5 } && pressSpans.dropLast().allSatisfy { $0 >= 25 })
    try reset()
    input.key("KeyG", true)
    input.key("KeyG", false)
    pump(0.4)
    let swipe = try events("swipe")
    record(
      "录制轨迹按顺序执行到终点",
      swipe.first?["action"] as? String == "DOWN"
        && swipe.filter { $0["action"] as? String == "MOVE" }.count > 5
        && lastPoint(swipe.last).map {
          $0.0 == Int((0.8 * w).rounded()) && $0.1 == Int((0.6 * h).rounded())
        } == true && swipe.last?["active"] as? Int == 0)
    try reset()
    input.key("KeyE", true)
    input.key("KeyE", false)
    pump(0.4)
    let pinch = try events("pinch")
    record(
      "缩放注入真实双指序列",
      pinch.contains { $0["action"] as? String == "POINTER_DOWN" && $0["count"] as? Int == 2 }
        && pinch.contains { $0["action"] as? String == "POINTER_UP" }
        && pinch.last?["active"] as? Int == 0)
    record(
      "缩放到指定距离",
      lastPoint(pinch.last).map {
        $0.0 == Int((w / 2 + fingerRadius * 2).rounded()) && $0.1 == Int((h / 2).rounded())
      } == true)
    try reset()
    input.key("KeyR", true)
    input.key("KeyR", false)
    pump(0.4)
    let turn = try events("rotate")
    record(
      "双指旋转到指定角度",
      turn.contains { $0["count"] as? Int == 2 }
        && lastPoint(turn.last).map {
          $0.0 == Int((w / 2).rounded()) && $0.1 == Int((h / 2 + fingerRadius).rounded())
        } == true && turn.last?["active"] as? Int == 0)
    try reset()
    input.key("KeyW", true)
    input.key("KeyE", true)
    input.key("KeyE", false)
    pump(0.2)
    input.key("KeyW", false)
    pump(0.2)
    let concurrent = try events("concurrent")
    record(
      "摇杆与双指手势同时操作",
      concurrent.contains { $0["count"] as? Int == 3 } && concurrent.last?["active"] as? Int == 0)
    try reset()
    input.key("KeyG", true)
    input.key("KeyG", false)
    pump(0.08)
    input.release()
    pump(0.1)
    let cancelled = try events("cancel")
    pump(0.3)
    let cancelledAfter = try events("cancelAfter")
    record(
      "取消预览和失焦后无迟到触控",
      cancelled.last?["active"] as? Int == 0 && cancelled.count == cancelledAfter.count)
    try reset()
    input.key("KeyQ", true)
    pump(0.15)
    var changed = profile
    changed.bindings[0].x = 0.4
    input.profile = changed
    pump(0.1)
    let switched = try events("switch")
    pump(0.15)
    let switchedAfter = try events("switchAfter")
    record(
      "切换配置停止连点与所有触点",
      switched.count == switchedAfter.count && switched.last?["active"] as? Int == 0)
    input.profile = profile
    try reset()
    for id in 2000..<2009 { input.touch(0, id, 0.2, 0.2) }
    input.key("KeyE", true)
    input.key("KeyE", false)
    pump(0.08)
    input.release()
    pump(0.1)
    let capacity = try events("capacity")
    record(
      "触点不足时拒绝整个双指手势",
      capacity.map { $0["count"] as? Int ?? 0 }.max() == 9 && capacity.last?["active"] as? Int == 0)
    let result: [String: Any] = [
      "checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true },
      "events": logs,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appendingPathComponent("data/gesture-integration-report.json"))
    print("Gesture integration: \(checks.count) checks, passed=\(result["passed"]!)")
    guard result["passed"] as? Bool == true else { throw DeckError(message: "触屏映射测试失败，请查看报告") }
  }
}
