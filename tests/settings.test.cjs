const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Settings, validateRam } = require('../src/settings.cjs');
const { Runtime } = require('../src/runtime.cjs');
test('only 6/8 GB RAM values are accepted and persisted', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'androiddeck-settings-'));
  try {
    const settings = new Settings(root); assert.equal(settings.value.ramMb, 6144);
    for (const value of [3072, 4096, 7168, 6144.5, '8192', NaN]) assert.throws(() => validateRam(value));
    settings.save({ ramMb: 8192, showMappings: false });
    const restored = new Settings(root); assert.equal(restored.value.ramMb, 8192); assert.equal(restored.value.showMappings, false);
    assert.throws(() => restored.save({ ramMb: 4096 })); assert.equal(new Settings(root).value.ramMb, 8192);
    assert.ok(!fs.existsSync(path.join(root, 'data/settings.json.tmp')));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
test('invalid settings fall back to 6 GB and AVD RAM changes preserve disks', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'androiddeck-avd-'));
  try {
    fs.mkdirSync(path.join(root, 'data'), { recursive: true });
    fs.writeFileSync(path.join(root, 'data/settings.json'), '{invalid');
    assert.equal(new Settings(root).value.ramMb, 6144);
    const runtime = new Runtime(root, () => {}); const avd = runtime.createAVD();
    fs.writeFileSync(path.join(avd, 'userdata-test'), 'preserve game data');
    runtime.setMemory(8192); runtime.createAVD();
    assert.match(fs.readFileSync(path.join(avd, 'config.ini'), 'utf8'), /^hw.ramSize=8192$/m);
    assert.match(fs.readFileSync(path.join(avd, 'config.ini'), 'utf8'), /^disk.dataPartition.size=32G$/m);
    assert.equal(fs.readFileSync(path.join(avd, 'userdata-test'), 'utf8'), 'preserve game data');
    assert.equal(runtime.owns('emulator-5580'), false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
