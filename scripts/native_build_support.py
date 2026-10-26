import pathlib
import subprocess

def compile_rpc(root: pathlib.Path, output: pathlib.Path):
    subprocess.run(['/usr/bin/clang', '-std=c11', '-O2', '-arch', 'arm64',
        '-mmacosx-version-min=13.0', '-Wall', '-Wextra', '-Werror',
        '-c', str(root / 'native/RawRPC.c'), '-o', str(output)], check=True)
    return ['-import-objc-header', str(root / 'native/RawRPC.h'), str(output), '-lcurl']
