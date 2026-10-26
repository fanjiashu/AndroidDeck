// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct EGLRuntimeTests {
  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
    let avd = root.appendingPathComponent("data/avd").resolvingSymlinksInPath()
    guard ["/private/tmp/AndroidDeck-pubgm-", "/tmp/AndroidDeck-pubgm-"].contains(where: { root.path.hasPrefix($0) }),
      avd.path.hasPrefix(root.path + "/") else {
      throw DeckError(message: "图形验证只能运行在隔离的测试设备目录")
    }
    let runtime = AndroidRuntime(root: root)
    runtime.log = { print($0); fflush(stdout) }
    runtime.resolution = .hd
    defer { runtime.stop(saveQuickBoot: false) }
    let package = "com.tencent.tmgp.pubgmhd"
    let destination = root.appendingPathComponent("data/egl-runtime-report.json")
    var checks: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) throws {
      checks.append(["name": name, "passed": passed])
      print("\(passed ? "PASS" : "FAIL") \(name)"); fflush(stdout)
      guard passed else { throw DeckError(message: name) }
    }
    func screenshot(_ name: String, _ serial: String) throws {
      let guest = "/data/local/tmp/androiddeck-egl-screen.png"
      _ = try runtime.adbRun(["shell", "screencap", "-p", guest], serial: serial)
      _ = try runtime.adbRun(["pull", guest, root.appendingPathComponent("data/" + name + ".png").path], serial: serial)
    }
    func stable(_ seconds: Int, serial: String) throws -> String {
      var pid = ""
      for second in 1...seconds {
        Thread.sleep(forTimeInterval: 1)
        let current = try runtime.adbRun(["shell", "pidof", package], serial: serial)
        if current.isEmpty || (!pid.isEmpty && current != pid) { return "" }
        pid = current
        if second % 30 == 0 { print("和平精英稳定运行 \(second) 秒"); fflush(stdout) }
      }
      return pid
    }
    var report: [String: Any] = ["canonicalDeviceModified": false]
    do {
      let serial = try runtime.start(allowQuickRestore: false)
      report["coldBootMilliseconds"] = runtime.bootElapsedMs
      let driverHash = try EGLCompatibility.checksum(in: runtime.adbRun(["shell", "sha256sum", EGLCompatibility.driver], serial: serial))
      try check("生产启动流程加载修正驱动", driverHash == EGLCompatibility.correctedSHA256)
      let gpu = try runtime.adbRun(["shell", "dumpsys", "SurfaceFlinger"], serial: serial)
      report["guestGPU"] = gpu.split(separator: "\n").first(where: { $0.contains("GLES:") }).map(String.init) ?? ""
      try check("仍使用 Apple M4 硬件渲染", gpu.contains("Apple M4") && !gpu.contains("SwiftShader"))
      try runtime.applyDisplay(DeckDisplayOptions(resolution: "hd", orientation: "landscape").spec(kind: .game), serial: serial)
      _ = try runtime.adbRun(["shell", "am", "force-stop", package], serial: serial)
      _ = try runtime.adbRun(["logcat", "-c"], serial: serial)
      try runtime.launch(package, serial: serial)
      let firstPID = try stable(90, serial: serial)
      try check("和平精英首次启动持续 90 秒无崩溃", !firstPID.isEmpty)
      try screenshot("egl-pubgm-stable-90s", serial)
      let inode = try runtime.adbRun(["shell", "stat", "-c", "%i", EGLCompatibility.driver], serial: serial)
      let maps = try runtime.adbRun(["shell", "su", "0", "cat", "/proc/" + firstPID + "/maps"], serial: serial)
      let eglMappings = maps.split(separator: "\n").filter { $0.contains("libEGL_emulation.so") }
      report["gameDriverMappings"] = eglMappings.map(String.init)
      try check("游戏进程映射修正驱动的实际 inode", eglMappings.contains { $0.split(whereSeparator: { $0.isWhitespace }).dropFirst(4).first.map(String.init) == inode })
      for attempt in 1...2 {
        _ = try runtime.adbRun(["shell", "am", "force-stop", package], serial: serial)
        try runtime.launch(package, serial: serial)
        try check("和平精英重复启动 \(attempt) 稳定 30 秒", !(try stable(30, serial: serial)).isEmpty)
      }
      let log = try runtime.adbRun(["logcat", "-d", "-v", "threadtime"], serial: serial)
      try check("没有原先的空函数指针或 EGL 标志崩溃", !log.contains("Fatal signal 11") && !log.contains("eglCreateContext(1755)"))
      for (app, orientation) in [("com.tencent.tmgp.dnf", "landscape"), ("com.phoenix.read", "portrait")] {
        _ = try runtime.adbRun(["shell", "am", "force-stop", package], serial: serial)
        try runtime.applyDisplay(DeckDisplayOptions(resolution: "hd", orientation: orientation).spec(kind: app == "com.phoenix.read" ? .app : .game), serial: serial)
        try runtime.launch(app, serial: serial)
        Thread.sleep(forTimeInterval: 12)
        let pid = try runtime.adbRun(["shell", "pidof", app], serial: serial)
        try check("\(app) 启动回归正常", !pid.isEmpty)
      }
      try runtime.applyDisplay(DeckDisplayOptions(resolution: "hd", orientation: "landscape").spec(kind: .game), serial: serial)
      try runtime.launch(package, serial: serial)
      try check("切回和平精英稳定运行", !(try stable(30, serial: serial)).isEmpty)
      let key = try runtime.bootCompatibilityKey()
      runtime.stop()
      try check("包含驱动身份的快速启动快照有效", runtime.quickBoot.eligible(key: key) != nil)
      let restored = try runtime.start()
      report["restoreBootMilliseconds"] = runtime.bootElapsedMs
      let restoredHash = try EGLCompatibility.checksum(in: runtime.adbRun(["shell", "sha256sum", EGLCompatibility.driver], serial: restored))
      try check("快速恢复后驱动校验正确", restoredHash == EGLCompatibility.correctedSHA256)
      try runtime.launch(package, serial: restored)
      try check("快速恢复后和平精英稳定运行 30 秒", !(try stable(30, serial: restored)).isEmpty)
      try screenshot("egl-pubgm-after-quickboot", restored)
      report["passed"] = true
    } catch {
      report["passed"] = false; report["error"] = error.localizedDescription
    }
    report["checks"] = checks
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
    print(destination.path); fflush(stdout)
    if report["passed"] as? Bool != true { exit(1) }
  }
}
