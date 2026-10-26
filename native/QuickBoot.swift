// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation
// These errors are emitted before the guest can answer ADB. Waiting for the
// boot timeout after them makes an ordinary app launch unnecessarily slow.
func snapshotRestoreFailed(in text: String) -> Bool {
  text.contains("Failed to load snapshot") || text.contains("Missing section footer")
    || text.contains("while loading VM state") && text.contains("Error -")
}

struct QuickBootRecord: Codable {
  let key: String
  let marker: String
  let files: [String: String]
}
struct QuickBootRecovery: Codable {
  let folder: String
  let files: [String: String]
}
final class QuickBootStore {
  let root: URL
  let fm = FileManager.default
  static let name = "AndroidDeckQuick"
  static let guestMarker = "/data/local/tmp/androiddeck-quickboot-generation"
  init(root: URL) { self.root = root }
  var avd: URL { root.appendingPathComponent("data/avd/AndroidDeck.avd") }
  var recordFile: URL { root.appendingPathComponent("data/quickboot.json") }
  var recoveryFile: URL { root.appendingPathComponent("data/quickboot-recovery.json") }
  func inventory(at folder: URL? = nil) throws -> [String: String] {
    let base = folder ?? avd
    var value: [String: String] = [:]
    guard let entries = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return value }
    for case let file as URL in entries {
      let path = String(file.path.dropFirst(base.path.count + 1))
      guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
        file.pathExtension == "img" || file.pathExtension == "qcow2" || path.hasPrefix("snapshots/\(Self.name)/") || path.hasPrefix("modem_simulator/") else { continue }
      let attributes = try fm.attributesOfItem(atPath: file.path)
      let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
      let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
      let smallHash = size <= 65536 ? try RuntimeDistribution.digest(file) : ""
      value[path] = "\(size):\(date):\(identity):\(smallHash)"
    }
    return value
  }
  func eligible(key: String) -> QuickBootRecord? {
    guard let data = try? Data(contentsOf: recordFile), let record = try? JSONDecoder().decode(QuickBootRecord.self, from: data),
      record.key == key, let files = try? inventory(), files == record.files,
      fm.fileExists(atPath: avd.appendingPathComponent("snapshots/\(Self.name)/snapshot.pb").path),
      fm.fileExists(atPath: avd.appendingPathComponent("snapshots/\(Self.name)/ram.bin").path) else { return nil }
    return record
  }
  func invalidate() { try? fm.removeItem(at: recordFile) }
  func checkpoint(key: String, marker: String) throws {
    let record = QuickBootRecord(key: key, marker: marker, files: try inventory())
    guard !record.files.isEmpty else { throw DeckError(message: "快速恢复记录不完整") }
    try JSONEncoder().encode(record).write(to: recordFile, options: .atomic)
  }
  func cloneBeforeRestore() throws -> URL {
    let parent = root.appendingPathComponent("data/quickboot-recovery-" + UUID().uuidString)
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    var committed = false
    defer { if !committed { try? fm.removeItem(at: parent) } }
    let destination = parent.appendingPathComponent("AndroidDeck.avd")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/cp")
    process.arguments = ["-cR", avd.path, destination.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { try? fm.removeItem(at: parent); throw DeckError(message: "磁盘保护副本无法创建，改为普通启动") }
    let original = try inventory(), copied = try inventory(at: destination)
    func withoutIdentity(_ value: String) -> String {
      let parts = value.split(separator: ":", omittingEmptySubsequences: false)
      return parts.count >= 4 ? "\(parts[0]):\(parts[1]):\(parts[3])" : value
    }
    guard original.mapValues(withoutIdentity) == copied.mapValues(withoutIdentity) else { throw DeckError(message: "磁盘保护副本校验失败") }
    try JSONEncoder().encode(QuickBootRecovery(folder: parent.lastPathComponent, files: copied)).write(to: recoveryFile, options: .atomic)
    committed = true
    return parent
  }
  private func recovery() throws -> QuickBootRecovery {
    let value = try JSONDecoder().decode(QuickBootRecovery.self, from: Data(contentsOf: recoveryFile))
    guard value.folder.hasPrefix("quickboot-recovery-"), UUID(uuidString: String(value.folder.dropFirst("quickboot-recovery-".count))) != nil else {
      throw DeckError(message: "磁盘保护记录无效，请保留设备数据")
    }
    return value
  }
  private func clearRecovery(_ parent: URL) throws {
    if fm.fileExists(atPath: recoveryFile.path) {
      guard try recovery().folder == parent.lastPathComponent else { throw DeckError(message: "磁盘保护记录不匹配") }
      try fm.removeItem(at: recoveryFile)
    }
  }
  @discardableResult func recoverInterruptedRestore() throws -> Bool {
    guard fm.fileExists(atPath: recoveryFile.path) else { return false }
    let record = try recovery(), parent = root.appendingPathComponent("data").appendingPathComponent(record.folder)
    if fm.fileExists(atPath: parent.appendingPathComponent("AndroidDeck.avd").path) {
      try restoreClone(parent)
    } else {
      // A crash between the atomic directory move and removing the journal is recoverable too.
      guard try inventory() == record.files else { throw DeckError(message: "上次恢复中断，保护副本不可用，请保留设备数据") }
      try clearRecovery(parent)
      try? fm.removeItem(at: parent)
    }
    return true
  }
  func restoreClone(_ parent: URL) throws {
    let backup = parent.appendingPathComponent("AndroidDeck.avd")
    guard fm.fileExists(atPath: backup.path) else { throw DeckError(message: "快速恢复失败，磁盘保护副本不可用，请保留现场") }
    let record = try recovery()
    guard record.folder == parent.lastPathComponent, try inventory(at: backup) == record.files else {
      throw DeckError(message: "磁盘保护副本已改变，请保留设备数据")
    }
    let failed = parent.appendingPathComponent("failed-restore.avd")
    let hasAVD = fm.fileExists(atPath: avd.path)
    if hasAVD { try fm.moveItem(at: avd, to: failed) }
    do { try fm.moveItem(at: backup, to: avd) }
    catch { if hasAVD { try? fm.moveItem(at: failed, to: avd) }; throw error }
    try clearRecovery(parent)
    try? fm.removeItem(at: parent)
  }
  func discardClone(_ parent: URL) throws { try clearRecovery(parent); try? fm.removeItem(at: parent) }
}
