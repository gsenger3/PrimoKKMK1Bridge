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
#  Markdown is rendered.

set -euo pipefail
cd "${0:A:h}/.."
# Material for MkDocs prints a banner on every build: it reaches end of life on May 5, 2027 (fixes until then), and
# Zensical, from the same team, is its successor and reads mkdocs.yml (https://zensical.org). Noted here instead.
export NO_MKDOCS_2_WARNING=1

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
python3 -I - doc/GUIDE.md $docs/index.md <<'EOF'
import re, sys
repo = "https://github.com/gsenger3/PrimoKKMK1Bridge"
text = open(sys.argv[1], encoding="utf-8").read()
# Links out of doc/: the README on the repository's front page, anything else as a file on GitHub.
text = re.sub(r"\]\(\.\./README\.md(#[^)]*)?\)", lambda m: f"]({repo}{m.group(1) or ''})", text)
text = re.sub(r"\]\(\.\./([^)]+)\)", lambda m: f"]({repo}/blob/main/{m.group(1)})", text)
# Python-Markdown leaves the inside of an HTML block alone unless it's marked (GitHub renders it either way).
text = text.replace("<details>", '<details markdown="1">')
# One page: no navigation sidebar, just the guide's own contents on the right.
front = "---\nhide:\n  - navigation\n---\n\n"
open(sys.argv[2], "w", encoding="utf-8").write(front + text)
EOF

case ${1:-build} in
  build)  $venv/bin/mkdocs build --strict --quiet && echo "built build/site/index.html" ;;
  serve)  $venv/bin/mkdocs serve ;;
  deploy) $venv/bin/mkdocs gh-deploy --strict --force \
            --message "User guide from $(git rev-parse --short HEAD) (doc/GUIDE.md), built with MkDocs {version}" ;;
  *)      echo "usage: tools/build_site.sh [build|serve|deploy]"; exit 2 ;;
esac
