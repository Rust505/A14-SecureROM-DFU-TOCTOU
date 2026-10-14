#!/usr/bin/env bash
# build_release.sh — usbliter8 build helper
#
# Usage:
#   ./build_release.sh [board]           # default: waveshare_rp2350_usb_a
#   ./build_release.sh --clean           # clean build dir first
#   PICO_SDK_PATH=/custom/path ./build_release.sh
#
# Supported boards (RP2350):  pico2, waveshare_rp2350_usb_a,
#                             waveshare_rp2350_zero, pimoroni_tiny2350
# Supported boards (RP2040):  pico, adafruit_feather_rp2040

set -euo pipefail

# ────────────────────────────────────────────────────────────────
# Colors (отключаются, если не tty)
# ────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

die()  { echo "${C_RED}ERROR:${C_RST} $*" >&2; exit 1; }
warn() { echo "${C_YEL}WARN:${C_RST} $*" >&2; }
info() { echo "${C_BLU}==>${C_RST} $*"; }

# ────────────────────────────────────────────────────────────────
# Аргументы
# ────────────────────────────────────────────────────────────────
CLEAN=0
BOARD=""
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            die "Unknown flag: $arg" ;;
        *)
            [[ -z "$BOARD" ]] || die "Only one board allowed (got '$BOARD' and '$arg')"
            BOARD="$arg" ;;
    esac
done
BOARD="${BOARD:-waveshare_rp2350_usb_a}"

# ────────────────────────────────────────────────────────────────
# Определяем ОС
# ────────────────────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      die "Unsupported OS: $OS" ;;
esac

# ────────────────────────────────────────────────────────────────
# Board-specific настройки
# ────────────────────────────────────────────────────────────────
case "$BOARD" in
    pico2|waveshare_rp2350_usb_a|waveshare_rp2350_zero|pimoroni_tiny2350)
        PICO_PLATFORM="rp2350-arm-s"
        ;;
    pico|adafruit_feather_rp2040)
        PICO_PLATFORM="rp2040"
        ;;
    *)
        warn "Unknown board '$BOARD', defaulting to rp2350-arm-s"
        PICO_PLATFORM="rp2350-arm-s"
        ;;
esac

BUILD_DIR="build_${BOARD}"

echo "=== usbliter8 build ==="
echo "  Board:       ${BOARD}"
echo "  Platform:    ${PICO_PLATFORM}"
echo "  OS:          ${PLATFORM}"
echo "  Build dir:   ${BUILD_DIR}"
echo ""

# ────────────────────────────────────────────────────────────────
# Поиск ARM GNU Toolchain
# ────────────────────────────────────────────────────────────────
find_arm_toolchain() {
    # 1) Уже в PATH — просто используем
    if command -v arm-none-eabi-gcc >/dev/null 2>&1; then
        echo "$(command -v arm-none-eabi-gcc)"
        return 0
    fi

    # 2) Типичные места
    local candidates=()

    if [[ "$PLATFORM" == "macos" ]]; then
        # ~/arm-gnu-toolchain — распакованный вручную в $HOME  ← ВАШ СЛУЧАЙ
        candidates+=("${HOME}/arm-gnu-toolchain/bin/arm-none-eabi-gcc")

        # Версионированные папки в $HOME (напр. ~/arm-gnu-toolchain-14.3.rel1-darwin-arm64-arm-none-eabi)
        if compgen -G "${HOME}/arm-gnu-toolchain-*" >/dev/null 2>&1; then
            for d in "${HOME}"/arm-gnu-toolchain-*; do
                candidates+=("${d}/bin/arm-none-eabi-gcc")
            done
        fi

        # В ~/Downloads (часто там распаковывают)
        if compgen -G "${HOME}/Downloads/arm-gnu-toolchain-*" >/dev/null 2>&1; then
            for d in "${HOME}"/Downloads/arm-gnu-toolchain-*; do
                candidates+=("${d}/bin/arm-none-eabi-gcc")
            done
        fi

        # ARM GNU Toolchain from developer.arm.com (.pkg installer)
        for v in 15.2.rel1 14.3.rel1 14.2.rel1 13.3.rel1 13.2.rel1 12.2.rel1 12.2.mpacbti-bet1; do
            candidates+=("/Applications/ArmGNUToolchain/${v}/bin/arm-none-eabi-gcc")
        done

        # Homebrew
        candidates+=("/opt/homebrew/bin/arm-none-eabi-gcc")     # Apple Silicon
        candidates+=("/usr/local/bin/arm-none-eabi-gcc")         # Intel

        # MacPorts
        candidates+=("/opt/local/bin/arm-none-eabi-gcc")
    else
        # Linux: apt / standalone
        candidates+=("/usr/bin/arm-none-eabi-gcc")
        candidates+=("/usr/local/bin/arm-none-eabi-gcc")
        candidates+=("${HOME}/arm-gnu-toolchain/bin/arm-none-eabi-gcc")

        if compgen -G "${HOME}/arm-gnu-toolchain-*" >/dev/null 2>&1; then
            for d in "${HOME}"/arm-gnu-toolchain-*; do
                candidates+=("${d}/bin/arm-none-eabi-gcc")
            done
        fi
    fi

    for c in "${candidates[@]}"; do
        if [[ -x "$c" ]]; then
            echo "$c"
            return 0
        fi
    done

    return 1
}

ARM_GCC="$(find_arm_toolchain || true)"

if [[ -z "$ARM_GCC" ]]; then
    cat >&2 <<EOF
${C_RED}ERROR:${C_RST} arm-none-eabi-gcc not found.

Install one of the following:

  ${C_GRN}macOS — ARM GNU Toolchain (recommended)${C_RST}
    Download 15.2.Rel1 (macOS, x86_64 or aarch64):
      https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads
    Install by extracting into /Applications/ArmGNUToolchain/15.2.rel1/
    or into \$HOME/arm-gnu-toolchain/
    Then either add to PATH:
      export PATH="\$HOME/arm-gnu-toolchain/bin:\$PATH"
    or just re-run this script — it detects both locations.

  ${C_GRN}macOS — Homebrew${C_RST}
    brew install arm-none-eabi-gcc
    # Homebrew кладёт в /opt/homebrew/bin (M1/M2/M3) — он в PATH по умолчанию.

  ${C_GRN}Linux (Debian/Ubuntu)${C_RST}
    sudo apt install gcc-arm-none-eabi libnewlib-arm-none-eabi \\
                     libstdc++-arm-none-eabi-newlib build-essential

  ${C_GRN}Linux (Fedora)${C_RST}
    sudo dnf install arm-none-eabi-gcc-cs arm-none-eabi-newlib

After installing, verify:
    arm-none-eabi-gcc --version
EOF
    exit 1
fi

ARM_BIN_DIR="$(dirname "$ARM_GCC")"
export PATH="${ARM_BIN_DIR}:${PATH}"

info "ARM toolchain: $ARM_GCC"
"$ARM_GCC" --version | head -n1 | sed "s/^/    /"

# ────────────────────────────────────────────────────────────────
# Проверка cmake / ninja
# ────────────────────────────────────────────────────────────────
command -v cmake >/dev/null 2>&1 || die "cmake not found. Install: brew install cmake (macOS) / apt install cmake (Linux)"
command -v ninja >/dev/null 2>&1 || warn "ninja not found — will fall back to Make. Install: brew install ninja"

CMAKE_VER="$(cmake --version | head -n1 | awk '{print $3}')"
info "CMake: $CMAKE_VER"

# Требование Pico SDK — CMake >= 3.13
if [[ "$(printf '%s\n' "3.13" "$CMAKE_VER" | sort -V | head -n1)" != "3.13" ]]; then
    die "CMake >= 3.13 required, got $CMAKE_VER"
fi

# ────────────────────────────────────────────────────────────────
# Поиск Pico SDK
# ────────────────────────────────────────────────────────────────
find_pico_sdk() {
    if [[ -n "${PICO_SDK_PATH:-}" && -d "${PICO_SDK_PATH}" ]]; then
        echo "${PICO_SDK_PATH}"; return 0
    fi
    local candidates=(
        "${HOME}/pico-sdk"
        "${HOME}/src/pico-sdk"
        "${HOME}/.pico-sdk"
        "${HOME}/Documents/pico-sdk"
        "/opt/pico-sdk"
        "/usr/local/pico-sdk"
        "../pico-sdk"
        "../../pico-sdk"
    )
    for c in "${candidates[@]}"; do
        if [[ -f "${c}/pico_sdk_init.cmake" ]]; then
            echo "$(cd "$c" && pwd)"; return 0
        fi
    done
    return 1
}

PICO_SDK_PATH="$(find_pico_sdk || true)"
[[ -n "$PICO_SDK_PATH" ]] || die "Pico SDK not found. Set PICO_SDK_PATH or clone to ~/pico-sdk:
    git clone -b 2.2.0 --depth 1 https://github.com/raspberrypi/pico-sdk.git ~/pico-sdk
    cd ~/pico-sdk && git submodule update --init"

info "Pico SDK: $PICO_SDK_PATH"

# Версия SDK
SDK_VER=""
if [[ -f "${PICO_SDK_PATH}/pico_sdk_version.cmake" ]]; then
    SDK_VER="$(grep -oE 'set\(PICO_SDK_VERSION_STRING [^)]+' "${PICO_SDK_PATH}/pico_sdk_version.cmake" \
               | head -n1 | awk '{print $2}')"
    info "SDK version: ${SDK_VER:-unknown}"

    # Для RP2350 требуем >= 2.0.0
    if [[ "$PICO_PLATFORM" == rp2350* ]]; then
        if [[ -n "$SDK_VER" ]] && [[ "$(printf '%s\n' "2.0.0" "$SDK_VER" | sort -V | head -n1)" != "2.0.0" ]]; then
            die "RP2350 requires Pico SDK >= 2.0.0, got $SDK_VER"
        fi
    fi
fi

# ────────────────────────────────────────────────────────────────
# Проверка submodules (tinyusb, pio_usb и т.п.)
# ────────────────────────────────────────────────────────────────
if [[ -d "${PICO_SDK_PATH}/lib/tinyusb" ]] && [[ -z "$(ls -A "${PICO_SDK_PATH}/lib/tinyusb" 2>/dev/null)" ]]; then
    die "Pico SDK submodules are not initialized. Run:
    cd ${PICO_SDK_PATH} && git submodule update --init"
fi

# Проверка, что нужная board-плата известна SDK
BOARD_HEADER="${PICO_SDK_PATH}/src/boards/include/boards/${BOARD}.h"
if [[ ! -f "$BOARD_HEADER" ]]; then
    warn "Board '$BOARD' not found in Pico SDK (${BOARD_HEADER} missing)."
    warn "Available RP2350 boards in your SDK:"
    ls "${PICO_SDK_PATH}/src/boards/include/boards/" 2>/dev/null \
        | grep -E 'rp2350|pico2' | sed 's/\.h$//' | sed 's/^/    /' || true
    die "Pick a valid board or update Pico SDK."
fi

# ────────────────────────────────────────────────────────────────
# Clean (опционально)
# ────────────────────────────────────────────────────────────────
if [[ "$CLEAN" == "1" ]]; then
    info "Cleaning ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
fi

# ────────────────────────────────────────────────────────────────
# CMake configure
# ────────────────────────────────────────────────────────────────
GENERATOR=()
if command -v ninja >/dev/null 2>&1; then
    GENERATOR=(-G Ninja)
fi

info "Configuring CMake (generator: ${GENERATOR[*]:-Unix Makefiles})"

cmake -S . -B "${BUILD_DIR}" \
    "${GENERATOR[@]}" \
    -DPICO_BOARD="${BOARD}" \
    -DPICO_PLATFORM="${PICO_PLATFORM}" \
    -DPICO_SDK_PATH="${PICO_SDK_PATH}" \
    -DCMAKE_BUILD_TYPE=MinSizeRel

# ────────────────────────────────────────────────────────────────
# Build
# ────────────────────────────────────────────────────────────────
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
info "Building with ${JOBS} jobs..."
cmake --build "${BUILD_DIR}" -j"${JOBS}"

# ────────────────────────────────────────────────────────────────
# Найти артефакты
# ────────────────────────────────────────────────────────────────
UF2="$(find "${BUILD_DIR}" -maxdepth 2 -name '*.uf2' -type f | head -n1 || true)"
ELF="$(find "${BUILD_DIR}" -maxdepth 2 -name '*.elf' -type f | head -n1 || true)"

echo ""
echo "${C_GRN}=== Build complete ===${C_RST}"
[[ -n "$UF2" ]] && echo "  UF2: $UF2"
[[ -n "$ELF" ]] && echo "  ELF: $ELF"
echo ""

if [[ -n "$UF2" ]]; then
    cat <<EOF
Flash to board:

  ${C_GRN}Option A — BOOTSEL (universal)${C_RST}
    1. Hold BOOTSEL on the RP2350 board
    2. Plug USB into your Mac
    3. Release BOOTSEL — board appears as a USB drive
    4. Copy the UF2:
         cp "${UF2}" /Volumes/RP2350/
       (или перетащите файл в Finder)

  ${C_GRN}Option B — picotool (быстрее для отладки)${C_RST}
    brew install picotool      # macOS, если ещё не установлен
    picotool load -f "${UF2}"
    picotool reboot

  ${C_GRN}Option C — read logs via UART${C_RST}
    # 115200 8N1 на GPIO0/GPIO1 (или USB CDC, если включён)
    screen /dev/tty.usbmodem* 115200

EOF
fi

# ────────────────────────────────────────────────────────────────
# Информация о поддерживаемых CPID
# ────────────────────────────────────────────────────────────────
cat <<EOF
${C_DIM}Supported devices in this build:${C_RST}
  CPID 0x8006 — S4/S5 (Apple Watch)   — malformed SETUP method
  CPID 0x8020 — A12 (iPhone XS/XR)    — malformed SETUP method
  CPID 0x8030 — A13 (iPhone 11)       — DMA smash method
  CPID 0x8101 — A14 (iPhone 12)       — TOCTOU method (EXPERIMENTAL)
  CPID 0x8110 — A15 (iPhone 13/14)    — TOCTOU method (EXPERIMENTAL)

${C_YEL}NOTE:${C_RST} T81xx TOCTOU requires CPFM:03 (development fused)!
EOF