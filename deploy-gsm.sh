#!/bin/bash
# ============================================================================
# deploy-gsm.sh —— 在 docker-empty:box64 容器内【手动】部署 GameServerManager(GSM3) + SteamCMD
#
# 运行位置：容器内部。
#   docker cp deploy-gsm.sh box64-gsm:/root/deploy-gsm.sh
#   docker exec -it box64-gsm bash /root/deploy-gsm.sh
#
# 设计（免特权、免 binfmt，符合 docker-empty:box64 的显式 box64 路线）：
#   【面板本体】arm64 原生 Node 跑（快、稳）
#       + 预加载 arch-spoof.cjs 把【os.arch() 伪装成 "x64"】
#       -> GSM 的 isX64Architecture() / assertSteamCMDSupported() 通过，面板解锁 SteamCMD。
#
#       ⚠️ 只伪装 os.arch()，【绝不能】伪装 process.arch：
#          ptyAssets.ts 用 process.arch 选 PTY 资产，zipToolsManager.ts 同理。
#          若 process.arch=x64，GSM 会去校验 pty_linux_x64，而我们把它包装成 box64 脚本后
#          「大小 + SHA-256」固定校验必然失败 -> ptyPath 为空 ->
#          「PTY 能力不可用：可信 PTY 运行时未初始化」。
#          保持 process.arch=arm64 -> 使用 arm64 原生 PTY/zip/7z，原始 ELF 直接通过可信校验。
#
#       ⚠️ 更早的方案「x86_64 Node + box64 跑面板」实测启动即 SIGSEGV(raise) abort，已弃用。
#   【真正的 x86_64 / i386 二进制】SteamCMD
#       SteamCMD 官方 Linux 包只有 i386 的 linux32/steamcmd。
#       镜像里的 box64 带 -D BOX32=ON，box32 兼容层可直接跑它 —— 由 fix-steamcmd.sh 处理。
#       免特权、免 binfmt：改写 steamcmd.sh 走 box64，不做内核注册。
#
# 目录约定（务必遵守，GSM3 用 process.cwd() 解析 data/ 与 lib/）：
#   /root/gsm            <- 包根目录（= dist/package 的内容），【必须在这里启动】
#     ├ start-box64.sh   <- 本脚本生成的启动器：arm64 node + arch 伪装 + server/index.js
#     ├ arch-x64.cjs     <- 架构伪装预加载脚本
#     ├ server/index.js  <- 后端入口
#     ├ public/          <- 前端（由 client/dist 复制而来）
#     └ data/{games,gameconfig,plugins,lib}
#
# 幂等：可重复执行（已存在的步骤会跳过）。
# ============================================================================
set -e

BOX64="$(command -v box64 || true)"
[ -z "$BOX64" ] && BOX64=/usr/local/bin/box64
[ -x "$BOX64" ] || { echo "!! 找不到 box64，请确认在 docker-empty:box64 容器内执行"; exit 1; }
echo "== box64: $BOX64"

GSM_SRC=/root/gsm-src          # 源码与构建目录
GSM_RUN=/root/gsm              # 面板运行目录（= 包根）
STEAMCMD_DIR=/root/steamcmd
LIB_DIR="$GSM_RUN/data/lib"    # 打包后环境的 lib 目录（cwd=data/lib）
ARM_NODE=/opt/node-arm64/bin/node

command -v file >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq file; }
command -v wget >/dev/null 2>&1 || apt-get install -y -qq wget

# 把 x86_64 二进制包装成 box64 脚本（真二进制改名 .bin）
wrap_bin() {
  local target="$1" dir base
  if [ -f "$target" ] && file "$target" 2>/dev/null | grep -q ELF; then
    mv -f "$target" "${target}.bin"
  fi
  [ -f "${target}.bin" ] || { echo "  ~ 跳过（无真二进制）: $target"; return 0; }
  dir="$(dirname "$target")"; base="$(basename "$target")"
  cat > "$target" <<EOF
#!/bin/bash
exec $BOX64 "$dir/$base.bin" "\$@"
EOF
  chmod +x "$target" "${target}.bin"
  echo "  -> 已包装: $target (真身 $base.bin)"
}

# ---------- 1) Node（arm64 原生，构建 + 运行面板都用） ----------
if [ ! -x "$ARM_NODE" ]; then
  echo ">> 下载 Node 22.17.0 (arm64)"
  wget -qO /tmp/n-arm64.tar.gz "https://nodejs.org/dist/v22.17.0/node-v22.17.0-linux-arm64.tar.gz"
  mkdir -p /opt/node-arm64
  tar -xzf /tmp/n-arm64.tar.gz -C /opt/node-arm64 --strip-components=1
  rm -f /tmp/n-arm64.tar.gz
fi

# ---------- 2) 构建 GSM ----------
if [ ! -d "$GSM_SRC/.git" ]; then
  echo ">> 克隆 GSM 源码"
  git clone --depth 1 https://github.com/GSManagerXZ/GameServerManager.git "$GSM_SRC"
fi
echo ">> 构建 GSM（arm64 原生 npm）"
export PATH=/opt/node-arm64/bin:$PATH
cd "$GSM_SRC"
npm config set registry https://registry.npmmirror.com
npm run install:all
npm run package:linux:x64:no-zip      # --target=linux-x64：资产与配置按 x64 产出

echo ">> 拷贝构建产物到 $GSM_RUN"
mkdir -p "$GSM_RUN"
cp -a "$GSM_SRC/dist/package/." "$GSM_RUN/"
# 补齐源码里 server/data 下的全部运行时数据（games / gameconfig / plugins / rcon 等）
[ -d "$GSM_SRC/server/data" ] && cp -a "$GSM_SRC/server/data/." "$GSM_RUN/data/" 2>/dev/null || true

# ---------- 3) 系统 node/npm -> arm64 原生 ----------
echo ">> 设置系统 node/npm"
cat > /usr/local/bin/node <<EOF
#!/bin/bash
exec "$ARM_NODE" "\$@"
EOF
cat > /usr/local/bin/npm <<EOF
#!/bin/bash
exec "$ARM_NODE" /opt/node-arm64/bin/npm "\$@"
EOF
chmod +x /usr/local/bin/node /usr/local/bin/npm

# ---------- 4) 架构伪装（关键：只改 os.arch()） ----------
echo ">> 写入架构伪装脚本 arch-spoof.cjs"
cat > "$GSM_RUN/arch-spoof.cjs" <<'EOF'
// 只把 os.arch() 报成 x64：assertSteamCMDSupported() 用它做门槛，解锁 SteamCMD。
// 刻意【不】改 process.arch：PTY / Zip-Tools / 7z 按 process.arch 选资产，
// 保持 arm64 才能用 arm64 原生资产并通过「大小 + SHA-256」可信校验。
(function () {
  try {
    const os = require('os');
    const spoof = () => 'x64';
    try {
      Object.defineProperty(os, 'arch', { value: spoof, configurable: true, writable: true });
    } catch (e) { try { os.arch = spoof; } catch (e2) {} }
    try {
      Object.defineProperty(os, 'endianness', { value: () => 'LE', configurable: true, writable: true });
    } catch (e) {}
  } catch (e) {}

  if (process.env.ARCH_SPOOF_DEBUG) {
    try {
      console.error('[arch-spoof] os.arch()=' + require('os').arch() +
                    '  process.arch=' + process.arch);
    } catch (e) {}
  }
})();
EOF
chmod 644 "$GSM_RUN/arch-spoof.cjs"
ARCH_SPOOF_DEBUG=1 "$ARM_NODE" --require "$GSM_RUN/arch-spoof.cjs" \
  -e "console.log('   os.arch()=' + require('os').arch() + '  process.arch=' + process.arch + '  （前者 x64、后者 arm64 才对）')"

# ---------- 5) 启动器（官方 start.sh 硬编码 node/bin/node，不能用） ----------
echo ">> 生成 start-box64.sh"
cat > "$GSM_RUN/start-box64.sh" <<EOF
#!/bin/bash
# 必须在包根目录运行：DATA_DIR=./data 与 data/lib 都按 process.cwd() 解析
cd "$GSM_RUN"
exec "$ARM_NODE" --require "$GSM_RUN/arch-x64.cjs" server/index.js
EOF
chmod +x "$GSM_RUN/start-box64.sh"

# ---------- 6) data / lib 目录（GSM 按 process.cwd() 解析） ----------
echo ">> 准备 data / lib 目录"
mkdir -p "$LIB_DIR" "$GSM_RUN/server/data"
ln -sfn "$LIB_DIR" "$GSM_RUN/server/data/lib"     # 兼容“开发环境”候选路径 <cwd>/server/data/lib

# ---------- 7) SteamCMD（x86_64）+ box64 包装 ----------
echo ">> 安装 SteamCMD"
mkdir -p "$STEAMCMD_DIR"
cd "$STEAMCMD_DIR"
if [ ! -f steamcmd.sh ] && [ ! -f steamcmd.bin ] && [ ! -f steamcmd ]; then
  wget -qO steamcmd_linux.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    || wget -qO steamcmd_linux.tar.gz https://media.steampowered.com/installer/steamcmd_linux.tar.gz
  tar -xzf steamcmd_linux.tar.gz && rm -f steamcmd_linux.tar.gz
fi
chmod +x steamcmd.sh 2>/dev/null || true
[ -f steamcmd ] && wrap_bin "$STEAMCMD_DIR/steamcmd"

# ---------- 8) x64 资产（PTY / zip / 7z）+ box64 包装 ----------
echo ">> 下载并包装 x64 资产"
# PTY：MCSManager/PTY release 297277624 的 linux-x64 资产（与源码 ptyAssets.ts 一致）
[ -e "$LIB_DIR/pty_linux_x64" ] || \
  wget -q --tries=3 --header="Accept: application/octet-stream" \
    -O "$LIB_DIR/pty_linux_x64" https://api.github.com/repos/MCSManager/PTY/releases/assets/374651721
wrap_bin "$LIB_DIR/pty_linux_x64"

for a in file_zip_linux_x64 7z_linux_x64; do
  [ -e "$LIB_DIR/$a" ] || \
    wget -q --tries=3 -O "$LIB_DIR/$a" "https://github.com/MCSManager/Zip-Tools/releases/latest/download/$a"
  wrap_bin "$LIB_DIR/$a"
done

# ---------- 9) 结果 ----------
echo
echo "==================== 部署完成 ===================="
echo "启动面板：   docker exec -d  box64-gsm $GSM_RUN/start-box64.sh"
echo "排错前台：   docker exec -it box64-gsm $GSM_RUN/start-box64.sh"
echo "确认进程：   docker exec box64-gsm ps -aux | grep -i node"
echo "确认监听：   docker exec box64-gsm ss -ltnp | grep 3001"
echo "SteamCMD：   docker exec -it box64-gsm /root/steamcmd/steamcmd +quit"
echo "面板访问：   http://<宿主IP>:3001   （server/.env: SERVER_PORT=3001）"
echo
echo "注意："
echo "  1) 必须在 $GSM_RUN 目录下启动（start-box64.sh 已内置 cd），"
echo "     GSM3 用 process.cwd() 解析 DATA_DIR=./data 与 data/lib、server/data/lib"
echo "  2) SteamCMD 下载的 x86_64 游戏服务端是动态二进制，免特权模式下"
echo "     需在 GSM 里把该游戏的「启动命令」写成：box64 ./<服务端二进制>"
echo "     （如需透明运行，改用 privileged + 容器内注册 binfmt，见 README）"
echo "=================================================="
