#!/bin/zsh
set -e
cd "${0:A:h}"
python3 scripts/setup-runtime.py
read "?安装完成，按回车关闭…"
