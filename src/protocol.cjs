'use strict';
const { EventEmitter } = require('node:events');

// scrcpy-server 3.3.4. Wire fields are big endian; the pinned source is linked in README.
function touchPacket(action, id, x, y, width, height) {
  if (![0, 1, 2].includes(action) || !Number.isInteger(id) || id < 0 || id > 10000
      || ![x, y, width, height].every(Number.isFinite) || width < 1 || height < 1
      || width > 65535 || height > 65535) throw new Error('无效触控事件');
  const b = Buffer.alloc(32);
  b[0] = 2; b[1] = action; b.writeBigInt64BE(BigInt(id), 2);
  b.writeUInt32BE(Math.max(0, Math.min(Math.round(x), width - 1)), 10);
  b.writeUInt32BE(Math.max(0, Math.min(Math.round(y), height - 1)), 14);
  b.writeUInt16BE(width, 18); b.writeUInt16BE(height, 20);
  b.writeUInt16BE(action === 1 ? 0 : 0xffff, 22);
  return b;
}
function keyPacket(action, code) {
  const b = Buffer.alloc(14); b[0] = 0; b[1] = action; b.writeUInt32BE(code, 2); return b;
}
function textPacket(text) {
  const value = Buffer.from(text.slice(0, 1000), 'utf8');
  const b = Buffer.alloc(5); b[0] = 1; b.writeUInt32BE(value.length, 1);
  return Buffer.concat([b, value]);
}
function scrollPacket(x, y, width, height, h, v) {
  if (![x, y, width, height, h, v].every(Number.isFinite)) throw new Error('滚动事件无效');
  const b = Buffer.alloc(21); b[0] = 3;
  b.writeUInt32BE(Math.max(0, Math.min(width - 1, Math.round(x * width))), 1);
  b.writeUInt32BE(Math.max(0, Math.min(height - 1, Math.round(y * height))), 5);
  b.writeUInt16BE(width, 9); b.writeUInt16BE(height, 11);
  const fixed = n => Math.max(-32768, Math.min(32767, Math.round(n * 2048)));
  b.writeInt16BE(fixed(h), 13); b.writeInt16BE(fixed(v), 15); return b;
}
class VideoParser extends EventEmitter {
  constructor() { super(); this.pending = Buffer.alloc(0); this.header = false; }
  feed(chunk) {
    this.pending = Buffer.concat([this.pending, chunk]);
    if (this.pending.length > 16 * 1024 * 1024) throw new Error('视频缓冲区超限');
    if (!this.header) {
      if (this.pending.length < 12) return;
      const codec = this.pending.subarray(0, 4).toString();
      const width = this.pending.readUInt32BE(4), height = this.pending.readUInt32BE(8);
      if (codec !== 'h264' || !width || !height || width > 8192 || height > 8192) throw new Error('不支持的视频格式');
      this.pending = this.pending.subarray(12); this.header = true;
      this.emit('size', { width, height });
    }
    while (this.pending.length >= 12) {
      const flags = this.pending.readBigUInt64BE(0), size = this.pending.readUInt32BE(8);
      if (!size || size > 8 * 1024 * 1024) throw new Error('无效的视频帧长度');
      if (this.pending.length < 12 + size) return;
      const data = Buffer.from(this.pending.subarray(12, 12 + size));
      this.pending = this.pending.subarray(12 + size);
      this.emit('frame', { config: !!(flags & (1n << 63n)), key: !!(flags & (1n << 62n)),
        timestamp: Number(flags & ((1n << 62n) - 1n)), data });
    }
  }
}
module.exports = { touchPacket, keyPacket, textPacket, scrollPacket, VideoParser };
