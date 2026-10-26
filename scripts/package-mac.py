#!/usr/bin/env python3
"""Package a clean offline app/DMG; notarize only with explicitly supplied credentials."""
import argparse, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT.parent
WORK = OUT.parent / 'work/distribution'
MACH = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}

def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda: f.read(8*1024*1024), b''): h.update(data)
    return h.hexdigest()

def macho(path):
    if path.is_symlink() or not path.is_file(): return False
    with path.open('rb') as f: return f.read(4) in MACH

def sign_bundle(app, identity):
    sdk = app / 'Contents/Resources/RuntimeSeed/.runtime/sdk'
    # Google's flat resource envelope treats NOTICE files as nested signed code.
    # Remove only obsolete signature metadata in our staged copy, then seal it anew.
    for p in sorted(sdk.rglob('_CodeSignature'), key=lambda p: len(p.parts), reverse=True):
        if p.is_dir(): shutil.rmtree(p)
    for p in sdk.rglob('._*'):
        if p.is_file(): p.unlink()
    launcher = sdk/'emulator/emulator'
    if launcher.exists(): launcher.rename(launcher.with_name('emulator-bin'))
    if launcher.exists(): raise RuntimeError('发行包仍包含会被识别成 flat bundle 的启动器')
    # Hardened runtime omits DYLD_LIBRARY_PATH. Resolve Google's libraries relative
    # to the actual QEMU location instead of enabling unrestricted DYLD variables.
    for engine in (sdk/'emulator/qemu/darwin-aarch64').glob('qemu-system-*'):
        if not macho(engine): continue
        commands = subprocess.check_output(['/usr/bin/otool','-l',str(engine)],text=True)
        for path in ['@executable_path/../../lib64', '@executable_path/../../lib64/qt/lib']:
            if f'path {path} (offset' not in commands:
                run('/usr/bin/install_name_tool','-add_rpath',path,engine,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    ent = WORK / 'emulator-entitlements.plist'
    ent.write_bytes(plistlib.dumps({'com.apple.security.hypervisor': True,
        'com.apple.security.cs.allow-jit': True, 'com.apple.security.cs.allow-unsigned-executable-memory': True}))
    inventory = []
    for p in sorted((p for p in sdk.rglob('*') if macho(p)), key=lambda p: len(p.parts), reverse=True):
        args = ['/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp' if identity != '-' else '--timestamp=none']
        if p.name in {'emulator-bin', 'qemu-system-aarch64', 'qemu-system-aarch64-headless'}: args += ['--entitlements', str(ent)]
        result = subprocess.run([str(a) for a in args]+[str(p)],capture_output=True,text=True)
        if result.returncode: raise RuntimeError(f'签名失败：{p}\n{result.stderr}')
        run('/usr/bin/codesign','--verify','--strict',p,stdout=subprocess.DEVNULL)
        inventory.append(str(p.relative_to(app)))
    for p in sorted(sdk.rglob('*.framework'), key=lambda p: len(p.parts), reverse=True):
        run('/usr/bin/codesign','--force','--sign',identity,'--options','runtime','--timestamp' if identity != '-' else '--timestamp=none',p,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    run('/usr/bin/codesign','--force','--sign',identity,'--options','runtime','--timestamp' if identity != '-' else '--timestamp=none',app)
    run('/usr/bin/codesign','--verify','--deep','--strict',app)
    return inventory

def submit_notary(file, profile, name):
    result = subprocess.check_output(['xcrun','notarytool','submit',str(file),'--keychain-profile',profile,'--wait','--output-format','json'])
    value = json.loads(result); (WORK/(name+'-notary.json')).write_bytes(result)
    if value.get('status') != 'Accepted':
        run('xcrun','notarytool','log',value['id'],'--keychain-profile',profile,WORK/(name+'-notary-log.json'))
        raise RuntimeError('Apple 公证未通过；请检查公证日志')
    return value['id']

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--identity', help='Authorized Developer ID Application identity; omit for an ad-hoc review build')
    parser.add_argument('--notary-profile', help='Existing notarytool keychain profile name, never a password')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--stage-only', action='store_true')
    parser.add_argument('--reuse-stage', action='store_true')
    parser.add_argument('--package-only', action='store_true', help='Package the already verified/signed stage without changing its bytes')
    args = parser.parse_args()
    if args.notary_profile and not args.identity: parser.error('公证需要 Developer ID Application 身份')
    WORK.mkdir(parents=True, exist_ok=True)
    image = WORK/'image'; app = image/'AndroidDeck.app'
    if args.package_only:
        if not app.is_dir(): raise RuntimeError('缺少已签名的发行副本')
    elif not args.reuse_stage:
        if not args.no_build:
            run(sys.executable,ROOT/'scripts/build-native.py',env=dict(os.environ,ANDROIDDECK_BUNDLE_NAME='AndroidDeck-distribution.app'))
        if image.exists(): shutil.rmtree(image)
        image.mkdir(); shutil.copytree(OUT/'AndroidDeck-distribution.app',app,symlinks=True)
        seed = app/'Contents/Resources/RuntimeSeed'; seed.mkdir(); (seed/'.runtime').mkdir()
        print('复制离线 Android SDK…',flush=True)
        shutil.copytree(ROOT/'.runtime/sdk',seed/'.runtime/sdk',symlinks=True)
        assets = seed/'assets'; assets.mkdir()
        for name in ['scrcpy-server','LICENSE-scrcpy.txt','TouchLab.apk']: shutil.copy2(ROOT/'assets'/name,assets/name)
        appsdir = seed/'Apps'; appsdir.mkdir(); apps = []
        catalog = json.loads((ROOT/'assets/builtin-apps.json').read_text())
        for item in catalog:
            source,name,package,code,file = (item[k] for k in ['source','name','package','versionCode','file'])
            target = appsdir/file; shutil.copy2(OUT/'APK'/source,target)
            apps.append({'package':package,'name':name,'file':'Apps/'+file,'versionCode':code,'sha256':digest(target)})
        (seed/'manifest.json').write_text(json.dumps({'version':1,'apps':apps},ensure_ascii=False,indent=2)+'\n')
        (image/'Applications').symlink_to('/Applications',target_is_directory=True)
        (image/'安装说明.txt').write_text('AndroidDeck · Apple Silicon 原生版\n\n将 AndroidDeck 拖到 Applications（应用程序），然后打开。\n首次启动自动准备 Android 14 运行组件；点击“启动 Android”后自动安装内置的地下城与勇士：起源、红果短剧、王者荣耀和和平精英。\n个人设备和键位保存于 ~/Library/Application Support/AndroidDeck/runtime。\n本安装包不包含制作人的账号、登录状态或游戏数据。\n首次打开内置应用的协议及登录请自行确认。\n')
    else:
        fresh = OUT/'AndroidDeck-distribution.app'
        shutil.copy2(fresh/'Contents/MacOS/AndroidDeck',app/'Contents/MacOS/AndroidDeck')
        shutil.copy2(fresh/'Contents/Info.plist',app/'Contents/Info.plist')
    if args.package_only:
        run('/usr/bin/codesign','--verify','--deep','--strict',app)
        inventory = [str(p.relative_to(app)) for p in (app/'Contents/Resources/RuntimeSeed/.runtime/sdk').rglob('*') if macho(p)]
    else:
        inventory = sign_bundle(app,args.identity or '-')
    version = plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version): raise RuntimeError('应用版本号无效')
    (image/'安装说明.txt').write_text('AndroidDeck · Apple Silicon 原生版\n\n将 AndroidDeck 拖到 Applications（应用程序），然后打开。\n打开后自动启动 Android；全新设备会离线安装内置的地下城与勇士：起源、红果短剧、王者荣耀和和平精英。\n正常退出后可快速恢复；左侧“重新启动 Android”可完整重启系统。\n右上角“设置”调整内存、分辨率和方向，“键位”打开自定义触摸映射。\n个人设备和键位保存于 ~/Library/Application Support/AndroidDeck/runtime。\n本安装包不包含制作人的账号、登录状态或游戏数据。\n首次打开内置应用的协议及登录请自行确认。\n')
    seed = app/'Contents/Resources/RuntimeSeed'
    if any(p.name not in {'.runtime', 'Apps', 'assets', 'manifest.json'} for p in seed.iterdir()): raise RuntimeError('发行运行组件包含未授权的额外数据')
    if any(p.suffix == '.qcow2' or p.name in {'adbkey', 'adbkey.pub'} for p in seed.rglob('*')): raise RuntimeError('发行副本包含个人设备磁盘或密钥')
    manifest = json.loads((seed/'manifest.json').read_text())
    for item in manifest['apps']:
        if digest(app/'Contents/Resources/RuntimeSeed'/item['file']) != item['sha256']: raise RuntimeError('内置 APK 字节校验失败')
    signature = subprocess.run(['/usr/bin/codesign','-d','--verbose=4',str(app)],capture_output=True,text=True,check=True).stderr
    if args.identity and 'Authority=Developer ID Application:' not in signature: raise RuntimeError('发行包缺少 Developer ID 签名')
    if args.identity:
        cert = WORK/'public-signature-cert'
        run('/usr/bin/codesign','-d','--extract-certificates='+str(cert),app,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        fingerprint = hashlib.sha1(pathlib.Path(str(cert)+'0').read_bytes()).hexdigest().upper()
        if len(args.identity) == 40 and fingerprint != args.identity.upper(): raise RuntimeError('签名证书与授权身份不符')
    else: fingerprint = None
    report = {'version':version,'app':str(app),'offline':True,'builtinApps':manifest['apps'],'existingUserDataIncluded':False,
        'signingCertificateSHA1':fingerprint,'nativeExecutableSHA256':digest(app/'Contents/MacOS/AndroidDeck'),
        'nativeMachOFiles':inventory,'signature':'Developer ID Application' if args.identity else 'ad-hoc review build','notarized':False}
    if args.stage_only:
        (OUT/'DMG打包验证报告.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n'); print(app); return
    if args.notary_profile:
        archive = WORK/'AndroidDeck-notary.zip'
        if archive.exists(): archive.unlink()
        run('/usr/bin/ditto','-c','-k','--keepParent',app,archive)
        report['appNotaryId'] = submit_notary(archive,args.notary_profile,'app')
        run('xcrun','stapler','staple',app); run('xcrun','stapler','validate',app)
    dmg = OUT/f'AndroidDeck-{version}-arm64.dmg'
    if dmg.exists(): dmg.unlink()
    run('/usr/bin/hdiutil','create','-volname','AndroidDeck','-srcfolder',image,'-format','UDZO',dmg)
    if args.identity: run('/usr/bin/codesign','--force','--sign',args.identity,'--timestamp',dmg)
    if args.notary_profile:
        report['dmgNotaryId'] = submit_notary(dmg,args.notary_profile,'dmg')
        run('xcrun','stapler','staple',dmg); run('xcrun','stapler','validate',dmg)
        run('/usr/sbin/spctl','--assess','--type','open','--context','context:primary-signature','--verbose=2',dmg)
        report['notarized'] = True
    run('/usr/bin/hdiutil','verify',dmg)
    report.update(dmg=str(dmg),bytes=dmg.stat().st_size,sha256=digest(dmg))
    (OUT/'DMG打包验证报告.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(dmg,flush=True)

if __name__ == '__main__': main()
