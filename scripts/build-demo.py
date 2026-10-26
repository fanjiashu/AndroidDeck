#!/usr/bin/env python3
"""Build the included real Android APK using the local SDK, without Gradle."""
import os, pathlib, subprocess
root = pathlib.Path(__file__).resolve().parent.parent
sdk = pathlib.Path(os.environ.get('ANDROID_HOME', str(pathlib.Path.home()/'Library/Android/sdk')))
jdk = pathlib.Path(os.environ.get('JAVA_HOME', '/Applications/Android Studio.app/Contents/jbr/Contents/Home'))
tools = sorted((sdk/'build-tools').iterdir())[-1]
jar = sorted((sdk/'platforms').glob('*/android.jar'))[-1]
work = root/'data/demo-build'
work.mkdir(parents=True, exist_ok=True)
(work/'classes').mkdir(exist_ok=True)
(work/'dex').mkdir(exist_ok=True)
env = dict(os.environ, JAVA_HOME=str(jdk))
def run(*args): subprocess.run([str(a) for a in args], check=True, env=env)
run(jdk/'bin/javac', '-source', '8', '-target', '8', '-encoding', 'UTF-8', '-classpath', jar, '-d', work/'classes', root/'demo/TouchLab.java')
run(tools/'d8', '--min-api', '26', '--lib', jar, '--output', work/'dex', *sorted((work/'classes').rglob('*.class')))
run(tools/'aapt', 'package', '-f', '-M', root/'demo/AndroidManifest.xml', '-I', jar, '-F', work/'unsigned.apk')
# aapt add resolves relative to cwd.
subprocess.run([str(tools/'aapt'), 'add', str(work/'unsigned.apk'), 'classes.dex'], cwd=work/'dex', check=True)
run(tools/'zipalign', '-f', '4', work/'unsigned.apk', work/'aligned.apk')
key = work/'demo.keystore'
if not key.exists():
    run(jdk/'bin/keytool', '-genkeypair', '-keystore', key, '-alias', 'androiddeck', '-storepass', 'androiddeck', '-keypass', 'androiddeck', '-dname', 'CN=AndroidDeck Demo', '-keyalg', 'RSA', '-validity', '10000')
run(tools/'apksigner', 'sign', '--ks', key, '--ks-pass', 'pass:androiddeck', '--out', root/'assets/TouchLab.apk', work/'aligned.apk')
run(tools/'apksigner', 'verify', '--verbose', root/'assets/TouchLab.apk')
print('Built', root/'assets/TouchLab.apk')
