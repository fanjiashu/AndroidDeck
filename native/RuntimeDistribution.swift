// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

struct BuiltinApplication: Codable {
  let package: String
  let name: String
  let file: String
  let versionCode: Int
  let sha256: String
}
struct RuntimeSeedManifest: Codable {
  let version: Int
  let apps: [BuiltinApplication]
}

final class RuntimeDistribution {
  let seed: URL?
  let progress: (String) -> Void
  init(seed: URL?, progress: @escaping (String) -> Void = { _ in }) {
    self.seed = seed; self.progress = progress
  }
  private func ready(at root: URL) -> Bool {
    let fm = FileManager.default, sdk = root.appendingPathComponent(".runtime/sdk")
    return (fm.isExecutableFile(atPath: sdk.appendingPathComponent("emulator/emulator-bin").path)
      || fm.isExecutableFile(atPath: sdk.appendingPathComponent("emulator/emulator").path))
      && fm.isExecutableFile(atPath: sdk.appendingPathComponent("platform-tools/adb").path)
      && fm.fileExists(atPath: root.appendingPathComponent("assets/scrcpy-server").path)
  }
  private func resource(_ relative: String) throws -> URL {
    guard let seed = seed, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw DeckError(message: "内置运行资源路径无效") }
    let base = seed.resolvingSymlinksInPath().standardizedFileURL
    let file = seed.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(base.path + "/") else { throw DeckError(message: "内置运行资源不能指向应用外部") }
    return file
  }
  func manifest() throws -> RuntimeSeedManifest? {
    guard seed != nil else { return nil }
    let value = try JSONDecoder().decode(RuntimeSeedManifest.self, from: Data(contentsOf: resource("manifest.json")))
    guard value.version == 1, value.apps.count <= 10, Set(value.apps.map(\.package)).count == value.apps.count else { throw DeckError(message: "内置应用清单无效") }
    for app in value.apps {
      guard app.package.range(of: "^[A-Za-z][\\w]*(\\.[\\w]+)+$", options: .regularExpression) != nil, app.versionCode > 0,
        app.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        app.file.hasSuffix(".apk"), app.file.hasPrefix("Apps/") else { throw DeckError(message: "内置应用信息无效") }
      _ = try resource(app.file)
    }
    return value
  }
  func prepare(at root: URL) throws {
    let fm = FileManager.default
    guard seed != nil else { return }
    _ = try manifest()
    if fm.fileExists(atPath: root.path) {
      guard ready(at: root) else { throw DeckError(message: "现有运行环境不完整，请恢复或重新安装运行组件；游戏数据未作更改") }
      return
    }
    progress("首次启动：正在准备 Android 运行环境…")
    let stage = root.deletingLastPathComponent().appendingPathComponent(".runtime-install-" + UUID().uuidString)
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { if fm.fileExists(atPath: stage.path) { try? fm.removeItem(at: stage) } }
    let source = try resource(".runtime")
    if let entries = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
      for case let file as URL in entries {
        if (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
          let target = file.resolvingSymlinksInPath().standardizedFileURL.path
          guard target.hasPrefix(source.path + "/") else { throw DeckError(message: "内置 SDK 链接超出运行环境") }
        }
      }
    }
    try fm.copyItem(at: source, to: stage.appendingPathComponent(".runtime"))
    progress("首次启动：正在准备触控组件…")
    try fm.copyItem(at: resource("assets"), to: stage.appendingPathComponent("assets"))
    try fm.createDirectory(at: stage.appendingPathComponent("data"), withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Preferences()).write(to: stage.appendingPathComponent("data/settings.json"), options: .atomic)
    guard ready(at: stage) else { throw DeckError(message: "运行组件准备失败，请重试") }
    do { try fm.moveItem(at: stage, to: root) }
    catch {
      // Another first launch may have completed while this process was copying.
      guard ready(at: root) else { throw error }
    }
    progress("Android 运行环境已准备好")
  }
  static func digest(_ file: URL) throws -> String {
    let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
    var hash = SHA256()
    while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  func installMissing(in runtime: AndroidRuntime, serial: String) throws {
    guard runtime.owns(serial), let list = try manifest() else { return }
    // Android returns status 1 (and no text) for `pm path` on a missing package.
    // A successful list query distinguishes absence from an ADB/service failure.
    let installed = Set(try runtime.adbRun(["shell", "pm", "list", "packages"], serial: serial, timeout: 30)
      .split(separator: "\n").filter { $0.hasPrefix("package:") }.map { String($0.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) })
    for app in list.apps {
      if installed.contains(app.package) { continue }
      progress("正在安装内置应用：\(app.name)…")
      let file = try resource(app.file)
      guard try Self.digest(file) == app.sha256 else { throw DeckError(message: "\(app.name) 安装包校验失败") }
      _ = try runtime.adbRun(["install", "-r", file.path], serial: serial, timeout: 600)
      guard try runtime.adbRun(["shell", "pm", "path", app.package], serial: serial).hasPrefix("package:") else { throw DeckError(message: "\(app.name) 安装未完成，下次启动会重试") }
    }
  }
}
