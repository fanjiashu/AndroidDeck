// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreImage
import CoreMedia
import Foundation
import MetalKit
import Network
import VideoToolbox

func nalUnits(_ data: Data) -> [Data] {
  let bytes = [UInt8](data)
  var starts: [(Int, Int)] = []
  var i = 0
  while i + 3 <= bytes.count {
    if bytes[i] == 0, bytes[i + 1] == 0 {
      if bytes[i + 2] == 1 {
        starts.append((i, i + 3))
        i += 3
        continue
      }
      if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
        starts.append((i, i + 4))
        i += 4
        continue
      }
    }
    i += 1
  }
  return starts.enumerated().compactMap { index, start in
    let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
    return start.1 < end ? Data(bytes[start.1..<end]) : nil
  }
}

final class H264Decoder {
  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var sps = Data(), pps = Data()
  var output: ((CVPixelBuffer) -> Void)?
  var failure: ((String) -> Void)?
  var hardware = false
  func configure(_ data: Data) throws {
    for n in nalUnits(data) {
      if n.first! & 31 == 7 { sps = n }
      if n.first! & 31 == 8 { pps = n }
    }
    guard !sps.isEmpty, !pps.isEmpty else { throw DeckError(message: "H.264 参数集缺失") }
    close()
    let a = [UInt8](sps)
    let b = [UInt8](pps)
    var desc: CMFormatDescription?
    let result = a.withUnsafeBufferPointer { ap in
      b.withUnsafeBufferPointer { bp in
        let pointers = [ap.baseAddress!, bp.baseAddress!]
        let sizes = [a.count, b.count]
        return pointers.withUnsafeBufferPointer { ptr in
          sizes.withUnsafeBufferPointer { count in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
              allocator: kCFAllocatorDefault, parameterSetCount: 2,
              parameterSetPointers: ptr.baseAddress!, parameterSetSizes: count.baseAddress!,
              nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
          }
        }
      }
    }
    guard result == noErr, let f = desc else { throw DeckError(message: "视频参数解析失败：\(result)") }
    format = f
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { ref, _, status, _, buffer, _, _ in
        guard let ref = ref else { return }
        let owner = Unmanaged<H264Decoder>.fromOpaque(ref).takeUnretainedValue()
        if status != noErr {
          owner.failure?("VideoToolbox 解码错误：\(status)")
          return
        }
        if let image = buffer { owner.output?(image) }
      }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
    let spec =
      [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
    let attrs =
      [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelBufferMetalCompatibilityKey: true,
      ] as CFDictionary
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: f, decoderSpecification: spec,
      imageBufferAttributes: attrs, outputCallback: &callback, decompressionSessionOut: &session)
    guard status == noErr, let decoder = session else {
      throw DeckError(message: "VideoToolbox 初始化失败：\(status)")
    }
    VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    var value: Unmanaged<CFTypeRef>?
    _ = withUnsafeMutablePointer(to: &value) { ptr in
      VTSessionCopyProperty(
        decoder, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        allocator: kCFAllocatorDefault, valueOut: UnsafeMutableRawPointer(ptr))
    }
    hardware = (value?.takeRetainedValue() as? Bool) ?? false
  }
  func decode(_ data: Data, pts: UInt64) {
    guard let decoder = session, let desc = format else { return }
    var avcc = Data()
    for nal in nalUnits(data) {
      let type = nal.first! & 31
      if type == 7 || type == 8 || type == 9 { continue }
      avcc.be(UInt32(nal.count))
      avcc.append(nal)
    }
    guard !avcc.isEmpty else { return }
    var block: CMBlockBuffer?
    let status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: avcc.count, flags: 0, blockBufferOut: &block)
    guard status == noErr, let memory = block else { return }
    _ = avcc.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: memory, offsetIntoDestination: 0, dataLength: avcc.count
      )
    }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1_000_000),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var size = avcc.count
    let s = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: memory, formatDescription: desc, sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &sample)
    guard s == noErr, let frame = sample else { return }
    let decoded = VTDecompressionSessionDecodeFrame(
      decoder, sampleBuffer: frame,
      flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback], frameRefcon: nil,
      infoFlagsOut: nil)
    if decoded != noErr { failure?("解码提交失败：\(decoded)") }
  }
  func close() {
    if let s = session {
      VTDecompressionSessionWaitForAsynchronousFrames(s)
      VTDecompressionSessionInvalidate(s)
    }
    session = nil
    format = nil
  }
  deinit { close() }
}

final class ScrcpyTransport {
  let runtime: AndroidRuntime
  let serial: String
  let preferences: Preferences
  private let io = DispatchQueue(label: "deck.native.video", qos: .userInteractive),
    controlQueue = DispatchQueue(label: "deck.native.control", qos: .userInteractive)
  private let sent = DispatchGroup(), decoder = H264Decoder()
  private var video: NWConnection?, control: NWConnection?, process: Process?, port: Int = 0,
    remote = ""
  private var pending = Data(), header = false, closing = false, failed = false
  private let countLock = NSLock()
  private var received = 0, decoded = 0
  private var raw: RawVideoStream?
  private let direct: Bool
  private let preferMappedFrames: Bool
  private let controlOnly: Bool
  private let orientationQueue = DispatchQueue(label: "deck.native.orientation")
  private var orientationTimer: DispatchSourceTimer?
  private var orientation: Int?
  var onFrame: ((CVPixelBuffer) -> Void)?
  var onSize: ((Int, Int) -> Void)?
  var onError: ((String) -> Void)?
  var onLog: ((String) -> Void)?
  var hardwareDecoder: Bool { decoder.hardware }
  var rawMode: Bool { raw != nil }
  var mappedMode: Bool { raw?.usingMappedFrames == true }
  var metrics: [String: Any] { raw?.metrics() ?? [:] }
  init(
    runtime: AndroidRuntime, serial: String, preferences: Preferences, direct: Bool = true,
    controlOnly: Bool = false, preferMappedFrames: Bool = false
  ) {
    self.runtime = runtime
    self.serial = serial
    self.preferences = preferences
    self.direct = direct
    self.controlOnly = controlOnly
    self.preferMappedFrames = preferMappedFrames
    decoder.output = { [weak self] image in
      guard let self = self, !self.closing else { return }
      self.countLock.lock()
      self.decoded += 1
      self.countLock.unlock()
      self.onFrame?(image)
    }
    decoder.failure = { [weak self] error in self?.fail(error) }
  }
  func counters() -> (Int, Int) {
    if let raw = raw { return raw.counters() }
    countLock.lock()
    defer { countLock.unlock() }
    return (received, decoded)
  }
  private func connectSocket() throws -> NWConnection {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let connection = NWConnection(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!,
      using: NWParameters(tls: nil, tcp: tcp))
    let ready = DispatchSemaphore(value: 0)
    var error: String?
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready: ready.signal()
      case .failed(let e):
        error = e.localizedDescription
        ready.signal()
      default: break
      }
    }
    connection.start(queue: io)
    guard ready.wait(timeout: .now() + 3) == .success, error == nil else {
      connection.cancel()
      throw DeckError(message: error ?? "视频连接超时")
    }
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed(let e) = state { self?.fail(e.localizedDescription) }
    }
    return connection
  }
  func start() throws {
    let useRaw =
      direct && runtime.owns(serial) && runtime.grpcPort != nil && runtime.grpcToken != nil
    let id = String(format: "%08x", UInt32.random(in: 1...0x7fff_ffff))
    remote = "/data/local/tmp/androiddeck-native-\(id).jar"
    _ = try runtime.adbRun(
      ["push", runtime.root.appendingPathComponent("assets/scrcpy-server").path, remote],
      serial: serial)
    let value = try runtime.adbRun(
      ["forward", "tcp:0", "localabstract:scrcpy_\(id)"], serial: serial)
    guard let n = Int(value) else { throw DeckError(message: "ADB 转发失败") }
    port = n
    let p = Process()
    let pipe = Pipe()
    p.executableURL = runtime.adb
    p.environment = runtime.environment
    p.arguments = [
      "-s", serial, "shell", "CLASSPATH=\(remote)", "app_process", "/",
      "com.genymobile.scrcpy.Server", "3.3.4", "scid=\(id)", "tunnel_forward=true", "audio=false",
      "video_codec=h264", "max_size=\(preferences.size)", "max_fps=\(preferences.fps)",
      "video_bit_rate=\(preferences.bitrate)", "send_device_meta=false", "send_dummy_byte=true",
      "send_codec_meta=true", "send_frame_meta=true", "clipboard_autosync=false", "power_on=true",
      "stay_awake=true", "cleanup=true",
    ]
    if useRaw || controlOnly { p.arguments!.append("video=false") }
    p.standardOutput = pipe
    p.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if !data.isEmpty {
        self?.onLog?(
          String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    p.terminationHandler = { [weak self] p in
      if self?.closing == false { self?.fail("画面服务退出：\(p.terminationStatus)") }
    }
    try p.run()
    process = p
    var first: NWConnection?
    for attempt in 0..<30 {
      do {
        let c = try connectSocket()
        let handshake = DispatchSemaphore(value: 0)
        var ok = false
        c.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
          ok = data?.count == 1
          handshake.signal()
        }
        if handshake.wait(timeout: .now() + 2) == .success, ok {
          first = c
          break
        }
        c.cancel()
      } catch { if attempt == 29 { throw error } }
      Thread.sleep(forTimeInterval: 0.15)
    }
    guard let v = first else { throw DeckError(message: "Android 视频服务握手失败") }
    if useRaw {
      control = v
      orientation = try runtime.screenshotOrientation(serial: serial, previous: nil)
      let stream = RawVideoStream()
      raw = stream
      stream.onFrame = { [weak self] image in self?.onFrame?(image) }
      stream.onSize = { [weak self] w, h in self?.onSize?(w, h) }
      stream.onError = { [weak self] message in self?.fail(message) }
      // A restored static display may not produce a new texture until its sensor state changes.
      let vectors = ["0:9.80:0", "9.80:0:0", "0:-9.80:0", "-9.80:0:0"]
      _ = try? runtime.adbRun(["emu", "sensor", "set", "acceleration", vectors[orientation ?? 0]], serial: serial, timeout: 2)
      try stream.start(
        port: runtime.grpcPort!, token: runtime.grpcToken!,
        directory: runtime.root.appendingPathComponent("data"),
        preferMappedFrames: preferMappedFrames && !CommandLine.arguments.contains("--inline-video"), refreshDisplay: { [weak self] in
          guard let self = self else { return }
          self.orientationQueue.sync {
          guard !self.closing, self.runtime.owns(self.serial) else { return }
          // After a headless snapshot, a static Surface may not have posted a texture yet.
          // Refresh only our display, after the screenshot listener is subscribed.
          _ = try? self.runtime.adbRun(["shell", "input", "keyevent", "223"], serial: self.serial, timeout: 2)
          _ = try? self.runtime.adbRun(["shell", "input", "keyevent", "224"], serial: self.serial, timeout: 2)
          _ = try? self.runtime.adbRun(["shell", "input", "keyevent", "82"], serial: self.serial, timeout: 2)
          }
        })
      onLog?(stream.usingMappedFrames ? "共享内存 RGBA 帧 · 原始分辨率 / Metal · 无 Android 视频编码" : "原始 RGBA 帧直连 · Metal · 无 Android 视频编码")
      let monitor = DispatchSource.makeTimerSource(queue: orientationQueue)
      monitor.schedule(deadline: .now() + 0.5, repeating: 0.5)
      monitor.setEventHandler { [weak self] in
        guard let self = self, !self.closing else { return }
        if let result = try? self.runtime.screenshotOrientation(
          serial: self.serial, previous: self.orientation)
        {
          self.orientation = result
        }
      }
      orientationTimer = monitor
      monitor.resume()
    } else if controlOnly {
      control = v
    } else {
      video = v
      control = try connectSocket()
      receiveVideo()
    }
    receiveControl()
  }
  private func receiveControl() {
    control?.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] _, _, done, error in
      guard let self = self, !self.closing else { return }
      if let e = error {
        self.fail(e.localizedDescription)
      } else if done {
        self.fail("触控连接断开")
      } else {
        self.receiveControl()
      }
    }
  }
  private func receiveVideo() {
    video?.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, done, error in
      guard let self = self, !self.closing else { return }
      if let d = data { do { try self.parse(d) } catch { self.fail(error.localizedDescription) } }
      if let e = error {
        self.fail(e.localizedDescription)
      } else if done {
        self.fail("视频连接断开")
      } else {
        self.receiveVideo()
      }
    }
  }
  private func parse(_ bytes: Data) throws {
    pending.append(bytes)
    guard pending.count <= 16 * 1024 * 1024 else { throw DeckError(message: "视频缓冲区超限") }
    if !header {
      guard pending.count >= 12 else { return }
      guard String(decoding: pending.prefix(4), as: UTF8.self) == "h264" else {
        throw DeckError(message: "视频编码不支持")
      }
      let w = Int(pending.integer(4, UInt32.self))
      let h = Int(pending.integer(8, UInt32.self))
      guard w > 0, h > 0, w <= 8192, h <= 8192 else { throw DeckError(message: "画面尺寸无效") }
      pending = Data(pending.dropFirst(12))
      header = true
      onSize?(w, h)
    }
    while pending.count >= 12 {
      let flags = pending.integer(0, UInt64.self)
      let size = Int(pending.integer(8, UInt32.self))
      guard size > 0, size <= 8 * 1024 * 1024 else { throw DeckError(message: "视频帧长度无效") }
      guard pending.count >= 12 + size else { return }
      let frame = Data(pending[12..<12 + size])
      pending = Data(pending.dropFirst(12 + size))
      if flags & (1 << 63) != 0 {
        try decoder.configure(frame)
      } else {
        countLock.lock()
        received += 1
        countLock.unlock()
        decoder.decode(frame, pts: flags & ((1 << 62) - 1))
      }
    }
  }
  func send(_ data: Data) {
    guard !closing, let c = control else { return }
    sent.enter()
    controlQueue.async {
      c.send(
        content: data,
        completion: .contentProcessed { [weak self] error in
          if let error = error { self?.fail(error.localizedDescription) }
          self?.sent.leave()
        })
    }
  }
  private func fail(_ message: String) {
    guard !closing, !failed else { return }
    failed = true
    onError?(message)
  }
  func close() {
    guard !closing else { return }
    closing = true
    orientationTimer?.cancel()
    orientationTimer = nil
    orientationQueue.sync {}
    raw?.close()
    raw = nil
    controlQueue.sync {}
    _ = sent.wait(timeout: .now() + 0.5)
    video?.cancel()
    control?.cancel()
    io.sync { decoder.close() }
    process?.terminate()
    _ = try? runtime.adbRun(["forward", "--remove", "tcp:\(port)"], serial: serial)
    if !remote.isEmpty { _ = try? runtime.adbRun(["shell", "rm", "-f", remote], serial: serial) }
    video = nil
    control = nil
  }
}

final class MetalVideoView: MTKView, MTKViewDelegate {
  private let gpuQueue: MTLCommandQueue
  private let context: CIContext
  private let frameLock = NSLock()
  private var latest: CVPixelBuffer?
  private var scheduled = false
  var onDisplayed: (() -> Void)?
  init() {
    let gpu = MTLCreateSystemDefaultDevice()!
    gpuQueue = gpu.makeCommandQueue()!
    context = CIContext(mtlDevice: gpu, options: [.cacheIntermediates: false])
    super.init(frame: .zero, device: gpu)
    delegate = self
    isPaused = true
    enableSetNeedsDisplay = false
    framebufferOnly = false
    colorPixelFormat = .bgra8Unorm
    clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
  }
  required init(coder: NSCoder) { fatalError() }
  func submit(_ image: CVPixelBuffer) {
    frameLock.lock()
    latest = image
    if scheduled {
      frameLock.unlock()
      return
    }
    scheduled = true
    frameLock.unlock()
    DispatchQueue.main.async { [weak self] in self?.draw() }
  }
  func snapshot() -> NSImage? {
    frameLock.lock()
    let buffer = latest
    frameLock.unlock()
    guard let buffer = buffer else { return nil }
    let source = CIImage(cvPixelBuffer: buffer)
    guard let image = context.createCGImage(source, from: source.extent) else { return nil }
    return NSImage(cgImage: image, size: source.extent.size)
  }
  func draw(in view: MTKView) {
    frameLock.lock()
    let image = latest
    scheduled = false
    frameLock.unlock()
    guard let buffer = image, let drawable = currentDrawable, let cmd = gpuQueue.makeCommandBuffer()
    else { return }
    let source = CIImage(cvPixelBuffer: buffer)
    let w = CGFloat(drawable.texture.width)
    let h = CGFloat(drawable.texture.height)
    let scaled = source.transformed(
      by: CGAffineTransform(scaleX: w / source.extent.width, y: h / source.extent.height))
    context.render(
      scaled, to: drawable.texture, commandBuffer: cmd,
      bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpaceCreateDeviceRGB())
    cmd.addCompletedHandler { _ in withExtendedLifetime(buffer) {} }
    cmd.present(drawable)
    cmd.commit()
    onDisplayed?()
  }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { draw() }
}
