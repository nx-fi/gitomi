#!/bin/sh
set -eu

base_url="https://github.com/nx-fi/gitomi"
latest_release_api="https://api.github.com/repos/nx-fi/gitomi/releases/latest"
version=""
target=""
tmp=""
tmp_bin=""
install_dir=""

say() {
  printf 'gitomi install: %s\n' "$*"
}

die() {
  printf 'gitomi install: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

fetch_stdout() {
  if have curl; then
    curl -fsSL "$1"
  elif have wget; then
    wget -qO- "$1"
  else
    return 127
  fi
}

download_file() {
  if have curl; then
    curl -fL --progress-bar "$1" -o "$2"
  elif have wget; then
    wget -O "$2" "$1"
  else
    return 127
  fi
}

cleanup() {
  if [ -n "$tmp" ]; then
    rm -rf "$tmp"
  fi
  if [ -n "$tmp_bin" ]; then
    rm -f "$tmp_bin"
  fi
}

trap cleanup EXIT INT TERM

[ -n "${HOME:-}" ] || die "HOME is unset"
install_dir="$HOME/.local/bin"

have mktemp || die "mktemp is required"
have tar || die "tar is required"
if ! have curl && ! have wget; then
  die "curl or wget is required"
fi

tmp="$(mktemp -d /tmp/gitomi-install.XXXXXX)" ||
  die "failed to create temporary directory"

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Linux) os_part="linux-musl" ;;
  Darwin) os_part="macos" ;;
  *) die "unsupported operating system: $os" ;;
esac

case "$arch" in
  x86_64 | amd64) arch_part="x86_64" ;;
  arm64 | aarch64) arch_part="aarch64" ;;
  *) die "unsupported architecture: $arch" ;;
esac

target="${arch_part}-${os_part}"

latest_json="$(fetch_stdout "$latest_release_api")" ||
  die "failed to resolve latest release"
version="$(printf '%s\n' "$latest_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$version" ] || die "latest release response did not include tag_name"

archive_base="gitomi-${version}-${target}"
archive="${archive_base}.tar.gz"
archive_url="${base_url}/releases/download/${version}/${archive}"
checksum="${archive}.sha256"
checksum_url="${archive_url}.sha256"

say "downloading ${archive}"
download_file "$archive_url" "$tmp/$archive" ||
  die "failed to download ${archive_url}"
download_file "$checksum_url" "$tmp/$checksum" ||
  die "failed to download ${checksum_url}"

if have sha256sum; then
  (cd "$tmp" && sha256sum -c "$checksum") >/dev/null
elif have shasum; then
  (cd "$tmp" && shasum -a 256 -c "$checksum") >/dev/null
else
  die "sha256sum or shasum is required"
fi
say "verified checksum"

tar -xzf "$tmp/$archive" -C "$tmp"
[ -f "$tmp/$archive_base/gt" ] || die "archive did not contain gt"

mkdir -p "$install_dir"
tmp_bin="$(mktemp "${install_dir}/.gt.tmp.XXXXXX")" ||
  die "failed to create temporary install file"
cp "$tmp/$archive_base/gt" "$tmp_bin"
chmod 755 "$tmp_bin"
mv "$tmp_bin" "$install_dir/gt"

say "installed gt to ${install_dir}/gt"
"$install_dir/gt" --version || true

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) say "add ${install_dir} to PATH to run gt from any directory" ;;
esac
