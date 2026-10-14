#!/usr/bin/env bash
# Build Deadband-x86_64.AppImage: one file that runs on most x86_64 Linux
# desktops (glibc 2.34 or newer -- PySide6 6.11's own floor: Ubuntu 22.04+,
# Debian 12+, RHEL 9+) with nothing installed.
#
#     packaging/appimage/build-appimage.sh            # output: build/appimage/
#
# The build runs inside the manylinux_2_34 container (AlmaLinux 9, glibc 2.34),
# which the script starts itself with podman (or docker, CONTAINER_ENGINE=docker).
# 2.34 is PySide6's floor anyway, so building there costs nothing; an older image
# can't be used, because pip there refuses PySide6 6.11's manylinux_2_34 wheels.
# Every native file that isn't a downloaded wheel -- the hidapi it compiles, the
# libusb and libxcb-cursor it copies -- links against whatever glibc and
# toolchain it was built with. Built on the host, they inherit the host's: a
# Fedora 44 build needed glibc 2.38 for hidapi and libxcb-cursor and a newer
# TLS ABI (GLIBC_ABI_GNU2_TLS) for libusb, so the AppImage ran only on distros
# as new as the build machine. Step 6 fails the build if anything bundled needs
# more than GLIBC_MAX. NO_CONTAINER=1 builds on the host anyway (that host only).
#
# What goes in:
#   * a relocatable CPython (python-appimage's manylinux build, downloaded),
#   * PySide6 (pinned below to the version the app is tested with),
#   * cython-hidapi built from source WITH THE HIDRAW BACKEND -- pip's source
#     build defaults to libusb, which cannot open the controllers (see
#     install.sh); a libusb build would launch fine and then fail every open,
#   * libusb-1.0 from the build container (the G7 Pro / Kaleid raw-USB path),
#     handed to the app through DEADBAND_LIBUSB because ctypes.util.find_library
#     only searches the system linker cache, never the bundle,
#   * libxcb-cursor from the build container: Qt 6.5+ needs it for X11
#     and many distros don't install it by default,
#   * the app itself: the repo's TRACKED top-level *.py, vendors/ and qml/ (git
#     ls-files, so untracked local scripts in the checkout never ship), plus the
#     assets, udev rules and LICENSE named in step 4.
#
# What can't go in: the udev rule. Granting device access needs root on the
# host, so AppImage users still install 70-gamesir.rules once; the README
# shows how to extract it from the AppImage (--appimage-extract <path>).
#
# Build prerequisites (this machine only, not users'): podman or docker.
# Inside the container the script installs systemd-devel (libudev headers),
# libusbx (libusb-1.0), xcb-util-cursor and git; gcc, curl, file and Python 3.12
# come with the image. The repo must be a git checkout.
# Downloads: the container image from quay.io; python-appimage from PyPI and its
# Python build from its GitHub releases; appimagetool from
# github.com/AppImage/appimagetool.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY_VERSION="${PY_VERSION:-3.12}"
PYSIDE6_VERSION="${PYSIDE6_VERSION:-6.11.2}"   # what the Linux checks ran on
LINUX_TAG="manylinux_2_28_x86_64"              # the relocatable Python's floor
GLIBC_MAX="${GLIBC_MAX:-2.34}"                 # PySide6 6.11's; nothing may need more
# Every download is pinned, so the shipped AppImage only changes when these lines
# do. To bump one: pick the new release, then update its version AND its hash.
# The image is pinned by digest (the tag is only for humans; podman/docker pull
# by the digest and refuse anything else):
#   curl -s 'https://quay.io/api/v1/repository/pypa/manylinux_2_34_x86_64/tag/?limit=20' \
#     | python3 -c 'import json,sys; [print(t["name"], t["manifest_digest"]) for t in json.load(sys.stdin)["tags"]]'
BUILD_IMAGE="${BUILD_IMAGE:-quay.io/pypa/manylinux_2_34_x86_64:2026.09.29-1@sha256:775612b592df48028dab9c8e4741605ed9cf050b06cc716423aceca6e6074158}"
OUT="${OUT:-$REPO/build/appimage}"
WORK="$OUT/work"
# A numbered release, never "continuous" (a rolling tag that is rebuilt in place).
# Hash: the release page lists it per asset, or sha256sum a download.
APPIMAGETOOL_VERSION="1.9.1"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-x86_64.AppImage"
# python-appimage and its dependencies, installed with --require-hashes (pip
# refuses anything unlisted or altered). Hashes: https://pypi.org/pypi/<name>/<version>/json
# (wheel + sdist; charset-normalizer's cp312 manylinux wheel too). The relocatable
# Python it then downloads comes from a rolling GitHub release that is replaced in
# place, so it can't be pinned by hash; step 6's import and glibc checks gate it.
# Single-quoted, so pip gets the backslash continuations as written.
PYTHON_APPIMAGE_REQUIREMENTS='
python-appimage==1.4.6 \
    --hash=sha256:3a120438eea6769a14bbb051e5d0708b40b5a9f993d6dbc39ab4ab127f94ac57 \
    --hash=sha256:6879f38c4aab1868c6e50cce8a79c85e7e949b3ab157ba3838fd6124802cbb15
requests==2.34.2 \
    --hash=sha256:2a0d60c172f83ac6ab31e4554906c0f3b3588d37b5cb939b1c061f4907e278e0 \
    --hash=sha256:f288924cae4e29463698d6d60bc6a4da69c89185ad1e0bcc4104f584e960b9ed
certifi==2026.7.22 \
    --hash=sha256:62f22742b58a1a33014a2b6b706588a8d7e2a88ae7bd1a6ebe8c992928483775 \
    --hash=sha256:741e2c3b351ddf169a738da9f2c048608ff7f2c5cc02f1ebc6b118bb090d5d55
charset-normalizer==3.5.2 \
    --hash=sha256:3d31298449090ab8d47b7b1b2a555ff73cac7ed438a08b7ac160980c7ebed649 \
    --hash=sha256:b6b751274acb69d77b3323d6b7dbaa3c7fdfc1eb829b7eb61d262f32e1af9685 \
    --hash=sha256:39de2a259fc954455c57274dc94c79d5842774e1247a016aff30bc0efed0f4ef
idna==3.20 \
    --hash=sha256:ab7ae7122974553370f0bdb919e1a960b2cd1bc1ef0276416d896db81c14582c \
    --hash=sha256:a7db850025b95ded1eae8a46181a1a6c56c92c96f0e2b005d9ff8dc0210cab44
urllib3==2.8.0 \
    --hash=sha256:0cf3cae568d36aa9576b28dfb35f11328f1cb974ca7647d9475ebb86c75ac6e3 \
    --hash=sha256:63bf2ead4c879426ebf22ef2a781eeb4aa3b4ae798a0435506f8687fd5bb9b63
setuptools==84.0.0 \
    --hash=sha256:51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670 \
    --hash=sha256:f4695c21257f0d9b537ec2692c941d02ee143b7cc1276941349a546573b2ef73
'
HIDAPI_VERSION="0.15.0"

# appimagetool and the python-appimage base are AppImages themselves; extract-
# and-run means FUSE isn't needed on the build machine.
export APPIMAGE_EXTRACT_AND_RUN=1

say() { printf '==> %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = x86_64 ] || die "builds x86_64 only (this is $(uname -m))"

# 0. Re-run inside the build container ----------------------------------------------
if [ -z "${DEADBAND_IN_CONTAINER:-}" ] && [ -z "${NO_CONTAINER:-}" ]; then
  engine="${CONTAINER_ENGINE:-$(command -v podman || command -v docker || true)}"
  [ -n "$engine" ] || die "podman or docker is needed (or NO_CONTAINER=1 for a host-only build)"
  mkdir -p "$OUT"
  owner=()
  # Rootful docker writes root-owned files; hand them back at the end. Rootless
  # podman maps container root to this user already, so it must not chown.
  case "$(basename "$engine")" in docker*) owner=(-e "HOST_OWNER=$(id -u):$(id -g)") ;; esac
  say "Building inside $BUILD_IMAGE (via $(basename "$engine"))"
  # label=disable: read the repo without relabelling it for SELinux (no :z).
  exec "$engine" run --rm --security-opt label=disable \
    -v "$REPO:$REPO" -v "$OUT:$OUT" -w "$REPO" \
    -e DEADBAND_IN_CONTAINER=1 -e OUT="$OUT" -e PY_VERSION="$PY_VERSION" \
    -e PYSIDE6_VERSION="$PYSIDE6_VERSION" -e GLIBC_MAX="$GLIBC_MAX" "${owner[@]}" \
    "$BUILD_IMAGE" bash "$REPO/packaging/appimage/build-appimage.sh"
fi
if [ -n "${DEADBAND_IN_CONTAINER:-}" ]; then
  say "Build container: $(. /etc/os-release; echo "$PRETTY_NAME"), $(ldd --version | head -n1)"
  dnf install -y -q systemd-devel libusbx xcb-util-cursor git-core >/dev/null \
    || die "could not install systemd-devel / libusbx / xcb-util-cursor / git in the container"
fi
command -v gcc >/dev/null || die "gcc is needed to build hidapi"
command -v curl >/dev/null || die "curl is needed for downloads"
command -v git >/dev/null || die "git is needed to list the repo's tracked files"
# safe.directory: inside a rootful container the checkout belongs to another uid.
git_ls() { git -c safe.directory="$REPO" -C "$REPO" ls-files -z -- "$@"; }
git_ls >/dev/null 2>&1 || die "$REPO is not a git checkout; the app is copied from its tracked files"

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

# 1. Base AppDir: a relocatable Python -------------------------------------------
say "Fetching python-appimage (Python $PY_VERSION, $LINUX_TAG)"
"$(command -v python3.12 || command -v python3)" -m venv "$WORK/tools"   # the image's python3 is 3.9
printf '%s' "$PYTHON_APPIMAGE_REQUIREMENTS" > "$WORK/tools-requirements.txt"
"$WORK/tools/bin/pip" install --quiet --require-hashes -r "$WORK/tools-requirements.txt"

recipe="$WORK/recipe"
mkdir -p "$recipe"
cp "$REPO/packaging/deadband.desktop" "$recipe/deadband.desktop"
cp "$REPO/assets/icon.png" "$recipe/deadband.png"
: > "$recipe/requirements.txt"          # everything is installed after extraction
cat > "$recipe/entrypoint.sh" <<'EOF'
{{ python-executable }} "$@"
EOF
"$WORK/tools/bin/python-appimage" build app -l "$LINUX_TAG" -p "$PY_VERSION" "$recipe"
base="$(ls "$WORK"/*.AppImage 2>/dev/null | head -n1)"
[ -n "$base" ] || die "python-appimage produced no AppImage"

say "Extracting the base AppDir"
"$base" --appimage-extract >/dev/null
APPDIR="$WORK/squashfs-root"
PYBIN="$(ls -d "$APPDIR"/opt/python"$PY_VERSION"/bin/python"$PY_VERSION" 2>/dev/null | head -n1)"
[ -x "$PYBIN" ] || die "no python$PY_VERSION inside the base AppDir"
PYREL="${PYBIN#"$APPDIR"/}"

# 2. Python dependencies ----------------------------------------------------------
say "Installing PySide6 $PYSIDE6_VERSION"
"$PYBIN" -m pip install --quiet --no-cache-dir "PySide6==$PYSIDE6_VERSION"

say "Building hidapi with the hidraw backend"
HIDAPI_WITH_HIDRAW=1 "$PYBIN" -m pip install --quiet --no-cache-dir \
    --no-binary hidapi "hidapi==$HIDAPI_VERSION"
backend="$("$PYBIN" -c "import sys; sys.path.insert(0, '$REPO')
from doctor import _hidapi_backend; print(_hidapi_backend())")"
case "$backend" in
  hidraw*) say "hidapi backend: $backend" ;;
  *) die "hidapi built with '$backend', not hidraw; the app could not open controllers" ;;
esac

# 3. Native libraries ---------------------------------------------------------------
mkdir -p "$APPDIR/usr/lib"
bundle_lib() {   # bundle_lib <soname> <required: 1|0>
  local path
  # awk reads to the end (no early exit): stopping early SIGPIPEs ldconfig,
  # which pipefail + set -e turn into a silent abort (exit 141).
  path="$(ldconfig -p 2>/dev/null | awk -v n="$1" '$1 == n && /x86-64/ && !p { p = $NF } END { if (p) print p }')"
  if [ -n "$path" ]; then
    cp -L "$path" "$APPDIR/usr/lib/$1"
    say "bundled $1 (from $path)"
  elif [ "$2" = 1 ]; then
    die "$1 not found on this machine; install it to bundle it"
  else
    say "not bundling $1 (not installed here; users without it on X11 need it)"
  fi
}
bundle_lib libusb-1.0.so.0 1
bundle_lib libxcb-cursor.so.0 0

# 4. The app: tracked files only ---------------------------------------------------
say "Copying the app"
share="$APPDIR/usr/share/deadband"
mkdir -p "$share/assets" "$share/packaging/udev"
# git ls-files, not a glob: untracked local scripts in the checkout stay out.
while IFS= read -r -d '' f; do
  [ -f "$REPO/$f" ] || continue                 # tracked but deleted locally
  install -D -m 644 "$REPO/$f" "$share/$f"
done < <(git_ls ':(glob)*.py' vendors qml)
[ -f "$share/deadband.py" ] || die "deadband.py is not tracked; nothing to run"
rm -f "$share/smoke_test.py"
cp "$REPO"/assets/icon.png "$REPO"/assets/icon-64.png "$REPO"/assets/icon-48.png \
   "$REPO"/assets/glyph-pad.png "$REPO"/assets/glyph-pad-dark.png "$share/assets"/
cp "$REPO/70-gamesir.rules" "$share"/
cp "$REPO/packaging/udev/70-deadband-g502x.rules" "$share/packaging/udev"/
cp "$REPO/LICENSE" "$share"/

# 5. Entry point --------------------------------------------------------------------
# Replaces python-appimage's generic AppRun: explicit about every variable.
cat > "$APPDIR/AppRun" <<EOF
#!/bin/bash
# Deadband AppImage entry point (generated by packaging/appimage/build-appimage.sh)
HERE="\$(dirname "\$(readlink -f "\$0")")"
export APPDIR="\${APPDIR:-\$HERE}"
export LD_LIBRARY_PATH="\$APPDIR/usr/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export DEADBAND_LIBUSB="\$APPDIR/usr/lib/libusb-1.0.so.0"
export DEADBAND_APPIMAGE=1
# -s: ignore ~/.local site-packages, so a user's own PySide6/hidapi can't shadow
# the bundled ones (a libusb-backend hidapi there would break every open).
exec "\$APPDIR/$PYREL" -s "\$APPDIR/usr/share/deadband/deadband.py" "\$@"
EOF
chmod 755 "$APPDIR/AppRun"
rm -f "$APPDIR"/*.desktop "$APPDIR"/*.png "$APPDIR/.DirIcon"
cp "$REPO/packaging/deadband.desktop" "$APPDIR/deadband.desktop"
cp "$REPO/assets/icon.png" "$APPDIR/deadband.png"
ln -sf deadband.png "$APPDIR/.DirIcon"

# 6. Smoke test inside the AppDir before packing ---------------------------------
say "Checking the bundle imports"
APPDIR="$APPDIR" LD_LIBRARY_PATH="$APPDIR/usr/lib" \
DEADBAND_LIBUSB="$APPDIR/usr/lib/libusb-1.0.so.0" \
  "$PYBIN" -s -c "
import sys; sys.path.insert(0, '$share')
import PySide6, hidcompat, controller_profile, bridge
from vendors.gamesir import usb_transport
libusb = usb_transport.library_version()
print('PySide6', PySide6.__version__, '| hid', hidcompat.IMPL, '| libusb', libusb)
# DEADBAND_LIBUSB points at the bundled copy only, so None means IT is broken.
sys.exit(0 if libusb else 'the bundled libusb-1.0 does not load')"

# The glibc floor: the newest GLIBC_x.y any bundled ELF file asks for. PySide6's
# wheels set it (2.34); anything above means a host-built file slipped in.
say "Checking the glibc floor (must be <= $GLIBC_MAX)"
command -v objdump >/dev/null || die "objdump is needed for the glibc check"
floor=0 worst="" over=()
# One objdump per file into a variable, no early-exiting readers in a pipe: with
# pipefail, a grep that matches nothing (or a grep -q that stops early) would
# abort the build or miss a match.
while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in ELF*) ;; *) continue ;; esac
  syms="$(objdump -p -T "$f" 2>/dev/null || true)"   # -p: version needs (GNU2_TLS)
  case "$syms" in *GLIBC_ABI_GNU2_TLS*) over+=("GNU2_TLS  ${f#"$APPDIR"/}") ;; esac
  v="$(printf '%s\n' "$syms" | sed -nE 's/.*GLIBC_([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | sort -V | tail -n1)"
  [ -n "$v" ] || continue
  if [ "$(printf '%s\n%s\n' "$v" "$floor" | sort -V | tail -n1)" = "$v" ] && [ "$v" != "$floor" ]; then
    floor="$v" worst="${f#"$APPDIR"/}"
  fi
  if [ "$(printf '%s\n%s\n' "$v" "$GLIBC_MAX" | sort -V | tail -n1)" != "$GLIBC_MAX" ]; then
    over+=("$v  ${f#"$APPDIR"/}")
  fi
done < <(find "$APPDIR" -type f \( -name '*.so*' -o -perm -u+x \) -print0)
[ ${#over[@]} -eq 0 ] || { printf '   %s\n' "${over[@]}" >&2; die "bundled files need a glibc newer than $GLIBC_MAX"; }
say "glibc floor: $floor (from $worst)"

# 7. Pack ----------------------------------------------------------------------------
say "Packing"
curl -fsSL -o "$WORK/appimagetool" "$APPIMAGETOOL_URL"
echo "$APPIMAGETOOL_SHA256  $WORK/appimagetool" | sha256sum -c --quiet - \
  || die "appimagetool $APPIMAGETOOL_VERSION does not match its pinned sha256; refusing to run it"
chmod +x "$WORK/appimagetool"
mkdir -p "$OUT"
ARCH=x86_64 "$WORK/appimagetool" --no-appstream "$APPDIR" "$OUT/Deadband-x86_64.AppImage"
[ -z "${HOST_OWNER:-}" ] || chown -R "$HOST_OWNER" "$OUT"
say "Done: $OUT/Deadband-x86_64.AppImage"
echo "    Users still need the udev rule once (README: 'Any distro (AppImage)')."
