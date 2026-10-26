// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

@main struct JoystickIntegration {
  static func main() throws {
    guard CommandLine.arguments.count >= 3 else {
      throw DeckError(message: "用法: joystick-tests 项目目录 serial")
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let serial = CommandLine.arguments[2]
    let runtime = AndroidRuntime(root: root)
    let stream = ScrcpyTransport(
      runtime: runtime, serial: serial, preferences: Preferences(), direct: false, controlOnly: true
    )
    let input = InputEngine()
    var checks: [[String: Any]] = []
    var eventGroups: [String: [[String: Any]]] = [:]
    let originalRotation = try runtime.adbRun(
      ["shell", "settings", "get", "system", "user_rotation"], serial: serial)
    let originalAuto = try runtime.adbRun(
      ["shell", "settings", "get", "system", "accelerometer_rotation"], serial: serial)
    let logPath = "/sdcard/Android/data/com.androiddeck.demo/files/touch-events.jsonl"
    func pump(_ duration: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: duration)) }
    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
      checks.append(["name": name, "passed": passed, "detail": detail])
    }
    func reset() throws {
      input.release()
      pump(0.08)
      _ = try runtime.adbRun(["shell", "rm", "-f", logPath], serial: serial)
    }
    func events(_ name: String) throws -> [[String: Any]] {
      let text = try runtime.adbRun(["shell", "cat", logPath], serial: serial)
      let events = text.split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
      eventGroups[name] = events
      return events
    }
    func firstPoint(_ event: [String: Any]) -> (Int, Int)? {
      guard let pointers = event["pointers"] as? [[String: Any]], let point = pointers.first,
        let x = point["x"] as? Int, let y = point["y"] as? Int
      else { return nil }
      return (x, y)
    }
    try stream.start()
    input.writer = { stream.send($0) }
    defer {
      input.release()
      pump(0.05)
      stream.close()
      _ = try? runtime.adbRun(
        ["shell", "settings", "put", "system", "user_rotation", originalRotation], serial: serial)
      _ = try? runtime.adbRun(
        ["shell", "settings", "put", "system", "accelerometer_rotation", originalAuto],
        serial: serial)
      try? runtime.launch("com.tencent.tmgp.dnf", serial: serial)
    }
    let exact = try runtime.adbRun(["shell", "getprop", "ro.input.resampling"], serial: serial)
    record("实际 Android 已启用精确触控", exact == "0", "ro.input.resampling=\(exact)")
    _ = try runtime.adbRun(["shell", "am", "force-stop", "com.androiddeck.demo"], serial: serial)
    try runtime.launch("com.androiddeck.demo", serial: serial)
    for rotation in ["0", "1"] {
      _ = try runtime.adbRun(
        ["shell", "settings", "put", "system", "accelerometer_rotation", "0"], serial: serial)
      _ = try runtime.adbRun(
        ["shell", "settings", "put", "system", "user_rotation", rotation], serial: serial)
      pump(0.7)
      input.width = rotation == "0" ? 720 : 1280
      input.height = rotation == "0" ? 1280 : 720
      for (key, direction) in [
        ("KeyW", (0, -1)), ("KeyA", (-1, 0)), ("KeyS", (0, 1)), ("KeyD", (1, 0)),
      ] {
        try reset()
        input.key(key, true)
        pump(0.5)
        input.key(key, false)
        pump(0.12)
        let values = try events(rotation + key)
        let moves = values.filter { $0["action"] as? String == "MOVE" }
        let expectedX = Int((0.22 * Double(input.width) + Double(direction.0) * 64.8).rounded())
        let expectedY = Int((0.73 * Double(input.height) + Double(direction.1) * 64.8).rounded())
        let positionsCorrect = moves.allSatisfy { value in
          guard let point = firstPoint(value) else { return false }
          return abs(point.0 - expectedX) <= 2 && abs(point.1 - expectedY) <= 2
        }
        let end = values.last
        let point = end.flatMap(firstPoint)
        let stopped = values.count
        pump(0.15)
        let after = try events(rotation + key + "After")
        record(
          "\(rotation == "0" ? "竖屏" : "横屏") \(key) 连续方向与释放",
          values.first?["action"] as? String == "DOWN" && moves.count >= 4 && positionsCorrect
            && end?["action"] as? String == "UP" && end?["active"] as? Int == 0
            && point.map { abs($0.0 - expectedX) <= 2 && abs($0.1 - expectedY) <= 2 } == true
            && after.count == stopped,
          "MOVE \(moves.count)，目标 \(expectedX),\(expectedY)")
      }
    }
    try reset()
    input.key("KeyW", true)
    input.key("KeyD", true)
    pump(0.15)
    input.key("KeyW", false)
    pump(0.15)
    input.key("KeyD", false)
    pump(0.1)
    let transitions = try events("diagonalTransition")
    let expectedD = (346, 526)
    let diagonal = (327, 480)
    let expectedW = (282, 461)
    let allowed = [expectedD, diagonal, expectedW]
    let transitionCoordinates = transitions.filter { $0["action"] as? String == "MOVE" }.allSatisfy
    { event in
      guard let p = firstPoint(event) else { return false }
      return allowed.contains { abs(p.0 - $0.0) <= 1 && abs(p.1 - $0.1) <= 1 }
    }
    record(
      "斜向切换复用同一个触点且坐标精确",
      transitions.filter { $0["action"] as? String == "DOWN" }.count == 1
        && transitions.filter { $0["action"] as? String == "UP" }.count == 1
        && transitions.allSatisfy { $0["count"] as? Int == 1 } && transitionCoordinates
        && transitions.last.flatMap(firstPoint).map {
          abs($0.0 - expectedD.0) <= 1 && abs($0.1 - expectedD.1) <= 1
        } == true)
    try reset()
    input.key("KeyW", true)
    input.key("KeyS", true)
    pump(0.15)
    input.key("KeyS", false)
    pump(0.15)
    input.key("KeyW", false)
    pump(0.1)
    let opposing = try events("opposing")
    let centerY = Int((0.73 * Double(input.height)).rounded())
    record(
      "相反方向回中后精确恢复方向",
      opposing.contains {
        $0["action"] as? String == "MOVE" && firstPoint($0).map { abs($0.1 - centerY) <= 1 } == true
      } && opposing.last?["active"] as? Int == 0
        && opposing.last.flatMap(firstPoint).map {
          abs($0.0 - expectedW.0) <= 1 && abs($0.1 - expectedW.1) <= 1
        } == true)
    try reset()
    input.key("KeyW", true)
    input.key("KeyW", false)
    pump(0.12)
    let quick = try events("quickTap")
    record("快速点按包含完整拖动与抬起", quick.map { $0["action"] as? String ?? "" } == ["DOWN", "MOVE", "UP"])
    try reset()
    input.key("KeyW", true)
    input.key("Space", true)
    pump(0.18)
    input.key("KeyW", false)
    pump(0.12)
    input.key("Space", false)
    pump(0.12)
    let dual = try events("dualTouch")
    record(
      "移动与动作双指互不释放",
      dual.contains { $0["count"] as? Int == 2 }
        && dual.contains { $0["action"] as? String == "POINTER_UP" && $0["active"] as? Int == 1 }
        && dual.last?["active"] as? Int == 0)
    try reset()
    input.key("KeyW", true)
    pump(0.1)
    input.release()
    pump(0.1)
    let released = try events("releaseAll")
    pump(0.15)
    let afterRelease = try events("releaseAllAfter")
    record(
      "失焦及退出释放后无迟到 MOVE",
      released.last?["action"] as? String == "UP" && released.count == afterRelease.count)
    let result: [String: Any] = [
      "checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true },
      "events": eventGroups,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appendingPathComponent("data/joystick-integration-report.json"))
    print("Joystick integration: \(checks.count) checks, passed=\(result["passed"]!)")
    guard result["passed"] as? Bool == true else {
      throw DeckError(message: "方向触控集成检查失败，请查看 joystick-integration-report.json")
    }
  }
}
