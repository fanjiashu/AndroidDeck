// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct StorageRuntimeTests {
  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    guard ["/private/tmp/AndroidDeck-storage-", "/tmp/AndroidDeck-storage-"].contains(where: { root.path.hasPrefix($0) }) else {
      throw DeckError(message: "仅允许隔离设备存储验证")
    }
    let runtime = AndroidRuntime(root: root)
    runtime.resolution = .hd
    runtime.log = { print($0); fflush(stdout) }
    defer { runtime.stop(saveQuickBoot: false) }
    var checks: [[String: Any]] = []
    var report: [String: Any] = [:]
    func check(_ name: String, _ value: Bool) throws {
      checks.append(["name": name, "passed": value])
      print("\(value ? "PASS" : "FAIL") \(name)"); fflush(stdout)
      if !value { throw DeckError(message: name) }
    }
    do {
      var serial = try runtime.start(allowQuickRestore: false)
      let info = try runtime.deviceInformation(serial: serial)
      report["deviceInfo"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info))
      try check("实际文件系统接近100GB且剩余超过60GB", info.diskTotal > 98 * (1 << 30) && info.diskAvailable > 60 * (1 << 30))
      let block = try runtime.adbRun(["shell", "su", "0", "blockdev", "--getsize64", "/dev/block/dm-37"], serial: serial)
      try check("加密块设备容量为100GiB", block == "107374182400")
      let header = try runtime.adbRun(["shell", "su", "0", "tune2fs", "-l", "/dev/block/dm-37"], serial: serial)
      try check("文件系统UUID保留且块数达到100GiB", header.contains("57f8f4bc-abf4-655f-bf67-946fc0f9f25b") && header.contains("26214400"))
      let packages = try runtime.adbRun(["shell", "pm", "list", "packages", "-3"], serial: serial)
      report["packages"] = packages
      try check("四款应用及触控试验场保留", ["com.androiddeck.demo", "com.tencent.tmgp.dnf", "com.phoenix.read", "com.tencent.tmgp.sgame", "com.tencent.tmgp.pubgmhd"].allSatisfy { packages.contains($0) })
      try runtime.applyDisplay(DeckDisplayOptions(resolution: "hd", orientation: "landscape").spec(kind: .game), serial: serial)
      try runtime.launch("com.tencent.tmgp.dnf", serial: serial)
      Thread.sleep(forTimeInterval: 8)
      try check("扩容后地下城能够启动", !(try runtime.adbRun(["shell", "pidof", "com.tencent.tmgp.dnf"], serial: serial)).isEmpty)
      try runtime.launch("com.tencent.tmgp.pubgmhd", serial: serial)
      Thread.sleep(forTimeInterval: 30)
      try check("扩容后和平精英稳定启动", !(try runtime.adbRun(["shell", "pidof", "com.tencent.tmgp.pubgmhd"], serial: serial)).isEmpty)
      runtime.stop()
      serial = try runtime.start()
      let restored = try runtime.deviceInformation(serial: serial)
      try check("快速恢复后100GB容量保留", restored.diskTotal > 98 * (1 << 30) && restored.diskAvailable > 60 * (1 << 30))
      try runtime.launch("com.tencent.tmgp.pubgmhd", serial: serial)
      Thread.sleep(forTimeInterval: 20)
      try check("快速恢复后游戏仍正常启动", !(try runtime.adbRun(["shell", "pidof", "com.tencent.tmgp.pubgmhd"], serial: serial)).isEmpty)
      report["passed"] = true
    } catch { report["passed"] = false; report["error"] = error.localizedDescription }
    report["checks"] = checks
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("data/storage-runtime-report.json"))
    print("存储验证完成"); fflush(stdout)
    if report["passed"] as? Bool != true { exit(1) }
  }
}
