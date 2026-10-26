#!/usr/bin/env python3
"""Build the Swift/AppKit desktop bundle without Electron or Node runtime."""
import os, pathlib, plistlib, shutil, subprocess
from native_build_support import compile_rpc
root=pathlib.Path(__file__).resolve().parent.parent
bundle=root.parent/os.environ.get('ANDROIDDECK_BUNDLE_NAME','AndroidDeck.app')
build=root/'data/native-build'
build.mkdir(parents=True,exist_ok=True)
cache=pathlib.Path(os.environ.get('ANDROIDDECK_BUILD_CACHE', str(root/'.cache/swift-modules')))
cache.mkdir(parents=True,exist_ok=True)
sources=[root/'native'/name for name in ['Model.swift','DeviceInformation.swift','DeviceInformationUI.swift','EGLCompatibility.swift','QuickBoot.swift','Mapping.swift','Wheel.swift','MappingEditor.swift','MuMuImport.swift','ReadySchemes.swift','Adaptation.swift','OverlayText.swift','Shell.swift','Fullscreen.swift','ShellVerification.swift','FramePresenter.swift','PresentationPolicy.swift','Presentation.swift','Projection.swift','PresentationVerification.swift','RuntimeDistribution.swift','Sound.swift','RawVideo.swift','Video.swift','Verification.swift','EditorVerification.swift','main.swift']]
sources += [root/'native/MappedFrames.swift', root/'native/DeckTheme.swift', root/'native/DesignVerification.swift']
rpc = compile_rpc(root, build/'RawRPC.o')
subprocess.run(['/usr/bin/swiftc','-swift-version','5','-O','-target','arm64-apple-macosx13.0','-module-cache-path',str(cache),
    *map(str,sources),*rpc,'-o',str(build/'AndroidDeck'),'-framework','AppKit','-framework','Network','-framework','VideoToolbox','-framework','MetalKit','-framework','CoreImage'],check=True)
if bundle.exists():shutil.rmtree(bundle)
macos=bundle/'Contents/MacOS';resources=bundle/'Contents/Resources'
macos.mkdir(parents=True);resources.mkdir()
shutil.copy2(build/'AndroidDeck',macos/'AndroidDeck')
if (root/'assets/AndroidDeck.icns').is_file():
    shutil.copy2(root/'assets/AndroidDeck.icns',resources/'AndroidDeck.icns')
if (root/'assets/AppIcons').is_dir():
    shutil.copytree(root/'assets/AppIcons', resources/'AppIcons')
info={'CFBundleName':'AndroidDeck','CFBundleDisplayName':'AndroidDeck','CFBundleIdentifier':'com.androiddeck.native',
      'CFBundleExecutable':'AndroidDeck','CFBundleIconFile':'AndroidDeck.icns','CFBundlePackageType':'APPL',
      'CFBundleShortVersionString':'1.8.1','CFBundleVersion':'1.8.1','LSMinimumSystemVersion':'13.0',
      'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','LSApplicationCategoryType':'public.app-category.developer-tools',
      'NSDocumentsFolderUsageDescription':'读取 AndroidDeck 运行环境并保存虚拟设备、游戏数据和键盘映射。'}
if not (resources/'AndroidDeck.icns').exists(): info.pop('CFBundleIconFile', None)
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(bundle)],check=True)
print(bundle)
