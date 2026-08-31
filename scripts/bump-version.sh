#!/bin/bash
# 统一版本号：Edge manifest / npm-launcher / Info.plist 模板 / Homebrew cask
# 用法：bash scripts/bump-version.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?用法: bash scripts/bump-version.sh 0.2.0}"

python3 - "$V" <<'EOF'
import json, sys, re
v = sys.argv[1]

p = "Windows/edge-extension/manifest.json"
d = json.load(open(p)); d["version"] = v
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)

p = "npm-launcher/package.json"
d = json.load(open(p)); d["version"] = v
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)

p = "scripts/package-app.sh"
s = open(p).read()
s = re.sub(r'<string>\d+\.\d+\.\d+</string>', f'<string>{v}</string>', s, count=1)
open(p, "w").write(s)

p = "homebrew/Casks/parallel-workbench.rb"
s = open(p).read()
s = re.sub(r'version "\d+\.\d+\.\d+"', f'version "{v}"', s, count=1)
open(p, "w").write(s)

print(f"✅ 版本统一为 {v}")
EOF
