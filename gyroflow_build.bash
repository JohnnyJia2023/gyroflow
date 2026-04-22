#!/usr/bin/env bash

# Build Gyroflow from source on macOS with working FFmpeg decode
# - Installs Homebrew (if missing)
# - Installs dependencies (ffmpeg, git, cmake, pkg-config, ninja, rust via rustup)
# - Clones Gyroflow with submodules
# - Builds a release binary
# - Verifies ffmpeg decoders (h264, hevc, prores if available)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OS_NAME=$(uname -s || echo "")
ARCH_NAME=$(uname -m || echo "")

GYROFLOW_DIR_DEFAULT="$SCRIPT_DIR/gyroflow_src"
GYROFLOW_DIR=${GYROFLOW_DIR:-$GYROFLOW_DIR_DEFAULT}

log() { printf "\033[1;34m[gyroflow-build]\033[0m %s\n" "$*" 1>&2; }
warn() { printf "\033[1;33m[gyroflow-build]\033[0m %s\n" "$*" 1>&2; }
err() { printf "\033[1;31m[gyroflow-build]\033[0m %s\n" "$*" 1>&2; }

require_macos() {
  if [[ "$OS_NAME" != "Darwin" ]]; then
    err "This script is intended for macOS (Darwin). Detected: $OS_NAME"
    exit 1
  fi
}

ensure_xcode_clt() {
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode Command Line Tools not found. Attempting to install..."
    # This will open a system dialog on first-time installs
    xcode-select --install || true
    warn "If a dialog appeared, complete that installation then re-run this script."
  fi
}

brew_in_path() {
  command -v brew >/dev/null 2>&1
}

add_brew_to_path() {
  # Ensure Homebrew path in current session PATH
  if [[ "$ARCH_NAME" == "arm64" ]]; then
    # Apple Silicon default prefix
    eval "$([ -f /opt/homebrew/bin/brew ] && /opt/homebrew/bin/brew shellenv)" || true
  else
    # Intel default prefix
    if [ -f /usr/local/bin/brew ]; then
      export PATH="/usr/local/bin:$PATH"
      export HOMEBREW_PREFIX="/usr/local"
    fi
  fi
}

ensure_homebrew() {
  add_brew_to_path
  if brew_in_path; then
    log "Homebrew found: $(brew --version | head -n1)"
    return 0
  fi
  warn "Homebrew not found. Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  add_brew_to_path
  if ! brew_in_path; then
    err "Homebrew installation did not place 'brew' on PATH. Please restart your shell and re-run."
    exit 1
  fi
}

ensure_rust() {
  if command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
    log "Rust toolchain present: rustc $(rustc --version | awk '{print $2, $3}')"
    if command -v rustup >/dev/null 2>&1; then
      log "Updating Rust toolchain via rustup..."
      rustup update --no-self-update || true
    fi
    return 0
  fi
  warn "Rust not found. Installing via rustup..."
  if ! command -v rustup-init >/dev/null 2>&1; then
    # Use Homebrew rustup if available for quicker install
    if brew_in_path; then
      brew install rustup-init || true
    fi
  fi
  if command -v rustup-init >/dev/null 2>&1; then
    rustup-init -y --profile minimal --default-toolchain stable
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  fi
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
  log "Rust installed: $(rustc --version)"
}

ensure_deps() {
  log "Ensuring required packages via Homebrew..."
  brew update
  brew install git cmake pkg-config ninja ffmpeg@7 x264 x265 opencv qt || true
  # 7-zip is needed by qml-video-rs build to extract mdk-sdk
  if ! command -v 7z >/dev/null 2>&1; then
    brew install sevenzip || brew install p7zip || true
  fi
  # Optional but useful tools
  brew install ripgrep || true
  # For Qt frameworks, force-link so headers/frameworks are visible where some build scripts expect them
  if brew list qt >/dev/null 2>&1; then
    brew link qt --force --overwrite || true
  fi
}

configure_media_toolchain() {
  local ffmpeg_prefix x264_prefix x265_prefix

  ffmpeg_prefix=$(brew --prefix ffmpeg@7 2>/dev/null || true)
  if [[ -z "$ffmpeg_prefix" ]]; then
    err "Homebrew ffmpeg@7 is required. Install it with: brew install ffmpeg@7"
    exit 1
  fi

  x264_prefix=$(brew --prefix x264 2>/dev/null || true)
  if [[ -z "$x264_prefix" ]]; then
    err "Homebrew x264 is required. Install it with: brew install x264"
    exit 1
  fi

  x265_prefix=$(brew --prefix x265 2>/dev/null || true)
  if [[ -z "$x265_prefix" ]]; then
    err "Homebrew x265 is required. Install it with: brew install x265"
    exit 1
  fi

  export PATH="$ffmpeg_prefix/bin:$PATH"
  export FFMPEG_DIR="$ffmpeg_prefix"
  export FFMPEG_INCLUDE_DIR="$ffmpeg_prefix/include"
  export FFMPEG_LIB_DIR="$ffmpeg_prefix/lib"
  export PKG_CONFIG_PATH="$ffmpeg_prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export X264_DIR="$x264_prefix"
  export X265_DIR="$x265_prefix"

  log "Configured media toolchain: ffmpeg@7=$ffmpeg_prefix x264=$x264_prefix x265=$x265_prefix"
}

verify_ffmpeg_decoders() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg not found on PATH after install; decode checks skipped."
    return 0
  fi
  local ver
  ver=$(ffmpeg -version | head -n1 || echo "ffmpeg")
  log "Using $ver"

  local missing=()
  for dec in h264 hevc prores; do
    if ! ffmpeg -hide_banner -decoders 2>/dev/null | grep -E "(^|[[:space:]])$dec\b" >/dev/null; then
      missing+=("$dec")
    fi
  done
  if ((${#missing[@]} > 0)); then
    warn "Some common decoders not reported by ffmpeg: ${missing[*]}"
    warn "Homebrew ffmpeg usually includes software decoders. If you hit decode issues, try: brew reinstall ffmpeg"
  else
    log "ffmpeg decoders look good (h264, hevc, prores present)."
  fi
}

clone_or_update_repo() {
  if [[ -d "$GYROFLOW_DIR/.git" ]]; then
    log "Updating existing Gyroflow repo at: $GYROFLOW_DIR"
    git -C "$GYROFLOW_DIR" fetch --all --tags
    git -C "$GYROFLOW_DIR" pull --rebase --autostash
    git -C "$GYROFLOW_DIR" submodule update --init --recursive
  else
    log "Cloning Gyroflow into: $GYROFLOW_DIR"
    git clone --recurse-submodules https://github.com/gyroflow/gyroflow.git "$GYROFLOW_DIR"
  fi
}

build_gyroflow() {
  set -x
  # Ensure cargo in PATH for this session
  if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
  fi

  # Help the opencv crate find Homebrew OpenCV
  if command -v brew >/dev/null 2>&1; then
    local ocv_prefix
    ocv_prefix=$(brew --prefix opencv 2>/dev/null || true)
    if [[ -n "$ocv_prefix" && -d "$ocv_prefix/lib/pkgconfig" ]]; then
      export PKG_CONFIG_PATH="$ocv_prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
      export OpenCV_DIR="$ocv_prefix/share/opencv4"
      log "Configured OpenCV pkg-config at: $ocv_prefix/lib/pkgconfig"
    fi
    # Help find Qt6 headers/frameworks (keg-only)
    local qt_prefix
    qt_prefix=$(brew --prefix qt 2>/dev/null || true)
    if [[ -n "$qt_prefix" ]]; then
      export PATH="$qt_prefix/bin:$PATH"
      export CMAKE_PREFIX_PATH="$qt_prefix:${CMAKE_PREFIX_PATH:-}"
      # Derive version dir under include (e.g., 6.9.2)
      local qt_ver
      qt_ver=$(ls -1 "$qt_prefix/include/QtCore" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1 || true)
      # Compose additional include and framework search paths
      local more_inc=(
        "$qt_prefix/include"
        "$qt_prefix/include/QtCore"
        "$qt_prefix/include/QtGui"
        "$qt_prefix/include/QtQml"
        "$qt_prefix/include/QtQuick"
      )
      if [[ -n "$qt_ver" ]]; then
        more_inc+=(
          "$qt_prefix/include/QtCore/$qt_ver/QtCore"
          "$qt_prefix/include/QtGui/$qt_ver/QtGui"
          "$qt_prefix/include/QtQml/$qt_ver/QtQml"
          "$qt_prefix/include/QtQuick/$qt_ver/QtQuick"
        )
      fi
      local IFS=:
      export CPLUS_INCLUDE_PATH="${CPLUS_INCLUDE_PATH:-}:${more_inc[*]}"
      unset IFS
      export CXXFLAGS="${CXXFLAGS:-} -F$qt_prefix/lib"
      export LDFLAGS="${LDFLAGS:-} -F$qt_prefix/lib"
      log "Configured Qt at: $qt_prefix (ver: ${qt_ver:-unknown})"
    fi
  fi

  if [[ -z "${FFMPEG_DIR:-}" ]]; then
    err "FFMPEG_DIR is not configured"
    exit 1
  fi
  export PATH="$FFMPEG_DIR/bin:$PATH"
  export FFMPEG_INCLUDE_DIR="${FFMPEG_INCLUDE_DIR:-$FFMPEG_DIR/include}"
  export FFMPEG_LIB_DIR="${FFMPEG_LIB_DIR:-$FFMPEG_DIR/lib}"
  export PKG_CONFIG_PATH="$FFMPEG_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  cd "$GYROFLOW_DIR"
  log "Starting release build (this can take a while)..."

  # Prefer building the full workspace; if that fails, fall back to likely GUI crate
  if RUST_BACKTRACE=1 cargo build --release --workspace; then
    :
  else
    warn "Workspace build failed; trying GUI crate fallback..."
    # Try a few likely package names seen in Gyroflow repos historically
    for pkg in gyroflow-gui gyroflow_gui gyroflow; do
      if cargo metadata --format-version=1 | grep -q '"name":\s*"'"$pkg"'"'; then
        cargo build --release -p "$pkg"
        break
      fi
    done
  fi

  local out_gui1="$GYROFLOW_DIR/target/release/gyroflow-gui"
  local out_gui2="$GYROFLOW_DIR/target/release/gyroflow"
  local app_bundle="$GYROFLOW_DIR/target/release/Gyroflow.app/Contents/MacOS/Gyroflow"

  log "Build complete. Searching for binaries..."
  if [[ -x "$app_bundle" ]]; then
    echo "$app_bundle"
    return 0
  elif [[ -x "$out_gui1" ]]; then
    echo "$out_gui1"
    return 0
  elif [[ -x "$out_gui2" ]]; then
    echo "$out_gui2"
    return 0
  else
    warn "Could not locate expected binary; listing target/release:"
    ls -lah "$GYROFLOW_DIR/target/release" || true
    return 1
  fi
}

print_usage() {
  local bin_path="$1"
  cat <<EOF

Gyroflow build finished.

- Binary: $bin_path
- Source: $GYROFLOW_DIR

Run from CLI:
  "$bin_path"  # launches the Gyroflow GUI

Environment notes:
- Ensure Homebrew bin is on PATH. For Apple Silicon:
    eval "\$([ -f /opt/homebrew/bin/brew ] && /opt/homebrew/bin/brew shellenv)"
- Ensure Rust cargo bin is on PATH:
    source "\$HOME/.cargo/env"

FFmpeg check:
  ffmpeg -hide_banner -decoders | egrep "(^|[[:space:]])(h264|hevc|prores)\b" || true

If decode issues persist, try:
  brew reinstall ffmpeg

EOF
}

main() {
  require_macos
  ensure_xcode_clt
  ensure_homebrew
  ensure_deps
  # Provide a compatibility wrapper for 7z if Homebrew only installed 7zz
  if ! command -v 7z >/dev/null 2>&1 && command -v 7zz >/dev/null 2>&1; then
    mkdir -p "$SCRIPT_DIR/.bin"
    cat > "$SCRIPT_DIR/.bin/7z" <<'EOSH'
#!/usr/bin/env bash
exec 7zz "$@"
EOSH
    chmod +x "$SCRIPT_DIR/.bin/7z"
    export PATH="$SCRIPT_DIR/.bin:$PATH"
    log "Created shim for 7z -> 7zz at $SCRIPT_DIR/.bin/7z"
  fi
  configure_media_toolchain
  ensure_rust
  verify_ffmpeg_decoders
  clone_or_update_repo
  local bin_path
  bin_path=$(build_gyroflow)
  mkdir -p "$SCRIPT_DIR/release"
  # Keep the install launcher pointing at the build-tree binary so Qt/MDK
  # resolve their runtime paths the same way as the known-good target binary.
  ln -sfn "$bin_path" "$SCRIPT_DIR/release/gyroflow"
  log "Refreshed launcher binary at: $SCRIPT_DIR/release/gyroflow"
  print_usage "$bin_path"
}

main "$@"
