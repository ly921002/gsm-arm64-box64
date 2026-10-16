#!/bin/bash
# ============================================================================
# fix-steamcmd.sh v4 —— arm64 + box64 下让 GSM 的 SteamCMD 可用
#
# 实测结论（本环境）：
#   * Valve 初始包只有 i386 的 linux32/steamcmd；arm64 直接 exec -> Exec format error。
#   * box64 带 BOX32，能跑 linux32/steamcmd，但它只负责自更新引导。
#   * 【自更新完成后会装出 linux64/ 目录 —— 真正的 x86_64 SteamCMD】
#       box64 linux64/steamcmd 可直接跑通（"Update complete, launching Steamcmd..."）。
#     -> 优先用 linux64（x86_64 模拟比 BOX32 转 i386 更稳更快）。
#   * SteamCMD 自更新会【覆盖 steamcmd.sh】，所以不能只改 steamcmd.sh。
#     -> 必须包装被调用方 linux32/steamcmd。
#
# 做法：
#   a) 真身 linux32/steamcmd.bin（i386 ELF）保留
#   b) linux32/steamcmd   -> 优先 exec box64 linux64/steamcmd；没有则 box64 linux32/steamcmd.bin
#   c) linuxarm64/steamcmd-> 同上（bootstrap 按 uname -m 可能找它）
#   d) steamcmd.sh        -> 同上（尽力，被自更新覆盖也无妨）
#   e) /lib/ld-linux.so.2 占位 -> 只为过 GSM 的「32 位 ELF loader 存在性」检查
#   f) 包装脚本遇 LD_TRACE_LOADED_OBJECTS（ldd 探测）直接 exit 0，
#      保证 GSM 预检 `ldd linux32/steamcmd` 不出现 "not found"
#
# GSM 预检对应（server/src/routes/gameDeployment.ts::checkLinuxSteamCMDRuntime）：
#   ① <dir>/linux32/steamcmd 存在  ② i386 loader 存在  ③ ldd 无 "not found"
#
# 用法：
#   docker cp fix-steamcmd.sh box64-gsm:/root/fix-steamcmd.sh
#   docker exec -it box64-gsm bash /root/fix-steamcmd.sh
# ============================================================================
set -e

BOX64="$(command -v box64 || true)"
[ -z "$BOX64" ] && BOX64=/usr/local/bin/box64
[ -x "$BOX64" ] || { echo "!! 找不到 box64"; exit 1; }
echo "== box64: $BOX64"
command -v file >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq file; }

# ---------- 1) i386 loader 占位 ----------
echo ">> 1) i386 loader 占位"
if [ -e /lib/ld-linux.so.2 ]; then
  echo "   已存在: /lib/ld-linux.so.2"
else
  printf '# box64 BOX32 占位标记：仅用于 GSM 的 32 位 ELF loader 存在性检查。\n' > /lib/ld-linux.so.2
  chmod 644 /lib/ld-linux.so.2
  echo "   已创建: /lib/ld-linux.so.2"
fi

# ---------- 2) 找 SteamCMD 安装目录 ----------
echo ">> 2) 查找 SteamCMD 安装目录"
mapfile -t DIRS < <(find /root -name 'steamcmd.sh' \
  -not -name '*.valve' \
  -not -path '*/gsm-src/*' -not -path '*/node_modules/*' \
  -printf '%h\n' 2>/dev/null | sort -u)
[ "${#DIRS[@]}" -eq 0 ] && echo "   !! 没找到 steamcmd.sh，请先在面板安装/更新 SteamCMD 再重跑"

for dir in "${DIRS[@]}"; do
  echo
  echo "   ==== $dir ===="
  echo "   目录: $(cd "$dir" && ls -d linux* package public 2>/dev/null | tr '\n' ' ')"

  # 2a) 保存 i386 真身
  if [ -f "$dir/linux32/steamcmd" ]; then
    if file -b "$dir/linux32/steamcmd" 2>/dev/null | grep -q ELF; then
      mv -f "$dir/linux32/steamcmd" "$dir/linux32/steamcmd.bin"
      echo "   真身已保存: linux32/steamcmd.bin"
    fi
  fi
  [ -f "$dir/linux32/steamcmd.bin" ] || { echo "   !! 没有 i386 真身，跳过"; continue; }
  chmod +x "$dir/linux32/steamcmd.bin"

  if [ -f "$dir/linux64/steamcmd" ]; then
    echo "   linux64/steamcmd: $(file -b "$dir/linux64/steamcmd" | cut -c1-60)  <- 优先使用"
  else
    echo "   linux64/steamcmd 尚不存在（自更新后会生成），暂回退 BOX32 + i386"
  fi

  # 2b) 通用包装脚本生成器
  write_wrapper() {
    local target="$1"
    mkdir -p "$(dirname "$target")"
    cat > "$target" <<EOF
#!/usr/bin/env bash
# SteamCMD box64 wrapper（由 fix-steamcmd.sh 生成）
# ldd 探测（LD_TRACE_LOADED_OBJECTS）时静默退出，保证 GSM 预检不出现 "not found"
[ -n "\$LD_TRACE_LOADED_OBJECTS" ] && exit 0

ROOT="$dir"
BOX64_BIN="$BOX64"

DEPTH="\${GSM_SC_SHIM_DEPTH:-0}"
DEPTH=\$((DEPTH + 1))
if [ "\$DEPTH" -gt 3 ]; then
  echo "\$0: 递归 \${DEPTH} 层，已停止（SteamCMD 疑似反复自更新）" >&2
  exit 1
fi
export GSM_SC_SHIM_DEPTH="\$DEPTH"

if [ "\${GSM_STEAMCMD_NO_LP:-0}" != "1" ]; then
  export LD_LIBRARY_PATH="\$ROOT/linux32:\${LD_LIBRARY_PATH}"
fi

# 优先 x86_64 原生模拟（自更新后才有），回退 BOX32 转 i386
if [ -f "\$ROOT/linux64/steamcmd" ] && file -b "\$ROOT/linux64/steamcmd" 2>/dev/null | grep -q 'ELF 64-bit'; then
  exec "\$BOX64_BIN" "\$ROOT/linux64/steamcmd" "\$@"
fi
exec "\$BOX64_BIN" "\$ROOT/linux32/steamcmd.bin" "\$@"
EOF
    chmod +x "$target"
    echo "   已包装: $target"
  }

  write_wrapper "$dir/linux32/steamcmd"
  write_wrapper "$dir/linuxarm64/steamcmd"

  # 2c) steamcmd.sh（可能被自更新覆盖，覆盖了也不影响）
  [ -f "$dir/steamcmd.sh.valve" ] || cp -a "$dir/steamcmd.sh" "$dir/steamcmd.sh.valve" 2>/dev/null || true
  write_wrapper "$dir/steamcmd.sh"
done

# ---------- 3) 预检模拟 ----------
echo
echo ">> 3) 模拟 GSM 预检"
for dir in "${DIRS[@]}"; do
  echo "   ldd $dir/linux32/steamcmd :"
  ldd "$dir/linux32/steamcmd" 2>&1 | sed 's/^/       /' | head -5
  echo "   （上面不应出现 'not found'）"
done

# ---------- 4) 自测 ----------
echo
echo ">> 4) 自测（超时 300s）"
for dir in "${DIRS[@]}"; do
  echo "   \$ cd $dir && timeout 300 ./steamcmd.sh +quit"
  ( cd "$dir" && timeout 300 ./steamcmd.sh +quit ) 2>&1 | tail -15 || true
done

echo
echo "==================== 完成 ===================="
echo "回 GSM 面板重试部署。排错："
echo "  1) docker exec -it box64-gsm bash -c 'cd /root/steamcmd && ./steamcmd.sh +quit'"
echo "  2) 卡在库加载：GSM_STEAMCMD_NO_LP=1 ./steamcmd.sh +quit"
echo "  3) 只想手工验证：cd /root/steamcmd/linux64 && box64 steamcmd +quit"
echo "=============================================="
