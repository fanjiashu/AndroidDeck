// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

func protoBytes(_ field: UInt8, _ value: Data) -> Data {
  var result = Data([field << 3 | 2]), length = value.count
  while length > 127 { result.append(UInt8(length & 127) | 128); length >>= 7 }
  result.append(UInt8(length)); result.append(value); return result
}

// A tiny event stream paces these unary captures. Only one RPC writes this
// region, and its pixels are copied into an owned buffer before the next RPC.
final class MappedFrames {
  private let folder: URL, file: URL
  private var client: OpaquePointer?
  private var memory: UnsafeMutableRawPointer?
  private let capacity = rawFrameByteLimit
  init(port: Int, token: String) throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("androiddeck-frames-" + UUID().uuidString)
    file = folder.appendingPathComponent("pixels.bin")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      let fd = Darwin.open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw DeckError(message: "共享画面文件创建失败") }
      defer { Darwin.close(fd) }
      guard ftruncate(fd, off_t(capacity)) == 0 else { throw DeckError(message: "共享画面容量设置失败") }
      let address = mmap(nil, capacity, PROT_READ, MAP_SHARED, fd, 0)
      guard address != MAP_FAILED, let address = address else { throw DeckError(message: "共享画面内存映射失败") }
      memory = address
      // The emulator treats the handle as a literal file path after file://.
      let handle = Data(("file://" + file.path).utf8)
      let transport = Data([8, 1]) + protoBytes(2, handle)
      let body = Data([8, 1]) + protoBytes(6, transport)
      var request = Data([0]); request.be(UInt32(body.count)); request.append(body)
      client = request.withUnsafeBytes { bytes in
        deck_rpc_create(Int32(port), token, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
      }
      guard client != nil else { throw DeckError(message: "共享画面客户端初始化失败") }
      // Probe protocol support before starting a stream, so unsupported SDKs
      // can retain the existing inline RGBA path without a UI interruption.
      try capture(sequence: 0) { _, _ in }
    } catch { close(); throw error }
  }
  func capture(sequence: UInt64, consume: (RawImage, Double) throws -> Void) throws {
    guard let client = client, let memory = memory else { throw DeckError(message: "共享画面连接已关闭") }
    guard deck_rpc_perform(client) == 0 else { throw DeckError(message: String(cString: deck_rpc_error(client))) }
    var count = 0
    guard let bytes = deck_rpc_body(client, &count), count >= 5, count <= 32768 else { throw DeckError(message: "共享画面响应无效") }
    let parsingStarted = ProcessInfo.processInfo.systemUptime
    let response = Data(bytes: bytes, count: count)
    let length = Int(response.integer(1, UInt32.self))
    guard response[0] == 0, length > 0, length == count - 5 else { throw DeckError(message: "共享画面响应边界无效") }
    try RawImage.withMappedImage(response.subdata(in: 5..<count),
      pixels: UnsafeRawBufferPointer(start: memory, count: capacity), sequence: sequence) { image in
        try consume(image, (ProcessInfo.processInfo.systemUptime - parsingStarted) * 1000)
      }
  }
  // Cancellation is the only operation allowed concurrently with capture.
  // Close is called after the owning stream's serial worker has drained.
  func cancel() { if let client = client { deck_rpc_cancel(client) } }
  func close() {
    if let client = client { deck_rpc_destroy(client); self.client = nil }
    if let memory = memory { munmap(memory, capacity); self.memory = nil }
    try? FileManager.default.removeItem(at: folder)
  }
  deinit { close() }
}
