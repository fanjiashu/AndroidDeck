// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension InputEngine {
  static let wheelActionIndex = 96

  // Explicit wheel bindings have priority. Apps otherwise receive a real finger swipe;
  // games retain Android's native mouse-wheel events.
  func wheel(_ x: Double, _ y: Double, deltaX: Double, deltaY: Double,
    precise: Bool = false, ended: Bool = false, momentum: Bool = false) {
    guard writer != nil, !suspended, x.isFinite, y.isFinite, deltaX.isFinite, deltaY.isFinite else { return }
    if ended { wheelAccumulated = 0 }
    guard abs(deltaX) + abs(deltaY) > 0.001 else { return }
    let code = deltaY > 0 ? "WheelUp" : "WheelDown"
    if enabled && abs(deltaY) > 0.001 &&
      (profile.bindings.contains { $0.code == code } || profile.shortcuts.contains { $0.code == code }) {
      key(code, true); key(code, false)
      return
    }
    guard wheelUsesTouch else { scroll(x, y, -deltaX / 100, -deltaY / 100); return }
    guard !momentum, abs(deltaY) > abs(deltaX) else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if precise {
      if now - wheelLastEvent > 0.3 || wheelAccumulated * deltaY < 0 { wheelAccumulated = 0 }
      wheelAccumulated += deltaY
      wheelLastEvent = now
      guard abs(wheelAccumulated) >= 20 else { return }
      wheelAccumulated = 0
    }
    let start = deltaY > 0 ? 0.3 : 0.75, end = deltaY > 0 ? 0.75 : 0.3
    let column = max(0.15, min(0.85, x))
    let gesture = Binding(code: code, mode: "swipe", x: column, y: start,
      label: "滚轮翻页", visible: false, durationMs: 240,
      path: [GesturePoint(x: column, y: start, t: 0), GesturePoint(x: column, y: end, t: 1)])
    if actions[Self.wheelActionIndex] != nil {
      // Keep at most one follow-up swipe. A trackpad/wheel burst must not keep
      // restarting the active finger or build seconds of delayed page changes.
      wheelPending = gesture
    } else {
      startBinding(gesture, index: Self.wheelActionIndex)
    }
  }

  func advanceWheel() {
    guard actions[Self.wheelActionIndex] == nil, let next = wheelPending else { return }
    wheelPending = nil
    guard wheelUsesTouch, !suspended, writer != nil else { return }
    startBinding(next, index: Self.wheelActionIndex)
  }

  func resetWheel() {
    wheelPending = nil; wheelAccumulated = 0; wheelLastEvent = 0
    cancelBinding(index: Self.wheelActionIndex)
  }
}
