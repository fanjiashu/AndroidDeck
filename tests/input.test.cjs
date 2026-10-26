const test = require('node:test');
const assert = require('node:assert/strict');
const { InputEngine, DEFAULT_PROFILE, validateProfile } = require('../src/input.cjs');
const { VideoParser, touchPacket } = require('../src/protocol.cjs');
function engine() { const packets = [], input = new InputEngine(); input.attach(b => packets.push(b), 720, 1280); return { input, packets }; }
test('simultaneous joystick and hold keep distinct pointer IDs and release', () => {
  const { input, packets } = engine(); input.key('KeyW', true); input.key('Space', true);
  assert.equal(input.contacts.size, 2);
  assert.deepEqual([...input.contacts.keys()], [100, 10]);
  const count = packets.length; input.key('Space', true); assert.equal(packets.length, count);
  input.release(); assert.equal(input.contacts.size, 0);
  assert.deepEqual(packets.slice(-2).map(b => b[1]), [1, 1]);
  assert.deepEqual(packets.slice(-2).map(b => Number(b.readBigInt64BE(2))), [100, 10]);
});
test('diagonal joystick radius remains circular for portrait dimensions', () => {
  const { input } = engine(); input.key('KeyW', true); input.key('KeyD', true);
  const p = input.contacts.get(100), j = input.profile.joystick;
  const radius = Math.hypot((p.x - j.x) * 720, (p.y - j.y) * 1280);
  assert.ok(Math.abs(radius - j.radius * 720) < 1e-8);
});
test('tap fires once until keyup; edits and rotation release contacts', () => {
  const { input, packets } = engine(); input.key('KeyF', true); input.key('KeyF', true);
  assert.equal(packets.length, 2); assert.equal(input.contacts.size, 0);
  input.key('Space', true); const edited = structuredClone(DEFAULT_PROFILE); edited.bindings[0].x = .81;
  input.setProfile(edited); assert.equal(input.contacts.size, 0);
  input.key('Space', true); input.resize(1280, 720); assert.equal(input.contacts.size, 0);
  input.setEnabled(false); input.key('KeyW', true); assert.equal(input.contacts.size, 0);
});
test('profile validation rejects duplicate and corrupt inputs', () => {
  const p = structuredClone(DEFAULT_PROFILE); p.bindings[0].code = 'KeyW'; assert.throws(() => validateProfile(p), /重复/);
  p.bindings[0].code = 'Space'; p.bindings[0].x = NaN; assert.throws(() => validateProfile(p), /触点/);
  assert.throws(() => touchPacket(0, 1, NaN, 0, 720, 1280));
});
test('fragmented video parser reads exact codec, flags and payload', () => {
  const parser = new VideoParser(), frames = []; let size;
  parser.on('size', p => { size = p; }); parser.on('frame', p => frames.push(p));
  const header = Buffer.alloc(12); header.write('h264'); header.writeUInt32BE(720, 4); header.writeUInt32BE(1280, 8);
  const frame = Buffer.alloc(15); frame.writeBigUInt64BE((1n << 62n) | 777n); frame.writeUInt32BE(3, 8); frame.set([1, 2, 3], 12);
  const bytes = Buffer.concat([header, frame]); for (const byte of bytes) parser.feed(Buffer.from([byte]));
  assert.deepEqual(size, { width: 720, height: 1280 }); assert.equal(frames[0].timestamp, 777);
  assert.equal(frames[0].key, true); assert.deepEqual([...frames[0].data], [1, 2, 3]);
});
test('malformed video frame length fails bounded parser', () => {
  const parser = new VideoParser(); const bytes = Buffer.alloc(24); bytes.write('h264'); bytes.writeUInt32BE(720, 4); bytes.writeUInt32BE(1280, 8); bytes.writeUInt32BE(0xffffffff, 20);
  assert.throws(() => parser.feed(bytes), /长度/);
});
test('touch registry respects the Android server ten-pointer maximum', () => {
  const { input, packets } = engine();
  for (let id = 1; id <= 11; id++) input.touch(0, id, .5, .5);
  assert.equal(input.contacts.size, 10); assert.equal(packets.length, 10);
  input.release(); assert.equal(packets.length, 20); assert.equal(input.contacts.size, 0);
});
test('hidden marker annotations retain held contacts and keyboard actions', () => {
  const { input, packets } = engine(); input.key('Space', true);
  const hidden = structuredClone(DEFAULT_PROFILE); hidden.bindings[0].visible = false; hidden.joystick.visible = false;
  input.setProfile(hidden); assert.equal(input.contacts.size, 1);
  input.key('KeyW', true); assert.equal(input.contacts.size, 2);
  input.key('Space', false); input.key('KeyW', false);
  assert.equal(input.contacts.size, 0); assert.equal(packets.at(-1)[1], 1);
  assert.throws(() => validateProfile({ ...hidden, bindings: [{ ...hidden.bindings[0], visible: 'no' }] }), /触点/);
});
test('F11 is reserved for desktop fullscreen', () => {
  const p = structuredClone(DEFAULT_PROFILE); p.bindings[0].code = 'F11';
  assert.throws(() => validateProfile(p), /全屏/);
});
