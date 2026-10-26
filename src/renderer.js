'use strict';
const $ = id => document.getElementById(id);
let current = { generation: 0, status: 'idle', profile: null, editing: false }, profile, busy = false;
let toastTimer, saveTimer, frameCount = 0, renderedFrames = 0, totalRendered = 0, lastFps = performance.now(), decoder, videoConfig, waitingForKey = true;
let moving = null, mouseDown = false, lastGeneration = -1;
const canvas = $('screen'), ctx = canvas.getContext('2d', { alpha: false });
const displayCode = code => ({ Space: 'SPACE', Escape: 'Esc', ShiftLeft: 'L⇧', ShiftRight: 'R⇧', ControlLeft: 'L⌃', ControlRight: 'R⌃', ArrowUp: '↑', ArrowDown: '↓', ArrowLeft: '←', ArrowRight: '→' }[code] || code.replace(/^Key|^Digit/, ''));
function toast(message, error = false) {
  $('toast').textContent = message; $('toast').classList.toggle('error', error); $('toast').hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { $('toast').hidden = true; }, error ? 8000 : 3500);
}
async function call(action, payload = {}, quiet = false) {
  try { return await window.deck.call(action, { generation: current.generation, ...payload }); }
  catch (error) { if (!quiet) toast(error.message.replace(/^Error invoking remote method 'deck:call': Error: /, ''), true); throw error; }
}
function send(message) { window.deck.input({ ...message, generation: current.generation }); }
async function task(action, payload = {}) {
  if (busy) return; busy = true; document.body.classList.add('busy'); updateControls();
  try { const result = await call(action, payload); if (['install', 'install-path'].includes(action) && result) { toast('APK 安装成功'); setView('apps'); } return result; }
  catch {} finally { busy = false; document.body.classList.remove('busy'); updateControls(); }
}
function setView(view) {
  send({ type: 'release' });
  for (const name of ['device', 'apps', 'logs']) $(`${name}-view`).hidden = name !== view;
  document.querySelectorAll('.nav').forEach(b => b.classList.toggle('active', b.dataset.view === view));
  $('page-title').textContent = { device: '虚拟设备', apps: '应用库', logs: '运行日志' }[view];
  fitScreen();
}
document.querySelectorAll('.nav').forEach(b => b.addEventListener('click', () => setView(b.dataset.view)));
function updateControls() {
  const ready = current.status === 'ready', booting = ['starting', 'connecting'].includes(current.status);
  for (const id of ['install', 'demo', 'rotate', 'screenshot', 'settings', 'reconnect', 'edit-mapping', 'refresh-apps', 'send-text', 'import-profile', 'reset-profile', 'mapping-toggle']) $(id).disabled = !ready || busy;
  $('start').disabled = booting || ready || busy; $('empty-start').disabled = booting || busy;
  $('stop').disabled = !ready || busy;
  $('connect-device').disabled = busy || !$('devices').value;
  $('memory-settings').disabled = busy || booting;
  $('fullscreen-memory').disabled = busy || booting;
  $('fullscreen').disabled = busy || current.fullscreenChanging;
  $('show-mappings').disabled = busy;
  document.querySelectorAll('.binding-row button,.binding-row input,.binding-row select,#joystick-toggle,#joystick-visible,#radius,#add-binding')
    .forEach(control => { control.disabled = !ready || busy; });
  $('boot-state').hidden = !booting;
  $('empty-state').hidden = ready || booting || !!current.size;
  $('screen-shell').hidden = !current.size;
  const label = { idle: '未启动', starting: '启动中', connecting: '连接中', ready: '运行中', error: '连接异常' }[current.status];
  $('status').className = 'status ' + current.status; $('status').lastChild.textContent = label;
  $('device-card-state').textContent = ready ? '● 运行中 · ' + current.serial : label;
  $('footer-state').textContent = ready ? '● 已连接 ' + current.serial : label;
}
function onState(state) {
  const enteredFullscreen = !current.fullscreen && state.fullscreen;
  if (lastGeneration !== state.generation) {
    lastGeneration = state.generation; videoConfig = null; waitingForKey = true;
    decoder?.close(); decoder = null; mouseDown = false;
  }
  current = state; profile = structuredClone(state.profile);
  document.body.classList.toggle('fullscreen-mode', !!state.fullscreen);
  $('fullscreen').textContent = state.fullscreen ? '退出全屏' : '⛶';
  $('show-mappings').checked = state.showMappings !== false;
  $('ram-current').textContent = `运存 ${(state.configuredRamMb || 6144) / 1024} GB`;
  $('ram-info').textContent = state.ownsDevice ? `当前运行 ${state.runningRamMb / 1024} GB` : '用于 AndroidDeck 虚拟设备';
  if (!$('memory-dialog').open) document.querySelectorAll('input[name="ram"]').forEach(radio => { radio.checked = Number(radio.value) === (state.configuredRamMb || 6144); });
  $('app-count').textContent = state.apps.length;
  $('mapping-toggle').checked = state.mappingEnabled;
  $('overlays').classList.toggle('editing', state.editing);
  $('edit-mapping').textContent = state.editing ? '完成编辑' : '编辑触点位置';
  $('edit-tip').hidden = !state.editing;
  $('profile-name').textContent = state.activePackage === 'default' ? '默认配置' : state.activePackage;
  $('active-app').textContent = '当前应用：' + (state.activePackage === 'default' ? '默认配置' : state.activePackage);
  if (state.size) $('resolution').textContent = `${state.size.width} × ${state.size.height}`;
  renderBindings(); renderOverlays(); renderApps(); updateControls(); fitScreen();
  if (enteredFullscreen) setView('device');
}
window.deck.onState(onState);
window.deck.onLog(entry => {
  const row = document.createElement('div'), time = document.createElement('span');
  time.className = 'log-time'; time.textContent = entry.time; row.append(time, document.createTextNode(entry.message));
  $('logs').append(row); while ($('logs').children.length > 300) $('logs').firstChild.remove();
  $('logs').scrollTop = $('logs').scrollHeight;
});
function codecFromAnnexB(data) {
  for (let i = 0; i < data.length - 7; i++) {
    let start = -1;
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) start = i + 3;
    else if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 0 && data[i + 3] === 1) start = i + 4;
    if (start >= 0 && (data[start] & 31) === 7) return 'avc1.' + [...data.slice(start + 1, start + 4)].map(n => n.toString(16).padStart(2, '0')).join('');
  }
  throw new Error('没有找到 H.264 配置');
}
function createDecoder(codec) {
  decoder?.close();
  decoder = new VideoDecoder({ output: frame => {
    try {
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth; canvas.height = frame.displayHeight;
        current.size = { width: canvas.width, height: canvas.height };
        send({ type: 'size', ...current.size }); fitScreen(); renderOverlays();
        $('resolution').textContent = `${canvas.width} × ${canvas.height}`;
      }
      ctx.drawImage(frame, 0, 0, canvas.width, canvas.height); renderedFrames++; totalRendered++;
    } finally { frame.close(); }
  }, error: error => { waitingForKey = true; toast('视频解码异常，请重新连接：' + error.message, true); } });
  decoder.configure({ codec, optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware', avc: { format: 'annexb' } });
}
window.deck.onFrame(frame => {
  try {
    if (frame.generation !== current.generation) return;
    frameCount++;
    const data = new Uint8Array(frame.data);
    if (frame.config) {
      const codec = codecFromAnnexB(data); videoConfig = data; createDecoder(codec); waitingForKey = true; return;
    }
    if (!decoder || decoder.state !== 'configured' || !videoConfig) return;
    if (decoder.decodeQueueSize > 4) {
      waitingForKey = true; createDecoder(codecFromAnnexB(videoConfig));
    }
    if (waitingForKey && !frame.key) return;
    const bytes = frame.key ? new Uint8Array(videoConfig.length + data.length) : data;
    if (frame.key) { bytes.set(videoConfig); bytes.set(data, videoConfig.length); waitingForKey = false; }
    decoder.decode(new EncodedVideoChunk({ type: frame.key ? 'key' : 'delta', timestamp: frame.timestamp, data: bytes }));
    const now = performance.now();
    if (now - lastFps > 1000) { $('fps').textContent = Math.round(renderedFrames * 1000 / (now - lastFps)) + ' FPS'; renderedFrames = 0; lastFps = now; }
  } catch (error) { toast('画面错误：' + error.message, true); }
  finally { window.deck.input({ type: 'ack', generation: frame.generation }); }
});
// Exposes read-only diagnostics for the real-device integration test.
Object.defineProperty(window, 'deckDiagnostics', { get: () => ({ received: frameCount, rendered: totalRendered, width: canvas.width, height: canvas.height, status: current.status, generation: current.generation }) });
function fitScreen() {
  if (!current.size || $('device-view').hidden) return;
  const bounds = $('screen-area').getBoundingClientRect(), ratio = current.size.width / current.size.height;
  const padding = current.fullscreen ? 0 : 28;
  const height = Math.min(Math.max(100, bounds.height - padding), Math.max(100, bounds.width - padding) / ratio);
  $('screen-shell').style.width = Math.round(height * ratio) + 'px';
  $('screen-shell').style.height = Math.round(height) + 'px';
  renderOverlays();
}
new ResizeObserver(fitScreen).observe($('screen-area'));
function coordinates(event) {
  const bounds = canvas.getBoundingClientRect();
  return { x: Math.max(0, Math.min(1, (event.clientX - bounds.left) / bounds.width)), y: Math.max(0, Math.min(1, (event.clientY - bounds.top) / bounds.height)) };
}
canvas.addEventListener('pointerdown', e => { if (current.editing || current.status !== 'ready' || e.button !== 0) return; e.preventDefault(); canvas.focus(); mouseDown = true; canvas.setPointerCapture(e.pointerId); send({ type: 'touch', action: 0, ...coordinates(e) }); });
canvas.addEventListener('pointermove', e => { if (mouseDown) send({ type: 'touch', action: 2, ...coordinates(e) }); });
function mouseUp(e) { if (mouseDown) { send({ type: 'touch', action: 1, ...coordinates(e) }); mouseDown = false; } }
canvas.addEventListener('pointerup', mouseUp); canvas.addEventListener('pointercancel', () => { send({ type: 'release' }); mouseDown = false; });
canvas.addEventListener('lostpointercapture', () => { if (mouseDown) { send({ type: 'release' }); mouseDown = false; } });
canvas.addEventListener('contextmenu', e => { e.preventDefault(); send({ type: 'android-key', keycode: 4 }); });
canvas.addEventListener('wheel', e => { e.preventDefault(); send({ type: 'scroll', ...coordinates(e), h: -e.deltaX / 100, v: -e.deltaY / 100 }); }, { passive: false });
function ignoresKeyboard(event) { return ['INPUT', 'TEXTAREA', 'SELECT'].includes(event.target.tagName) || event.target.classList.contains('key-capture') || current.editing || $('device-view').hidden; }
window.addEventListener('keydown', e => {
  if ($('memory-dialog').open) { if (e.code === 'Escape') { e.preventDefault(); $('memory-dialog').close(); } return; }
  if (current.fullscreenChanging && ['F11', 'Escape'].includes(e.code)) { e.preventDefault(); return; }
  if (e.code === 'F11' && !e.repeat) { e.preventDefault(); task('fullscreen', { enabled: !current.fullscreen }); return; }
  if (e.code === 'Escape' && current.fullscreen) { e.preventDefault(); if (!e.repeat) task('fullscreen', { enabled: false }); return; }
  if (ignoresKeyboard(e) || e.metaKey || current.status !== 'ready') return;
  if (profile?.bindings.some(b => b.code === e.code) || profile?.shortcuts.some(b => b.code === e.code) || profile?.joystick.enabled && profile.joystick.keys.includes(e.code)) { e.preventDefault(); send({ type: 'key', code: e.code, down: true }); }
});
window.addEventListener('keyup', e => { send({ type: 'key', code: e.code, down: false }); });
window.addEventListener('blur', () => { send({ type: 'release' }); mouseDown = false; });
document.addEventListener('visibilitychange', () => { if (document.hidden) send({ type: 'release' }); });
document.addEventListener('focusin', e => { if (['INPUT', 'SELECT', 'TEXTAREA'].includes(e.target.tagName) && !['show-mappings', 'joystick-visible'].includes(e.target.id)) send({ type: 'release' }); });
function persist() { clearTimeout(saveTimer); const snapshot = structuredClone(profile), gen = current.generation; saveTimer = setTimeout(() => call('save-profile', { profile: snapshot, generation: gen }).catch(() => { profile = structuredClone(current.profile); renderBindings(); renderOverlays(); }), 120); }
function renderBindings() {
  if (!profile) return; $('bindings').replaceChildren();
  $('joystick-toggle').checked = profile.joystick.enabled;
  $('joystick-visible').checked = profile.joystick.visible !== false;
  ['w', 'a', 's', 'd'].forEach((name, i) => { document.querySelector('.key-' + name).textContent = displayCode(profile.joystick.keys[i]); });
  $('radius').value = Math.round(profile.joystick.radius * 100); $('radius-label').textContent = $('radius').value + '%';
  profile.bindings.forEach((binding, i) => {
    const row = document.createElement('div'); row.className = 'binding-row';
    const key = document.createElement('button'); key.className = 'key-capture'; key.textContent = displayCode(binding.code); key.title = '点击后按下新按键';
    key.addEventListener('click', () => { key.textContent = '按键…'; key.focus(); });
    key.addEventListener('keydown', e => { e.preventDefault(); e.stopPropagation(); binding.code = e.code; key.textContent = displayCode(e.code); persist(); key.blur(); });
    const info = document.createElement('div'); info.className = 'binding-info';
    const label = document.createElement('input'); label.value = binding.label; label.maxLength = 32; label.title = '触点名称'; label.addEventListener('change', () => { binding.label = label.value; persist(); });
    const mode = document.createElement('select'); for (const [value, text] of [['hold', '按住持续触摸'], ['tap', '按下点击一次']]) { const option = document.createElement('option'); option.value = value; option.textContent = text; mode.append(option); } mode.value = binding.mode; mode.addEventListener('change', () => { binding.mode = mode.value; persist(); });
    info.append(label, mode);
    const remove = document.createElement('button'); remove.className = 'delete-binding'; remove.textContent = '×'; remove.title = '删除触点'; remove.addEventListener('click', () => { profile.bindings.splice(i, 1); persist(); renderBindings(); renderOverlays(); });
    const visible = document.createElement('button'); visible.className = 'binding-visibility';
    visible.textContent = binding.visible === false ? '○' : '◉';
    visible.title = binding.visible === false ? '显示此键位标记' : '隐藏此键位标记（按键仍有效）';
    visible.setAttribute('aria-label', visible.title); visible.setAttribute('aria-pressed', String(binding.visible !== false));
    visible.addEventListener('click', () => { binding.visible = binding.visible === false; persist(); renderBindings(); renderOverlays(); });
    row.append(key, info, visible, remove); $('bindings').append(row);
  });
}
function renderOverlays() {
  $('overlays').replaceChildren(); if (!profile || !current.editing && (!current.mappingEnabled || current.showMappings === false)) return;
  const markers = profile.bindings.map((binding, index) => ({ binding, index }));
  if (profile.joystick.enabled) markers.push({ binding: profile.joystick, index: 'joystick' });
  for (const { binding, index } of markers) {
    if (binding.visible === false && !current.editing) continue;
    const marker = document.createElement('div'); marker.className = 'mapping-marker' + (index === 'joystick' ? ' joystick' : '');
    marker.textContent = index === 'joystick' ? `${displayCode(binding.keys[0])}\n${displayCode(binding.keys[1])}   ${displayCode(binding.keys[3])}\n${displayCode(binding.keys[2])}` : displayCode(binding.code);
    marker.style.left = binding.x * 100 + '%'; marker.style.top = binding.y * 100 + '%';
    if (index === 'joystick' && current.size) {
      const radius = binding.radius * Math.min(canvas.getBoundingClientRect().width, canvas.getBoundingClientRect().height);
      marker.style.width = marker.style.height = Math.max(52, radius * 2) + 'px';
    }
    marker.addEventListener('pointerdown', e => { if (!current.editing) return; e.preventDefault(); marker.setPointerCapture(e.pointerId); moving = { binding, marker }; });
    marker.addEventListener('pointermove', e => { if (moving?.marker !== marker) return; Object.assign(binding, coordinates(e)); marker.style.left = binding.x * 100 + '%'; marker.style.top = binding.y * 100 + '%'; });
    marker.addEventListener('pointerup', () => { if (moving?.marker === marker) { moving = null; persist(); } });
    marker.addEventListener('pointercancel', () => { moving = null; });
    $('overlays').append(marker);
  }
}
function renderApps() {
  $('apps-list').replaceChildren();
  if (!current.apps?.length) { const empty = document.createElement('div'); empty.className = 'apps-empty'; empty.textContent = '还没有应用。安装一个 APK，或试试下方的触控试验场。'; $('apps-list').append(empty); }
  for (const app of current.apps || []) {
    const button = document.createElement('button'); button.className = 'app-card';
    const icon = document.createElement('div'); icon.className = 'app-icon'; icon.textContent = app.package === 'com.androiddeck.demo' ? '✣' : app.name[0].toUpperCase();
    const details = document.createElement('div'), name = document.createElement('strong'), pkg = document.createElement('small'); name.textContent = app.name; pkg.textContent = app.package; details.append(name, pkg); button.append(icon, details);
    button.addEventListener('click', async () => { await task('launch', { package: app.package }); setView('device'); canvas.focus(); }); $('apps-list').append(button);
  }
}
async function refreshDevices() {
  try { const devices = await call('devices'); $('devices').replaceChildren(); const placeholder = document.createElement('option'); placeholder.value = ''; placeholder.textContent = '选择 ADB 设备'; $('devices').append(placeholder); for (const d of devices) { const option = document.createElement('option'); option.value = d.serial; option.disabled = d.status !== 'device'; option.textContent = `${d.name} (${d.status})`; $('devices').append(option); } updateControls(); } catch {}
}
$('start').onclick = $('empty-start').onclick = () => task('start');
for (const [id, action] of [['stop', 'stop'], ['install', 'install'], ['demo', 'demo'], ['rotate', 'rotate'], ['screenshot', 'screenshot'], ['settings', 'settings'], ['reconnect', 'reconnect'], ['refresh-apps', 'refresh-apps'], ['import-profile', 'import-profile'], ['export-profile', 'export-profile'], ['reset-profile', 'reset-profile']]) $(id).onclick = async () => { await task(action); if (action === 'demo') { setView('device'); canvas.focus(); } };
$('devices').onchange = updateControls; $('refresh-devices').onclick = refreshDevices;
$('connect-device').onclick = () => task('connect', { serial: $('devices').value });
$('mapping-toggle').onchange = () => task('mapping-enabled', { enabled: $('mapping-toggle').checked });
$('show-mappings').onchange = async () => { await task('mapping-visibility', { visible: $('show-mappings').checked }); canvas.focus(); };
$('fullscreen').onclick = () => task('fullscreen', { enabled: !current.fullscreen });
function openMemorySettings() {
  send({ type: 'release' });
  document.querySelectorAll('input[name="ram"]').forEach(radio => { radio.checked = Number(radio.value) === current.configuredRamMb; });
  $('memory-note').textContent = current.ownsDevice ? '修改后会重新启动虚拟设备，已安装的应用、游戏数据和键盘映射会保留。' : '只调整 AndroidDeck 虚拟设备的运存，下次启动时生效。';
  $('host-memory').textContent = current.hostRamGb ? `本机物理内存：${current.hostRamGb} GB` : '';
  $('memory-apply').textContent = current.ownsDevice ? '保存并重启 Android' : '保存设置';
  $('memory-dialog').showModal();
}
$('memory-settings').onclick = $('fullscreen-memory').onclick = openMemorySettings;
$('memory-cancel').onclick = () => $('memory-dialog').close();
$('memory-apply').onclick = async () => {
  const ramMb = Number(document.querySelector('input[name="ram"]:checked')?.value);
  $('memory-dialog').close(); const result = await task('memory', { ramMb });
  if (result) toast(result.restarted ? `已重启，当前运存 ${ramMb / 1024} GB` : `已保存 ${ramMb / 1024} GB 运存设置`);
};
$('edit-mapping').onclick = () => task('editing', { enabled: !current.editing });
$('joystick-toggle').onchange = () => { profile.joystick.enabled = $('joystick-toggle').checked; persist(); renderOverlays(); };
$('joystick-visible').onchange = () => { profile.joystick.visible = $('joystick-visible').checked; persist(); renderOverlays(); };
$('radius').oninput = () => { profile.joystick.radius = Number($('radius').value) / 100; $('radius-label').textContent = $('radius').value + '%'; renderOverlays(); };
$('radius').onchange = persist;
$('add-binding').onclick = () => { if (profile.bindings.length >= 20) return toast('最多支持 20 个触点', true); const used = [...profile.bindings.map(b => b.code), ...profile.shortcuts.map(b => b.code), ...profile.joystick.keys]; const code = Array.from('GQEZXCVBNTYU').map(c => 'Key' + c).find(c => !used.includes(c)); if (!code) return; profile.bindings.push({ code, mode: 'hold', x: .5, y: .5, label: '新触点' }); persist(); renderBindings(); renderOverlays(); };
$('send-text').onclick = () => { send({ type: 'text', value: $('text-value').value }); $('text-value').value = ''; canvas.focus(); };
document.querySelectorAll('[data-android-key]').forEach(b => b.onclick = () => { send({ type: 'android-key', keycode: Number(b.dataset.androidKey) }); canvas.focus(); });
$('clear-logs').onclick = () => $('logs').replaceChildren();
document.addEventListener('dragover', e => { if ([...e.dataTransfer.items].some(i => i.kind === 'file')) { e.preventDefault(); if (current.status === 'ready') $('drop-hint').hidden = false; } });
document.addEventListener('dragleave', e => { if (!e.relatedTarget) $('drop-hint').hidden = true; });
document.addEventListener('drop', e => { e.preventDefault(); $('drop-hint').hidden = true; const file = [...e.dataTransfer.files].find(f => /\.apk$/i.test(f.name)); if (!file) return toast('请拖入 .apk 安装包', true); if (current.status !== 'ready') return toast('请先启动 Android', true); task('install-path', { path: window.deck.filePath(file) }); });
(async () => { try { const initial = await call('init'); onState(initial); if (!initial.runtimeAvailable) toast('请先运行「安装运行环境.command」', true); await refreshDevices(); } catch {} })();
