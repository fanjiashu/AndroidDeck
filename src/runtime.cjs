'use strict';
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const { spawn, execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { validateRam } = require('./settings.cjs');
const run = promisify(execFile);
const wait = ms => new Promise(r => setTimeout(r, ms));
class Runtime {
  constructor(root, log, ramMb = 6144) {
    this.root = root; this.log = log;
    this.ramMb = validateRam(ramMb); this.runningRamMb = null;
    this.sdk = path.join(root, '.runtime/sdk');
    this.avdHome = path.join(root, 'data/avd');
    const candidates = [process.env.ANDROID_SDK_ROOT, process.env.ANDROID_HOME,
      path.join(process.env.HOME || '', 'Library/Android/sdk')].filter(Boolean);
    this.toolSdk = candidates.find(p => fs.existsSync(path.join(p, 'platform-tools/adb'))) || this.sdk;
    this.adb = fs.existsSync(path.join(this.sdk, 'platform-tools/adb'))
      ? path.join(this.sdk, 'platform-tools/adb') : path.join(this.toolSdk, 'platform-tools/adb');
    this.env = { ...process.env, ANDROID_SDK_ROOT: this.sdk, ANDROID_HOME: this.sdk,
      ANDROID_AVD_HOME: this.avdHome, ANDROID_EMULATOR_HOME: path.join(root, 'data/emulator'),
      ANDROID_USER_HOME: path.join(root, 'data/android') };
  }
  async adbRun(args, serial, timeout = 20000) {
    const result = await run(this.adb, [...(serial ? ['-s', serial] : []), ...args],
      { timeout, maxBuffer: 4 * 1024 * 1024, env: this.env });
    return result.stdout.trim();
  }
  async devices() {
    const output = await this.adbRun(['devices', '-l']);
    return output.split('\n').slice(1).map(line => {
      const [serial, status] = line.trim().split(/\s+/);
      return { serial, status, name: line.match(/model:(\S+)/)?.[1]?.replaceAll('_', ' ') || serial };
    }).filter(d => d.serial);
  }
  available() { return fs.existsSync(path.join(this.sdk, 'emulator/emulator')) && fs.existsSync(this.imagePath()); }
  imagePath() { return path.join(this.sdk, 'system-images/android-34/default/arm64-v8a/system.img'); }
  owns(serial) { return !!this.child && this.child.exitCode === null && this.serial === serial; }
  setMemory(ramMb) { this.ramMb = validateRam(ramMb); }
  async freePort() {
    const devices = await this.devices();
    for (let p = 5580; p <= 5680; p += 2) {
      if (devices.some(d => d.serial === `emulator-${p}`)) continue;
      const servers = [];
      try {
        for (const port of [p, p + 1]) {
          const s = net.createServer(); servers.push(s);
          await new Promise((resolve, reject) => { s.once('error', reject); s.listen(port, '127.0.0.1', resolve); });
        }
        return p;
      } catch {} finally { for (const s of servers) if (s.listening) s.close(); }
    }
    throw new Error('没有可用的模拟器端口');
  }
  createAVD() {
    const avd = path.join(this.avdHome, 'AndroidDeck.avd');
    fs.mkdirSync(avd, { recursive: true });
    const image = path.dirname(this.imagePath());
    fs.writeFileSync(path.join(this.avdHome, 'AndroidDeck.ini'), `avd.ini.encoding=UTF-8\npath=${avd}\ntarget=android-34\n`);
    fs.writeFileSync(path.join(avd, 'config.ini'), [
      'AvdId=AndroidDeck', 'avd.ini.displayname=AndroidDeck · Android 14', 'avd.ini.encoding=UTF-8',
      'abi.type=arm64-v8a', 'hw.cpu.arch=arm64', 'hw.cpu.ncore=4', `hw.ramSize=${this.ramMb}`,
      'hw.lcd.width=720', 'hw.lcd.height=1280', 'hw.lcd.density=240', 'hw.gpu.enabled=yes',
      'hw.gpu.mode=host', 'hw.keyboard=yes', 'hw.mainKeys=no', 'hw.dPad=no', 'hw.trackBall=no',
      'hw.audioInput=yes', 'hw.audioOutput=yes', 'hw.camera.back=none', 'hw.camera.front=none',
      'hw.battery=yes', 'hw.sensors.orientation=yes', 'disk.dataPartition.size=32G',
      'tag.id=default', 'tag.display=Default Android System Image', `image.sysdir.1=${image}/`,
      'showDeviceFrame=no', 'skin.name=720x1280', 'skin.dynamic=yes', 'fastboot.forceColdBoot=yes',
      'PlayStore.enabled=false', 'runtime.network.latency=none', 'runtime.network.speed=full'
    ].join('\n') + '\n');
    return avd;
  }
  async start() {
    if (this.child && this.child.exitCode === null) return this.serial;
    if (!this.available()) throw new Error('Android 运行环境未安装，请先运行「安装运行环境.command」');
    this.createAVD();
    const port = await this.freePort(); this.serial = `emulator-${port}`;
    const exe = path.join(this.sdk, 'emulator/emulator');
    const logFile = fs.openSync(path.join(this.root, 'data/emulator.log'), 'a');
    this.runningRamMb = this.ramMb;
    this.child = spawn(exe, ['-avd', 'AndroidDeck', '-port', String(port), '-memory', String(this.ramMb), '-no-window',
      '-no-snapshot', '-no-boot-anim', '-gpu', 'host', '-netdelay', 'none', '-netspeed', 'full', '-no-metrics'],
      { env: this.env, stdio: ['ignore', logFile, logFile] });
    fs.closeSync(logFile);
    let failure;
    this.child.once('error', e => { failure = e; });
    this.log(`正在启动 Android 14 · ${this.runningRamMb / 1024} GB 运存 · ${this.serial}`);
    try {
      for (let attempt = 0; attempt < 180; attempt++) {
        if (failure || this.child.exitCode !== null) throw new Error('模拟器启动失败，请查看 data/emulator.log：' + (failure?.message || this.child.exitCode));
        try {
          if (await this.adbRun(['shell', 'getprop', 'sys.boot_completed'], this.serial, 2000) === '1') {
            // Only configure our newly owned AVD; never alter an externally selected device.
            await this.adbRun(['shell', 'settings', 'put', 'secure', 'immersive_mode_confirmations', 'confirmed'], this.serial);
            await this.adbRun(['shell', 'input', 'keyevent', '82'], this.serial);
            this.log('Android 已完成启动'); return this.serial;
          }
        } catch {}
        await wait(1000);
      }
      throw new Error('Android 启动超时，请查看模拟器日志');
    } catch (error) { await this.stop(); throw error; }
  }
  async stop() {
    const child = this.child; this.child = null; this.runningRamMb = null;
    if (!child || child.exitCode !== null || !child.pid) return;
    // Flush guest page cache before stopping virtualization. Recent APK data can
    // otherwise remain only in Android RAM even after an ADB write has completed.
    await this.adbRun(['shell', 'sync'], this.serial, 10000).catch(error => this.log('设备未响应磁盘同步：' + error.message));
    child.kill('SIGTERM');
    await Promise.race([new Promise(r => child.once('exit', r)), wait(8000)]);
    if (child.exitCode === null) {
      child.kill('SIGKILL');
      await Promise.race([new Promise(r => child.once('exit', r)), wait(3000)]);
    }
    // ADB's transport disappearance is asynchronous after the process exits.
    for (let attempt = 0; attempt < 30; attempt++) {
      if (!(await this.devices()).some(d => d.serial === this.serial)) break;
      await wait(200);
    }
    this.log('本应用创建的虚拟设备已关闭');
  }
  async apps(serial) {
    const packages = (await this.adbRun(['shell', 'pm', 'list', 'packages', '-3'], serial))
      .split('\n').map(p => p.replace(/^package:/, '').trim()).filter(p => /^[\w.]+$/.test(p));
    const apps = [];
    for (const pkg of packages) {
      const component = await this.component(serial, pkg);
      if (component) apps.push({ package: pkg, component, name: pkg === 'com.androiddeck.demo' ? '触控试验场' : pkg.split('.').at(-1) });
    }
    return apps;
  }
  async component(serial, pkg) {
    if (!/^[a-zA-Z][\w]*(\.[\w]+)+$/.test(pkg)) throw new Error('无效包名');
    const result = await this.adbRun(['shell', 'cmd', 'package', 'resolve-activity', '--brief',
      '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', pkg], serial);
    return result.split('\n').find(line => /^[\w.]+\/[\w.$]+$/.test(line)) || null;
  }
  async launch(serial, pkg) {
    const component = await this.component(serial, pkg);
    if (!component) throw new Error('此 APK 没有可启动的主界面');
    const result = await this.adbRun(['shell', 'am', 'start', '-W', '-n', component], serial, 45000);
    if (/Error:|Exception/.test(result)) throw new Error(result);
  }
  async install(serial, file) {
    if (!path.isAbsolute(file) || path.extname(file).toLowerCase() !== '.apk' || !fs.statSync(file).isFile()) throw new Error('请选择有效的 APK 文件');
    this.log('安装 APK：' + path.basename(file));
    let result;
    try { result = await this.adbRun(['install', '-r', file], serial, 180000); }
    catch (error) {
      const detail = [error.stdout, error.stderr, error.message].filter(Boolean).join('\n');
      const reasons = { INSTALL_FAILED_NO_MATCHING_ABIS: 'APK 的原生库不兼容 ARM64，请选择 arm64-v8a 或通用版本。',
        INSTALL_FAILED_OLDER_SDK: 'APK 要求的 Android 版本高于当前 Android 14。',
        INSTALL_FAILED_UPDATE_INCOMPATIBLE: '已安装的同名应用签名不同，不能覆盖安装。',
        INSTALL_FAILED_INSUFFICIENT_STORAGE: 'Android 虚拟设备的存储空间不足。',
        INSTALL_PARSE_FAILED: 'APK 文件无效、损坏或不完整。' };
      const reason = Object.entries(reasons).find(([code]) => detail.includes(code));
      throw new Error(reason ? reason[1] : detail.slice(-1500));
    }
    if (!/Success/.test(result)) throw new Error(result || 'APK 安装失败');
    this.log('APK 安装成功'); return this.apps(serial);
  }
}
module.exports = { Runtime, wait };
