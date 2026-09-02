#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  create-run-installer.sh \
    --input APK_DIRECTORY \
    --output OUTPUT.run \
    --platform x64|arm \
    --release IMMORTALWRT_RELEASE \
    --target IMMORTALWRT_TARGET
EOF
}

die() {
  echo "create-run-installer: $*" >&2
  exit 1
}

input_dir=
output_file=
platform=
release=
target=

while (($# > 0)); do
  case "$1" in
    --input)
      (($# >= 2)) || die "--input requires a value"
      input_dir=$2
      shift 2
      ;;
    --output)
      (($# >= 2)) || die "--output requires a value"
      output_file=$2
      shift 2
      ;;
    --platform)
      (($# >= 2)) || die "--platform requires a value"
      platform=$2
      shift 2
      ;;
    --release)
      (($# >= 2)) || die "--release requires a value"
      release=$2
      shift 2
      ;;
    --target)
      (($# >= 2)) || die "--target requires a value"
      target=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$input_dir" ]] || die "--input is required"
[[ -n "$output_file" ]] || die "--output is required"
[[ -n "$platform" ]] || die "--platform is required"
[[ -n "$release" ]] || die "--release is required"
[[ -n "$target" ]] || die "--target is required"
[[ -d "$input_dir" ]] || die "APK directory does not exist: $input_dir"

case "$platform" in
  x64|arm) ;;
  *) die "unsupported platform: $platform" ;;
esac
case "$release" in
  *[!A-Za-z0-9._-]*) die "invalid release: $release" ;;
esac
case "$target" in
  *[!A-Za-z0-9_./-]*) die "invalid target: $target" ;;
esac

input_dir=$(realpath "$input_dir")
mkdir -p "$(dirname "$output_file")"
output_file=$(realpath -m "$output_file")

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

payload_dir="$work_dir/payload"
payload_archive="$work_dir/payload.tar.gz"
installer_header="$work_dir/installer.sh"
mkdir -p "$payload_dir"

copy_required_package() {
  local pattern=$1
  local package_type=$2
  local matches=()

  mapfile -d '' -t matches < <(
    find "$input_dir" -maxdepth 1 -type f -name "$pattern" -print0
  )
  if ((${#matches[@]} != 1)); then
    die "expected one $package_type package matching $pattern, found ${#matches[@]}"
  fi

  cp "${matches[0]}" "$payload_dir/"
  basename "${matches[0]}" >> "$payload_dir/install-order"
}

copy_required_package 'kmod-oaf-*.apk' 'kernel module'
copy_required_package 'appfilter-*.apk' 'service'
copy_required_package 'luci-app-oaf-*.apk' 'LuCI application'

while IFS= read -r -d '' translation; do
  cp "$translation" "$payload_dir/"
  basename "$translation" >> "$payload_dir/install-order"
done < <(
  find "$input_dir" -maxdepth 1 -type f -name 'luci-i18n-oaf-*.apk' -print0 | sort -z
)

cat > "$payload_dir/build-info" <<EOF
IMMORTALWRT_RELEASE=$release
IMMORTALWRT_TARGET=$target
PLATFORM=$platform
EOF

source_date_epoch=${SOURCE_DATE_EPOCH:-0}
[[ "$source_date_epoch" =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH must be an integer"

tar \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --create \
  --gzip \
  --file "$payload_archive" \
  --directory "$payload_dir" \
  .

cat > "$installer_header" <<EOF
#!/bin/sh

set -eu

readonly REQUIRED_DISTRIBUTION='immortalwrt'
readonly REQUIRED_RELEASE='$release'
readonly REQUIRED_TARGET='$target'
readonly REQUIRED_PLATFORM='$platform'
readonly PAYLOAD_MARKER='__OAF_PAYLOAD_BELOW__'
EOF

cat >> "$installer_header" <<'EOF'

die() {
  echo "OpenAppFilter installer: $*" >&2
  exit 1
}

if [ "$#" -ne 0 ]; then
  die "this installer does not accept arguments"
fi

[ "$(id -u)" -eq 0 ] || die "run this installer as root"
[ -r /etc/openwrt_release ] || die "/etc/openwrt_release was not found"
command -v apk >/dev/null 2>&1 || die "the apk package manager was not found"

# The release file is provided by the installed ImmortalWrt system.
. /etc/openwrt_release

distribution=$(printf '%s' "${DISTRIB_ID:-}" | tr '[:upper:]' '[:lower:]')
[ "$distribution" = "$REQUIRED_DISTRIBUTION" ] \
  || die "expected ImmortalWrt, found ${DISTRIB_ID:-unknown}"
[ "${DISTRIB_RELEASE:-}" = "$REQUIRED_RELEASE" ] \
  || die "expected release $REQUIRED_RELEASE, found ${DISTRIB_RELEASE:-unknown}"
[ "${DISTRIB_TARGET:-}" = "$REQUIRED_TARGET" ] \
  || die "expected target $REQUIRED_TARGET, found ${DISTRIB_TARGET:-unknown}"

machine=$(uname -m)
case "$REQUIRED_PLATFORM:$machine" in
  x64:x86_64|arm:aarch64|arm:arm64) ;;
  *) die "platform $machine does not match $REQUIRED_PLATFORM" ;;
esac

payload_line=$(
  awk -v marker="$PAYLOAD_MARKER" '$0 == marker { print NR + 1; exit }' "$0"
)
[ -n "$payload_line" ] || die "embedded package payload was not found"

temporary_dir=$(mktemp -d /tmp/openappfilter.XXXXXX)
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

tail -n +"$payload_line" "$0" | tar -xzf - -C "$temporary_dir" \
  || die "failed to extract the embedded packages"
[ -s "$temporary_dir/install-order" ] || die "package installation manifest is missing"

set --
while IFS= read -r package || [ -n "$package" ]; do
  [ -n "$package" ] || continue
  [ -f "$temporary_dir/$package" ] || die "embedded package is missing: $package"
  set -- "$@" "$temporary_dir/$package"
done < "$temporary_dir/install-order"
[ "$#" -gt 0 ] || die "no packages were found in the payload"

echo "Installing $# OpenAppFilter packages"
apk add --allow-untrusted "$@" || die "package installation failed"

echo "OpenAppFilter installation completed successfully."
exit 0
__OAF_PAYLOAD_BELOW__
EOF

cat "$installer_header" "$payload_archive" > "$output_file"
chmod 0755 "$output_file"

echo "Created $output_file"
