// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class DeviceInformationView: NSStackView {
  let refresh = NSButton(title: "刷新设备信息", target: nil, action: nil)
  private let model = NSTextField(wrappingLabelWithString: "启动 Android 后查看设备信息")
  private let version = NSTextField(labelWithString: "系统版本：—")
  private let processor = NSTextField(labelWithString: "CPU / 架构：—")
  private let storage = NSTextField(labelWithString: "磁盘总量：—")
  private let storageUsed = NSTextField(labelWithString: "已用空间：—")
  private let storageFree = NSTextField(labelWithString: "剩余空间：—")
  private let memory = NSTextField(labelWithString: "内存总量：—")
  private let memoryUsed = NSTextField(labelWithString: "已用内存：—")
  private let memoryFree = NSTextField(labelWithString: "可用内存：—")
  private let resolution = NSTextField(labelWithString: "当前画面：—")
  private let updated = NSTextField(labelWithString: "设备未连接")
  private var connected = false
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    orientation = .vertical; alignment = .leading; spacing = 8
    edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
    DeckTheme.styleSurface(self, radius: 12, color: DeckTheme.background)
    widthAnchor.constraint(equalToConstant: 264).isActive = true
    let title = NSTextField(labelWithString: "设备概览")
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    addArrangedSubview(title)
    for field in [model, version, processor, storage, storageUsed, storageFree, memory, memoryUsed, memoryFree, resolution, updated] {
      field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      field.textColor = DeckTheme.secondary
      field.widthAnchor.constraint(equalToConstant: 236).isActive = true
      addArrangedSubview(field)
    }
    storageFree.textColor = lime; memoryFree.textColor = lime; updated.textColor = muted
    model.preferredMaxLayoutWidth = 236
    model.textColor = DeckTheme.ink
    storageFree.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    memoryFree.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    memoryFree.toolTip = "可用内存包含系统能够回收的缓存"
    refresh.bezelStyle = .rounded; refresh.font = .systemFont(ofSize: 11)
    addArrangedSubview(refresh)
    refresh.isEnabled = false
  }
  required init?(coder: NSCoder) { fatalError() }
  func setConnected(_ value: Bool) {
    refresh.isEnabled = value
    guard connected != value else { return }
    connected = value
    if !value {
      for field in [version, processor, storage, storageUsed, storageFree, memory, memoryUsed, memoryFree, resolution] {
        field.stringValue = field.stringValue.components(separatedBy: "：").first! + "：—"
      }
      model.stringValue = "启动 Android 后查看设备信息"; updated.stringValue = "设备未连接"
    }
  }
  func setRefreshing() { refresh.isEnabled = false; updated.stringValue = "正在读取…" }
  func showError(_ message: String) { refresh.isEnabled = connected; updated.stringValue = "读取失败，点刷新重试"; updated.toolTip = message }
  func show(_ info: AndroidDeviceInformation, width: Int, height: Int) {
    func bytes(_ value: Int64) -> String { String(format: "%.1f GB", Double(value) / Double(1 << 30)) }
    model.stringValue = info.model
    version.stringValue = "系统：Android \(info.androidVersion) / API \(info.apiLevel)"
    let architecture = info.architecture == "arm64-v8a" ? "ARM64" : info.architecture
    processor.stringValue = "CPU：\(info.cpuCount > 0 ? String(info.cpuCount) + " 核" : "未知核数") / \(architecture)"
    storage.stringValue = "磁盘总量：\(bytes(info.diskTotal))"
    storageUsed.stringValue = "已用空间：\(bytes(info.diskUsed))"
    storageFree.stringValue = "剩余空间：\(bytes(info.diskAvailable))"
    memory.stringValue = "内存总量：\(bytes(info.memoryTotal))"
    memoryUsed.stringValue = "已用内存：\(bytes(info.memoryUsed))"
    memoryFree.stringValue = "可用内存：\(bytes(info.memoryAvailable))"
    resolution.stringValue = "当前画面：\(width) × \(height)"
    let time = DateFormatter(); time.timeStyle = .short
    updated.stringValue = "\(time.string(from: Date())) 更新 · 每 5 秒刷新"
    refresh.isEnabled = connected
  }
}

extension AppDelegate {
  @objc func refreshDeviceInformation(_ sender: Any?) {
    guard ready, !busy, !quitting, !deviceInfoPending, let serial = serial else { return }
    deviceInfoPending = true; deviceInfoView.setRefreshing()
    let connection = generation
    let currentRuntime = runtime!
    deviceInfoQueue.async { [weak self] in
      let result = Result { try currentRuntime.deviceInformation(serial: serial) }
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.deviceInfoPending = false
        guard self.ready, !self.quitting, self.serial == serial, self.generation == connection else { return }
        self.lastDeviceInfoRefresh = ProcessInfo.processInfo.systemUptime
        switch result {
        case .success(let info):
          self.deviceInfoView.show(info, width: self.input.width, height: self.input.height)
        case .failure(let error): self.deviceInfoView.showError(error.localizedDescription)
        }
        self.rootView.needsLayout = true
      }
    }
  }
}
