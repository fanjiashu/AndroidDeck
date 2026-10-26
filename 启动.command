#!/bin/zsh
set -e
cd "${0:A:h}"
bundle_path="${PWD:A:h}/AndroidDeck.app"
if [[ -x "$bundle_path/Contents/MacOS/AndroidDeck" ]]; then
  exec "$bundle_path/Contents/MacOS/AndroidDeck" "$@"
fi
print "缺少原生应用包，请运行：python3 scripts/build-native.py"
read "?按回车关闭…"
