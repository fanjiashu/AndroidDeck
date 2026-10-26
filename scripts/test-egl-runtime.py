#!/usr/bin/env python3
"""Verify the EGL repair, repeat game launches, regressions, and QuickBoot on an isolated AVD."""
import pathlib
import subprocess
import sys

from native_build_support import compile_rpc
root = pathlib.Path(__file__).resolve().parent.parent
binary = root.parent.parent / 'work/egl-runtime-tests'
sources = ['Model.swift', 'EGLCompatibility.swift', 'QuickBoot.swift', 'Mapping.swift', 'Wheel.swift',
    'MuMuImport.swift', 'ReadySchemes.swift', 'FramePresenter.swift', 'PresentationPolicy.swift',
    'RuntimeDistribution.swift', 'Sound.swift', 'RawVideo.swift', 'EGLRuntimeTests.swift']
rpc = compile_rpc(root, root.parent.parent / 'work/test-egl-runtime-RawRPC.o')
subprocess.run(['/usr/bin/swiftc', '-swift-version', '5', '-D', 'NATIVE_UNIT_TESTS', '-O', '-module-cache-path',
    str(root.parent.parent / 'work/swift-modules'), *[str(root / 'native' / name) for name in sources],
    str(root/'native/MappedFrames.swift'), *rpc, '-framework', 'CoreVideo', '-o', str(binary)], check=True)
subprocess.run([str(binary), sys.argv[1]], check=True)
