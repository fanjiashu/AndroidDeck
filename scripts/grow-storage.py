#!/usr/bin/env python3
"""Offline, backed-up growth of AndroidDeck's existing qcow2 userdata chain.

The guest's decrypted ext4 filesystem must be grown only after every mount and
APEX loop reference has been safely removed; online resize is unreliable here.
This script never wipes userdata, drops an overlay, or changes encryption keys.
"""
import argparse, datetime, hashlib, json, pathlib, re, shutil, subprocess
from zoneinfo import ZoneInfo

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--size-gb', type=int, default=100)
parser.add_argument('--avd', type=pathlib.Path)
parser.add_argument('--backup-only', action='store_true')
args = parser.parse_args()
if not 32 <= args.size_gb <= 1024: parser.error('容量必须在 32–1024 GB 范围内')
avd = (args.avd or root/'data/avd/AndroidDeck.avd').resolve()
if avd.name != 'AndroidDeck.avd': parser.error('仅处理 AndroidDeck.avd')
qemu = root/'.runtime/sdk/emulator/qemu-img'
images = [avd/'userdata-qemu.img', avd/'userdata-qemu.img.qcow2']
target = args.size_gb*1024**3
def run(*args):
    return subprocess.run([str(a) for a in args], check=True, text=True, capture_output=True).stdout
def info(image):
    return json.loads(run(qemu, 'info', '--output=json', image))
processes = run('/bin/ps', '-axo', 'args')
emulator_directory = str((root/'.runtime/sdk/emulator').resolve()) + '/'
if any(line.startswith(emulator_directory) and '-avd AndroidDeck' in line for line in processes.splitlines()):
    raise SystemExit('请先正常关闭 AndroidDeck 虚拟设备。运行中不修改磁盘。')
before = [info(p) for p in images]
if any(item['format'] != 'qcow2' for item in before):
    raise SystemExit('镜像格式与此迁移不符，未执行任何修改。')
if any(item['virtual-size'] > target for item in before):
    raise SystemExit(f'现有磁盘已大于 {args.size_gb} GB，拒绝缩小。')
if all(item['virtual-size'] == target for item in before) and not args.backup_only:
    print(f'虚拟磁盘已经是 {args.size_gb} GB。'); raise SystemExit(0)
if pathlib.Path(before[1].get('backing-filename','')).name != images[0].name:
    raise SystemExit('userdata backing 链与预期不符，未执行修改。')
work = root.parent.parent/'work'
stamp = datetime.datetime.now(ZoneInfo('Asia/Shanghai')).strftime('%Y%m%d-%H%M%S')
backup = work/f'androiddeck-storage-backup-{stamp}-{avd.parent.parent.parent.name}'
backup.mkdir(parents=True)
print('完整备份虚拟设备到', backup, flush=True)
run('/bin/cp', '-cR', avd, backup)
copy = backup/avd.name
def digest(file):
    h=hashlib.sha256()
    with file.open('rb') as f:
        for chunk in iter(lambda:f.read(8*1024*1024),b''):h.update(chunk)
    return h.hexdigest()
verified = {}
for file in sorted(avd.rglob('*')):
    if file.is_file():
        relative = file.relative_to(avd)
        print('校验备份', relative, flush=True)
        original=digest(file)
        if original != digest(copy/relative): raise SystemExit('备份校验失败，未修改镜像。')
        verified[str(relative)] = original
for name in ['quickboot.json', 'quickboot-recovery.json']:
    file = avd.parent.parent/name
    if file.exists(): shutil.copy2(file, backup/name)
(backup/'manifest.json').write_text(json.dumps({'source':str(avd),'sha256':verified,'before':before,'targetBytes':target,'phase':'backup-verified'},indent=2))
if args.backup_only:
    print('BACKUP_VERIFIED=' + str(backup), flush=True)
    raise SystemExit(0)
for file in images: print(run(qemu, 'check', '-f', 'qcow2', file).strip(), flush=True)
try:
    for file, metadata in zip(images, before):
        for snapshot in metadata.get('snapshots', []):
            print('移除已备份的旧容量快照', file.name, snapshot['id'], flush=True)
            run(qemu, 'snapshot', '-d', snapshot['id'], file)
    for file in images:
        print(run(qemu, 'resize', '-f', 'qcow2', file, f'{args.size_gb}G').strip(), flush=True)
    after = [info(p) for p in images]
    if any(item['virtual-size'] != target for item in after): raise RuntimeError('镜像容量验证失败')
    for file in images: print(run(qemu, 'check', '-f', 'qcow2', file).strip(), flush=True)
    config = avd/'config.ini'
    config.write_text(re.sub(r'^disk\.dataPartition\.size=.*$', f'disk.dataPartition.size={args.size_gb}G', config.read_text(), flags=re.M))
    record = avd.parent.parent/'quickboot.json'
    if record.exists(): record.unlink()
    (backup/'after.json').write_text(json.dumps(after,indent=2))
except Exception:
    failed = backup/'failed-avd'
    shutil.move(avd, failed)
    run('/bin/cp', '-cR', copy, avd.parent)
    print('迁移失败，已整体恢复原虚拟设备；失败副本保留在', failed, flush=True)
    raise
print(f'QCOW2 链已扩至 {args.size_gb} GB，备份已校验。还需完整卸载来宾数据卷后离线扩展 ext4；此步骤未自动执行。', flush=True)
