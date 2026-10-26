const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
for (const dir of ['src', 'tests', 'scripts']) {
  for (const file of fs.readdirSync(path.join(root, dir))) {
    if (/\.(cjs|js)$/.test(file)) {
      execFileSync(process.execPath, ['--check', path.join(root, dir, file)]);
      console.log('OK', `${dir}/${file}`);
    }
  }
}
