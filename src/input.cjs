'use strict';
const { touchPacket, keyPacket, textPacket, scrollPacket } = require('./protocol.cjs');
const DEFAULT_PROFILE = {
  version: 1, joystick: { enabled: true, x: 0.22, y: 0.73, radius: 0.09,
    keys: ['KeyW', 'KeyA', 'KeyS', 'KeyD'] },
  bindings: [ { code: 'Space', mode: 'hold', x: 0.80, y: 0.73, label: '动作' },
    { code: 'KeyF', mode: 'tap', x: 0.72, y: 0.50, label: '交互' } ],
  shortcuts: [ { code: 'Escape', keycode: 4 }, { code: 'F2', keycode: 3 },
    { code: 'F3', keycode: 187 }, { code: 'F4', keycode: 24 }, { code: 'F5', keycode: 25 } ]
};
const validCode = code => typeof code === 'string' && /^(Key[A-Z]|Digit[0-9]|F([1-9]|1[0-2])|Space|Escape|Arrow(Up|Down|Left|Right)|Shift(Left|Right)|Control(Left|Right)|Alt(Left|Right)|Tab|Enter|Backspace)$/.test(code);
function inputLayout(profile) {
  const j = profile.joystick;
  return JSON.stringify({ joystick: { enabled: j.enabled, x: j.x, y: j.y, radius: j.radius, keys: j.keys },
    bindings: profile.bindings.map(({ code, mode, x, y }) => ({ code, mode, x, y })),
    shortcuts: profile.shortcuts.map(({ code, keycode }) => ({ code, keycode })) });
}
function validateProfile(p) {
  if (!p || p.version !== 1 || !Array.isArray(p.bindings) || p.bindings.length > 20
      || !Array.isArray(p.shortcuts) || p.shortcuts.length > 20) throw new Error('映射文件格式错误');
  const unit = n => Number.isFinite(n) && n >= 0 && n <= 1;
  const keys = new Set();
  const use = code => { if (code === 'F11') throw new Error('F11 保留给全屏切换'); if (!validCode(code) || keys.has(code)) throw new Error('按键无效或重复：' + code); keys.add(code); };
  const j = p.joystick;
  if (!j || typeof j.enabled !== 'boolean' || !unit(j.x) || !unit(j.y)
      || !Number.isFinite(j.radius) || j.radius < 0.01 || j.radius > 0.30
      || !Array.isArray(j.keys) || j.keys.length !== 4 || !j.keys.every(validCode)
      || new Set(j.keys).size !== 4) throw new Error('方向摇杆配置错误');
  if (j.enabled) j.keys.forEach(use);
  if (j.visible !== undefined && typeof j.visible !== 'boolean') throw new Error('摇杆显示设置错误');
  for (const b of p.bindings) {
    use(b.code);
    if (!['tap', 'hold'].includes(b.mode) || !unit(b.x) || !unit(b.y)
        || typeof b.label !== 'string' || b.label.length > 32
        || b.visible !== undefined && typeof b.visible !== 'boolean') throw new Error('触点配置错误');
  }
  for (const s of p.shortcuts) {
    use(s.code); if (![3, 4, 187, 24, 25, 26, 66, 67, 82].includes(s.keycode)) throw new Error('快捷键不支持');
  }
  return JSON.parse(JSON.stringify(p));
}
class InputEngine {
  constructor() { this.profile = validateProfile(DEFAULT_PROFILE); this.pressed = new Set(); this.contacts = new Map(); this.keys = new Set(); this.enabled = true; }
  attach(writer, width, height) { this.release(); this.writer = writer; this.resize(width, height); }
  resize(width, height) {
    if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 || width > 8192 || height > 8192) return;
    if (this.width !== width || this.height !== height) this.release();
    this.width = width; this.height = height;
  }
  setProfile(profile) {
    const valid = validateProfile(profile);
    if (inputLayout(this.profile) !== inputLayout(valid)) this.release();
    this.profile = valid;
  }
  setEnabled(enabled) { this.release(); this.enabled = !!enabled; }
  touch(action, id, x, y) {
    if (!this.writer || !this.width || ![x, y].every(Number.isFinite)) return;
    x = Math.max(0, Math.min(1, x)); y = Math.max(0, Math.min(1, y));
    if (action === 0 && this.contacts.has(id)) return;
    if (action === 0 && this.contacts.size >= 10) return; // pinned scrcpy MAX_POINTERS
    if (action !== 0 && !this.contacts.has(id)) return;
    const writer = this.writer;
    writer(touchPacket(action, id, x * this.width, y * this.height, this.width, this.height));
    if (this.writer !== writer) return;
    if (action === 1) this.contacts.delete(id); else this.contacts.set(id, { x, y });
  }
  key(code, down) {
    if (!validCode(code) || !this.enabled || !this.writer) return;
    if (down === this.pressed.has(code)) return; // suppress OS repeats and unmatched keyups
    if (down) this.pressed.add(code); else this.pressed.delete(code);
    const j = this.profile.joystick;
    if (j.enabled && j.keys.includes(code)) { this.joystick(); return; }
    const index = this.profile.bindings.findIndex(b => b.code === code);
    if (index >= 0) {
      const b = this.profile.bindings[index], id = 10 + index;
      if (down) { this.touch(0, id, b.x, b.y); if (b.mode === 'tap') this.touch(1, id, b.x, b.y); }
      else if (b.mode === 'hold') this.touch(1, id, b.x, b.y);
      return;
    }
    const s = this.profile.shortcuts.find(s => s.code === code);
    if (s) {
      this.writer(keyPacket(down ? 0 : 1, s.keycode));
      if (down) this.keys.add(s.keycode); else this.keys.delete(s.keycode);
    }
  }
  joystick() {
    const j = this.profile.joystick;
    const active = j.keys.some(k => this.pressed.has(k));
    if (!active) { this.touch(1, 100, j.x, j.y); return; }
    if (!this.contacts.has(100)) this.touch(0, 100, j.x, j.y);
    let dx = Number(this.pressed.has(j.keys[3])) - Number(this.pressed.has(j.keys[1]));
    let dy = Number(this.pressed.has(j.keys[2])) - Number(this.pressed.has(j.keys[0]));
    const magnitude = Math.hypot(dx, dy) || 1; dx /= magnitude; dy /= magnitude;
    // Radius is a fraction of the shorter screen edge, so circles stay circular.
    const scale = Math.min(this.width, this.height);
    this.touch(2, 100, j.x + dx * j.radius * scale / this.width, j.y + dy * j.radius * scale / this.height);
  }
  androidKey(code) { if (this.writer && [3, 4, 187, 24, 25, 26, 66, 67, 82].includes(code)) { this.writer(keyPacket(0, code)); this.writer(keyPacket(1, code)); } }
  text(value) { if (this.writer && typeof value === 'string') this.writer(textPacket(value)); }
  scroll(x, y, h, v) { if (this.writer && this.width) this.writer(scrollPacket(x, y, this.width, this.height, h, v)); }
  release() {
    for (const [id, p] of [...this.contacts]) this.touch(1, id, p.x, p.y);
    if (this.writer) for (const code of this.keys) this.writer(keyPacket(1, code));
    this.contacts.clear(); this.keys.clear(); this.pressed.clear();
  }
  detach() { this.release(); this.writer = null; }
}
module.exports = { InputEngine, DEFAULT_PROFILE, validateProfile, validCode };
