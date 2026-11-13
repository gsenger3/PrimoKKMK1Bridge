#!/bin/zsh
#
#  make_release.sh
#  PrimoKKMK1Bridge
#
#  Created by George Senger on 11/13/2026.
#  Copyright © 2026 Primo Studios. All rights reserved.
#
#  Licensed under the MIT License. See LICENSE in the project root or
#  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
#
#  Builds the release downloads from the committed code (HEAD), both with one version stamp (issue #19):
#
#    build/release/PrimoKKMK1Editor-<version>-macOS-arm64.zip       Apple Silicon only, the smaller download
#    build/release/PrimoKKMK1Editor-<version>-macOS-universal.zip   Apple Silicon and Intel Macs
#
#  Each holds the editor app with the bridge inside, for macOS 14 or later. The script checks what's in each zip
#  (architectures, minimum macOS, signature) and prints its size and SHA-256 for the release notes. It doesn't
#  publish anything: attach the zips to a GitHub release yourself (gh release create, or the website).
#
#    tools/make_release.sh [--ref COMMIT] [--allow-dirty]
#
#  It builds from a clean copy of HEAD (or --ref: a tag or commit, say to rebuild an earlier release) in
#  build/release/src, so uncommitted changes aren't in the release; building HEAD stops if there are any, unless
#  --allow-dirty.

set -euo pipefail
cd "${0:A:h}/.."

ref=HEAD
allow_dirty=false
while (( $# )); do
    case $1 in
        --ref) ref=${2:-}; shift 2 ;;
        --allow-dirty) allow_dirty=true; shift ;;
        *) echo "usage: tools/make_release.sh [--ref COMMIT] [--allow-dirty]" >&2; exit 2 ;;
    esac
done
git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { echo "make_release.sh: no commit \"$ref\"" >&2; exit 2; }
if [[ $ref == HEAD && -n "$(git status --porcelain)" ]] && ! $allow_dirty; then
    echo "There are uncommitted changes, which wouldn't be in the release (it's built from HEAD)." >&2
    echo "Commit them first, or run with --allow-dirty to build HEAD anyway." >&2
    exit 1
fi

out=$PWD/build/release
src=$out/src
rm -rf $out
mkdir -p $src
git archive "$ref" | tar -x -C $src
commit=$(git rev-parse --short "$ref^{commit}")

cd $src
version=$(tools/stamp_version.sh)
source build/version.env
echo "release $version from $commit"

zips=()
for arch in arm64 universal; do
    editor/build.sh --arch $arch --keep-version
    mkdir -p $out/$arch
    rm -rf $out/$arch/PrimoKKMK1Editor.app
    mv build/PrimoKKMK1Editor.app $out/$arch/
    zip=$out/PrimoKKMK1Editor-$APP_VERSION-macOS-$arch.zip
    ditto -c -k --sequesterRsrc --keepParent $out/$arch/PrimoKKMK1Editor.app $zip
    zips+=($zip)
done

# Check what a download really holds: unzip each, then its signature, architectures and minimum macOS.
echo
for zip in $zips; do
    check=$out/check/${zip:t:r}
    rm -rf $check
    mkdir -p $check
    ditto -x -k $zip $check
    app=$check/PrimoKKMK1Editor.app
    codesign --verify --strict $app
    echo "${zip:t}  $(stat -f %z $zip) bytes"
    echo "  SHA-256 $(shasum -a 256 $zip | cut -d' ' -f1)"
    for program in PrimoKKMK1Editor PrimoKKMK1Bridge; do
        binary=$app/Contents/MacOS/$program
        for a in $(lipo -archs $binary); do
            echo "  $program $a, macOS $(vtool -arch $a -show-build $binary | awk '/minos/{print $2}') or later"
        done
    done
    echo "  version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $app/Contents/Info.plist)" \
         "($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $app/Contents/Info.plist)), signature ok"
done
rm -rf $out/check
