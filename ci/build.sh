#!/usr/bin/env bash
# Build, sign and stage the AbelNotes Flatpak repository for one app tag.
#
# Run by .github/workflows/publish.yml inside the Flathub CI container, and the
# same way by hand:
#   docker run --rm --privileged -v "$PWD:/w" -w /w -e TAG=v0.37.7 -e SITE_URL=... \
#     -e GPG_PRIVATE_KEY -e GPG_PASSPHRASE -e LEAK_EXTRA \
#     ghcr.io/flathub-infra/flatpak-github-actions:freedesktop-25.08 ci/build.sh
#
# Env: TAG, SITE_URL, GPG_PRIVATE_KEY (armored), GPG_PASSPHRASE, LEAK_EXTRA
# (regex alternatives for personal identifiers, kept out of this public file).
# Optional: GOOGLE_CLIENT_ID + GOOGLE_CLIENT_SECRET (desktop Drive client;
# without them Drive is off), NOTES_FILE (GitHub release notes, markdown),
# PACKAGING_REF (app commit whose flatpak/ to use instead of the default).
# Output: _site/ (the static site to publish). _work/ holds secrets: never
# publish it.
set -euo pipefail

: "${TAG:?}" "${SITE_URL:?}" "${GPG_PRIVATE_KEY:?}" "${GPG_PASSPHRASE:?}" "${LEAK_EXTRA:?}"
SITE_URL=${SITE_URL%/}

APP=app.abelnotes.notes
SRC=https://github.com/abelnotes/abelnotes.git
FF_REPO=https://github.com/TheAppgineer/flatpak-flutter
# The packaging (manifest template, metainfo) lives in the app repository
# under flatpak/ and is taken from the release tag. Tags older than this
# commit predate the build-defines.json layout and use its flatpak/ instead.
PACKAGING_FLOOR=8487895be3260dc5cd35026289f0c37158ebac52
FF_COMMIT=e59a96fcb0fcf48fcd46e8134cae64c26fdc3290
# Only this key may sign: a swapped secret would otherwise lock every
# existing install out of updates.
EXPECTED_FPR=470FB712EAA3383EBE737959D5C072DD570C9170
# Machine paths and personal data that must never reach the published site.
LEAK="(/home/[a-z][a-z0-9_-]*/|/Users/[A-Za-z]|$LEAK_EXTRA)"

ROOT=$(pwd)
W=$ROOT/_work
OUT=$ROOT/_site
rm -rf "$W" "$OUT"
mkdir -p "$W" "$OUT"

say() { printf '\n==> %s\n' "$1"; }

say "Resolving $TAG"
VERSION=${TAG#v}
COMMIT=$(git ls-remote "$SRC" "refs/tags/$TAG^{}" | cut -f1)
[[ -n $COMMIT ]] || COMMIT=$(git ls-remote "$SRC" "refs/tags/$TAG" | cut -f1)
[[ -n $COMMIT ]] || { echo "tag $TAG not found in $SRC" >&2; exit 1; }
echo "$TAG = $COMMIT"

say "Packaging"
git clone -q --filter=blob:none --no-checkout "$SRC" "$W/app"
if [[ -n ${PACKAGING_REF:-} ]]; then
  PKG=$(git -C "$W/app" rev-parse --verify "$PACKAGING_REF^{commit}")
elif git -C "$W/app" merge-base --is-ancestor "$PACKAGING_FLOOR" "$COMMIT"; then
  PKG=$COMMIT
else
  PKG=$PACKAGING_FLOOR
fi
echo "flatpak/ from $PKG"
git -C "$W/app" show "$PKG:flatpak/flatpak-flutter.yml" > "$W/template.yml"
git -C "$W/app" show "$PKG:flatpak/$APP.metainfo.xml" > "$W/metainfo.in.xml"

say "Manifest and metadata"
sed -E "s#^([[:space:]]+tag:) v[0-9][0-9.]*\$#\1 $TAG#" "$W/template.yml" > "$W/flatpak-flutter.yml"
grep -q "tag: $TAG\$" "$W/flatpak-flutter.yml" || { echo "could not pin the tag" >&2; exit 1; }
grep -q 'dart-define-from-file=build-defines.json' "$W/flatpak-flutter.yml" ||
  { echo "flatpak/ at $PKG predates build-defines.json; set PACKAGING_REF" >&2; exit 1; }
python3 ci/metainfo.py "$W/metainfo.in.xml" "$VERSION" "${NOTES_FILE:-}" > "$W/$APP.metainfo.xml"
COMMIT="$COMMIT" python3 - > "$W/build-defines.json" <<'EOF'
import json, os
d = {"GIT_COMMIT": os.environ["COMMIT"][:7]}
for k in ("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET"):
    if os.environ.get(k):
        d[k] = os.environ[k]
print(json.dumps(d))
EOF
chmod 600 "$W/build-defines.json"

say "Offline sources (flatpak-flutter ${FF_COMMIT:0:7})"
git clone -q "$FF_REPO" "$W/ff"
git -C "$W/ff" checkout -q "$FF_COMMIT"
python3 -m venv "$W/venv"
"$W/venv/bin/pip" install -q -r "$W/ff/requirements.txt"
(cd "$W" && "$W/venv/bin/python" ff/flatpak-flutter.py --app-module abelnotes flatpak-flutter.yml)

say "Signing key"
export GNUPGHOME=$W/gnupg
mkdir -m 700 "$GNUPGHOME"
echo allow-preset-passphrase > "$GNUPGHOME/gpg-agent.conf"
printf '%s\n' "$GPG_PRIVATE_KEY" |
  gpg --batch --pinentry-mode loopback --passphrase-fd 3 --import 3< <(printf '%s' "$GPG_PASSPHRASE") 2>/dev/null
FPR=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
[[ $FPR == "$EXPECTED_FPR" ]] || { echo "signing key is $FPR, expected $EXPECTED_FPR" >&2; exit 1; }
KEYGRIP=$(gpg --list-secret-keys --with-colons --with-keygrip | awk -F: '/^grp/{print $10; exit}')
gpg-connect-agent reloadagent /bye >/dev/null
printf '%s' "$GPG_PASSPHRASE" | "$(gpgconf --list-dirs libexecdir)/gpg-preset-passphrase" --preset "$KEYGRIP"
trap 'gpg-connect-agent reloadagent /bye >/dev/null 2>&1 || true' EXIT
echo "signing as $FPR"

say "Build"
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
(cd "$W" && flatpak-builder --user --sandbox --disable-rofiles-fuse --install-deps-from=flathub \
  --force-clean --default-branch=stable --repo="$W/repo" --gpg-sign="$FPR" \
  build-dir "$APP.yml")

say "Checking the build"
LIBAPP=$W/build-dir/files/abelnotes/lib/libapp.so
grep -aq "${COMMIT:0:7}" "$LIBAPP" || { echo "GIT_COMMIT missing from libapp.so" >&2; exit 1; }
if [[ -n ${GOOGLE_CLIENT_ID:-} ]]; then
  grep -aq "$GOOGLE_CLIENT_ID" "$LIBAPP" || { echo "Drive client missing from libapp.so" >&2; exit 1; }
fi
grep -q "release version=\"$VERSION\"" "$W/build-dir/files/share/metainfo/$APP.metainfo.xml"

say "Repository"
flatpak build-update-repo --title=AbelNotes --default-branch=stable \
  --generate-static-deltas --prune --gpg-sign="$FPR" "$W/repo"
cp -r "$W/repo" "$OUT/repo"
gpg --export "$FPR" > "$OUT/abelnotes.gpg"
GPGB64=$(base64 -w0 "$OUT/abelnotes.gpg")
cat > "$OUT/abelnotes.flatpakref" <<EOF
[Flatpak Ref]
Title=AbelNotes
Name=$APP
Branch=stable
Url=$SITE_URL/repo/
SuggestRemoteName=abelnotes
Homepage=https://abelnotes.app
Icon=$SITE_URL/icon.png
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
IsRuntime=false
GPGKey=$GPGB64
EOF
cat > "$OUT/abelnotes.flatpakrepo" <<EOF
[Flatpak Repo]
Title=AbelNotes
Url=$SITE_URL/repo/
Homepage=https://abelnotes.app
Comment=AbelNotes app repository
GPGKey=$GPGB64
EOF
flatpak build-bundle --repo-url="$SITE_URL/repo/" \
  --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
  --gpg-keys="$OUT/abelnotes.gpg" "$W/repo" "$OUT/abelnotes.flatpak" "$APP" stable
cp "$W/build-dir/files/share/icons/hicolor/512x512/apps/$APP.png" "$OUT/icon.png"
sed -e "s#@VERSION@#$VERSION#g" -e "s#@SITE_URL@#$SITE_URL#g" -e "s#@FPR@#$FPR#g" site/index.html > "$OUT/index.html"
echo "$VERSION" > "$OUT/version.txt"

say "Leak scan"
# Repo objects are compressed, so scan the uncompressed build too.
hits=0
while IFS= read -r -d '' f; do
  if strings -a "$f" 2>/dev/null | grep -Ec "$LEAK" >/dev/null; then echo "LEAK: ${f#$ROOT/}"; hits=1; fi
done < <(find "$W/build-dir/files" "$OUT" -type f -print0)
# The Drive desktop secret is in the binary on purpose; the signing key is not.
if grep -rlaF -- "$GPG_PASSPHRASE" "$OUT" >/dev/null || grep -rlaF "PRIVATE KEY BLOCK" "$OUT" >/dev/null; then
  echo "signing secrets ended up in _site" >&2; hits=1
fi
[[ $hits == 0 ]] || { echo "refusing to publish" >&2; exit 1; }
echo "clean"

say "Done: $VERSION ($(du -sh "$OUT" | cut -f1))"
