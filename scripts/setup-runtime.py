#!/usr/bin/env python3
"""Project-owned, checksum-pinned Google Android runtime installer for Apple Silicon."""
import hashlib, os, pathlib, platform, shutil, subprocess, tempfile, urllib.request, zipfile
root = pathlib.Path(__file__).resolve().parent.parent
sdk = root/'.runtime/sdk'
download = root/'.runtime/downloads'
packages = [
    ('https://dl.google.com/android/repository/emulator-darwin_aarch64-15917651.zip', 'f22f44948a2b7f0a0103645b9a639290eef92426', sdk),
    ('https://dl.google.com/android/repository/sys-img/android/arm64-v8a-34_r04.zip', 'd9f2011131919abe952814e041f16f317242c3fa', sdk/'system-images/android-34/default'),
]
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('此版本仅支持 Apple Silicon Mac。')
download.mkdir(parents=True, exist_ok=True)
sdk.mkdir(parents=True, exist_ok=True)
def checksum(file, algorithm='sha1'):
    h = hashlib.new(algorithm)
    with open(file,'rb') as f:
        for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
    return h.hexdigest()
def extract(file,destination):
    destination.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(file) as z:
        for item in z.infolist():
            target = (destination/item.filename).resolve()
            if not target.is_relative_to(destination.resolve()): raise ValueError('非法压缩包路径')
        # macOS unzip preserves executable bits and framework symlinks.
    subprocess.run(['/usr/bin/unzip','-oq',str(file),'-d',str(destination)],check=True)
for url,expected,destination in packages:
    file = download/url.rsplit('/',1)[-1]
    if not file.exists() or checksum(file)!=expected:
        print('下载',url,flush=True)
        subprocess.run(['/usr/bin/curl','-fL','--retry','3','-o',str(file)+'.partial',url],check=True)
        os.replace(str(file)+'.partial',file)
    if checksum(file)!=expected: raise SystemExit('校验失败：'+str(file))
    print('校验成功，解压…',flush=True);extract(file,destination)
adb = sdk/'platform-tools/adb'
if not adb.exists():
    source = pathlib.Path(os.environ.get('ANDROID_HOME',str(pathlib.Path.home()/'Library/Android/sdk')))/'platform-tools'
    if (source/'adb').exists(): shutil.copytree(source,sdk/'platform-tools',dirs_exist_ok=True)
    else:
        # Platform-tools is versioned in the Google repository. Discover the stable
        # macOS package and verify against that same official metadata.
        import xml.etree.ElementTree as E
        xml = urllib.request.urlopen('https://dl.google.com/android/repository/repository2-3.xml',timeout=40).read()
        repo = E.fromstring(xml)
        pkg = next(p for p in repo.findall('remotePackage') if p.get('path')=='platform-tools')
        archive = next(a for a in pkg.findall('archives/archive') if a.findtext('host-os')=='macosx')
        complete=archive.find('complete');url='https://dl.google.com/android/repository/'+complete.findtext('url')
        file=download/complete.findtext('url');subprocess.run(['/usr/bin/curl','-fL','--retry','3','-o',str(file),url],check=True)
        if checksum(file)!=complete.findtext('checksum'):raise SystemExit('ADB 校验失败')
        extract(file,sdk)
server = root/'assets/scrcpy-server'
server.parent.mkdir(parents=True, exist_ok=True)
server_sha256 = '8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e'
if not server.exists() or checksum(server, 'sha256') != server_sha256:
    server_url = 'https://github.com/Genymobile/scrcpy/releases/download/v3.3.4/scrcpy-server-v3.3.4'
    temporary = server.with_suffix('.partial')
    subprocess.run(['/usr/bin/curl', '-fL', '--retry', '3', '-o', str(temporary), server_url], check=True)
    if checksum(temporary, 'sha256') != server_sha256: raise SystemExit('scrcpy 校验失败')
    os.replace(temporary, server)
print('完成。现在可以启动 AndroidDeck。')
