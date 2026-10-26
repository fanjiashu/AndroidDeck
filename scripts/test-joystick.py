#!/usr/bin/env python3
"""Check native joystick MotionEvents on an existing emulator, then restore DNF."""
import pathlib, subprocess, sys
from native_build_support import compile_rpc
root = pathlib.Path(__file__).resolve().parent.parent
binary = root / 'data/joystick-tests'
cache = root.parent.parent / 'work/swift-modules'
rpc = compile_rpc(root, root.parent.parent / 'work/test-joystick-RawRPC.o')
subprocess.run(['/usr/bin/swiftc', '-swift-version', '5', '-D', 'NATIVE_UNIT_TESTS', '-O', '-module-cache-path', str(cache),
    *[str(root / 'native' / name) for name in ['Model.swift', 'EGLCompatibility.swift', 'QuickBoot.swift', 'RuntimeDistribution.swift', 'FramePresenter.swift', 'Mapping.swift','Wheel.swift', 'MuMuImport.swift', 'PresentationPolicy.swift', 'Sound.swift', 'RawVideo.swift', 'Video.swift', 'JoystickTests.swift']],
    str(root/'native/MappedFrames.swift'), *rpc, '-framework', 'AppKit', '-framework', 'VideoToolbox', '-framework', 'MetalKit', '-framework', 'CoreImage', '-o', str(binary)], check=True)
subprocess.run([str(binary), str(root), sys.argv[1] if len(sys.argv) > 1 else 'emulator-5580'], check=True)
