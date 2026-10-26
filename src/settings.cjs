'use strict';
const fs = require('node:fs');
const path = require('node:path');
const RAM_OPTIONS = Object.freeze([6144, 8192]);
const DEFAULT_SETTINGS = Object.freeze({ version: 1, ramMb: 6144, showMappings: true });
function validateRam(ramMb) {
  if (!RAM_OPTIONS.includes(ramMb)) throw new Error('运存请选择 6 GB 或 8 GB');
  return ramMb;
}
function validateSettings(value) {
  if (!value || value.version !== 1 || typeof value.showMappings !== 'boolean') throw new Error('设置文件格式错误');
  return { version: 1, ramMb: validateRam(value.ramMb), showMappings: value.showMappings };
}
class Settings {
  constructor(root, log = () => {}) {
    this.file = path.join(root, 'data/settings.json');
    this.value = { ...DEFAULT_SETTINGS };
    try { this.value = validateSettings(JSON.parse(fs.readFileSync(this.file, 'utf8'))); }
    catch (error) { if (error.code !== 'ENOENT') log('设置文件无效，已恢复 6 GB 默认设置'); }
  }
  save(patch) {
    const value = validateSettings({ ...this.value, ...patch });
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    fs.writeFileSync(this.file + '.tmp', JSON.stringify(value, null, 2));
    fs.renameSync(this.file + '.tmp', this.file);
    this.value = value; return { ...value };
  }
}
module.exports = { Settings, RAM_OPTIONS, DEFAULT_SETTINGS, validateRam, validateSettings };
