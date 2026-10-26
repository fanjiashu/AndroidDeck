// SPDX-License-Identifier: GPL-3.0-only
import CoreVideo
import Foundation

// Frame pixels stay on the renderer's latest-frame path. UI metadata is published only on a size change.
final class FramePresenter {
  private let lock = NSLock()
  private var active = true
  private var dimensions: (Int, Int)?
  private var projection: ((CVPixelBuffer) -> Void)?
  let render: (CVPixelBuffer) -> Void
  let changed: (Int, Int) -> Void
  init(render: @escaping (CVPixelBuffer) -> Void, changed: @escaping (Int, Int) -> Void) {
    self.render = render; self.changed = changed
  }
  func setProjection(_ value: ((CVPixelBuffer) -> Void)?) { lock.lock(); projection = value; lock.unlock() }
  func submit(_ frame: CVPixelBuffer) {
    let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
    lock.lock()
    guard active else { lock.unlock(); return }
    let different = dimensions?.0 != w || dimensions?.1 != h
    dimensions = (w, h)
    // Finish the bounded submission before close returns; an old stream cannot submit afterwards.
    render(frame); projection?(frame)
    lock.unlock()
    if different { changed(w, h) }
  }
  func close() { lock.lock(); active = false; projection = nil; lock.unlock() }
}
