'use strict';
const { app, BrowserWindow, ipcMain, dialog, Menu } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { Runtime, wait } = require('./runtime.cjs');
const { Scrcpy } = require('./scrcpy.cjs');
const { InputEngine, DEFAULT_PROFILE, validateProfile } = require('./input.cjs');
const { Settings } = require('./settings.cjs');
const codeRoot = path.resolve(__dirname, '..');
const locationFile = path.join(codeRoot, 'runtime-location.json');
const root = fs.existsSync(locationFile)
  ? path.resolve(codeRoot, JSON.parse(fs.readFileSync(locationFile, 'utf8')).relativePath) : codeRoot;
fs.mkdirSync(path.join(root, 'data'), { recursive: true });
app.setPath('userData', path.join(root, 'data/electron'));
app.setPath('logs', path.join(root, 'data/logs'));
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');
const rendererURL = pathToFileURL(path.join(__dirname, 'index.html')).href;
let win, stream, serial, generation = 0, queued = Promise.resolve(), quitting = false;
let outstanding = 0, needKey = false, configFrame;
const input = new InputEngine();
const state = { status: 'idle', serial: null, activePackage: 'default', apps: [], size: null, generation: 0, profile: DEFAULT_PROFILE, mappingEnabled: true, editing: false, fullscreen: false, fullscreenChanging: false };
const log = message => {
  const entry = { time: new Date().toLocaleTimeString('zh-CN', { hour12: false }), message: String(message).slice(0, 2000) };
  console.log(`[${entry.time}] ${entry.message}`);
  if (win && !win.isDestroyed()) win.webContents.send('deck:log', entry);
};
const settings = new Settings(root, log);
const runtime = new Runtime(root, log, settings.value.ramMb);
const hostRamGb = Math.round(require('node:os').totalmem() / 1024 ** 3);
function snapshot() {
  Object.assign(state, { configuredRamMb: settings.value.ramMb, runningRamMb: runtime.runningRamMb,
    ownsDevice: runtime.owns(serial), hostRamGb, showMappings: settings.value.showMappings });
  return { ...state };
}
function publish() { const value = snapshot(); if (win && !win.isDestroyed()) win.webContents.send('deck:state', value); }
function enqueue(operation) { const result = queued.then(operation); queued = result.catch(() => {}); return result; }
function authenticated(event) { return win && event.sender === win.webContents && event.senderFrame === win.webContents.mainFrame && event.senderFrame.url === rendererURL; }
function checkSession(gen) { if (!serial || state.status !== 'ready' || gen !== generation) throw new Error('Android 会话已变更，请重试'); }
const profilesFile = path.join(root, 'data/profiles.json');
let profiles = {};
try { profiles = JSON.parse(fs.readFileSync(profilesFile, 'utf8')); } catch {}
function loadProfile(pkg) {
  try { return validateProfile(profiles[pkg] || DEFAULT_PROFILE); }
  catch { log('映射配置损坏，已恢复默认配置'); return validateProfile(DEFAULT_PROFILE); }
}
function saveProfile(profile) {
  const valid = validateProfile(profile); input.setProfile(valid);
  profiles[state.activePackage] = valid;
  fs.writeFileSync(profilesFile + '.tmp', JSON.stringify(profiles, null, 2));
  fs.renameSync(profilesFile + '.tmp', profilesFile);
  state.profile = valid; publish(); return valid;
}
async function disconnect() {
  input.detach(); generation++; state.generation = generation;
  const old = stream; stream = null; serial = null; outstanding = 0; configFrame = null; needKey = false;
  if (old) await old.close();
  state.serial = null; state.status = 'idle'; state.size = null; state.apps = []; publish();
}
async function connect(target, preserveProfile = false) {
  const selectedPackage = preserveProfile && serial === target ? state.activePackage : 'default';
  const device = (await runtime.devices()).find(d => d.serial === target && d.status === 'device');
  if (!device) throw new Error('设备未就绪或未授权');
  await disconnect(); serial = target; state.serial = target; state.status = 'connecting'; publish();
  const session = generation, next = new Scrcpy(runtime, serial); stream = next;
  next.on('log', log);
  next.on('size', size => {
    if (stream !== next) return;
    state.size = size; input.attach(packet => next.write(packet), size.width, size.height); publish();
  });
  next.on('frame', frame => {
    if (stream !== next || !win || win.isDestroyed()) return;
    if (frame.config) configFrame = frame;
    if (outstanding >= 4) { needKey = true; return; }
    if (needKey && !frame.config && !frame.key) return;
    if (needKey && frame.key) {
      if (configFrame) { outstanding++; win.webContents.send('deck:frame', { ...configFrame, generation: session }); }
      needKey = false;
    }
    outstanding++; win.webContents.send('deck:frame', { ...frame, generation: session });
  });
  next.on('failure', error => {
    if (stream !== next) return;
    input.detach(); state.status = 'error'; log(error.message); publish();
    enqueue(async () => { if (stream === next) await disconnect(); });
  });
  try {
    await next.connect();
    state.apps = await runtime.apps(serial);
    state.activePackage = selectedPackage === 'default' || state.apps.some(a => a.package === selectedPackage) ? selectedPackage : 'default';
    state.profile = loadProfile(state.activePackage); input.setProfile(state.profile);
    state.editing = false; input.setEnabled(state.mappingEnabled);
    state.status = 'ready'; publish(); log(`已连接 ${target}，实时画面和触控已启用`);
  } catch (e) { await disconnect(); throw e; }
}
async function setFullscreen(enabled) {
  if (typeof enabled !== 'boolean') throw new Error('全屏设置无效');
  if (state.fullscreenChanging) return snapshot();
  if (win.isFullScreen() === enabled) return snapshot();
  input.release(); state.fullscreenChanging = true; publish();
  try {
    await new Promise(resolve => {
      const name = enabled ? 'enter-full-screen' : 'leave-full-screen';
      const done = () => { clearTimeout(timer); win.off(name, done); resolve(); };
      const timer = setTimeout(done, 5000);
      win.once(name, done); win.setFullScreen(enabled);
    });
  } finally { state.fullscreen = win.isFullScreen(); state.fullscreenChanging = false; publish(); }
  if (state.fullscreen !== enabled) throw new Error('全屏切换未完成，请再试一次');
  return snapshot();
}
async function changeMemory(payload) {
  if (payload.generation !== generation) throw new Error('设备会话已变更，请重新打开运存设置');
  const before = { package: state.activePackage, restart: state.status === 'ready' && runtime.owns(serial)
    && runtime.runningRamMb !== payload.ramMb };
  settings.save({ ramMb: payload.ramMb }); runtime.setMemory(settings.value.ramMb); publish();
  if (!before.restart) { log(`已保存 ${settings.value.ramMb / 1024} GB 运存设置`); return { ...snapshot(), restarted: false }; }
  input.release(); await disconnect(); state.status = 'starting'; publish();
  try {
    await runtime.stop();
    await connect(await runtime.start());
    // A restarted emulator may receive a new serial: restore by package, not serial.
    if (before.package !== 'default' && state.apps.some(a => a.package === before.package)) {
      await runtime.launch(serial, before.package); state.activePackage = before.package;
      state.profile = loadProfile(before.package); input.setProfile(state.profile);
    }
    publish(); log(`运存已切换为 ${runtime.runningRamMb / 1024} GB，应用与数据已保留`);
    return { ...snapshot(), restarted: true };
  } catch (error) {
    await disconnect(); await runtime.stop(); publish();
    throw new Error('运存设置已保存，但重新启动失败；可改为 6 GB 后重试。' + error.message);
  }
}
async function operation(action, payload = {}) {
  switch (action) {
    case 'init': return { ...snapshot(), runtimeAvailable: runtime.available(), devices: await runtime.devices() };
    case 'devices': return runtime.devices();
    case 'fullscreen': return setFullscreen(payload.enabled);
    case 'memory': return changeMemory(payload);
    case 'mapping-visibility':
      if (typeof payload.visible !== 'boolean') throw new Error('键位显示设置无效');
      settings.save({ showMappings: payload.visible }); publish(); return snapshot();
    case 'start':
      state.status = 'starting'; publish();
      try { await connect(await runtime.start()); } catch (e) { state.status = 'idle'; publish(); throw e; }
      return { ...state };
    case 'connect':
      if (typeof payload.serial !== 'string' || payload.serial.length > 150) throw new Error('设备编号无效');
      await connect(payload.serial); return { ...state };
    case 'stop': await disconnect(); await runtime.stop(); return { ...state };
    case 'reconnect': { const target = serial; if (!target) throw new Error('请先启动 Android'); await connect(target, true); return { ...state }; }
    case 'install': {
      checkSession(payload.generation);
      const result = await dialog.showOpenDialog(win, { title: '安装 APK', properties: ['openFile'], filters: [{ name: 'Android 安装包', extensions: ['apk'] }] });
      if (result.canceled) return null;
      input.release(); state.apps = await runtime.install(serial, result.filePaths[0]); publish(); return state.apps;
    }
    case 'install-path':
      checkSession(payload.generation); input.release();
      if (typeof payload.path !== 'string') throw new Error('APK 路径无效');
      state.apps = await runtime.install(serial, payload.path); publish(); return state.apps;
    case 'demo':
      checkSession(payload.generation); input.release();
      state.apps = await runtime.install(serial, path.join(root, 'assets/TouchLab.apk'));
      await runtime.launch(serial, 'com.androiddeck.demo');
      state.activePackage = 'com.androiddeck.demo'; state.profile = loadProfile(state.activePackage);
      input.setProfile(state.profile); publish(); return state.apps;
    case 'launch':
      checkSession(payload.generation); input.release();
      await runtime.launch(serial, payload.package); state.activePackage = payload.package;
      state.profile = loadProfile(state.activePackage); input.setProfile(state.profile); publish(); return true;
    case 'refresh-apps': checkSession(payload.generation); state.apps = await runtime.apps(serial); publish(); return state.apps;
    case 'save-profile': checkSession(payload.generation); return saveProfile(payload.profile);
    case 'reset-profile': checkSession(payload.generation); return saveProfile(DEFAULT_PROFILE);
    case 'import-profile': {
      checkSession(payload.generation); input.release();
      const result = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [{ name: '键盘映射', extensions: ['json'] }] });
      if (result.canceled) return null;
      if (fs.statSync(result.filePaths[0]).size > 65536) throw new Error('映射文件过大');
      return saveProfile(JSON.parse(fs.readFileSync(result.filePaths[0], 'utf8')));
    }
    case 'export-profile': {
      const result = await dialog.showSaveDialog(win, { defaultPath: 'AndroidDeck-映射.json', filters: [{ name: '键盘映射', extensions: ['json'] }] });
      if (!result.canceled) fs.writeFileSync(result.filePath, JSON.stringify(state.profile, null, 2)); return true;
    }
    case 'mapping-enabled': checkSession(payload.generation); state.mappingEnabled = !!payload.enabled; input.setEnabled(state.mappingEnabled && !state.editing); publish(); return true;
    case 'editing': checkSession(payload.generation); state.editing = !!payload.enabled; input.release(); input.setEnabled(state.mappingEnabled && !state.editing); publish(); return true;
    case 'settings': checkSession(payload.generation); input.release(); await runtime.adbRun(['shell', 'am', 'start', '-a', 'android.settings.SETTINGS'], serial); return true;
    case 'rotate':
      checkSession(payload.generation); input.release();
      await runtime.adbRun(['shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0'], serial);
      await runtime.adbRun(['shell', 'settings', 'put', 'system', 'user_rotation', state.size?.width > state.size?.height ? '0' : '1'], serial);
      await wait(500); await connect(serial, true); return true;
    case 'screenshot': {
      checkSession(payload.generation);
      const file = path.join(root, 'data', `Android-${Date.now()}.png`);
      const { execFile } = require('node:child_process');
      const png = await new Promise((resolve, reject) => execFile(runtime.adb, ['-s', serial, 'exec-out', 'screencap', '-p'],
        { encoding: 'buffer', maxBuffer: 16 * 1024 * 1024, timeout: 10000, env: runtime.env }, (err, stdout) => err ? reject(err) : resolve(stdout)));
      const result = await dialog.showSaveDialog(win, { defaultPath: file, filters: [{ name: 'PNG', extensions: ['png'] }] });
      if (!result.canceled) fs.writeFileSync(result.filePath, png); return true;
    }
    default: throw new Error('不支持的操作');
  }
}
ipcMain.handle('deck:call', async (event, action, payload) => {
  if (!authenticated(event)) throw new Error('未授权的窗口');
  if (JSON.stringify(payload || {}).length > 65536) throw new Error('请求过大');
  try { return await enqueue(() => operation(action, payload)); }
  catch (e) { log('操作失败：' + e.message); throw new Error(e.message); }
});
ipcMain.on('deck:input', (event, message) => {
  if (!authenticated(event) || !message || message.generation !== generation) {
    if (process.argv.includes('--integration-test') && message?.type !== 'ack') console.log('IGNORED INPUT', message, event.senderFrame?.url, rendererURL, generation);
    return;
  }
  if (message.type === 'ack') { outstanding = Math.max(0, outstanding - 1); return; }
  if (message.type === 'release') { input.release(); return; }
  if (state.status !== 'ready') return;
  if (message.type === 'key' && typeof message.down === 'boolean') input.key(message.code, message.down);
  if (message.type === 'touch' && !state.editing && [0, 1, 2].includes(message.action)) input.touch(message.action, 1, message.x, message.y);
  if (message.type === 'android-key') input.androidKey(message.keycode);
  if (message.type === 'text') input.text(message.value);
  if (message.type === 'scroll') { try { input.scroll(message.x, message.y, message.h, message.v); } catch {} }
  if (message.type === 'size') { input.resize(message.width, message.height); state.size = { width: input.width, height: input.height }; }
});
if (!app.requestSingleInstanceLock()) app.quit();
app.on('second-instance', () => { win?.show(); win?.focus(); });
app.whenReady().then(async () => {
  const iconPath = path.join(root, 'assets/androiddeck-icon.png');
  if (process.platform === 'darwin' && fs.existsSync(iconPath)) app.dock.setIcon(iconPath);
  app.setAboutPanelOptions({ applicationName: 'AndroidDeck', applicationVersion: app.getVersion(), iconPath });
  Menu.setApplicationMenu(Menu.buildFromTemplate([{ label: 'AndroidDeck', submenu: [{ role: 'about' }, { type: 'separator' }, { role: 'quit' }] },
    { label: '编辑', submenu: [{ role: 'undo' }, { role: 'redo' }, { type: 'separator' }, { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }] },
    { label: '视图', submenu: [{ label: '进入 / 退出全屏', role: 'togglefullscreen' }] }]));
  win = new BrowserWindow({ width: 1390, height: 930, minWidth: 1024, minHeight: 700, backgroundColor: '#0b0e14',
    icon: iconPath,
    title: 'AndroidDeck · 安卓模拟器', titleBarStyle: 'hiddenInset', trafficLightPosition: { x: 20, y: 20 },
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (event, url) => { if (url !== rendererURL) event.preventDefault(); });
  win.webContents.on('will-attach-webview', event => event.preventDefault());
  win.on('blur', () => input.release());
  for (const name of ['enter-full-screen', 'leave-full-screen']) win.on(name, () => {
    input.release(); state.fullscreen = win.isFullScreen(); state.fullscreenChanging = false; publish();
  });
  win.webContents.on('render-process-gone', () => input.release());
  await win.loadFile(path.join(__dirname, 'index.html'));
  if (process.argv.includes('--integration-test')) {
    try { await require('../tests/integration.cjs')({ win, runtime, input, state, root, operation: (a, p) => enqueue(() => operation(a, p)), wait, log }); }
    catch (e) {
      console.error(e); fs.writeFileSync(path.join(root, 'data/integration-error.txt'), e.stack);
      const capture = await win.webContents.capturePage(); fs.writeFileSync(path.join(root, 'data/integration-failure.png'), capture.toPNG());
      if (serial) {
        const diagnostics = await runtime.adbRun(['shell', 'logcat', '-d', '-t', '2500', '-s', 'AndroidRuntime:E', 'ActivityTaskManager:I', 'DeckTouch:I'], serial).catch(() => '');
        fs.writeFileSync(path.join(root, 'data/integration-android-errors.txt'), diagnostics);
      }
      process.exitCode = 1;
    }
    if (!process.argv.includes('--keep-open')) app.quit();
  }
  if (process.argv.includes('--showcase')) {
    try { await enqueue(() => operation('start')); await enqueue(() => operation('demo', { generation })); }
    catch (e) { log(e.message); }
  }
  const startPackage = process.argv.find(arg => arg.startsWith('--start-package='))?.slice('--start-package='.length);
  if (startPackage) {
    try { await enqueue(() => operation('start')); await enqueue(() => operation('launch', { generation, package: startPackage })); }
    catch (error) { log(error.message); }
  }
});
app.on('window-all-closed', () => app.quit());
app.on('before-quit', event => {
  if (quitting) return;
  event.preventDefault(); quitting = true;
  enqueue(async () => { await disconnect(); await runtime.stop(); }).finally(() => app.exit(process.exitCode || 0));
});
