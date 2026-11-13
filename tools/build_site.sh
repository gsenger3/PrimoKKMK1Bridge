#!/bin/zsh
#
#  build_site.sh
#  PrimoKKMK1Bridge
#
#  Created by George Senger on 11/13/2026.
#  Copyright © 2026 Primo Studios. All rights reserved.
#
#  Licensed under the MIT License. See LICENSE in the project root or
#  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
#
#  Makes the user guide website from doc/GUIDE.md with MkDocs (mkdocs.yml), and publishes it to GitHub Pages.
#
#    tools/build_site.sh          build it into build/site/
#    tools/build_site.sh serve    preview it at http://127.0.0.1:8000 (run it again after editing the guide)
#    tools/build_site.sh deploy   build it and push it to the gh-pages branch, which GitHub Pages serves
#
#  MkDocs is installed the first time, into a virtual environment in build/mkdocs-venv
#  (versions in tools/site_requirements.txt). The page itself is made in build/site-docs: doc/GUIDE.md as index.md,
#  with doc/img, its links out of doc/ pointing at the repository on GitHub, and its <details> block marked so its
#  Markdown is rendered; the site's stylesheet from doc/site/stylesheets; and the page and header icons, scaled from
#  the editor's app icon (editor/img/appicon.png). The theme's own overrides are in doc/site/overrides.

set -euo pipefail
cd "${0:A:h}/.."

venv=build/mkdocs-venv
wanted=$(grep -c . tools/site_requirements.txt)
have=0
[[ -x $venv/bin/pip ]] && have=$($venv/bin/pip freeze 2>/dev/null | grep -cxF -f tools/site_requirements.txt || true)
if (( have < wanted )); then
  echo "installing MkDocs into $venv"
  python3 -m venv $venv
  $venv/bin/pip install --quiet --disable-pip-version-check -r tools/site_requirements.txt
fi

docs=build/site-docs
rm -rf $docs
mkdir -p $docs
cp -R doc/img $docs/img
cp -R doc/site/stylesheets $docs/stylesheets
# The editor's app icon: favicon.ico (which the theme links), 64 px for the header and the page icon, and 180 px for
# iPhones and iPads.
sips -z 32 32 -s format ico editor/img/appicon.png --out $docs/img/favicon.ico >/dev/null
sips -z 64 64 editor/img/appicon.png --out $docs/img/appicon-64.png >/dev/null
sips -z 180 180 editor/img/appicon.png --out $docs/img/apple-touch-icon.png >/dev/null
python3 -I - doc/GUIDE.md $docs/index.md <<'EOF'
import re, sys
repo = "https://github.com/gsenger3/PrimoKKMK1Bridge"
text = open(sys.argv[1], encoding="utf-8").read()
# Links out of doc/: the README on the repository's front page, anything else as a file on GitHub.
text = re.sub(r"\]\(\.\./README\.md(#[^)]*)?\)", lambda m: f"]({repo}{m.group(1) or ''})", text)
text = re.sub(r"\]\(\.\./([^)]+)\)", lambda m: f"]({repo}/blob/main/{m.group(1)})", text)
# Python-Markdown leaves the inside of an HTML block alone unless it's marked (GitHub renders it either way).
text = text.replace("<details>", '<details markdown="1">')
open(sys.argv[2], "w", encoding="utf-8").write(text)
EOF

case ${1:-build} in
  build)  $venv/bin/mkdocs build --strict --quiet && echo "built build/site/index.html" ;;
  serve)  $venv/bin/mkdocs serve ;;
  deploy) source="$(git rev-parse --short HEAD)"
          [[ -n "$(git status --porcelain -- doc mkdocs.yml tools/build_site.sh tools/site_requirements.txt editor/img)" ]] \
            && source="$source plus uncommitted changes"
          $venv/bin/mkdocs gh-deploy --strict --force \
            --message "User guide from $source (doc/GUIDE.md), built with MkDocs {version}" ;;
  *)      echo "usage: tools/build_site.sh [build|serve|deploy]"; exit 2 ;;
esac
