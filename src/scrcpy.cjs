'use strict';
const { EventEmitter } = require('node:events');
const { spawn } = require('node:child_process');
const net = require('node:net');
const path = require('node:path');
const crypto = require('node:crypto');
const { VideoParser } = require('./protocol.cjs');
const { wait } = require('./runtime.cjs');
class Scrcpy extends EventEmitter {
  constructor(runtime, serial) { super(); this.runtime = runtime; this.serial = serial; this.closing = false; }
  async connect() {
    const r = this.runtime, id = crypto.randomInt(1, 0x7fffffff).toString(16).padStart(8, '0');
    this.remote = `/data/local/tmp/androiddeck-${id}.jar`;
    await r.adbRun(['push', path.join(r.root, 'assets/scrcpy-server'), this.remote], this.serial);
    this.port = Number(await r.adbRun(['forward', 'tcp:0', `localabstract:scrcpy_${id}`], this.serial));
    this.process = spawn(r.adb, ['-s', this.serial, 'shell', `CLASSPATH=${this.remote}`, 'app_process', '/',
      'com.genymobile.scrcpy.Server', '3.3.4', `scid=${id}`, 'tunnel_forward=true', 'audio=false',
      'video_codec=h264', 'max_size=1280', 'max_fps=60', 'video_bit_rate=8000000',
      'send_device_meta=false', 'send_dummy_byte=true', 'send_codec_meta=true', 'send_frame_meta=true',
      'clipboard_autosync=false', 'power_on=true', 'stay_awake=true', 'cleanup=true'], { env: r.env });
    this.process.stdout.on('data', b => this.emit('log', b.toString().trim()));
    this.process.stderr.on('data', b => this.emit('log', b.toString().trim()));
    this.process.on('error', e => this.fail(e));
    this.process.on('exit', code => { if (!this.closing) this.fail(new Error('屏幕服务退出：' + code)); });
    // ADB accepting TCP does not prove that Android's abstract socket exists yet.
    // The pinned server sends one dummy byte after accepting the first socket.
    this.video = await this.socket(true);
    this.control = await this.socket();
    this.control.on('data', () => {}); // clipboard autosync disabled, still drain device messages
    const parser = new VideoParser();
    parser.on('size', size => this.emit('size', size));
    parser.on('frame', frame => this.emit('frame', frame));
    this.video.on('data', b => { try { parser.feed(b); } catch (e) { this.fail(e); } });
    this.video.on('close', () => { if (!this.closing) this.fail(new Error('Android 视频连接已断开')); });
    this.control.on('close', () => { if (!this.closing) this.fail(new Error('Android 触控连接已断开')); });
  }
  async socket(handshake = false) {
    for (let n = 0; n < 25; n++) {
      try {
        const socket = await new Promise((resolve, reject) => {
          const s = net.createConnection({ host: '127.0.0.1', port: this.port });
          s.setTimeout(2000);
          s.once('error', reject); s.once('timeout', () => { s.destroy(); reject(new Error('连接超时')); });
          s.once('connect', () => { s.setTimeout(0); s.setNoDelay(true); resolve(s); });
        });
        if (handshake) {
          try {
            await new Promise((resolve, reject) => {
              const timer = setTimeout(() => finish(new Error('Android 服务握手超时')), 2000);
              const finish = error => {
                clearTimeout(timer); socket.off('readable', readable); socket.off('close', closed); socket.off('error', finish);
                error ? reject(error) : resolve();
              };
              const closed = () => finish(new Error('Android 服务尚未就绪'));
              const readable = () => { if (socket.read(1) !== null) finish(); };
              socket.on('readable', readable); socket.once('close', closed); socket.once('error', finish);
              readable();
            });
          } catch (e) { socket.destroy(); throw e; }
        }
        socket.on('error', e => this.fail(e)); return socket;
      } catch (e) { if (n === 24) throw e; await wait(200); }
    }
  }
  write(packet) {
    if (this.closing || !this.control || this.control.destroyed) return;
    if (this.control.writableLength > 65536) { this.fail(new Error('触控连接拥塞，已停止输入')); return; }
    this.control.write(packet);
  }
  fail(error) { if (!this.closing && !this.failed) { this.failed = true; this.emit('failure', error); } }
  async close() {
    if (this.closing) return;
    this.closing = true;
    // flush prior release events before ending the control stream
    if (this.control && !this.control.destroyed) {
      await Promise.race([new Promise(r => this.control.end(r)), wait(150)]);
    }
    this.video?.destroy(); this.control?.destroy(); this.process?.kill('SIGTERM');
    if (this.port) await this.runtime.adbRun(['forward', '--remove', `tcp:${this.port}`], this.serial).catch(() => {});
    if (this.remote) await this.runtime.adbRun(['shell', 'rm', '-f', this.remote], this.serial).catch(() => {});
  }
}
module.exports = { Scrcpy };
