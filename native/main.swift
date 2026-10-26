// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreVideo
import Foundation
import UniformTypeIdentifiers

let lime = DeckTheme.accent
let muted = DeckTheme.secondary
func label(_ text: String, _ size: CGFloat = 12, _ color: NSColor = DeckTheme.ink) -> NSTextField {
  let v = NSTextField(labelWithString: text)
  v.font = .systemFont(ofSize: max(11, size), weight: size >= 18 ? .semibold : size >= 13 ? .medium : .regular)
  v.textColor = color
  return v
}
func button(_ text: String, _ target: AnyObject, _ action: Selector) -> NSButton {
  let b = DeckButton(frame: .zero); b.title = text; b.target = target; b.action = action
  return b
}
func column() -> NSStackView {
  let v = MappingColumn()
  v.orientation = .vertical
  v.alignment = .leading
  v.distribution = .fill
  v.spacing = 12
  return v
}
final class MappingColumn: NSStackView {
  override var isFlipped: Bool { true }
}
func mappingContentHeight(_ view: NSView) -> CGFloat {
  if let stack = view as? NSStackView {
    let children = stack.arrangedSubviews.filter { !$0.isHidden }
    if stack.orientation == .vertical {
      return stack.edgeInsets.top + stack.edgeInsets.bottom + children.map(mappingContentHeight).reduce(0, +) + stack.spacing
        * CGFloat(max(0, children.count - 1))
    }
    return stack.edgeInsets.top + stack.edgeInsets.bottom + (children.map(mappingContentHeight).max() ?? 0)
  }
  if let height = view.constraints.first(where: { $0.isActive && $0.firstAttribute == .height && $0.secondItem == nil && $0.relation == .equal })?.constant { return height }
  if view is NSScrollView { return 140 }
  return max(0, view.intrinsicContentSize.height)
}

final class MarkerOverlay: NSView {
  weak var canvas: VideoCanvas?
  override var isFlipped: Bool { true }
  override func draw(_ rect: NSRect) { canvas?.drawMarkers() }
  override func mouseDown(with event: NSEvent) { canvas?.mouseDown(with: event) }
  override func mouseDragged(with event: NSEvent) { canvas?.mouseDragged(with: event) }
  override func mouseUp(with event: NSEvent) { canvas?.mouseUp(with: event) }
  override func rightMouseDown(with event: NSEvent) { canvas?.rightMouseDown(with: event) }
  override func rightMouseUp(with event: NSEvent) { canvas?.rightMouseUp(with: event) }
  override func otherMouseDown(with event: NSEvent) { canvas?.otherMouseDown(with: event) }
  override func otherMouseUp(with event: NSEvent) { canvas?.otherMouseUp(with: event) }
  override func magnify(with event: NSEvent) { canvas?.magnify(with: event) }
  override func rotate(with event: NSEvent) { canvas?.rotate(with: event) }
  override func scrollWheel(with event: NSEvent) { canvas?.scrollWheel(with: event) }
}
final class VideoCanvas: NSView {
  private let overlay = MarkerOverlay(frame: .zero)
  let metal = MetalVideoView()
  var dimensions = CGSize(width: 720, height: 1280)
  var profile = Profile.standard { didSet { prepareMarkerText() } }
  let markerText = OverlayTextCache(color: lime.cgColor)
  var markerDraws = 0
  var editing = false { didSet { if !editing { bindingPrompt = nil } } }
  var showMarkers = true
  var mappingEnabled = true
  var input: InputEngine?
  var onMoved: ((Int, Double, Double) -> Void)?
  var onCreated: ((String, TouchPoint, [GesturePoint]?, Int?, Int?) -> Void)?
  var onSelected: ((Int?) -> Void)?
  var onRebind: ((Int) -> Void)?
  var onEndpointMoved: ((Int, Double, Double) -> Void)?
  var onEditorDragBegin: (() -> Void)?
  var onCaptureMouse: ((String) -> Bool)?
  var tool = "select"
  var selectedBinding: Int?
  var replacingBinding: Int?
  private var recorded: [GesturePoint] = [], recordStart = 0.0
  private var endpoint = false, mappedMouse = false, directMouse = false
  private var grabOffset = TouchPoint(x: 0, y: 0)
  private var mouseStart = NSPoint.zero, editorDragged = false
  var onCalibrationPoint: ((TouchPoint) -> Void)?
  var calibrationPrompt: String? { didSet { prepareMarkerText() } }
  var bindingPrompt: String? { didSet { prepareMarkerText() } }
  private var mouseCenter = TouchPoint(x: 0.5, y: 0.5), mouseRadius = 40.0, mouseAngle = 0.0
  private var mouseGestureEnd: Timer?
  private var selected: Int?
  var videoRect: CGRect = .zero
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    addSubview(metal)
    overlay.canvas = self
    addSubview(overlay)
    prepareMarkerText()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let r = dimensions.width / max(1, dimensions.height)
    let h = min(bounds.height, bounds.width / r)
    videoRect = CGRect(
      x: (bounds.width - h * r) / 2, y: (bounds.height - h) / 2, width: h * r, height: h)
    metal.frame = videoRect
    overlay.frame = bounds
    needsDisplay = true
  }
  func normalized(_ point: NSPoint) -> (Double, Double) {
    (
      Double(max(0, min(1, (point.x - videoRect.minX) / max(1, videoRect.width)))),
      Double(max(0, min(1, (point.y - videoRect.minY) / max(1, videoRect.height))))
    )
  }
  func markers() -> [(Int, Double, Double, String)] {
    guard editing || mappingEnabled && showMarkers else { return [] }
    var result = profile.bindings.enumerated().compactMap { i, b in
      !editing && b.visible == false ? nil : (i, b.x, b.y, keyLabel(b.code))
    }
    let j = profile.joystick
    if j.enabled && (editing || j.visible != false) {
      result.append((-1, j.x, j.y, j.keys.map(keyLabel).joined(separator: " ")))
    }
    return result
  }
  func prepareMarkerText() {
    var keys = profile.bindings.map { keyLabel($0.code) } + [profile.joystick.keys.map(keyLabel).joined(separator: " ")]
    for index in profile.bindings.indices {
      let group = sharedSwipeIndices(index)
      if group.count > 1 {
        keys.append(group.map { keyLabel(profile.bindings[$0].code) }.joined(separator: "/"))
        keys.append(group.filter { profile.bindings[$0].visible != false }.map { keyLabel(profile.bindings[$0].code) }.joined(separator: "/"))
      }
    }
    markerText.prepare(keys: keys,
      captions: profile.bindings.filter { !$0.label.isEmpty }.map { String($0.label.prefix(12)) }, prompt: calibrationPrompt ?? bindingPrompt)
  }
  func sharedSwipeIndices(_ index: Int) -> [Int] {
    guard profile.bindings.indices.contains(index), profile.bindings[index].mode == "swipe" else { return [] }
    let binding = profile.bindings[index]
    return profile.bindings.indices.filter { profile.bindings[$0].mode == "swipe" && profile.bindings[$0].x == binding.x && profile.bindings[$0].y == binding.y }
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    overlay.needsDisplay = true
  }
  func drawMarkers() {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    markerDraws += 1
    for (i, x, y, name) in markers() {
      let group = sharedSwipeIndices(i).filter { editing || profile.bindings[$0].visible != false }
      if group.count > 1, i != (group.contains(selectedBinding ?? -1) ? selectedBinding : group.first) { continue }
      let displayName = group.count > 1 && !editing ? group.map { keyLabel(profile.bindings[$0].code) }.joined(separator: "/") : name
      let p = CGPoint(
        x: videoRect.minX + CGFloat(x) * videoRect.width,
        y: videoRect.minY + CGFloat(y) * videoRect.height)
      let size: CGFloat =
        i == -1
        ? max(52, CGFloat(profile.joystick.radius) * min(videoRect.width, videoRect.height) * 2)
        : max(34, markerText.size(displayName, style: .key).width + 10)
      let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
      let path = NSBezierPath(ovalIn: rect)
      NSColor.black.withAlphaComponent(0.48).setFill()
      path.fill()
      lime.setStroke()
      path.lineWidth = 1.5
      if i == selectedBinding { path.lineWidth = 3 }
      path.stroke()
      let s = markerText.size(displayName, style: .key)
      markerText.draw(displayName, style: .key, topLeft: CGPoint(x: p.x - s.width / 2, y: p.y - s.height / 2), in: context)
      if i >= 0, profile.bindings.indices.contains(i) {
        let binding = profile.bindings[i]
        if editing && i == selectedBinding {
          for finger in 0..<max(1, binding.fingerCount) {
            let trajectory = NSBezierPath()
            for step in 0...16 {
              let points = binding.points(
                at: Double(step) / 16, width: Int(dimensions.width), height: Int(dimensions.height))
              guard points.indices.contains(finger) else { continue }
              let point = CGPoint(
                x: videoRect.minX + points[finger].x * videoRect.width,
                y: videoRect.minY + points[finger].y * videoRect.height)
              if step == 0 { trajectory.move(to: point) } else { trajectory.line(to: point) }
            }
            lime.withAlphaComponent(0.65).setStroke()
            trajectory.lineWidth = 1.5
            trajectory.stroke()
          }
          if let last = binding.path?.last {
            let end = CGPoint(
              x: videoRect.minX + last.x * videoRect.width,
              y: videoRect.minY + last.y * videoRect.height)
            lime.setFill()
            NSBezierPath(ovalIn: CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10)).fill()
          }
        }
        for id in [10 + i, 1000 + i] {
          if let point = input?.contacts[id] {
            let screen = CGPoint(
              x: videoRect.minX + point.0 * videoRect.width,
              y: videoRect.minY + point.1 * videoRect.height)
            lime.setFill()
            NSBezierPath(ovalIn: CGRect(x: screen.x - 5, y: screen.y - 5, width: 10, height: 10))
              .fill()
          }
        }
        if editing && !binding.label.isEmpty {
          let caption = String(binding.label.prefix(12))
          markerText.draw(caption, style: .caption, topLeft: CGPoint(x: p.x - markerText.size(caption, style: .caption).width / 2, y: p.y + 20), in: context)
        }
      }
      if i == -1, let contact = input?.contacts[100] {
        let point = CGPoint(
          x: videoRect.minX + contact.0 * videoRect.width,
          y: videoRect.minY + contact.1 * videoRect.height)
        let line = NSBezierPath()
        line.move(to: p)
        line.line(to: point)
        line.lineWidth = 2
        lime.setStroke()
        line.stroke()
        lime.setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)).fill()
      }
    }
    if let prompt = calibrationPrompt ?? bindingPrompt {
      let size = markerText.size(prompt, style: .prompt)
      NSColor.black.withAlphaComponent(0.8).setFill()
      NSBezierPath(rect: CGRect(x: videoRect.minX + 8, y: videoRect.minY + 8, width: size.width + 8, height: size.height + 8)).fill()
      markerText.draw(prompt, style: .prompt, topLeft: CGPoint(x: videoRect.minX + 12, y: videoRect.minY + 12), in: context)
    }
    if recorded.count > 1 {
      let line = NSBezierPath()
      for (i, value) in recorded.enumerated() {
        let point = CGPoint(
          x: videoRect.minX + value.x * videoRect.width,
          y: videoRect.minY + value.y * videoRect.height)
        if i == 0 { line.move(to: point) } else { line.line(to: point) }
      }
      lime.setStroke()
      line.lineWidth = 2
      line.stroke()
    }
  }
  override func mouseDown(with event: NSEvent) {
    if onCaptureMouse?("MouseLeft") == true { return }
    window?.makeFirstResponder(self)
    let p = convert(event.locationInWindow, from: nil)
    guard videoRect.contains(p) else { return }
    let (x, y) = normalized(p)
    if let calibration = onCalibrationPoint { calibration(TouchPoint(x: x, y: y)); return }
    if editing {
      mouseStart = p; editorDragged = false
      if tool == "swipe" {
        recordStart = ProcessInfo.processInfo.systemUptime
        recorded = [GesturePoint(x: x, y: y, t: 0)]
        needsDisplay = true
        return
      }
      if tool != "select" {
        onCreated?(tool, TouchPoint(x: x, y: y), nil, nil, nil)
        return
      }
      if let index = selectedBinding, profile.bindings.indices.contains(index),
        let last = profile.bindings[index].path?.last,
        hypot((last.x - x) * Double(videoRect.width), (last.y - y) * Double(videoRect.height)) < 18
      {
        selected = index
        grabOffset = TouchPoint(x: x - last.x, y: y - last.y)
        endpoint = true
        return
      }
      let nearest = markers().min {
        let a = hypot(($0.1 - x) * Double(videoRect.width), ($0.2 - y) * Double(videoRect.height))
        let b = hypot(($1.1 - x) * Double(videoRect.width), ($1.2 - y) * Double(videoRect.height))
        if abs(a - b) < 1e-6 { return $0.0 == selectedBinding && $1.0 != selectedBinding }
        return a < b
      }
      if let m = nearest,
        hypot((m.1 - x) * Double(videoRect.width), (m.2 - y) * Double(videoRect.height)) < (m.0 == -1 ? max(26, profile.joystick.radius * Double(min(videoRect.width, videoRect.height))) + 6 : 23)
      {
        selected = m.0
        grabOffset = TouchPoint(x: x - m.1, y: y - m.2)
        selectedBinding = m.0 >= 0 ? m.0 : nil
        endpoint = false
        onSelected?(selectedBinding)
      } else {
        onCreated?("tap", TouchPoint(x: x, y: y), nil, nil, nil)
      }
    } else {
      if mappingEnabled && !event.modifierFlags.contains(.option),
        input?.profile.bindings.contains(where: { $0.code == "MouseLeft" }) == true
          || mappingEnabled && !event.modifierFlags.contains(.option)
            && input?.profile.shortcuts.contains(where: { $0.code == "MouseLeft" }) == true
      {
        mappedMouse = true
        input?.key("MouseLeft", true)
      } else {
        directMouse = true
        input?.touch(0, 1, x, y)
      }
    }
  }
  override func mouseDragged(with event: NSEvent) {
    let (x, y) = normalized(convert(event.locationInWindow, from: nil))
    if editing, let index = selected {
      let mouse = convert(event.locationInWindow, from: nil)
      if !editorDragged {
        guard hypot(mouse.x - mouseStart.x, mouse.y - mouseStart.y) >= 3 else { return }
        editorDragged = true; onEditorDragBegin?()
      }
      let point = TouchPoint(x: x - grabOffset.x, y: y - grabOffset.y).clipped
      if endpoint { onEndpointMoved?(index, point.x, point.y) } else { onMoved?(index, point.x, point.y) }
    } else if editing && !recorded.isEmpty {
      let time = min(5, ProcessInfo.processInfo.systemUptime - recordStart)
      if time > recorded.last!.t + 0.008 {
        if recorded.count >= 256 {
          recorded = recorded.enumerated().filter { $0.offset == 0 || $0.offset % 2 == 0 }.map(
            \.element)
        }
        recorded.append(GesturePoint(x: x, y: y, t: time))
        needsDisplay = true
      }
    } else if !editing && directMouse {
      input?.touch(2, 1, x, y)
    }
  }
  override func mouseUp(with event: NSEvent) {
    let (x, y) = normalized(convert(event.locationInWindow, from: nil))
    if editing && !recorded.isEmpty {
      if recorded.count >= 256 {
        recorded = recorded.enumerated().filter { $0.offset == 0 || $0.offset % 2 == 0 }.map(
          \.element)
      }
      let time = max(
        recorded.last!.t + 0.001, min(5, ProcessInfo.processInfo.systemUptime - recordStart))
      recorded.append(GesturePoint(x: x, y: y, t: time))
      let duration = max(50, min(5000, Int(time * 1000)))
      let points = recorded.map { GesturePoint(x: $0.x, y: $0.y, t: $0.t / time) }
      let first = points[0]
      recorded = []
      onCreated?("swipe", TouchPoint(x: first.x, y: first.y), points, duration, replacingBinding)
      replacingBinding = nil
      needsDisplay = true
    } else if editing, let index = selected, index >= 0, !endpoint, !editorDragged {
      onRebind?(index)
    } else if !editing {
      if mappedMouse {
        input?.key("MouseLeft", false)
      } else if directMouse {
        input?.touch(1, 1, x, y)
      }
    }
    mappedMouse = false
    directMouse = false
    selected = nil
  }
  override func rightMouseDown(with event: NSEvent) {
    if onCaptureMouse?("MouseRight") == true { return }
    guard !editing else { return }
    if input?.profile.bindings.contains(where: { $0.code == "MouseRight" }) == true
      || input?.profile.shortcuts.contains(where: { $0.code == "MouseRight" }) == true
    {
      input?.key("MouseRight", true)
    } else {
      input?.clickKey(4)
    }
  }
  override func rightMouseUp(with event: NSEvent) { input?.key("MouseRight", false) }
  override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2, onCaptureMouse?("MouseMiddle") != true, !editing {
      input?.key("MouseMiddle", true)
    }
  }
  override func otherMouseUp(with event: NSEvent) { input?.key("MouseMiddle", false) }
  override func scrollWheel(with event: NSEvent) {
    let dy = Double(event.scrollingDeltaY), dx = Double(event.scrollingDeltaX)
    if abs(dy) > 0.001, onCaptureMouse?(dy > 0 ? "WheelUp" : "WheelDown") == true { return }
    guard !editing else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard videoRect.contains(point) else { return }
    let (x, y) = normalized(point)
    input?.wheel(x, y, deltaX: dx, deltaY: dy, precise: event.hasPreciseScrollingDeltas,
      ended: event.phase.contains(.ended) || event.phase.contains(.cancelled),
      momentum: !event.momentumPhase.isEmpty)
  }
  func cancelEditorGesture() {
    recorded = []
    selected = nil
    replacingBinding = nil
    endMouseGesture()
    needsDisplay = true
  }
  func endMouseGesture() {
    mouseGestureEnd?.invalidate()
    mouseGestureEnd = nil
    for id in [2, 3] { if let p = input?.contacts[id] { input?.touch(1, id, p.0, p.1) } }
  }
  func moveMouseGesture(_ event: NSEvent, scale: Double, rotation: Double) {
    guard !editing, let input = input else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard videoRect.contains(point) else { return }
    if input.contacts[2] == nil || input.contacts[3] == nil {
      guard input.contacts.count <= 8 else { return }
      let center = normalized(point)
      mouseCenter = TouchPoint(x: center.0, y: center.1)
      mouseRadius = Double(min(input.width, input.height)) * 0.08
      mouseAngle = 0
      for (i, sign) in [-1.0, 1.0].enumerated() {
        input.touch(
          0, i + 2, mouseCenter.x + sign * mouseRadius / Double(input.width), mouseCenter.y)
      }
    }
    mouseRadius = max(4, min(Double(min(input.width, input.height)) * 0.4, mouseRadius * scale))
    mouseAngle += rotation
    for (i, sign) in [-1.0, 1.0].enumerated() {
      input.touch(
        2, i + 2, mouseCenter.x + sign * cos(mouseAngle) * mouseRadius / Double(input.width),
        mouseCenter.y + sign * sin(mouseAngle) * mouseRadius / Double(input.height))
    }
    mouseGestureEnd?.invalidate()
    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      endMouseGesture()
    } else {
      mouseGestureEnd = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) {
        [weak self] _ in self?.endMouseGesture()
      }
    }
  }
  override func magnify(with event: NSEvent) {
    moveMouseGesture(event, scale: max(0.2, 1 + Double(event.magnification)), rotation: 0)
  }
  override func rotate(with event: NSEvent) {
    moveMouseGesture(event, scale: 1, rotation: -Double(event.rotation) * .pi / 180)
  }
}

final class DeckRoot: NSView {
  let left = column(), right = column(), top = DeckHeader(frame: .zero), bottom = FullscreenBar(frame: .zero),
    canvas = VideoCanvas(frame: .zero)
  let settings = column(), settingsScroll = NSScrollView(), placeholder = DevicePlaceholder(frame: .zero)
  let sidebarSurface = NSView(), inspectorSurface = DeckInspectorSurface(frame: .zero)
  let inspectorTitle = label("设置", 20), inspectorClose = DeckButton(frame: .zero)
  let stageTitle = label("Android 工作台", 25), stageSubtitle = label("你的应用与游戏，随时继续。", 12, muted)
  let connectionBadge = label("准备连接", 11), appCount = label("0", 11, muted)
  var inspectorOverlaysCanvas = false
  var inspector = DeckInspector.none
  var displayReady = false
  var full = false { didSet { bottom.full = full; needsLayout = true } }
  var onAPK: ((URL) -> Void)?
  var onLayout: (() -> Void)?
  let rightScroll = NSScrollView(), leftScroll = NSScrollView()
  var scrollMappingsToTop = true
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = DeckTheme.background.cgColor
    DeckTheme.styleSurface(sidebarSurface, radius: 0, color: DeckTheme.sidebar, border: false)
    rightScroll.documentView = right
    rightScroll.hasVerticalScroller = true
    rightScroll.autohidesScrollers = true
    rightScroll.scrollerStyle = .overlay
    rightScroll.drawsBackground = false
    leftScroll.documentView = left
    leftScroll.hasVerticalScroller = true; leftScroll.autohidesScrollers = true; leftScroll.drawsBackground = false
    leftScroll.scrollerStyle = .overlay
    settingsScroll.documentView = settings; settingsScroll.hasVerticalScroller = true
    settingsScroll.autohidesScrollers = true; settingsScroll.drawsBackground = false
    settingsScroll.scrollerStyle = .overlay
    DeckTheme.styleSurface(canvas, radius: 18, color: .black); canvas.layer?.masksToBounds = true
    for v in [sidebarSurface, canvas, placeholder, leftScroll, inspectorSurface, rightScroll, settingsScroll, top, bottom] { addSubview(v) }
    inspectorSurface.addSubview(inspectorTitle); inspectorSurface.addSubview(inspectorClose)
    inspectorClose.visualStyle = .icon; inspectorClose.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭面板")
    inspectorClose.imagePosition = .imageOnly; inspectorClose.toolTip = "关闭面板"
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError() }
  override func updateTrackingAreas() { super.updateTrackingAreas(); bottom.track(in: self) }
  func draggedAPK(_ sender: NSDraggingInfo) -> URL? {
    (sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first(where: {
        $0.pathExtension.lowercased() == "apk"
      })
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggedAPK(sender) == nil ? [] : .copy
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let url = draggedAPK(sender), let handler = onAPK else { return false }
    handler(url)
    return true
  }
  func savePreview(_ url: URL) {
    guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return }
    cacheDisplay(in: bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
  }
  override func layout() {
    super.layout()
    let w = bounds.width
    let h = bounds.height
    leftScroll.isHidden = full
    sidebarSurface.isHidden = full
    inspectorSurface.isHidden = full || inspector == .none
    rightScroll.isHidden = full || inspector != .mappings
    settingsScroll.isHidden = full || inspector != .settings
    placeholder.isHidden = displayReady
    canvas.isHidden = !displayReady
    top.isHidden = full
    if !displayReady { bottom.isHidden = true } else if !full { bottom.isHidden = false }
    canvas.layer?.cornerRadius = full ? 0 : 18; canvas.layer?.borderWidth = full ? 0 : 1
    layer?.backgroundColor = full ? NSColor.black.cgColor : DeckTheme.background.cgColor
    let l: CGFloat = full ? 0 : 256
    inspectorOverlaysCanvas = !full && inspector != .none && w < 1240
    let r: CGFloat = full || inspector == .none || inspectorOverlaysCanvas ? 0 : 332
    sidebarSurface.frame = NSRect(x: 0, y: 0, width: 256, height: h)
    // Leave room for macOS's "Always" scrollbar preference without clipping
    // the fixed-width application rows or primary actions.
    leftScroll.frame = NSRect(x: 16, y: 22, width: 240, height: h - 44)
    left.frame = NSRect(x: 0, y: 0, width: 224, height: mappingContentHeight(left))
    let panelTop: CGFloat = inspectorOverlaysCanvas ? 100 : 20
    inspectorSurface.frame = NSRect(x: w - 320, y: panelTop, width: 300, height: h - panelTop - 20)
    inspectorTitle.stringValue = inspector == .mappings ? "键位与操作" : "设备设置"
    inspectorTitle.frame = NSRect(x: 18, y: 18, width: 228, height: 28)
    inspectorClose.frame = NSRect(x: 252, y: 14, width: 34, height: 34)
    rightScroll.frame = NSRect(x: w - 304, y: panelTop + 58, width: 284, height: h - panelTop - 96)
    right.frame = NSRect(x: 0, y: 0, width: 264, height: mappingContentHeight(right))
    settingsScroll.frame = rightScroll.frame
    settings.frame = NSRect(x: 0, y: 0, width: 254, height: mappingContentHeight(settings))
    if scrollMappingsToTop {
      rightScroll.contentView.scroll(
        to: NSPoint(x: 0, y: 0))
      scrollMappingsToTop = false
    }
    top.frame = NSRect(x: l + 24, y: 16, width: max(80, w - l - r - 48), height: 70)
    let barWidth: CGFloat = min(w - 48, 560)
    bottom.frame = full ? NSRect(x: (w - barWidth) / 2, y: h - 72, width: barWidth, height: 48)
      : NSRect(x: l + 24, y: h - 64, width: max(80, w - l - r - 48), height: 44)
    canvas.frame = full ? bounds : NSRect(x: l + 24, y: 100, width: max(80, w - l - r - 48), height: max(100, h - 184))
    placeholder.frame = canvas.frame
    if inspectorOverlaysCanvas && !displayReady {
      placeholder.frame.size.width = max(280, inspectorSurface.frame.minX - canvas.frame.minX - 12)
    }
    canvas.needsLayout = true
    onLayout?()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
  var window: NSWindow!
  let rootView = DeckRoot(frame: .zero), input = InputEngine()
  let worker = DispatchQueue(label: "deck.native.operations", qos: .userInitiated)
  var runtime: AndroidRuntime!
  var transport: ScrcpyTransport?
  var framePresenter: FramePresenter?
  var serial: String?
  var prefs = Preferences(), profiles: [String: Profile] = [:], profile = Profile.standard,
    activePackage = "default", busy = false, ready = false, generation = 0
  var captureIndex: Int?
  var captureMouseEnabled = false
  let mappingPanel = MappingPanel(frame: .zero)
  var activeScheme = ""
  var mappingUndo: [Profile] = []
  var audioPercent = 80, audioMaximum = 15, audioRevision = 0
  var audioDebounce: Timer?
  var audioRefreshTicks = 0
  var readySchemes: [ReadyScheme] = []
  var foregroundTicks = 0, foregroundPending = false
  var androidGamePackages = Set<String>()
  var displayRevision = 0, lastRequestedDisplay: DeckDisplaySpec?, displayAwaitingFrame: DeckDisplaySpec?
  var projection: DeckProjection?
  var presentationVerificationStarted = false
  var shellLifecycleStarted = false
  let appLaunchTime = ProcessInfo.processInfo.systemUptime
  var knownApps: [AndroidApp] = []
  var startupError = ""
  let restartButton = DeckButton(frame: .zero), settingsButton = DeckButton(frame: .zero), mappingsButton = DeckButton(frame: .zero)
  let deviceSummary = label("准备 Android…", 11, muted)
  let deviceInfoView = DeviceInformationView(frame: .zero)
  let deviceInfoQueue = DispatchQueue(label: "deck.device.information", qos: .utility)
  var deviceInfoPending = false, lastDeviceInfoRefresh = 0.0
  var calibrationSource: [(String, TouchPoint)] = [], calibrationTargets: [TouchPoint] = []
  var calibrationOriginal: Profile?
  var settingsLoaded = false
  var benchmark = false
  var benchmarkGame = false
  var quitting = false
  var firstReadyMs = 0.0
  var displayed = 0, previousDisplay = 0, previousReceived = 0, previousDecoded = 0
  var lastTick = ProcessInfo.processInfo.systemUptime
  var benchmarkStart = 0.0, benchmarkSamples: [[String: Double]] = []
  var status = label("正在读取运行环境…", 12, muted),
    fpsLabel = label("Swift · VideoToolbox · Metal", 10, muted), ramPopup = NSPopUpButton(),
    quality = NSPopUpButton(), devicesPopup = NSPopUpButton()
  let kindPopup = NSPopUpButton(), resolutionPopup = NSPopUpButton(), orientationPopup = NSPopUpButton()
  let interactionHint = label("应用：翻页 / 点击\n游戏：方向 / 技能", 10, muted)
  let resolutionInfo = label("分辨率切换后重启 Android", 10, muted)
  var applyResolutionButton: NSButton!
  var appsBox = column(), bindingsBox = column(), text = NSTextField(), logView = NSTextView(),
    showButton = NSButton(checkboxWithTitle: "显示键位", target: nil, action: nil),
    mappingButton = NSButton(checkboxWithTitle: "启用键盘映射", target: nil, action: nil),
    editButton: NSButton!, startButton: NSButton!, stopButton: NSButton!, installButton: NSButton!
  var logLines: [String] = []
  var timer: Timer?
  var keyMonitor: Any?
  var root: URL {
    if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--runtime-root=") }) {
      return URL(fileURLWithPath: String(option.dropFirst("--runtime-root=".count)))
    }
    let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AndroidDeck/runtime")
    if FileManager.default.fileExists(atPath: installed.path) || runtimeSeed != nil { return installed }
    return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("AndroidDeck")
  }
  var runtimeSeed: URL? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let value = resources.appendingPathComponent("RuntimeSeed")
    return FileManager.default.fileExists(atPath: value.appendingPathComponent("manifest.json").path) ? value : nil
  }
  var distribution: RuntimeDistribution {
    RuntimeDistribution(seed: runtimeSeed) { [weak self] message in
      self?.log(message)
      DispatchQueue.main.async { self?.status.stringValue = message }
    }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = CommandLine.arguments.contains("--native-benchmark") ? "AndroidDeck · 性能验证" : "AndroidDeck"
    window.minSize = NSSize(width: 960, height: 680)
    window.backgroundColor = DeckTheme.background
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.delegate = self
    window.acceptsMouseMovedEvents = true
    window.contentView = rootView
    window.center()
    buildMenu()
    buildUI()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    rootView.canvas.input = input
    input.onContactChange = { [weak self] in self?.rootView.canvas.needsDisplay = true }
    input.onAudioAction = { [weak self] action in self?.adjustGameAudio(action) }
    rootView.onAPK = { [weak self] url in self?.installAPK(url) }
    text.delegate = self
    rootView.canvas.metal.onDisplayed = { [weak self] in self?.displayed += 1 }
    rootView.canvas.onMoved = { [weak self] i, x, y in
      guard let self = self else { return }
      if i < 0 {
        self.profile.joystick.x = x
        self.profile.joystick.y = y
      } else {
        self.profile.bindings[i].move(to: TouchPoint(x: x, y: y))
      }
      self.saveProfile(rebuild: false)
      self.mappingPanel.refreshDetails()
    }
    rootView.canvas.onCreated = { [weak self] mode, point, path, duration, replacing in
      self?.createMapping(
        mode: mode, point: point, path: path, duration: duration, replacing: replacing)
    }
    rootView.canvas.onSelected = { [weak self] index in
      self?.captureIndex = nil; self?.captureMouseEnabled = false
      self?.mappingPanel.selectedIndex = index
      self?.mappingPanel.refreshDetails()
    }
    rootView.canvas.onRebind = { [weak self] index in self?.beginQuickKeyCapture(index) }
    rootView.canvas.onEndpointMoved = { [weak self] index, x, y in
      guard let self = self, self.profile.bindings.indices.contains(index),
        self.profile.bindings[index].path != nil
      else { return }
      let last = self.profile.bindings[index].path!.count - 1
      self.profile.bindings[index].path![last].x = x
      self.profile.bindings[index].path![last].y = y
      self.saveProfile(rebuild: false)
    }
    rootView.canvas.onEditorDragBegin = { [weak self] in
      guard let self = self else { return }
      self.mappingUndo.append(self.profile)
      if self.mappingUndo.count > 20 { self.mappingUndo.removeFirst() }
    }
    rootView.canvas.onCaptureMouse = { [weak self] code in
      guard let self = self, self.captureMouseEnabled, self.captureIndex != nil else {
        return false
      }
      self.captureMappingCode(code)
      return true
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
      [weak self] event in self?.handleKey(event) ?? event
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick()
    }
    initializeRuntime()
  }
  func initializeRuntime() {
    settingsLoaded = false; busy = true; startupError = ""
    updateControls()
    worker.async { [weak self] in
      guard let self = self else { return }
      do {
        try self.distribution.prepare(at: self.root)
        try FileManager.default.createDirectory(
          at: self.root.appendingPathComponent("data"), withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        let settings =
          (try? Data(contentsOf: self.root.appendingPathComponent("data/settings.json"))).flatMap {
            try? decoder.decode(Preferences.self, from: $0)
          }?.checked() ?? Preferences()
        var maps =
          (try? Data(contentsOf: self.root.appendingPathComponent("data/profiles.json"))).flatMap {
            try? decoder.decode([String: Profile].self, from: $0)
          } ?? [:]
        let dnf = "com.tencent.tmgp.dnf"
        if let old = maps[dnf], old.joystickPresetVersion == nil, (try? old.checked()) != nil {
          let original = self.root.appendingPathComponent("data/profiles.json")
          let backup = self.root.appendingPathComponent("data/profiles-before-joystick-v1.json")
          if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: original, to: backup)
          }
          maps[dnf] = old.migrateJoystick(for: dnf)
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          try encoder.encode(maps).write(to: original, options: .atomic)
        }
        var soundMigration = false
        for (key, value) in maps where value.soundPresetVersion == nil {
          if (try? value.checked()) != nil {
            maps[key] = value.withDefaultSoundKeys()
            soundMigration = true
          }
        }
        if soundMigration {
          let original = self.root.appendingPathComponent("data/profiles.json")
          let backup = self.root.appendingPathComponent("data/profiles-before-touch-editor.json")
          if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: original, to: backup)
          }
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          try encoder.encode(maps).write(to: original, options: .atomic)
        }
        let runtime = AndroidRuntime(root: self.root)
        runtime.quickBootEnabled = CommandLine.arguments.contains("--quick-boot")
          && !CommandLine.arguments.contains("--cold-boot")
        runtime.log = { [weak self] s in self?.log(s) }
        DispatchQueue.main.async {
          self.runtime = runtime
          guard !self.quitting else { return }
          self.prefs = settings
          if CommandLine.arguments.contains("--presentation-ui-test") { self.prefs.followForegroundApp = false }
          self.profiles = maps
          self.settingsLoaded = true
          self.busy = false
          self.ramPopup.selectItem(at: settings.ramMb == 8192 ? 1 : 0)
          self.quality.selectItem(at: settings.size == 1280 ? 1 : 0)
          self.status.stringValue = "设备设置已就绪"
          self.renderProfile()
          self.loadCachedApplications()
          self.updateControls()
          self.refreshDevices(nil)
          if CommandLine.arguments.contains("--design-review") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.verifyDesignPreview() }
          } else if CommandLine.arguments.contains("--overlay-render-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.verifyMarkerRendering() }
          } else if CommandLine.arguments.contains("--shell-preview-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.verifyShellPreview() }
          } else if CommandLine.arguments.contains("--fullscreen-ui-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.verifyFullscreenChrome() }
          } else if CommandLine.arguments.contains("--benchmark-game") {
            self.benchmark = true
            self.benchmarkGame = true
            self.start(package: "com.tencent.tmgp.dnf")
          } else if CommandLine.arguments.contains("--native-benchmark") {
            self.benchmark = true
            self.start(package: "com.androiddeck.demo")
          } else if let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--start-package=")
          }) {
            self.start(package: String(arg.dropFirst("--start-package=".count)))
          } else if let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--connect-device=")
          }) {
            self.operation("连接测试设备…") {
              try self.connectStream(String(arg.dropFirst("--connect-device=".count)))
            }
          } else if !CommandLine.arguments.contains("--no-auto-start") {
            self.start(package: self.resumePackage)
          }
        }
      } catch { self.showError(error.localizedDescription) }
    }
  }
  func buildMenu() {
    let main = NSMenu()
    let app = NSMenuItem()
    main.addItem(app)
    let sub = NSMenu()
    sub.addItem(
      withTitle: "关于 AndroidDeck",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    sub.addItem(.separator())
    sub.addItem(
      withTitle: "退出 AndroidDeck", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    app.submenu = sub
    let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
    let e = NSMenu()
    for (name, sel, key) in [
      ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
      ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a"),
    ] { e.addItem(withTitle: name, action: sel, keyEquivalent: key) }
    edit.submenu = e
    main.addItem(edit)
    let view = NSMenuItem(title: "视图", action: nil, keyEquivalent: "")
    let v = NSMenu()
    let item = NSMenuItem(title: "进入 / 退出全屏", action: #selector(fullscreen(_:)), keyEquivalent: "f")
    item.keyEquivalentModifierMask = [.command, .control]
    item.target = self
    v.addItem(item)
    let controlsItem = NSMenuItem(title: "显示 / 隐藏全屏工具栏", action: #selector(toggleFullscreenControls(_:)), keyEquivalent: "h")
    controlsItem.keyEquivalentModifierMask = [.command, .shift]; controlsItem.target = self
    v.addItem(controlsItem)
    view.submenu = v
    main.addItem(view)
    NSApp.mainMenu = main
  }
  func buildUI() {
    let left = rootView.left
    left.spacing = 16
    let brand = NSStackView(); brand.orientation = .horizontal; brand.spacing = 9
    let icon = NSImageView(); icon.image = NSImage(named: NSImage.applicationIconName)
    icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 34).isActive = true
    brand.addArrangedSubview(icon); brand.addArrangedSubview(label("AndroidDeck", 20))
    left.addArrangedSubview(brand); left.addArrangedSubview(deviceSummary)
    startButton = button("启动 Android", self, #selector(startClicked(_:)))
    (startButton as? DeckButton)?.visualStyle = .primary
    restartButton.title = "重新启动"; restartButton.visualStyle = .quiet
    restartButton.toolTip = "完整重新启动 Android，保留应用和数据"
    restartButton.target = self; restartButton.action = #selector(restartAndroid(_:))
    stopButton = button("关闭设备", self, #selector(stopClicked(_:)))
    (stopButton as? DeckButton)?.visualStyle = .quiet
    installButton = button("安装 APK", self, #selector(install(_:)))
    for b in [startButton!, installButton!] { b.widthAnchor.constraint(equalToConstant: 224).isActive = true; left.addArrangedSubview(b) }
    installButton.title = "＋  安装 APK"; (installButton as? DeckButton)?.visualStyle = .primary
    let deviceActions = NSStackView(views: [restartButton, stopButton!]); deviceActions.spacing = 8
    for b in [restartButton, stopButton!] { b.widthAnchor.constraint(equalToConstant: 108).isActive = true }
    left.addArrangedSubview(deviceActions)
    let libraryHeading = NSStackView(views: [label("应用库", 14), rootView.appCount]); libraryHeading.spacing = 12
    libraryHeading.edgeInsets = NSEdgeInsets(top: 16, left: 2, bottom: 0, right: 0)
    left.addArrangedSubview(libraryHeading); appsBox.spacing = 8
    left.addArrangedSubview(appsBox)
    let refresh = button("刷新应用库", self, #selector(refreshApps(_:))); (refresh as? DeckButton)?.visualStyle = .quiet
    left.addArrangedSubview(refresh)
    left.addArrangedSubview(DeckTheme.section("本地设备", detail: "应用、键位与数据自动保存"))
    left.addArrangedSubview(label("Android 14   /   Apple Silicon", 11, muted))
    rootView.placeholder.action.target = self
    rootView.placeholder.action.action = #selector(startClicked(_:))

    let settings = rootView.settings
    deviceInfoView.refresh.target = self
    deviceInfoView.refresh.action = #selector(refreshDeviceInformation(_:))
    settings.addArrangedSubview(deviceInfoView)
    settings.addArrangedSubview(DeckTheme.section("性能与容量", detail: "根据应用需要调整设备配置"))
    settings.addArrangedSubview(label("虚拟磁盘配置：\(AndroidRuntime.storageCapacityGB) GB", 11, muted))
    settings.addArrangedSubview(label("Android 内存", 11, muted))
    ramPopup.addItems(withTitles: ["6 GB", "8 GB"]); settings.addArrangedSubview(ramPopup)
    settings.addArrangedSubview(button("应用内存并重启", self, #selector(applyRAM(_:))))
    settings.addArrangedSubview(DeckTheme.section("画面与操作", detail: "按应用保存你的使用习惯"))
    settings.addArrangedSubview(label("当前应用模式", 11, muted))
    kindPopup.target = self; kindPopup.action = #selector(changeContentKind(_:))
    settings.addArrangedSubview(kindPopup); settings.addArrangedSubview(interactionHint)
    settings.addArrangedSubview(label("屏幕分辨率", 11, muted))
    resolutionPopup.addItems(withTitles: DeckResolution.allCases.map(\.title))
    resolutionPopup.target = self; resolutionPopup.action = #selector(changeDisplayOption(_:))
    settings.addArrangedSubview(resolutionPopup); settings.addArrangedSubview(resolutionInfo)
    applyResolutionButton = button("应用分辨率并重启", self, #selector(applyResolution(_:)))
    settings.addArrangedSubview(applyResolutionButton)
    orientationPopup.addItems(withTitles: DeckOrientation.allCases.map(\.title))
    orientationPopup.target = self; orientationPopup.action = #selector(changeDisplayOption(_:))
    settings.addArrangedSubview(orientationPopup)
    for popup in [ramPopup, kindPopup, resolutionPopup, orientationPopup, devicesPopup, quality] {
      popup.widthAnchor.constraint(equalToConstant: 264).isActive = true
    }
    settings.addArrangedSubview(DeckTheme.section("设备投屏", detail: "连接 Android 手机或平板"))
    settings.addArrangedSubview(devicesPopup)
    settings.addArrangedSubview(button("刷新设备", self, #selector(refreshDevices(_:))))
    settings.addArrangedSubview(button("连接所选设备", self, #selector(connectExisting(_:))))
    settings.addArrangedSubview(label("投屏画面质量", 11, muted))
    quality.addItems(withTitles: ["流畅 · 960 / 45 FPS", "高清 · 1280 / 60 FPS"])
    quality.target = self; quality.action = #selector(changeQuality(_:)); settings.addArrangedSubview(quality)
    settings.addArrangedSubview(DeckTheme.section("运行记录"))
    let logs = NSScrollView(); logs.documentView = logView; logs.hasVerticalScroller = true
    logs.heightAnchor.constraint(equalToConstant: 140).isActive = true
    logs.widthAnchor.constraint(equalToConstant: 246).isActive = true
    logView.isEditable = false; logView.backgroundColor = .clear
    logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
    settings.addArrangedSubview(logs)

    for v in [rootView.stageTitle, rootView.stageSubtitle, rootView.connectionBadge, status, fpsLabel] { rootView.top.addSubview(v) }
    status.font = .systemFont(ofSize: 11); status.textColor = muted
    fpsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); fpsLabel.textColor = muted
    for (b, title, selector, symbol) in [
      (settingsButton, "设置", #selector(toggleSettings(_:)), "gearshape"),
      (mappingsButton, "键位", #selector(toggleMappingPanel(_:)), "keyboard")
    ] {
      b.title = title; b.visualStyle = .normal; b.setButtonType(.pushOnPushOff)
      b.target = self; b.action = selector; b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      b.imagePosition = .imageLeading; rootView.top.addSubview(b)
    }
    rootView.onLayout = { [weak self] in
      guard let self = self else { return }
      let width = self.rootView.top.bounds.width
      self.rootView.stageTitle.frame = NSRect(x: 0, y: 0, width: max(100, width - 204), height: 34)
      self.rootView.stageSubtitle.frame = NSRect(x: 0, y: 40, width: max(100, width - 204), height: 18)
      self.status.frame = NSRect(x: 0, y: 60, width: max(100, width - 204), height: 16); self.status.isHidden = !self.busy && self.startupError.isEmpty
      self.fpsLabel.frame = NSRect(x: width - 240, y: 48, width: 240, height: 16)
      self.rootView.connectionBadge.frame = NSRect(x: width - 206, y: 2, width: 202, height: 16)
      self.settingsButton.frame = NSRect(x: width - 182, y: 12, width: 84, height: 34)
      self.mappingsButton.frame = NSRect(x: width - 88, y: 12, width: 84, height: 34)
      self.rootView.connectionBadge.isHidden = true
    }
    let right = rootView.right
    mappingButton.target = self; mappingButton.action = #selector(toggleMapping(_:))
    right.addArrangedSubview(mappingButton)
    mappingPanel.owner = self; right.addArrangedSubview(mappingPanel); editButton = mappingPanel.edit
    text.placeholderString = "输入文字…"; right.addArrangedSubview(text)
    right.addArrangedSubview(button("发送文本", self, #selector(sendText(_:))))
    let bar = NSStackView(); bar.orientation = .horizontal; bar.spacing = 8
    bar.frame = NSRect(x: 0, y: 5, width: 520, height: 34)
    rootView.bottom.addSubview(bar)
    @discardableResult func action(_ title: String, _ symbol: String, _ selector: Selector, _ tag: Int = 0) -> NSButton {
      let b = button("", self, selector); b.tag = tag
      (b as? DeckButton)?.visualStyle = .icon
      b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      b.imagePosition = .imageOnly; b.toolTip = title
      b.widthAnchor.constraint(equalToConstant: 34).isActive = true; bar.addArrangedSubview(b)
      return b
    }
    action("返回", "chevron.left", #selector(nav(_:)), 4)
    action("Android 主页", "house", #selector(nav(_:)), 3)
    action("最近任务", "square.stack", #selector(nav(_:)), 187)
    action("横竖屏切换", "rotate.right", #selector(rotate(_:)))
    action("截图", "camera", #selector(screenshot(_:)))
    action("重连画面", "arrow.triangle.2.circlepath", #selector(reconnect(_:)))
    action("投影", "airplay.video", #selector(projectionMenu(_:)))
    action("全屏 / F11", "arrow.up.left.and.arrow.down.right", #selector(fullscreen(_:)))
    showButton.target = self; showButton.action = #selector(toggleMarkers(_:))
    bar.addArrangedSubview(showButton)
    rootView.bottom.dismissButton = action("隐藏工具栏 · 移动鼠标显示 · ⌘⇧H 切换", "chevron.down", #selector(hideFullscreenControls(_:)))
    rootView.inspectorClose.target = self; rootView.inspectorClose.action = #selector(closeInspector(_:))
    DeckTheme.styleControls(in: settings); DeckTheme.styleControls(in: right)
    rootView.needsLayout = true; updateControls()
  }
  func updateControls() {
    startButton.isEnabled = !busy && !ready && (settingsLoaded || !startupError.isEmpty)
    startButton.title = ready ? "Android 已启动" : busy ? "正在启动…" : "启动 Android"
    stopButton.isEnabled = !busy && (ready || runtime?.child != nil)
    installButton.isEnabled = ready && !busy
    editButton.isEnabled = ready && !busy
    ramPopup.isEnabled = settingsLoaded && !busy
    if transport?.rawMode == true {
      if quality.titleOfSelectedItem != "原始画面 · 无损直连" {
        quality.removeAllItems()
        quality.addItem(withTitle: "原始画面 · 无损直连")
      }
    } else if quality.numberOfItems == 1 {
      quality.removeAllItems()
      quality.addItems(withTitles: ["流畅 · 960 / 45 FPS", "高清 · 1280 / 60 FPS"])
      quality.selectItem(at: prefs.size == 1280 ? 1 : 0)
    }
    quality.isEnabled = settingsLoaded && !busy && !benchmark && transport?.rawMode != true
    renderAudio()
    renderPresentation()
    quality.toolTip = transport?.rawMode == true ? "本地模拟器使用原始分辨率直接显示；此选项用于外接设备的压缩画面" : "压缩视频质量"
    for view in appsBox.arrangedSubviews { (view as? NSButton)?.isEnabled = settingsLoaded && !busy && !benchmark }
    updateShell()
    deviceInfoView.setConnected(ready && !busy)
  }
  func log(_ message: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.logLines.append(message)
      if self.logLines.count > 100 { self.logLines.removeFirst() }
      self.logView.string = self.logLines.joined(separator: "\n")
      self.logView.scrollToEndOfDocument(nil)
      print(message)
    }
  }
  func showError(_ text: String) {
    DispatchQueue.main.async { [weak self] in
      self?.status.stringValue = text
      self?.startupError = text
      self?.log("错误：" + text)
      self?.busy = false
      self?.updateControls()
    }
  }
  func operation(_ title: String, _ body: @escaping () throws -> Void) {
    guard !busy, settingsLoaded, !quitting else { return }
    input.release()
    busy = true
    startupError = ""
    status.stringValue = title
    updateControls()
    worker.async { [weak self] in
      do {
        try body()
        DispatchQueue.main.async {
          self?.busy = false
          self?.updateControls()
        }
      } catch { self?.showError(error.localizedDescription) }
    }
  }
  func connectStream(_ target: String, package: String = "default", direct: Bool = true, mapped: Bool = false) throws {
    framePresenter?.close()
    transport?.close()
    generation += 1
    DispatchQueue.main.sync {
      self.input.suspended = false; self.displayAwaitingFrame = nil; self.lastRequestedDisplay = nil
    }
    let id = generation
    if runtime.owns(target) {
      let spec = DispatchQueue.main.sync { self.displaySpec(package: package).using(self.runtime.resolution) }
      try runtime.applyDisplay(spec, serial: target)
      _ = try runtime.adbRun(["shell", "input", "keyevent", "224"], serial: target)
      _ = try runtime.screenshotOrientation(serial: target, previous: nil)
    }
    let t = ScrcpyTransport(
      runtime: runtime, serial: target, preferences: prefs,
      direct: direct && !CommandLine.arguments.contains("--encoded-video"), preferMappedFrames: mapped)
    transport = t
    t.onLog = { [weak self] s in self?.log(s) }
    t.onError = { [weak self, weak t] error in
      DispatchQueue.main.async {
        guard let self = self, self.transport === t else { return }
        self.input.release()
        self.cancelLayoutCalibration()
        self.ready = false
        self.status.stringValue = error
        let currentPackage = self.activePackage
        if t?.mappedMode == true && !self.busy {
          self.operation("共享画面连接中断，恢复原始帧通道…") {
            try self.connectStream(target, package: currentPackage, mapped: false)
          }
        } else if t?.rawMode == true && !self.busy {
          self.operation("画面直连中断，切换 H.264…") {
            try self.connectStream(target, package: currentPackage, direct: false)
          }
        } else {
          self.updateControls()
        }
      }
    }
    t.onSize = { [weak self, weak t] w, h in
      DispatchQueue.main.async {
        guard let self = self, self.transport === t, self.generation == id else { return }
        self.cancelLayoutCalibration()
        self.rootView.canvas.cancelEditorGesture()
        self.input.resize(width: w, height: h)
        self.rootView.canvas.dimensions = CGSize(width: w, height: h)
        self.rootView.canvas.needsLayout = true
        self.updateProjectionSize(width: w, height: h)
        self.resumeInputForDisplay(width: w, height: h)
      }
    }
    let presenter = FramePresenter(render: { [weak self] buffer in self?.rootView.canvas.metal.submit(buffer) }, changed: { [weak self, weak t] w, h in
      guard let self = self else { return }
      DispatchQueue.main.async {
        guard self.transport === t, self.generation == id else { return }
        self.updateProjectionSize(width: w, height: h)
        self.resumeInputForDisplay(width: w, height: h)
        if self.input.width != w || self.input.height != h {
          self.cancelLayoutCalibration()
          self.rootView.canvas.cancelEditorGesture()
          self.input.resize(width: w, height: h)
          self.rootView.canvas.dimensions = CGSize(width: w, height: h)
          self.rootView.canvas.needsLayout = true
        }
      }
    })
    framePresenter = presenter
    if let projected = DispatchQueue.main.sync(execute: { self.projection?.canvas.metal }) {
      presenter.setProjection { [weak projected] buffer in projected?.submit(buffer) }
    }
    t.onFrame = { [weak presenter] buffer in presenter?.submit(buffer) }
    do { try t.start() } catch {
      t.close()
      if direct && runtime.owns(target) && !CommandLine.arguments.contains("--encoded-video") {
        log("画面直连暂不可用，切换到 H.264：\(error.localizedDescription)")
        try connectStream(target, package: package, direct: false)
        return
      }
      throw error
    }
    if package != "default" {
      let spec = DispatchQueue.main.sync { self.displaySpec(package: package).using(self.runtime.resolution) }
      try runtime.applyDisplay(spec, serial: target)
      try runtime.launch(package, serial: target)
    }
    let apps = DispatchQueue.main.sync { self.knownApps }
    DispatchQueue.main.async {
      guard self.transport === t, self.generation == id, !self.quitting else { return }
      self.serial = target
      self.ready = true
      if self.firstReadyMs == 0 { self.firstReadyMs = (ProcessInfo.processInfo.systemUptime - self.appLaunchTime) * 1000 }
      self.activePackage = package
      self.activeScheme = self.prefs.profileSelections?[package] ?? ""
      self.androidGamePackages = Set(apps.filter(\.isGame).map(\.package))
      self.prepareInteractionSchemes(package: package)
      if !MappingStore.schemes(package: package, profiles: self.profiles).contains(
        self.activeScheme)
      {
        self.activeScheme = ""
      }
      self.profile = MappingStore.resolve(
        package: package, scheme: self.activeScheme, profiles: self.profiles)
      self.input.profile = self.profile
      self.input.writer = { [weak t] packet in t?.send(packet) }
      self.input.enabled = true
      self.rootView.canvas.editing = false
      self.renderProfile()
      self.renderApps(apps)
      self.rememberApplication(package)
      self.requestDisplayForActivePackage()
      self.refreshGameAudio()
      self.status.stringValue = "Android 已就绪 · \(self.prefs.ramMb / 1024) GB"
      self.updateControls()
      self.window.makeFirstResponder(self.rootView.canvas)
      if self.benchmark { self.benchmarkStart = ProcessInfo.processInfo.systemUptime }
      if CommandLine.arguments.contains("--mapping-ui-test") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.verifyMappingEditor() }
      } else if CommandLine.arguments.contains("--mapping-follow-test") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.verifyForegroundMapping() }
      } else if CommandLine.arguments.contains("--presentation-ui-test"), !self.presentationVerificationStarted {
        self.presentationVerificationStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.verifyPresentationUI() }
      } else if CommandLine.arguments.contains("--shell-lifecycle-test"), !self.shellLifecycleStarted {
        self.shellLifecycleStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.verifyShellLifecycle() }
      } else if CommandLine.arguments.contains("--startup-report") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.writeStartupReport() }
      }
    }
    worker.async {
      guard DispatchQueue.main.sync(execute: { self.generation == id && !self.quitting }) else { return }
      let listed = try? self.runtime.apps(serial: target)
      let gpu = try? self.runtime.adbRun(["shell", "dumpsys", "SurfaceFlinger"], serial: target)
      DispatchQueue.main.async {
        guard self.generation == id, self.serial == target else { return }
        if let listed = listed { self.renderApps(listed); self.rememberApplication(package); self.updateControls() }
        if let line = gpu?.split(separator: "\n").first(where: { $0.contains("GLES:") }) { self.log(String(line)) }
      }
    }
  }
  func start(package: String = "default") {
    operation("正在启动 Android · 硬件 GPU…") {
      self.runtime.ramMb = self.prefs.ramMb
      self.runtime.resolution = self.displaySpec(package: package).resolution
      self.runtime.mediaVolumePercent = self.prefs.mediaVolumePercent ?? 80
      let s = try self.runtime.start()
      try self.distribution.installMissing(in: self.runtime, serial: s)
      let target = package == "default" || (try? self.runtime.component(package, serial: s)) != nil ? package : "default"
      try self.connectStream(s, package: target)
    }
  }
  @objc func startClicked(_ sender: Any?) {
    if !settingsLoaded { initializeRuntime() } else { start(package: resumePackage) }
  }
  @objc func stopClicked(_ sender: Any?) {
    cancelLayoutCalibration()
    operation("正在关闭设备…") {
      self.transport?.close()
      self.framePresenter?.close()
      self.transport = nil
      self.runtime.stop()
      DispatchQueue.main.async {
        self.input.writer = nil
        self.ready = false
        self.serial = nil
        self.status.stringValue = "设备已关闭"
      }
    }
  }
  @objc func refreshDevices(_ sender: Any?) {
    guard settingsLoaded else { return }
    worker.async {
      let list = (try? self.runtime.devices()) ?? []
      DispatchQueue.main.async {
        self.devicesPopup.removeAllItems()
        self.devicesPopup.addItems(withTitles: list.isEmpty ? ["没有设备"] : list)
      }
    }
  }
  @objc func connectExisting(_ sender: Any?) {
    guard let s = devicesPopup.titleOfSelectedItem,
      s.hasPrefix("emulator-") || s.contains(":") || s != "没有设备"
    else { return }
    operation("连接设备…") { try self.connectStream(s) }
  }
  @objc func refreshApps(_ sender: Any?) {
    guard let s = serial else { return }
    operation("刷新应用…") {
      let apps = try self.runtime.apps(serial: s)
      DispatchQueue.main.async {
        self.renderApps(apps)
        self.status.stringValue = "应用已刷新"
      }
    }
  }
  func renderApps(_ cachedApps: [AndroidApp]) {
    let apps = cachedApps.map {
      AndroidApp(package: $0.package, name: AppInteraction.builtinNames[$0.package] ?? $0.name,
        isGame: $0.isGame || AppInteraction.knownGames.contains($0.package))
    }
    knownApps = apps
    rootView.appCount.stringValue = "\(apps.count)"
    androidGamePackages = Set(apps.filter(\.isGame).map(\.package))
    mappingPanel.refreshApplications(apps)
    for v in appsBox.arrangedSubviews {
      appsBox.removeArrangedSubview(v)
      v.removeFromSuperview()
    }
    for app in apps {
      let b = DeckAppButton(frame: .zero); b.title = app.name; b.target = self; b.action = #selector(launchApp(_:))
      b.package = app.package; b.detail = app.isGame ? "游戏 · 技能映射" : "应用 · 翻页遥控"
      if let resources = Bundle.main.resourceURL {
        for ext in ["png", "webp"] {
          if let image = NSImage(contentsOf: resources.appendingPathComponent("AppIcons/\(app.package).\(ext)")) { b.appIcon = image; break }
        }
      }
      b.tileColor = app.package == "com.phoenix.read" ? NSColor.systemOrange : app.package == "com.tencent.tmgp.pubgmhd" ? NSColor.systemTeal : app.package == "com.tencent.tmgp.sgame" ? NSColor.systemYellow : DeckTheme.accent
      b.selectedApp = app.package == prefs.lastOpenedPackage
      b.widthAnchor.constraint(equalToConstant: 224).isActive = true
      b.setAccessibilityLabel(app.name); b.setAccessibilityHelp(b.detail)
      b.identifier = NSUserInterfaceItemIdentifier(app.package)
      appsBox.addArrangedSubview(b)
    }
    if ready, let bytes = try? JSONEncoder().encode(apps) {
      try? bytes.write(to: root.appendingPathComponent("data/application-library.json"), options: .atomic)
    }
    rootView.needsLayout = true
  }
  @objc func launchApp(_ sender: NSButton) {
    guard let p = sender.identifier?.rawValue, !busy, settingsLoaded, !benchmark else { return }
    guard ready, let s = serial else { start(package: p); return }
    // App switching keeps the VM and its physical framebuffer alive. Applying a
    // different saved resolution is a separate, explicit device operation.
    let spec = displaySpec(package: p).using(runtime.resolution)
    let begun = ProcessInfo.processInfo.systemUptime
    input.suspended = true
    operation("打开 \(sender.title)…") {
      do {
        try self.runtime.applyDisplay(spec, serial: s)
        try self.runtime.launch(p, serial: s)
      } catch {
        DispatchQueue.main.async {
          self.displayAwaitingFrame = spec
          self.resumeInputForDisplay(width: self.input.width, height: self.input.height)
        }
        throw error
      }
      DispatchQueue.main.async {
        self.selectMappingPackage(p)
        self.displayAwaitingFrame = spec
        self.resumeInputForDisplay(width: self.input.width, height: self.input.height)
        self.rememberApplication(p)
        self.status.stringValue = sender.title
        self.window.makeFirstResponder(self.rootView.canvas)
        self.log(String(format: "切换 %@ 用时 %.2f 秒 · Android 保持运行", sender.title, ProcessInfo.processInfo.systemUptime - begun))
      }
    }
  }
  @objc func install(_ sender: Any?) {
    guard serial != nil else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
    panel.beginSheetModal(for: window) { result in
      if result == .OK, let url = panel.url {
        self.installAPK(url)
      }
    }
  }
  func installAPK(_ url: URL) {
    guard let s = serial, ready, !busy else {
      status.stringValue = "请先启动 Android 再安装 APK"
      return
    }
    operation("安装 \(url.lastPathComponent)…") {
      try self.runtime.install(url, serial: s)
      let apps = try self.runtime.apps(serial: s)
      DispatchQueue.main.async {
        self.renderApps(apps)
        self.status.stringValue = "APK 安装成功"
      }
    }
  }
  func controlTextDidBeginEditing(_ notification: Notification) {
    input.release(); captureIndex = nil; captureMouseEnabled = false
    rootView.canvas.bindingPrompt = rootView.canvas.editing ? "点技能后按键设置 · 当前可编辑名称和参数" : nil
  }
  func persistPreferences() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let bytes = try? encoder.encode(prefs) {
      try? bytes.write(to: root.appendingPathComponent("data/settings.json"), options: .atomic)
    }
  }
  @objc func applyRAM(_ sender: Any?) {
    guard settingsLoaded else { return }
    let ram = ramPopup.indexOfSelectedItem == 1 ? 8192 : 6144
    let p = activePackage
    let owned = runtime.owns(serial)
    prefs.ramMb = ram
    persistPreferences()
    operation(owned ? "切换运存并重启…" : "保存运存…") {
      self.runtime.ramMb = ram
      if owned {
        self.transport?.close()
        self.transport = nil
        self.runtime.stop(saveQuickBoot: false)
        self.runtime.resolution = self.displaySpec(package: p).resolution
        let s = try self.runtime.start(allowQuickRestore: false)
        try self.connectStream(s, package: p)
      } else {
        DispatchQueue.main.async { self.status.stringValue = "已保存 \(ram/1024) GB，下一次启动生效" }
      }
    }
  }
  @objc func changeQuality(_ sender: Any?) {
    let high = quality.indexOfSelectedItem == 1
    prefs.streamSize = high ? 1280 : 960
    prefs.streamFps = high ? 60 : 45
    prefs.streamBitrate = high ? 8_000_000 : 4_000_000
    persistPreferences()
    reconnect(nil)
  }
  @objc func reconnect(_ sender: Any?) {
    guard let s = serial else { return }
    let p = activePackage
    operation("重连原生画面…") { try self.connectStream(s, package: p) }
  }
  @objc func nav(_ sender: NSButton) {
    input.clickKey(UInt32(sender.tag))
    window.makeFirstResponder(rootView.canvas)
  }
  @objc func rotate(_ sender: Any?) {
    guard let s = serial else { return }
    if runtime.owns(s) {
      orientationPopup.selectItem(at: DeckOrientation.allCases.firstIndex(of: input.width > input.height ? .portrait : .landscape)!)
      changeDisplayOption(nil)
    } else {
      // scrcpy's explicit rotate-device command does not rewrite phone display settings.
      transport?.send(Data([11]))
    }
  }
  @objc func screenshot(_ sender: Any?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "AndroidDeck.png"
    panel.beginSheetModal(for: window) { result in
      guard result == .OK, let url = panel.url, let s = self.serial else { return }
      self.operation("保存截图…") {
        let remote = "/data/local/tmp/androiddeck-shot.png"
        _ = try self.runtime.adbRun(["shell", "screencap", "-p", remote], serial: s)
        _ = try self.runtime.adbRun(["pull", remote, url.path], serial: s)
        _ = try? self.runtime.adbRun(["shell", "rm", remote], serial: s)
        DispatchQueue.main.async { self.status.stringValue = "截图已保存" }
      }
    }
  }
  func renderProfile() {
    rootView.canvas.profile = profile
    rootView.canvas.showMarkers = prefs.showMappings
    rootView.canvas.mappingEnabled = input.enabled
    rootView.canvas.needsDisplay = true
    showButton.state = prefs.showMappings ? .on : .off
    mappingButton.state = input.enabled ? .on : .off
    mappingPanel.refresh()
    renderPresentation()
    projection?.canvas.profile = profile
    projection?.canvas.mappingEnabled = input.enabled
    rootView.scrollMappingsToTop = false
    rootView.needsLayout = true
    renderAudio()
    updateShell()
  }
  func saveProfile(rebuild: Bool = true) {
    do {
      profile = try profile.checked()
      profiles[mappingKey] = profile
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(profiles).write(
        to: root.appendingPathComponent("data/profiles.json"), options: .atomic)
      input.profile = profile
      rootView.canvas.profile = profile
      if rebuild { renderProfile() } else { rootView.canvas.needsDisplay = true }
    } catch { showError(error.localizedDescription) }
  }
  @objc func toggleMapping(_ sender: Any?) {
    input.release()
    input.enabled = mappingButton.state == .on
    renderProfile()
  }
  @objc func toggleMarkers(_ sender: Any?) {
    prefs.showMappings = showButton.state == .on
    persistPreferences()
    renderProfile()
    window.makeFirstResponder(rootView.canvas)
  }
  @objc func editMapping(_ sender: Any?) {
    if rootView.inspector != .mappings { setInspector(.mappings) }
    input.release()
    cancelLayoutCalibration()
    captureIndex = nil
    rootView.canvas.editing.toggle()
    rootView.canvas.cancelEditorGesture()
    if rootView.canvas.editing {
      ensurePersonalMappingScheme()
      rootView.canvas.tool = "select"
      mappingPanel.tool.selectItem(at: 0)
      rootView.canvas.bindingPrompt = contentKind == .app ? "点触摸位置 → 按键设置 · 拖动调整翻页轨迹" : "点一下技能 → 按键设置 · 拖动调整位置 · 完成后使用"
    }
    renderProfile()
  }
  @objc func captureKey(_ sender: NSButton) {
    input.release()
    captureIndex = sender.tag
    sender.title = "按键…"
  }
  @objc func resetProfile(_ sender: Any?) {
    guard !busy else { return }
    input.release()
    commitMapping(Profile.initial(for: activePackage))
  }
  @objc func modeChanged(_ sender: NSPopUpButton) {
    input.release()
    profile.bindings[sender.tag].mode = sender.indexOfSelectedItem == 1 ? "tap" : "hold"
    saveProfile()
  }
  @objc func bindingVisible(_ sender: NSButton) {
    profile.bindings[sender.tag].visible = profile.bindings[sender.tag].visible == false
    saveProfile()
  }
  @objc func deleteBinding(_ sender: NSButton) {
    input.release()
    profile.bindings.remove(at: sender.tag)
    saveProfile()
  }
  @objc func addBinding(_ sender: Any?) {
    guard profile.bindings.count < 20 else { return }
    let used = Set(
      profile.bindings.map(\.code) + profile.joystick.keys + profile.shortcuts.map(\.code))
    guard
      let key = ["KeyG", "KeyQ", "KeyE", "KeyZ", "KeyX", "KeyC", "KeyV", "KeyB", "KeyN", "KeyT"]
        .first(where: { !used.contains($0) })
    else { return }
    input.release()
    profile.bindings.append(
      Binding(code: key, mode: "hold", x: 0.5, y: 0.5, label: "新触点", visible: nil))
    saveProfile()
  }
  @objc func toggleJoystick(_ sender: NSButton) {
    input.release()
    profile.joystick.enabled = sender.state == .on
    saveProfile()
  }
  @objc func toggleJoystickVisible(_ sender: NSButton) {
    profile.joystick.visible = sender.state == .on
    saveProfile()
  }
  @objc func radiusChanged(_ sender: NSSlider) {
    input.release()
    profile.joystick.radius = sender.doubleValue / 100
    saveProfile(rebuild: false)
  }
  @objc func importProfile(_ sender: Any?) {
    input.release()
    let p = NSOpenPanel()
    p.allowedContentTypes = [.json]
    let keep = NSButton(checkboxWithTitle: "保留当前已校准的摇杆", target: nil, action: nil)
    keep.state = .on
    p.accessoryView = keep
    p.beginSheetModal(for: window) { result in
      guard result == .OK, let url = p.url else { return }
      do {
        let bytes = try Data(contentsOf: url)
        self.input.release()
        let imported = try MuMuMappingImport.decode(
          bytes, current: self.profile, keepJoystick: keep.state == .on, width: self.input.width,
          height: self.input.height)
        self.commitMapping(imported.profile)
        self.status.stringValue =
          imported.skipped.isEmpty ? "映射方案已导入" : "方案已导入；未支持的 MuMu 控件 \(imported.skipped.count) 项"
      } catch { self.showError(error.localizedDescription) }
    }
  }
  @objc func exportProfile(_ sender: Any?) {
    let p = NSSavePanel()
    p.allowedContentTypes = [.json]
    p.nameFieldStringValue = "AndroidDeck-映射.json"
    p.beginSheetModal(for: window) { result in
      if result == .OK, let url = p.url, let bytes = try? JSONEncoder().encode(self.profile) {
        try? bytes.write(to: url, options: .atomic)
      }
    }
  }
  @objc func sendText(_ sender: Any?) {
    input.text(text.stringValue)
    text.stringValue = ""
    window.makeFirstResponder(rootView.canvas)
  }
  @objc func fullscreen(_ sender: Any?) {
    input.release()
    window.toggleFullScreen(nil)
  }
  @objc func hideFullscreenControls(_ sender: Any?) { rootView.bottom.hideNow(); window.makeFirstResponder(rootView.canvas) }
  @objc func toggleFullscreenControls(_ sender: Any?) {
    if NSApp.keyWindow === projection?.window { projection?.viewport.controls.toggleVisibility() }
    else if rootView.full { rootView.bottom.toggleVisibility() }
  }
  func windowDidEnterFullScreen(_ notification: Notification) {
    input.release()
    rootView.full = true
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    rootView.needsLayout = true
    window.makeFirstResponder(rootView.canvas)
  }
  func windowDidExitFullScreen(_ notification: Notification) {
    input.release()
    rootView.full = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    rootView.needsLayout = true
  }
  func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
    [.fullScreen, .autoHideDock, .autoHideMenuBar]
  }
  func windowDidResignKey(_ notification: Notification) { input.release() }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(nil)
    return false
  }
  func handleKey(_ e: NSEvent) -> NSEvent? {
    guard e.window === window || e.window === projection?.window, let code = physicalCodes[e.keyCode] else { return e }
    let masks: [UInt16: UInt] = [56: 2, 60: 4, 59: 1, 62: 0x2000, 58: 0x20, 61: 0x40]
    let down =
      e.type == .flagsChanged
      ? e.modifierFlags.rawValue & (masks[e.keyCode] ?? 0) != 0 : e.type == .keyDown
    // Key-up releases pointers even after focus moves to a text field.
    if !down { input.key(code, false) }
    if down, code == "KeyH", e.modifierFlags.contains([.command, .shift]),
      rootView.full || projection?.viewport.full == true {
      if !e.isARepeat { toggleFullscreenControls(nil) }; return nil
    }
    if down, code == "Escape", calibrationOriginal != nil {
      cancelLayoutCalibration()
      renderProfile()
      return nil
    }
    if down, captureIndex != nil {
      captureMappingCode(code)
      return nil
    }
    if down, code == "F11" {
      if !e.isARepeat { if e.window === projection?.window { projection?.window.toggleFullScreen(nil) } else { fullscreen(nil) } }
      return nil
    }
    if down, code == "Escape", rootView.full {
      fullscreen(nil)
      return nil
    }
    if down, code == "Escape", e.window === projection?.window, projection?.window.styleMask.contains(.fullScreen) == true {
      projection?.window.toggleFullScreen(nil); return nil
    }
    if e.modifierFlags.contains(.command) || e.window?.firstResponder is NSTextView
      || e.window?.firstResponder is NSTextField || rootView.canvas.editing || busy || !ready || input.suspended
    {
      return e
    }
    if profile.bindings.contains(where: { $0.code == code })
      || profile.shortcuts.contains(where: { $0.code == code })
      || profile.joystick.enabled && profile.joystick.keys.contains(code)
    {
      if !e.isARepeat { input.key(code, down) }
      return nil
    }
    return e
  }
  func tick() {
    if rootView.inspector == .settings, ProcessInfo.processInfo.systemUptime - lastDeviceInfoRefresh >= 5 {
      refreshDeviceInformation(nil)
    }
    if CommandLine.arguments.contains("--overlay-live-test") {
      rootView.canvas.needsDisplay = true
      if ready, foregroundTicks % 15 == 0 {
        let report: [String: Any] = ["ready": ready, "uptimeSeconds": ProcessInfo.processInfo.systemUptime, "markerDraws": rootView.canvas.markerDraws,
          "cachedLines": rootView.canvas.markerText.count, "package": activePackage, "scheme": activeScheme]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: root.appendingPathComponent("data/marker-live-report.json"), options: .atomic) }
      }
    }
    foregroundTicks += 1
    if foregroundTicks % 2 == 0 { pollForegroundMapping() }
    audioRefreshTicks += 1
    if audioRefreshTicks % 3 == 0, ready, !busy { refreshGameAudio() }
    let now = ProcessInfo.processInfo.systemUptime
    let dt = max(0.1, now - lastTick)
    lastTick = now
    let counts = transport?.counters() ?? (0, 0)
    let receive = Double(max(0, counts.0 - previousReceived)) / dt
    let decode = Double(max(0, counts.1 - previousDecoded)) / dt
    let display = Double(displayed - previousDisplay) / dt
    previousReceived = counts.0
    previousDecoded = counts.1
    previousDisplay = displayed
    fpsLabel.stringValue = ready ? String(format: "显示 %.0f FPS · 接收 %.0f FPS", display, receive) : "等待连接"
    if benchmark, benchmarkStart > 0 {
      let elapsed = now - benchmarkStart
      if elapsed > 5 {
        benchmarkSamples.append([
          "receivedFps": receive, "decodedFps": decode, "displayedFps": display,
        ])
      }
      if elapsed > 22 {
        benchmark = false
        finishBenchmark()
      }
    }
  }
  func finishBenchmark() {
    input.release()
    let samples = benchmarkSamples
    let game = benchmarkGame
    rootView.savePreview(root.appendingPathComponent("data/verified-native.png"))
    if let image = rootView.canvas.metal.snapshot(), let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    {
      try? png.write(to: root.appendingPathComponent("data/native-video.png"))
    }
    worker.async {
      do {
        guard let serial = self.serial else { return }
        var result: [String: Any] = [
          "samples": samples, "hardwareDecoder": self.transport?.hardwareDecoder ?? false,
          "scene": game ? "DNF" : "TouchLab",
          "transport": self.transport?.mappedMode == true ? "RGBA shared memory" : self.transport?.rawMode == true ? "RGBA direct" : "H264",
          "transportMetrics": self.transport?.metrics ?? [:],
          "preset": [
            "size": self.prefs.size, "fps": self.prefs.fps, "bitrate": self.prefs.bitrate,
          ],
        ]
        if !game {
          let foreground = try self.runtime.adbRun(["shell", "dumpsys", "activity", "activities"], serial: serial)
          guard ReadySchemeCatalogue.foregroundPackage(in: foreground) == "com.androiddeck.demo" else {
            throw DeckError(message: "测试应用已切换，性能验证停止")
          }
          DispatchQueue.main.async {
            self.input.key("KeyW", true)
            self.input.key("Space", true)
          }
          Thread.sleep(forTimeInterval: 0.4)
          DispatchQueue.main.async { self.input.release() }
          Thread.sleep(forTimeInterval: 0.4)
          let events = try self.runtime.adbRun(
            ["shell", "cat", "/sdcard/Android/data/com.androiddeck.demo/files/touch-events.jsonl"],
            serial: serial)
          result["dualTouchObserved"] = events.contains("\"count\":2")
        }
        let gpu =
          try self.runtime.adbRun(["shell", "dumpsys", "SurfaceFlinger"], serial: serial).split(
            separator: "\n"
          ).first(where: { $0.contains("GLES:") }).map(String.init) ?? ""
        result["guestGPU"] = gpu
        let layers = try self.runtime.adbRun(
          ["shell", "dumpsys", "SurfaceFlinger", "--list"], serial: serial)
        let needle = game ? "com.tencent.tmgp.dnf" : "com.androiddeck.demo"
        if let layer = layers.split(separator: "\n").first(where: {
          $0.contains(needle)
            && (game ? $0.hasPrefix("SurfaceView[") : $0.hasPrefix("com.androiddeck.demo/"))
        }) {
          let latency = try self.runtime.adbRun(
            ["shell", "dumpsys", "SurfaceFlinger", "--latency", String(layer)], serial: serial)
          let times = latency.split(separator: "\n").dropFirst().compactMap { line -> Double? in
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard columns.count == 3, let n = Double(columns[1]), n > 0, n < 9e18 else {
              return nil
            }
            return n
          }
          if let first = times.first, let last = times.last, last > first {
            result["guestSurfaceFps"] = Double(times.count - 1) * 1e9 / (last - first)
          }
        }
        let filename = game ? "native-game-performance.json" : "native-performance.json"
        try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(
          to: self.root.appendingPathComponent("data/" + filename))
        if !game && CommandLine.arguments.contains("--verify-native") {
          let checks: [String: Any]
          do { checks = try self.verifyNative(serial: serial) }
          catch { checks = ["passed": false, "error": error.localizedDescription] }
          try JSONSerialization.data(withJSONObject: checks, options: .prettyPrinted).write(
            to: self.root.appendingPathComponent("data/native-integration-report.json"))
          self.log("NATIVE_INTEGRATION_DONE")
        }
        self.log("NATIVE_BENCHMARK_DONE")
        DispatchQueue.main.async { self.status.stringValue = "原生性能检查完成" }
        if CommandLine.arguments.contains("--quit-after-benchmark") {
          RunLoop.main.perform { NSApp.terminate(nil) }
        }
      } catch {
        self.showError(error.localizedDescription)
        let failure: [String: Any] = ["passed": false, "error": error.localizedDescription]
        let filename = game ? "native-game-performance.json" : "native-performance.json"
        if let data = try? JSONSerialization.data(withJSONObject: failure) {
          try? data.write(to: self.root.appendingPathComponent("data/" + filename), options: .atomic)
          if CommandLine.arguments.contains("--verify-native") { try? data.write(to: self.root.appendingPathComponent("data/native-integration-report.json"), options: .atomic) }
        }
        if CommandLine.arguments.contains("--quit-after-benchmark") { RunLoop.main.perform { NSApp.terminate(nil) } }
      }
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting { return .terminateLater }
    quitting = true
    window.orderOut(nil)
    cancelLayoutCalibration()
    input.release()
    ready = false
    worker.async {
      self.framePresenter?.close()
      self.transport?.close()
      self.runtime?.stop()
      RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
        NSApp.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
