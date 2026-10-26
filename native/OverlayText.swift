// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import CoreText
import Foundation

enum OverlayTextStyle: Hashable { case key, caption, prompt }
private struct OverlayTextKey: Hashable {
  let text: String
  let style: OverlayTextStyle
}
private struct OverlayTextLine {
  let line: CTLine
  let size: CGSize
  let ascent: CGFloat
}

/// Immutable CoreText lines are prepared when text changes, never while painting.
final class OverlayTextCache {
  private let color: CGColor
  private let fonts: [OverlayTextStyle: CTFont] = [
    .key: CTFontCreateWithName("Menlo-Bold" as CFString, 10, nil),
    .caption: CTFontCreateWithName("HelveticaNeue" as CFString, 9, nil),
    .prompt: CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 14, nil),
  ]
  private var lines: [OverlayTextKey: OverlayTextLine] = [:]
  var count: Int { lines.count }
  init(color: CGColor) { self.color = color }
  func prepare(keys: [String], captions: [String], prompt: String?) {
    var wanted = Set(keys.map { OverlayTextKey(text: $0, style: .key) })
    wanted.formUnion(captions.map { OverlayTextKey(text: $0, style: .caption) })
    if let prompt = prompt { wanted.insert(OverlayTextKey(text: prompt, style: .prompt)) }
    var next: [OverlayTextKey: OverlayTextLine] = [:]
    for key in wanted {
      if let existing = lines[key] { next[key] = existing; continue }
      let foreground = key.style == .prompt ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : color
      let attributes: [CFString: Any] = [kCTFontAttributeName: fonts[key.style]!, kCTForegroundColorAttributeName: foreground]
      guard let string = CFAttributedStringCreate(nil, key.text as CFString, attributes as CFDictionary) else { continue }
      let line = CTLineCreateWithAttributedString(string)
      var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
      let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
      next[key] = OverlayTextLine(line: line, size: CGSize(width: max(0, width), height: max(1, ascent + descent + leading)), ascent: ascent)
    }
    lines = next
  }
  func size(_ text: String, style: OverlayTextStyle) -> CGSize {
    lines[OverlayTextKey(text: text, style: style)]?.size ?? .zero
  }
  func draw(_ text: String, style: OverlayTextStyle, topLeft: CGPoint, in context: CGContext) {
    guard let value = lines[OverlayTextKey(text: text, style: style)] else { return }
    context.saveGState()
    context.translateBy(x: topLeft.x, y: topLeft.y + value.ascent)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = .identity
    context.textPosition = .zero
    CTLineDraw(value.line, context)
    context.restoreGState()
  }
}
