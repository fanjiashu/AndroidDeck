// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

enum EGLCompatibility {
  // Android 14 ARM64 r04 goldfish EGL rejects FLAGS_KHR=0, although zero is the default.
  // Correct only the pinned driver's mask validation. The original SDK and APKs stay intact.
  // Source: google/gfxstream guest/egl/egl.cpp, eglCreateContext; EGL_KHR_create_context.
  static let originalSHA256 = "f548cce6ed2fd6481ffb82c4d6dbc151cc8b48f638f79c2e4f30c8afdccdb67c"
  static let correctedSHA256 = "52ee8a9cc324dd7972738a1c4d76bd862fd2c26a8d5d866dd8daf09c7fc0bd2e"
  static let fingerprint = "egl-flags-mask-v1|" + originalSHA256 + "|" + correctedSHA256
  static let driver = "/vendor/lib64/egl/libEGL_emulation.so"
  static let label = "u:object_r:same_process_hal_file:s0"
  static let offset = 0x157f8
  static let before = Data([0xdf, 0x09, 0x00, 0x72, 0x81, 0xfe, 0xff, 0x54])
  // tst w14,#~7; b.eq next_attribute. Zero is valid; unknown flag bits remain invalid.
  static let after = Data([0xdf, 0x71, 0x1d, 0x72, 0x80, 0xfe, 0xff, 0x54])

  static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  static func correctedDriver(_ bytes: Data) throws -> Data {
    if digest(bytes) == correctedSHA256 { return bytes }
    guard digest(bytes) == originalSHA256, bytes.count >= offset + before.count,
      bytes.subdata(in: offset..<(offset + before.count)) == before else {
      throw DeckError(message: "EGL 驱动版本不在已验证的兼容范围内，原驱动未作更改")
    }
    var result = bytes
    result.replaceSubrange(offset..<(offset + before.count), with: after)
    guard digest(result) == correctedSHA256 else {
      throw DeckError(message: "EGL 兼容驱动校验失败，原驱动未作更改")
    }
    return result
  }
  static func checksum(in output: String) throws -> String {
    guard let value = output.split(whereSeparator: { $0.isWhitespace }).first,
      value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
      throw DeckError(message: "未能读取 EGL 驱动校验值")
    }
    return String(value)
  }
}

extension AndroidRuntime {
  func prepareEGLCompatibility(serial: String) throws {
    guard owns(serial) else { return }
    let current = try EGLCompatibility.checksum(in: adbRun(
      ["shell", "su", "0", "sha256sum", EGLCompatibility.driver], serial: serial))
    let label = try adbRun(["shell", "ls", "-Z", EGLCompatibility.driver], serial: serial)
      .split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    guard label == EGLCompatibility.label else {
      throw DeckError(message: "EGL 驱动权限标签异常，请重新启动 Android")
    }
    if current == EGLCompatibility.correctedSHA256 { return }
    guard current == EGLCompatibility.originalSHA256 else {
      throw DeckError(message: "EGL 驱动版本不在已验证的兼容范围内，原驱动未作更改")
    }
    let folder = root.appendingPathComponent("data/egl-compat")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let local = folder.appendingPathComponent(EGLCompatibility.correctedSHA256 + ".so")
    if (try? RuntimeDistribution.digest(local)) != EGLCompatibility.correctedSHA256 {
      let original = folder.appendingPathComponent("original-" + UUID().uuidString + ".so")
      defer { try? FileManager.default.removeItem(at: original) }
      _ = try adbRun(["pull", EGLCompatibility.driver, original.path], serial: serial)
      let bytes = try EGLCompatibility.correctedDriver(Data(contentsOf: original))
      try bytes.write(to: local, options: .atomic)
    }
    let guestFolder = "/data/local/tmp/androiddeck-egl"
    let guest = guestFolder + "/" + EGLCompatibility.correctedSHA256 + ".so"
    _ = try adbRun(["shell", "su", "0", "mkdir", "-p", guestFolder], serial: serial)
    let entries = try adbRun(["shell", "su", "0", "ls", guestFolder], serial: serial)
      .split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let exists = entries.contains(EGLCompatibility.correctedSHA256 + ".so")
    if exists {
      guard try EGLCompatibility.checksum(in: adbRun(["shell", "su", "0", "sha256sum", guest], serial: serial)) == EGLCompatibility.correctedSHA256 else {
        throw DeckError(message: "已缓存的 EGL 兼容驱动校验失败，请重新准备运行环境")
      }
    } else {
      let upload = "/data/local/tmp/androiddeck-egl-upload-" + UUID().uuidString + ".so"
      defer { _ = try? adbRun(["shell", "su", "0", "rm", "-f", upload], serial: serial) }
      _ = try adbRun(["push", local.path, upload], serial: serial)
      _ = try adbRun(["shell", "su", "0", "cp", upload, guest], serial: serial)
    }
    _ = try adbRun(["shell", "su", "0", "chmod", "644", guest], serial: serial)
    _ = try adbRun(["shell", "su", "0", "chcon", EGLCompatibility.label, guest], serial: serial)
    guard try EGLCompatibility.checksum(in: adbRun(["shell", "su", "0", "sha256sum", guest], serial: serial)) == EGLCompatibility.correctedSHA256 else {
      throw DeckError(message: "EGL 兼容驱动传输校验失败，原驱动未作更改")
    }
    _ = try adbRun(["shell", "su", "0", "mount", "-o", "bind", guest, EGLCompatibility.driver], serial: serial)
    guard try EGLCompatibility.checksum(in: adbRun(["shell", "su", "0", "sha256sum", EGLCompatibility.driver], serial: serial)) == EGLCompatibility.correctedSHA256 else {
      throw DeckError(message: "EGL 兼容驱动未成功加载，请重新启动 Android")
    }
    log?("EGL 上下文兼容修正已就绪 · 硬件 GPU")
  }
}
