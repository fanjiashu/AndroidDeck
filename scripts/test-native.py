#!/usr/bin/env python3
"""Compile and execute the Swift protocol/input/pixel self tests on macOS."""
import pathlib, subprocess
from native_build_support import compile_rpc
root = pathlib.Path(__file__).resolve().parent.parent
cache = root.parent.parent / 'work/swift-modules'
cache.mkdir(parents=True, exist_ok=True)
binary = root / 'data/native-selftests'
rpc = compile_rpc(root, cache.parent/'selftest-RawRPC.o')
subprocess.run(['/usr/bin/swiftc', '-swift-version', '5', '-D', 'NATIVE_UNIT_TESTS', '-O', '-module-cache-path', str(cache),
    *[str(root / 'native' / name) for name in ['Model.swift', 'DeviceInformation.swift', 'EGLCompatibility.swift', 'QuickBoot.swift', 'Mapping.swift','Wheel.swift', 'MuMuImport.swift', 'ReadySchemes.swift', 'FramePresenter.swift', 'PresentationPolicy.swift', 'RuntimeDistribution.swift', 'Sound.swift', 'RawVideo.swift', 'SelfTests.swift']],
    str(root/'native/MappedFrames.swift'), *rpc, '-framework', 'CoreVideo', '-o', str(binary)], check=True)
result = subprocess.check_output([str(binary)])
(root / 'data/native-selftests.json').write_bytes(result)
print(result.decode())
