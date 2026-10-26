// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import QuartzCore

enum DeckTheme {
  static let background = NSColor(srgbRed: 0.044, green: 0.057, blue: 0.078, alpha: 1)
  static let sidebar = NSColor(srgbRed: 0.064, green: 0.080, blue: 0.105, alpha: 1)
  static let surface = NSColor(srgbRed: 0.083, green: 0.103, blue: 0.133, alpha: 1)
  static let raised = NSColor(srgbRed: 0.120, green: 0.145, blue: 0.180, alpha: 1)
  static let line = NSColor(srgbRed: 0.20, green: 0.24, blue: 0.29, alpha: 1)
  static let ink = NSColor(srgbRed: 0.94, green: 0.96, blue: 0.98, alpha: 1)
  static let secondary = NSColor(srgbRed: 0.62, green: 0.68, blue: 0.75, alpha: 1)
  static let accent = NSColor(srgbRed: 0.72, green: 0.94, blue: 0.51, alpha: 1)
  static let motion = 0.18
  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  static func styleSurface(_ view: NSView, radius: CGFloat = 16, color: NSColor = surface, border: Bool = true) {
    view.wantsLayer = true
    view.layer?.cornerRadius = radius
    view.layer?.backgroundColor = color.cgColor
    view.layer?.borderWidth = border ? 1 : 0
    view.layer?.borderColor = line.withAlphaComponent(0.65).cgColor
  }
  static func section(_ title: String, detail: String? = nil) -> NSStackView {
    let stack = MappingColumn(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
    let heading = label(title, 14, ink); heading.font = .systemFont(ofSize: 14, weight: .semibold)
    stack.addArrangedSubview(heading)
    if let detail = detail { stack.addArrangedSubview(label(detail, 11, secondary)) }
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 4, right: 0)
    return stack
  }
  static func styleControls(in view: NSView) {
    if let popup = view as? NSPopUpButton { popup.font = .systemFont(ofSize: 12); popup.controlSize = .regular }
    else if let field = view as? NSTextField, field.isEditable {
      field.font = .systemFont(ofSize: 12); field.focusRingType = .default
    }
    for child in view.subviews { styleControls(in: child) }
  }
}

// Keep NSButton's action routing, keyboard activation and accessibility. Only
// drawing and hover feedback are custom; clicks remain native AppKit behavior.
class DeckButton: NSButton {
  enum Style { case normal, primary, quiet, icon }
  var visualStyle = Style.normal { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
  private(set) var hovered = false
  private var area: NSTrackingArea?
  override var intrinsicContentSize: NSSize {
    let text = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)])
    return NSSize(width: max(visualStyle == .icon ? 36 : 58, text.width + (image == nil ? 24 : 46)), height: 34)
  }
  override init(frame: NSRect) { super.init(frame: frame); isBordered = false; font = .systemFont(ofSize: 12, weight: .medium); focusRingType = .default }
  required init?(coder: NSCoder) { super.init(coder: coder) }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let area = area { removeTrackingArea(area) }
    let next = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
    addTrackingArea(next); area = next
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    let selected = state == .on, pressed = isHighlighted
    let fill: NSColor
    switch visualStyle {
    case .primary: fill = DeckTheme.accent.withAlphaComponent(isEnabled ? (pressed ? 0.72 : hovered ? 0.91 : 1) : 0.20)
    case .quiet, .icon: fill = selected ? DeckTheme.accent.withAlphaComponent(0.14) : hovered || pressed ? DeckTheme.raised : .clear
    case .normal: fill = selected ? DeckTheme.accent.withAlphaComponent(0.14) : hovered || pressed ? DeckTheme.raised : DeckTheme.surface
    }
    let rect = bounds.insetBy(dx: 1, dy: 2), path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
    fill.setFill(); path.fill()
    if visualStyle == .normal { DeckTheme.line.withAlphaComponent(0.55).setStroke(); path.lineWidth = 1; path.stroke() }
    let foreground = visualStyle == .primary && isEnabled ? DeckTheme.background : selected ? DeckTheme.accent : DeckTheme.ink
    let alpha: CGFloat = isEnabled ? 1 : 0.40
    let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: foreground.withAlphaComponent(alpha)]
    let text = title as NSString, size = text.size(withAttributes: attributes)
    let imageOnly = imagePosition == .imageOnly || title.isEmpty
    let iconSize: CGFloat = visualStyle == .icon ? 18 : 16
    let total = size.width + (image != nil && !imageOnly ? iconSize + 7 : 0)
    let start = (bounds.width - total) / 2
    if let image = image {
      let original = image.copy() as! NSImage; original.isTemplate = false
      let tinted = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
        original.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        foreground.setFill(); rect.fill(using: .sourceAtop)
        return true
      }
      let target = NSRect(x: imageOnly ? (bounds.width - iconSize) / 2 : start, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
      NSGraphicsContext.saveGraphicsState()
      tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
    }
    if !imageOnly { text.draw(at: NSPoint(x: start + (image == nil ? 0 : iconSize + 7), y: (bounds.height - size.height) / 2), withAttributes: attributes) }
    if window?.firstResponder === self { DeckTheme.accent.setStroke(); NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 8, yRadius: 8).stroke() }
  }
}

final class DeckAppButton: DeckButton {
  var package = ""
  var detail = ""
  var selectedApp = false { didSet { needsDisplay = true } }
  var appIcon: NSImage?
  var tileColor = DeckTheme.accent
  override var intrinsicContentSize: NSSize { NSSize(width: 224, height: 64) }
  override func draw(_ dirtyRect: NSRect) {
    let selected = selectedApp, alpha: CGFloat = isEnabled ? 1 : 0.42
    let rect = bounds.insetBy(dx: 1, dy: 1)
    let fill = selected ? DeckTheme.accent.withAlphaComponent(0.085) : isHighlighted || hovered ? DeckTheme.raised : DeckTheme.surface.withAlphaComponent(0.35)
    fill.setFill(); NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
    if selected {
      DeckTheme.accent.withAlphaComponent(0.28).setStroke(); NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).stroke()
      DeckTheme.accent.setFill(); NSBezierPath(roundedRect: NSRect(x: 1, y: 20, width: 3, height: 24), xRadius: 1.5, yRadius: 1.5).fill()
    }
    let iconRect = NSRect(x: 12, y: 14, width: 36, height: 36)
    tileColor.withAlphaComponent(0.14 * alpha).setFill(); NSBezierPath(roundedRect: iconRect, xRadius: 10, yRadius: 10).fill()
    if let appIcon = appIcon {
      NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: iconRect, xRadius: 10, yRadius: 10).addClip()
      appIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
    } else {
      let initial = String(title.prefix(1)) as NSString
      let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: tileColor.withAlphaComponent(alpha)]
      let size = initial.size(withAttributes: attrs)
      initial.draw(at: NSPoint(x: iconRect.midX - size.width / 2, y: iconRect.midY - size.height / 2), withAttributes: attrs)
    }
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
    (title as NSString).draw(in: NSRect(x: 60, y: 14, width: bounds.width - 72, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: DeckTheme.ink.withAlphaComponent(alpha), .paragraphStyle: paragraph])
    (detail as NSString).draw(in: NSRect(x: 60, y: 34, width: bounds.width - 72, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: (selected ? DeckTheme.accent : DeckTheme.secondary).withAlphaComponent(alpha), .paragraphStyle: paragraph])
    if window?.firstResponder === self { DeckTheme.accent.setStroke(); NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10).stroke() }
  }
}

final class DeckInspectorSurface: NSView {
  override var isFlipped: Bool { true }
  override init(frame: NSRect) { super.init(frame: frame); DeckTheme.styleSurface(self, radius: 18) }
  required init?(coder: NSCoder) { fatalError() }
}
final class DeckHeader: NSView { override var isFlipped: Bool { true } }
