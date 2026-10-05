#!/usr/bin/env bash
# hub_log 单独编译 + 单元测试一键脚本（不依赖 supperproject）
#
#   ./verify.sh              # debug 配置：configure → build → ctest
#   ./verify.sh release      # release 配置
#
# 工具链策略与主工程保持一致：MSVC(cl.exe) 优先，检测不到回退 MinGW(gcc)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_WIN="$(cygpath -m "$SCRIPT_DIR" 2>/dev/null || echo "$SCRIPT_DIR")"
CONFIG="${1:-Debug}"
BDIR_WIN="$MODULE_WIN/build"
CMAKE_BIN="${CMAKE_BIN:-cmake}"
NINJA_BIN="${NINJA_BIN:-ninja}"
TOOLCHAIN=""

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_OFF=$'\033[0m'
say()  { printf '%s[hub_log]%s %s\n' "$C_CYN" "$C_OFF" "$*"; }
ok()   { printf '%s[  ok  ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[ warn ]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail() { printf '%s[ fail ]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

setup_msvc_env() {
  local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  [ -f "$vswhere" ] || return 1
  local vsdir
  vsdir=$("$vswhere" -latest -products '*' \
           -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
           -property installationPath 2>/dev/null | tr -d '\r' | head -1)
  [ -n "$vsdir" ] || return 1
  local vcvars="$vsdir/VC/Auxiliary/Build/vcvarsall.bat"
  [ -f "$vcvars" ] || return 1
  local win_vcvars tmpbat win_bat envout
  win_vcvars=$(cygpath -w "$vcvars")
  tmpbat="${TEMP:-/tmp}/hub_log_vcvars_$$.bat"
  printf '@echo off\r\ncall "%s" x64 >nul 2>&1\r\nset\r\n' "$win_vcvars" > "$tmpbat"
  win_bat=$(cygpath -w "$tmpbat" 2>/dev/null || echo "$tmpbat")
  envout=$( ( unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL; cmd //c "$win_bat" ) 2>/dev/null | tr -d '\r' ) || true
  rm -f "$tmpbat"
  [ -n "$envout" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      PATH)
        local posix_new; posix_new=$(cygpath -p "$v" 2>/dev/null || true)
        [ -n "$posix_new" ] && export PATH="$posix_new:$PATH"
        ;;
      INCLUDE|LIB|LIBPATH|WindowsSdkDir|WindowsSDKVersion|VCToolsInstallDir|VCToolsVersion|ExternalIncludePath)
        [ -n "$v" ] && export "$k=$v"
        ;;
    esac
  done <<< "$envout"
  command -v cl >/dev/null 2>&1
}

ORIG_PATH="$PATH"   # 回退 MinGW 时需要还原：导入过 MSVC 环境的 PATH 会让 gcc 链路串味

detect_toolchain() {
  if [ "${HUB_TOOLCHAIN:-auto}" = "mingw" ]; then
    command -v gcc >/dev/null 2>&1 && { TOOLCHAIN=mingw; return 0; }
    fail "HUB_TOOLCHAIN=mingw 但未找到 gcc"
  fi
  if [ "${HUB_TOOLCHAIN:-auto}" = "msvc" ] || command -v cl >/dev/null 2>&1; then
    if setup_msvc_env || command -v cl >/dev/null 2>&1; then
      TOOLCHAIN=msvc
      return 0
    fi
  fi
  if command -v gcc >/dev/null 2>&1; then
    TOOLCHAIN=mingw
    return 0
  fi
  fail "找不到可用 C++ 编译器（cl / gcc）"
}

detect_toolchain
command -v "$CMAKE_BIN" >/dev/null 2>&1 || fail "找不到 cmake（可用 CMAKE_BIN 指定）"
if [ "$TOOLCHAIN" = "msvc" ] && ! command -v "$NINJA_BIN" >/dev/null 2>&1; then
  fail "MSVC 路径需要 ninja（可用 NINJA_BIN 指定）"
fi

say "工具链 = $TOOLCHAIN，配置 = $CONFIG"

# 工具链切换会让 CMake 缓存失效（生成器/编译器不匹配直接报错），自动重建
stamp="$BDIR_WIN/.hub_log_toolchain"
if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null || echo '')" != "$TOOLCHAIN" ]; then
  warn "检测到工具链切换（$(cat "$stamp") → $TOOLCHAIN），清理重建 build/"
  "$CMAKE_BIN" -E remove_directory "$BDIR_WIN"
fi

if [ -f "$BDIR_WIN/CMakeCache.txt" ]; then
  say "复用已有构建目录 build/"
else
  say "configure ..."
  if [ "$TOOLCHAIN" = "msvc" ]; then
    # MSVC 侧典型失败：SDK 未装全（link 阶段缺 rc.exe / mt.exe）或工具链登记信息读不到。
    # 这种时候不要卡死用户，直接降级到 MinGW —— 验证的是同一份源码。
    if ! "$CMAKE_BIN" -S "$MODULE_WIN" -B "$BDIR_WIN" -G Ninja \
        -DCMAKE_BUILD_TYPE="$CONFIG" \
        -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl; then
      warn "MSVC 配置失败，回退 MinGW(gcc)"
      "$CMAKE_BIN" -E remove_directory "$BDIR_WIN"
      # 关键点：必须在「干净」的执行环境里重试。导入过 MSVC 的环境变量
      # （INCLUDE/LIB/LIBPATH 与前置到 PATH 的 cl.exe 目录）会让 MinGW 的
      # 编译/链接串味，直接重试依旧失败 —— 与主工程 lunch 隔离 MSVC 环境同一个坑。
      exec env -u INCLUDE -u LIB -u LIBPATH -u CL -u ExternalIncludePath \
           -u WindowsSdkDir -u WindowsSDKVersion \
           -u VCToolsInstallDir -u VCToolsVersion \
           PATH="$ORIG_PATH" HUB_TOOLCHAIN=mingw bash "$0" "$@"
    fi
  fi
  if [ "$TOOLCHAIN" = "mingw" ]; then
    "$CMAKE_BIN" -S "$MODULE_WIN" -B "$BDIR_WIN" -G Ninja \
      -DCMAKE_BUILD_TYPE="$CONFIG"
  fi
  echo "$TOOLCHAIN" > "$stamp"
fi

say "build ..."
"$CMAKE_BIN" --build "$BDIR_WIN" --config "$CONFIG"
ok "编译通过"

say "ctest ..."
( cd "$BDIR_WIN" && ctest --output-on-failure )
ok "全部用例通过"
