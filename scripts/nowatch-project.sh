#!/usr/bin/env bash
# Generates WellderNoWatch.xcodeproj: the same iOS app without the embedded watch app.
# Xcode refuses to build a scheme that embeds a watch app unless the watchOS platform runtime is
# installed (Xcode > Settings > Components). Use this on machines/CI without it.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
s = open('project.yml').read()
s = s.replace('name: Wellder\n', 'name: WellderNoWatch\n', 1)
s = s.replace('      - target: WellderWatch\n', '', 1)
s = s.replace('  WellderWatch:\n    build:\n      targets:\n        WellderWatch: all\n', '')
open('.project-nowatch.yml', 'w').write(s)
PY
xcodegen generate --spec .project-nowatch.yml --quiet
rm .project-nowatch.yml
echo "Generated WellderNoWatch.xcodeproj (scheme: Wellder)"
