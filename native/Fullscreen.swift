// SPDX-License-Identifier: GPL-3.0-only
import AppKit

// A floating control bar observes its whole viewport. It never changes the
// video frame or intercepts clicks after hiding.
final class FullscreenBar: NSView {
  var full = false { didSet { dismissButton?.isHidden = !full; if full != oldValue { pointerOverBar = false; reveal() } } }
  var dismissButton: NSButton? { didSet { dismissButton?.isHidden = !full } }
  var hideDelay = 2.5
  private var hideTimer: Timer?
  private var tracking: NSTrackingArea?
  private weak var viewport: NSView?
  private var pointerOverBar = false
  private var interactions = 0
  override var isFlipped: Bool { true }
  override func layout() {
    super.layout()
    if let controls = subviews.first as? NSStackView {
      controls.frame = NSRect(x: full ? 12 : 0, y: full ? 7 : 5, width: max(0, bounds.width - (full ? 24 : 0)), height: 34)
    }
  }

  func track(in view: NSView) {
    if let tracking = tracking { viewport?.removeTrackingArea(tracking) }
    viewport = view
    let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
    view.addTrackingArea(area); tracking = area
  }
  override func mouseMoved(with event: NSEvent) { guard full else { return }; pointerActivity(at: convert(event.locationInWindow, from: nil)) }
  override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
  override func mouseExited(with event: NSEvent) { guard full else { return }; pointerOverBar = false; scheduleHide() }
  func pointerActivity(at point: NSPoint) {
    pointerOverBar = bounds.contains(point)
    reveal()
  }
  func reveal() {
    hideTimer?.invalidate(); hideTimer = nil
    isHidden = false
    wantsLayer = true
    layer?.cornerRadius = full ? 14 : 0
    layer?.backgroundColor = full ? DeckTheme.background.withAlphaComponent(0.92).cgColor : NSColor.clear.cgColor
    layer?.borderColor = DeckTheme.line.withAlphaComponent(0.65).cgColor; layer?.borderWidth = full ? 1 : 0
    scheduleHide()
  }
  func beginInteraction() { interactions += 1; reveal() }
  func endInteraction() { interactions = max(0, interactions - 1); scheduleHide() }
  func hideNow() {
    guard full else { return }
    hideTimer?.invalidate(); hideTimer = nil
    pointerOverBar = false; isHidden = true
  }
  func toggleVisibility() { if isHidden { reveal() } else { hideNow() } }
  private func scheduleHide() {
    hideTimer?.invalidate(); hideTimer = nil
    guard full, !pointerOverBar, interactions == 0 else { return }
    let timer = Timer(timeInterval: hideDelay, repeats: false) { [weak self] _ in
      guard let self = self, self.full else { return }
      if self.window?.attachedSheet != nil || NSApp.modalWindow != nil || self.pointerOverBar || self.interactions > 0 {
        self.scheduleHide(); return
      }
      self.isHidden = true
      self.hideTimer = nil
    }
    hideTimer = timer; RunLoop.main.add(timer, forMode: .common)
  }
  deinit { hideTimer?.invalidate() }
}

final class ProjectionViewport: NSView {
  let canvas: VideoCanvas
  let controls = FullscreenBar(frame: .zero)
  var full = false { didSet { controls.full = full; needsLayout = true } }
  init(canvas: VideoCanvas) {
    self.canvas = canvas
    super.init(frame: .zero)
    addSubview(canvas); addSubview(controls)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func updateTrackingAreas() { super.updateTrackingAreas(); controls.track(in: self) }
  override func layout() {
    super.layout()
    canvas.frame = bounds; canvas.needsLayout = true
    controls.frame = NSRect(x: (bounds.width - 192) / 2, y: bounds.height - 68, width: 192, height: 44)
    if !full { controls.isHidden = true }
  }
}
