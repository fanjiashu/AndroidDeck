#!/usr/bin/env python3
import pathlib, subprocess, sys
from native_build_support import compile_rpc
root = pathlib.Path(__file__).resolve().parent.parent
binary = root.parent.parent/'work/storage-runtime-tests'
sources = ['Model.swift','DeviceInformation.swift','EGLCompatibility.swift','QuickBoot.swift','Mapping.swift','Wheel.swift',
    'MuMuImport.swift','ReadySchemes.swift','FramePresenter.swift','PresentationPolicy.swift','RuntimeDistribution.swift',
    'Sound.swift','RawVideo.swift','StorageRuntimeTests.swift']
rpc = compile_rpc(root, root.parent.parent / 'work/test-storage-runtime-RawRPC.o')
subprocess.run(['/usr/bin/swiftc','-swift-version','5','-D','NATIVE_UNIT_TESTS','-O','-module-cache-path',
    str(root.parent.parent/'work/swift-modules'),*[str(root/'native'/name) for name in sources],
    str(root/'native/MappedFrames.swift'), *rpc, '-framework','CoreVideo','-o',str(binary)],check=True)
subprocess.run([str(binary),sys.argv[1]],check=True)
