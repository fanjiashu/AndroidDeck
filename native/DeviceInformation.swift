// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct AndroidDeviceInformation: Codable {
  let model: String
  let androidVersion: String
  let apiLevel: Int
  let architecture: String
  let cpuCount: Int
  let memoryTotal: Int64
  let memoryAvailable: Int64
  let diskTotal: Int64
  let diskUsed: Int64
  let diskAvailable: Int64
  var memoryUsed: Int64 { memoryTotal - memoryAvailable }

  static func parse(properties: String, memory: String, disk: String, cpus: String) throws -> Self {
    var props: [String: String] = [:]
    for line in properties.split(separator: "\n") {
      let parts = line.components(separatedBy: "]: [")
      if parts.count == 2, parts[0].hasPrefix("["), parts[1].hasSuffix("]") {
        props[String(parts[0].dropFirst())] = String(parts[1].dropLast())
      }
    }
    var memoryKB: [String: Int64] = [:]
    for line in memory.split(separator: "\n") {
      let parts = line.split(whereSeparator: { $0.isWhitespace })
      if parts.count >= 2, let value = Int64(parts[1]), value >= 0, value <= Int64.max / 1024 {
        memoryKB[String(parts[0]).replacingOccurrences(of: ":", with: "")] = value
      }
    }
    guard let totalMemoryKB = memoryKB["MemTotal"], totalMemoryKB > 0,
      let availableMemoryKB = memoryKB["MemAvailable"] ?? memoryKB["MemFree"], availableMemoryKB <= totalMemoryKB,
      let version = props["ro.build.version.release"], !version.isEmpty,
      let api = Int(props["ro.build.version.sdk"] ?? ""), api > 0 else {
      throw DeckError(message: "安卓系统信息尚未就绪")
    }
    let row = disk.split(separator: "\n").compactMap { line -> [Int64]? in
      let parts = line.split(whereSeparator: { $0.isWhitespace })
      guard parts.count >= 6, let total = Int64(parts[1]), let used = Int64(parts[2]),
        let available = Int64(parts[3]), total > 0, total <= Int64.max / 1024,
        used >= 0, available >= 0, used <= total, available <= total else { return nil }
      return [total * 1024, used * 1024, available * 1024]
    }.first
    guard let values = row else { throw DeckError(message: "未能读取安卓磁盘空间") }
    var processors = Set<Int>()
    for section in cpus.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",") {
      let range = section.split(separator: "-")
      guard !range.isEmpty, range.count <= 2 else { continue }
      guard let first = Int(range[0]), first >= 0, first <= 4095 else { continue }
      let last = range.count == 2 ? Int(range[1]) ?? -1 : first
      if last >= first, last <= 4095 { processors.formUnion(first...last) }
    }
    return Self(model: props["ro.product.model"] ?? "Android 设备", androidVersion: version, apiLevel: api,
      architecture: props["ro.product.cpu.abi"] ?? "未知", cpuCount: processors.count,
      memoryTotal: totalMemoryKB * 1024, memoryAvailable: availableMemoryKB * 1024,
      diskTotal: values[0], diskUsed: values[1], diskAvailable: values[2])
  }
}

extension AndroidRuntime {
  func deviceInformation(serial: String) throws -> AndroidDeviceInformation {
    var properties = ""
    for key in ["ro.product.model", "ro.build.version.release", "ro.build.version.sdk", "ro.product.cpu.abi"] {
      let value = try adbRun(["shell", "getprop", key], serial: serial, timeout: 2)
      properties += "[\(key)]: [\(value)]\n"
    }
    let memory = try adbRun(["shell", "cat", "/proc/meminfo"], serial: serial, timeout: 3)
    let disk = try adbRun(["shell", "df", "-k", "/data"], serial: serial, timeout: 3)
    let cpus = try adbRun(["shell", "cat", "/sys/devices/system/cpu/online"], serial: serial, timeout: 3)
    return try AndroidDeviceInformation.parse(properties: properties, memory: memory, disk: disk, cpus: cpus)
  }
}
