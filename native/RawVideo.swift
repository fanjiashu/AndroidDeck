// SPDX-License-Identifier: GPL-3.0-only
import Accelerate
import CoreVideo
import Foundation

// A UHD RGBA frame uses 33,177,600 bytes; retain a finite budget for metadata/chunking.
let rawFrameByteLimit = 40 * 1024 * 1024
let rawReadChunkBytes = 1024 * 1024

// The installed emulator_controller.proto is the wire contract. No generated SDK is needed.
struct ProtoFields {
  var numbers: [Int: UInt64] = [:]
  var bytes: [Int: Data] = [:]
  var byteRanges: [Int: Range<Int>] = [:]
  init(_ data: Data, skipPixels: Bool = false) throws {
    var offset = 0
    func varint() throws -> UInt64 {
      var value: UInt64 = 0
      for shift in stride(from: 0, through: 63, by: 7) {
        guard offset < data.count else { throw DeckError(message: "原始帧字段截断") }
        let b = data[offset]
        offset += 1
        if shift == 63 && b > 1 { throw DeckError(message: "原始帧整数溢出") }
        value |= UInt64(b & 127) << shift
        if b < 128 { return value }
      }
      throw DeckError(message: "原始帧整数无效")
    }
    while offset < data.count {
      let tag = try varint()
      let field = Int(tag >> 3)
      guard field > 0 else { throw DeckError(message: "原始帧字段无效") }
      switch tag & 7 {
      case 0: numbers[field] = try varint()
      case 2:
        let length = try varint()
        guard length <= UInt64(data.count - offset) else { throw DeckError(message: "原始帧长度无效") }
        byteRanges[field] = offset..<offset + Int(length)
        if !skipPixels || field != 4 { bytes[field] = data.subdata(in: offset..<offset + Int(length)) }
        offset += Int(length)
      case 1, 5:
        let length = tag & 7 == 1 ? 8 : 4
        guard length <= data.count - offset else { throw DeckError(message: "原始帧字段截断") }
        offset += length
      default: throw DeckError(message: "原始帧字段类型不支持")
      }
    }
  }
}

struct RawImage {
  let width: Int, height: Int
  let pixels: Data
  let sequence: UInt64
  var inactive: Bool { width == 0 && height == 0 }
  init(_ data: Data) throws { try self.init(data, borrowPixels: false) }
  private init(_ data: Data, borrowPixels: Bool) throws {
    let fields = try ProtoFields(data, skipPixels: borrowPixels)
    guard let formatData = fields.bytes[1] else {
      throw DeckError(message: "原始帧缺少像素或格式")
    }
    let format = try ProtoFields(formatData)
    let w = format.numbers[3] ?? 0
    let h = format.numbers[4] ?? 0
    if w == 0, h == 0, (fields.byteRanges[4]?.count ?? 0) == 0 {
      width = 0; height = 0; pixels = Data(); sequence = fields.numbers[5] ?? 0
      return
    }
    guard let pixelRange = fields.byteRanges[4] else { throw DeckError(message: "原始帧缺少像素") }
    guard format.numbers[1] == 1, w > 0, h > 0, w <= 4096, h <= 4096,
      w * h * 4 <= UInt64(rawFrameByteLimit), UInt64(pixelRange.count) == w * h * 4
    else {
      throw DeckError(message: "原始帧尺寸或 RGBA 像素无效")
    }
    width = Int(w)
    height = Int(h)
    if borrowPixels {
      pixels = data.withUnsafeBytes { bytes in
        Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!.advanced(by: pixelRange.lowerBound)), count: pixelRange.count, deallocator: .none)
      }
    } else { pixels = fields.bytes[4]! }
    sequence = fields.numbers[5] ?? 0
  }
  // The callback must finish copying pixels into an owned buffer before this scope returns.
  static func withBorrowedImage(_ bytes: UnsafeRawBufferPointer, _ consume: (RawImage) throws -> Void) throws {
    guard let base = bytes.baseAddress, !bytes.isEmpty else { throw DeckError(message: "原始帧为空") }
    let message = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
    try consume(try RawImage(message, borrowPixels: true))
  }
  private init(width: Int, height: Int, pixels: Data, sequence: UInt64) {
    self.width = width; self.height = height; self.pixels = pixels; self.sequence = sequence
  }
  static func withMappedImage(_ metadata: Data, pixels: UnsafeRawBufferPointer, sequence: UInt64,
    _ consume: (RawImage) throws -> Void) throws {
    let fields = try ProtoFields(metadata)
    guard let formatData = fields.bytes[1], (fields.byteRanges[4]?.count ?? 0) == 0 else {
      throw DeckError(message: "共享画面协议未生效")
    }
    let format = try ProtoFields(formatData), w = format.numbers[3] ?? 0, h = format.numbers[4] ?? 0
    if w == 0, h == 0 { try consume(RawImage(width: 0, height: 0, pixels: Data(), sequence: sequence)); return }
    guard format.numbers[1] == 1, w > 0, h > 0, w <= 4096, h <= 4096,
      w * h * 4 <= UInt64(rawFrameByteLimit), w * h * 4 <= UInt64(pixels.count), let address = pixels.baseAddress else {
      throw DeckError(message: "共享画面尺寸或内存范围无效")
    }
    let borrowed = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: address), count: Int(w * h * 4), deallocator: .none)
    try consume(RawImage(width: Int(w), height: Int(h), pixels: borrowed, sequence: sequence))
  }
}

func copyRawPixels(_ image: RawImage, into output: CVPixelBuffer) throws {
  guard CVPixelBufferGetWidth(output) == image.width, CVPixelBufferGetHeight(output) == image.height,
    CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA,
    CVPixelBufferGetBytesPerRow(output) >= image.width * 4 else { throw DeckError(message: "原始帧与目标像素缓冲区不匹配") }
  CVPixelBufferLockBaseAddress(output, [])
  defer { CVPixelBufferUnlockBaseAddress(output, []) }
  guard let destination = CVPixelBufferGetBaseAddress(output) else {
    throw DeckError(message: "原始帧内存不可访问")
  }
  let rowBytes = CVPixelBufferGetBytesPerRow(output)
  let map: [UInt8] = [2, 1, 0, 3]
  let status = image.pixels.withUnsafeBytes { bytes -> vImage_Error in
    // Pinned host renderer is top-down. Convert directly into the strided Metal buffer, in one pass.
    var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
      height: vImagePixelCount(image.height), width: vImagePixelCount(image.width), rowBytes: image.width * 4)
    var target = vImage_Buffer(data: destination, height: vImagePixelCount(image.height),
      width: vImagePixelCount(image.width), rowBytes: rowBytes)
    return map.withUnsafeBufferPointer {
      vImagePermuteChannels_ARGB8888(&source, &target, $0.baseAddress!, vImage_Flags(kvImageNoFlags))
    }
  }
  guard status == kvImageNoError else { throw DeckError(message: "像素通道转换失败：\(status)") }
}

final class RawVideoStream {
  private let io = DispatchQueue(label: "deck.native.raw", qos: .userInteractive)
  private let state = NSLock(), countersLock = NSLock()
  private var process: Process?, pipe: Pipe?, pending = Data(), stopping = false
  private var reservedBytes = 0
  private var pool: CVPixelBufferPool?, width = 0, height = 0
  private var received = 0, submitted = 0, missing = 0, lastSequence: UInt64?
  private var intervals: [Double] = [], lastArrival: Double?
  private var parseTimes: [Double] = [], conversionTimes: [Double] = []
  private var temporary: [URL] = []
  private var mapped: MappedFrames?
  private var coalescedSignals = 0
  private var mappedFramesEnabled = false
  private var captureTimes: [Double] = []
  var usingMappedFrames: Bool { state.lock(); defer { state.unlock() }; return mappedFramesEnabled }
  var onFrame: ((CVPixelBuffer) -> Void)?
  var onError: ((String) -> Void)?
  var onSize: ((Int, Int) -> Void)?
  var isStopping: Bool {
    state.lock()
    defer { state.unlock() }
    return stopping
  }
  func counters() -> (Int, Int) {
    countersLock.lock()
    defer { countersLock.unlock() }
    return (received, submitted)
  }
  func metrics() -> [String: Any] {
    countersLock.lock()
    defer { countersLock.unlock() }
    let sorted = intervals.sorted()
    func percentile(_ p: Double) -> Double {
      sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
    return [
      "receivedFrames": received, "submittedFrames": submitted, "sourceSequenceGaps": missing,
      "arrivalP50Ms": percentile(0.5), "arrivalP95Ms": percentile(0.95),
      "parseP50Ms": quantile(parseTimes, 0.5), "parseP95Ms": quantile(parseTimes, 0.95),
      "conversionP50Ms": quantile(conversionTimes, 0.5), "conversionP95Ms": quantile(conversionTimes, 0.95),
      "sharedMemory": usingMappedFrames, "coalescedSignals": coalescedSignals,
      "captureP50Ms": quantile(captureTimes, 0.5), "captureP95Ms": quantile(captureTimes, 0.95),
    ]
  }
  private func quantile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
  }
  // A regular-file mapping writes every captured frame to the SSD. Use the pipe by default.
  func start(port: Int, token: String, directory: URL, preferMappedFrames: Bool = false, refreshDisplay: (() -> Void)? = nil) throws {
    guard token.range(of: "^[A-Za-z0-9._=+/-]+$", options: .regularExpression) != nil else {
      throw DeckError(message: "本地画面授权令牌无效")
    }
    if preferMappedFrames { mapped = try? MappedFrames(port: port, token: token) }
    state.lock(); mappedFramesEnabled = mapped != nil; state.unlock()
    let request = directory.appendingPathComponent("raw-request-\(UUID().uuidString).bin")
    let headers = directory.appendingPathComponent("raw-headers-\(UUID().uuidString).txt")
    temporary = [request, headers]
    let body = usingMappedFrames ? Data([8, 1, 24, 64, 32, 64]) : Data([8, 1])
    var packet = Data([0]); packet.be(UInt32(body.count)); packet.append(body)
    try packet.write(to: request, options: .atomic)
    let p = Process()
    let output = Pipe()
    let errors = Pipe()
    let configuration = Pipe()
    let first = DispatchSemaphore(value: 0)
    let refreshSettled = DispatchGroup()
    var started = false
    var diagnostic = Data()
    let diagnosticLock = NSLock()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = [
      "--http2-prior-knowledge", "--no-buffer", "--silent", "--show-error",
      "--config", "-", "--dump-header", headers.path, "--connect-timeout", "3",
      "-X", "POST", "-H", "Content-Type: application/grpc", "-H", "TE: trailers",
      "--data-binary", "@" + request.path,
      "http://127.0.0.1:\(port)/android.emulation.control.EmulatorController/streamScreenshot",
    ]
    p.standardOutput = output
    p.standardError = errors
    p.standardInput = configuration
    errors.fileHandleForReading.readabilityHandler = { handle in
      let d = handle.availableData
      diagnosticLock.lock()
      diagnostic.append(d)
      if diagnostic.count > 2048 { diagnostic = Data(diagnostic.suffix(2048)) }
      diagnosticLock.unlock()
    }
    p.terminationHandler = { [weak self] child in
      guard let self = self else { return }
      self.io.async {
        first.signal()
        if !self.isStopping {
          let trailers = (try? String(contentsOf: headers, encoding: .utf8)) ?? ""
          let status = trailers.split(separator: "\n").filter { $0.lowercased().hasPrefix("grpc-") }
            .joined(separator: " ")
          diagnosticLock.lock(); let reason = String(decoding: diagnostic, as: UTF8.self); diagnosticLock.unlock()
          self.onError?("画面直连结束：\(child.terminationStatus) \(status) \(reason)")
        }
      }
    }
    try p.run()
    process = p
    pipe = output
    // Pass the ephemeral token through stdin; it never appears in process arguments or logs.
    guard token.range(of: "^[A-Za-z0-9._=+/-]+$", options: .regularExpression) != nil else {
      close()
      throw DeckError(message: "本地画面授权令牌无效")
    }
    try configuration.fileHandleForWriting.write(
      contentsOf: Data("header = \"authorization: Bearer \(token)\"\n".utf8))
    try configuration.fileHandleForWriting.close()
    io.async { [weak self] in
      guard let self = self else { return }
      do {
        while !self.isStopping {
          let more = try autoreleasepool { () throws -> Bool in
            // Foundation's counted pipe read may wait for a full megabyte.
            // Small update signals must be delivered even on a static screen.
            let chunk = self.usingMappedFrames ? output.fileHandleForReading.availableData
              : try output.fileHandleForReading.read(upToCount: rawReadChunkBytes) ?? Data()
            guard !chunk.isEmpty
            else { return false }
            try self.consume(chunk)
            if !started, self.counters().1 > 0 {
              started = true
              first.signal()
            }
            return true
          }
          if !more { break }
        }
      } catch {
        diagnosticLock.lock(); diagnostic.append(Data(error.localizedDescription.utf8)); diagnosticLock.unlock()
        first.signal()
        if !self.isStopping { self.onError?(error.localizedDescription) }
      }
    }
    if let refreshDisplay = refreshDisplay {
      refreshSettled.enter()
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) { [weak self] in
        defer { refreshSettled.leave() }
        guard let self = self, !self.isStopping, self.counters().1 == 0 else { return }
        refreshDisplay()
      }
    }
    guard first.wait(timeout: .now() + 8) == .success, counters().1 > 0 else {
      diagnosticLock.lock(); let reason = String(decoding: diagnostic.suffix(512), as: UTF8.self); diagnosticLock.unlock()
      close()
      throw DeckError(message: "模拟器画面直连握手失败" + (reason.isEmpty ? "" : "：" + reason))
    }
    refreshSettled.wait()
  }
  private func consume(_ data: Data) throws {
    pending.append(data)
    guard pending.count <= rawFrameByteLimit + rawReadChunkBytes else { throw DeckError(message: "原始帧缓冲超限") }
    var latestSignal: UInt64?, signals = 0
    while pending.count >= 5 {
      let length = Int(pending.integer(1, UInt32.self))
      guard pending[0] == 0, length > 0, length <= rawFrameByteLimit else { throw DeckError(message: "原始帧消息无效") }
      let capacity = length + 5 + rawReadChunkBytes
      if capacity > reservedBytes { pending.reserveCapacity(capacity); reservedBytes = capacity }
      guard pending.count >= length + 5 else { break }
      let arrival = ProcessInfo.processInfo.systemUptime
      try pending.withUnsafeBytes { bytes in
        let message = UnsafeRawBufferPointer(rebasing: bytes[5..<5 + length])
        try RawImage.withBorrowedImage(message) { image in
          if usingMappedFrames {
            guard image.inactive || (image.width <= 64 && image.height <= 64) else { throw DeckError(message: "画面更新信号尺寸无效") }
            if !image.inactive { latestSignal = image.sequence; signals += 1 }
          } else {
            try publish(image, arrival: arrival, parsingMs: (ProcessInfo.processInfo.systemUptime - arrival) * 1000)
          }
        }
      }
      // Preserve the large allocation between frames; only the small next-frame tail is copied.
      let tail = pending.count > length + 5 ? pending.subdata(in: length + 5..<pending.count) : Data()
      pending.removeAll(keepingCapacity: true)
      pending.append(tail)
    }
    if let sequence = latestSignal, let mapped = mapped {
      countersLock.lock(); coalescedSignals += max(0, signals - 1); countersLock.unlock()
      let begun = ProcessInfo.processInfo.systemUptime
      try mapped.capture(sequence: sequence) { image, parsingMs in
        countersLock.lock()
        captureTimes.append((ProcessInfo.processInfo.systemUptime - begun) * 1000)
        if captureTimes.count > 1800 { captureTimes.removeFirst() }
        countersLock.unlock()
        try self.publish(image, arrival: ProcessInfo.processInfo.systemUptime,
          parsingMs: parsingMs)
      }
    }
  }
  private func publish(_ image: RawImage, arrival: Double, parsingMs: Double) throws {
    if image.inactive { return }
    if image.width != width || image.height != height {
      width = image.width
      height = image.height
      let attrs: [CFString: Any] = [
        kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:],
      ]
      guard
        CVPixelBufferPoolCreate(
          nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
          attrs as CFDictionary, &pool) == kCVReturnSuccess
      else { throw DeckError(message: "原始帧内存池创建失败") }
      onSize?(width, height)
    }
    countersLock.lock()
    received += 1
    if let seq = lastSequence, image.sequence > seq + 1 {
      missing += Int(image.sequence - seq - 1)
    }
    lastSequence = image.sequence
    let now = arrival
    if let last = lastArrival {
      intervals.append((now - last) * 1000)
      if intervals.count > 1800 { intervals.removeFirst() }
    }
    lastArrival = now
    parseTimes.append(parsingMs); if parseTimes.count > 1800 { parseTimes.removeFirst() }
    countersLock.unlock()
    var buffer: CVPixelBuffer?
    guard let pool = pool else { throw DeckError(message: "原始帧内存池缺失") }
    let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      nil, pool,
      [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &buffer)
    if allocation == kCVReturnWouldExceedAllocationThreshold { return }
    guard allocation == kCVReturnSuccess, let output = buffer else {
      throw DeckError(message: "原始帧分配失败：\(allocation)")
    }
    let conversionStarted = ProcessInfo.processInfo.systemUptime
    try copyRawPixels(image, into: output)
    let convertedMs = (ProcessInfo.processInfo.systemUptime - conversionStarted) * 1000
    countersLock.lock()
    submitted += 1
    conversionTimes.append(convertedMs); if conversionTimes.count > 1800 { conversionTimes.removeFirst() }
    countersLock.unlock()
    onFrame?(output)
  }
  func close() {
    state.lock()
    stopping = true
    state.unlock()
    mapped?.cancel()
    if let p = process, p.isRunning {
      p.terminate()
      p.waitUntilExit()
    }
    io.sync {
      pending = Data()
      pool = nil
      mapped?.close(); mapped = nil
      state.lock(); mappedFramesEnabled = false; state.unlock()
    }
    process = nil
    pipe = nil
    for file in temporary { try? FileManager.default.removeItem(at: file) }
    temporary = []
  }
}
