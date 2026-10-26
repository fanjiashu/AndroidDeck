// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

struct MediaVolume {
  let value: Int
  let maximum: Int
  var percent: Int { Int((Double(value) / Double(max(1, maximum)) * 100).rounded()) }
  init(output: String) throws {
    let expression = try NSRegularExpression(
      pattern: "volume is ([0-9]+) in range \\[([0-9]+)\\.\\.([0-9]+)\\]")
    guard
      let match = expression.firstMatch(
        in: output, range: NSRange(output.startIndex..., in: output)),
      let currentRange = Range(match.range(at: 1), in: output),
      let maximumRange = Range(match.range(at: 3), in: output),
      let value = Int(output[currentRange]), let maximum = Int(output[maximumRange]), maximum > 0
    else { throw DeckError(message: "无法读取设备媒体音量") }
    self.value = value
    self.maximum = maximum
  }
}
extension AndroidRuntime {
  func mediaVolume(serial: String) throws -> MediaVolume {
    try MediaVolume(
      output: adbRun(
        ["shell", "cmd", "media_session", "volume", "--stream", "3", "--get"], serial: serial))
  }
  func setMediaVolume(percent: Int, serial: String) throws -> MediaVolume {
    guard owns(serial) else { throw DeckError(message: "外接设备请使用音量快捷键") }
    let state = try mediaVolume(serial: serial)
    let index = Int((Double(max(0, min(100, percent))) * Double(state.maximum) / 100).rounded())
    // The bundled Android 14 shell command attributes setters to the wrong package under uid 2000.
    _ = try adbRun(
      [
        "shell", "su", "0", "cmd", "media_session", "volume", "--stream", "3", "--set",
        String(index),
      ], serial: serial)
    let updated = try mediaVolume(serial: serial)
    guard updated.value == index else { throw DeckError(message: "媒体音量设置未生效") }
    return updated
  }
}
#if !NATIVE_UNIT_TESTS
  extension AppDelegate {
    func setGameVolume(_ percent: Int) {
      guard ready, let serial = serial, runtime.owns(serial) else { return }
      let value = max(0, min(100, percent))
      audioPercent = value
      prefs.mediaVolumePercent = value
      if value > 0 { prefs.lastAudibleVolumePercent = value }
      persistPreferences()
      renderAudio()
      audioDebounce?.invalidate()
      audioRevision += 1
      let revision = audioRevision
      audioDebounce = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) {
        [weak self] _ in
        guard let self = self else { return }
        self.audioDebounce = nil
        self.worker.async {
          do {
            let state = try self.runtime.setMediaVolume(percent: value, serial: serial)
            DispatchQueue.main.async {
              guard self.audioRevision == revision else { return }
              self.audioPercent = state.percent
              self.audioMaximum = state.maximum
              self.prefs.mediaVolumePercent = state.percent
              if state.percent > 0 { self.prefs.lastAudibleVolumePercent = state.percent }
              self.persistPreferences()
              self.renderAudio()
            }
          } catch { self.showError(error.localizedDescription) }
        }
      }
    }
    func adjustGameAudio(_ action: String) {
      guard ready, let serial = serial else { return }
      if !runtime.owns(serial) {
        if let code = ["volumeUp": UInt32(24), "volumeDown": UInt32(25), "mute": UInt32(164)][
          action]
        {
          input.clickKey(code)
        }
        return
      }
      let step = max(1, Int((100.0 / Double(max(1, audioMaximum))).rounded()))
      if action == "mute" {
        setGameVolume(audioPercent == 0 ? prefs.lastAudibleVolumePercent ?? 80 : 0)
      } else {
        setGameVolume(audioPercent + (action == "volumeUp" ? step : -step))
      }
    }
    func renderAudio() {
      mappingPanel.volume.doubleValue = Double(audioPercent)
      mappingPanel.volumeText.stringValue =
        audioPercent == 0 ? "游戏音量 · 静音" : "游戏音量 · \(audioPercent)%"
      mappingPanel.volume.isEnabled = ready && !busy && runtime?.owns(serial) == true
    }
    func refreshGameAudio() {
      guard ready, let serial = serial, audioDebounce == nil else { return }
      let revision = audioRevision
      worker.async {
        if let state = try? self.runtime.mediaVolume(serial: serial) {
          DispatchQueue.main.async {
            guard self.audioRevision == revision else { return }
            self.audioPercent = state.percent
            self.audioMaximum = state.maximum
            if self.runtime.owns(serial), self.prefs.mediaVolumePercent != state.percent {
              self.prefs.mediaVolumePercent = state.percent
              if state.percent > 0 { self.prefs.lastAudibleVolumePercent = state.percent }
              self.persistPreferences()
            }
            self.renderAudio()
          }
        }
      }
    }
  }
#endif
