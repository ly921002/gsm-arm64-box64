#!/bin/bash
# ============================================================================
# fix-arch.sh v2 —— arm64 + box64 环境下 GSM 的「架构伪装 + 可信资产」正确姿势
#
# 解决的问题：
#   1) 面板要解锁 SteamCMD     -> 需要 os.arch() === 'x64'
#   2) PTY 报错「PTY 能力不可用：可信 PTY 运行时未初始化」
#      -> 因为 v1 把 process.arch 也伪装成 x64，GSM 于是去用 pty_linux_x64；
#         而我们把它包装成了 82 字节的 box64 脚本，
#         ptyAssets.verifyPtyAsset() 的固定「大小 + SHA-256」校验直接判定不可信，
#         ptyManager.getPtyPath() 抛错 -> TerminalManager.ptyPath='' -> 该报错。
#
# 正确姿势（关键点）：
#   ✅ 只伪装 os.arch()      —— architectureSupport.assertSteamCMDSupported 用的是 os.arch()
#   ❌ 不要伪装 process.arch —— ptyAssets / zipToolsManager 用的是 process.arch，
#                              保持 arm64 就会去用【arm64 原生资产】，
#                              原始 ELF 能通过大小+SHA256 校验，-fifo 探测也能原生跑通。
#   → 结果：SteamCMD 解锁 + PTY/zip/7z 全部原生可用，一个 box64 包装都不需要。
#
# 用法：
#   docker cp fix-arch.sh box64-gsm:/root/fix-arch.sh
#   docker exec -it box64-gsm bash /root/fix-arch.sh
#   docker exec -d  box64-gsm /root/gsm/start-box64.sh      # 重启面板
# 幂等，可重复执行。
# ============================================================================
set -e

GSM_RUN=/root/gsm
ARM_NODE=/opt/node-arm64/bin/node
LIB_DIR="$GSM_RUN/data/lib"
[ -d "$GSM_RUN" ]  || { echo "!! 没有 $GSM_RUN"; exit 1; }
[ -x "$ARM_NODE" ] || ARM_NODE="$(command -v node)"
[ -x "$ARM_NODE" ] || { echo "!! 找不到可用的 Node"; exit 1; }

command -v wget >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq wget; }

# ---------- 1) 系统 node/npm = arm64 原生 ----------
echo ">> 1) 系统 node/npm 还原为 arm64 原生"
cat > /usr/local/bin/node <<EOF
#!/bin/bash
exec "$ARM_NODE" "\$@"
EOF
cat > /usr/local/bin/npm <<EOF
#!/bin/bash
exec "$ARM_NODE" /opt/node-arm64/bin/npm "\$@"
EOF
chmod +x /usr/local/bin/node /usr/local/bin/npm
echo "   process.arch = $(/usr/local/bin/node -e 'console.log(process.arch)')  （应为 arm64，保持原样）"

# ---------- 2) 只伪装 os.arch() ----------
echo ">> 2) 写入架构伪装脚本 arch-spoof.cjs（仅 os.arch）"
cat > "$GSM_RUN/arch-spoof.cjs" <<'EOF'
// GSM3 on arm64 + box64
// 只把 os.arch() 报成 x64：architectureSupport.assertSteamCMDSupported() 用它做门槛，
// 解锁 SteamCMD / Factorio headless 等 x86_64 自动部署能力。
//
// 刻意【不】改 process.arch：
//   ptyAssets.getPtyAsset(platform, process.arch) 和 zipToolsManager 都按 process.arch 选资产，
//   保持 arm64 => 使用 pty_linux_arm64 / file_zip_linux_arm64 / 7z_linux_arm64 原生资产，
//   原始 ELF 能通过固定清单的「大小 + SHA-256」校验，且 -fifo 能力探测可原生执行。
//   若伪装成 x64，就会去校验 pty_linux_x64，任何包装/替换都会让可信校验失败。
(function () {
  try {
    const os = require('os');
    const spoof = () => 'x64';
    try {
      Object.defineProperty(os, 'arch', { value: spoof, configurable: true, writable: true });
    } catch (e) {
      try { os.arch = spoof; } catch (e2) {}
    }
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
  -e "console.log('   os.arch()=' + require('os').arch() + '   process.arch=' + process.arch)  // 前者 x64、后者 arm64 才对"

# ---------- 3) 启动器 ----------
echo ">> 3) 生成 start-box64.sh"
cat > "$GSM_RUN/start-box64.sh" <<EOF
#!/bin/bash
# 必须在包根目录运行：DATA_DIR=./data 与 data/lib 都按 process.cwd() 解析
cd "$GSM_RUN"
exec "$ARM_NODE" --require "$GSM_RUN/arch-spoof.cjs" server/index.js
EOF
chmod +x "$GSM_RUN/start-box64.sh"

# ---------- 4) 换成 arm64 原生资产（不再用 box64 包装） ----------
echo ">> 4) 安装 arm64 原生资产到 $LIB_DIR"
mkdir -p "$LIB_DIR" "$GSM_RUN/server/data"
ln -sfn "$LIB_DIR" "$GSM_RUN/server/data/lib"

# 把旧的 x64（含被包装成脚本的）挪走，避免干扰
mkdir -p "$LIB_DIR/_x64_unused"
for f in pty_linux_x64 pty_linux_x64.bin file_zip_linux_x64 file_zip_linux_x64.bin \
         7z_linux_x64 7z_linux_x64.bin; do
  [ -e "$LIB_DIR/$f" ] && mv -f "$LIB_DIR/$f" "$LIB_DIR/_x64_unused/" 2>/dev/null || true
done
[ -d "$LIB_DIR/_x64_unused" ] && echo "   已把 x64 资产移入 $LIB_DIR/_x64_unused/"

# PTY（arm64）：MCSManager/PTY release 297277624，源码 ptyAssets.ts 固定清单
#   name: pty_linux_arm64  assetId: 374651727  size: 2752664
#   sha256: 48d8496997053b60eb84d2b02f4ec751298c7f214c615b08aca43309739ebf83
PTY_SHA_EXPECT=48d8496997053b60eb84d2b02f4ec751298c7f214c615b08aca43309739ebf83
if [ ! -f "$LIB_DIR/pty_linux_arm64" ]; then
  echo "   下载 pty_linux_arm64 ..."
  wget -q --tries=3 --header="Accept: application/octet-stream" \
    -O "$LIB_DIR/pty_linux_arm64" \
    https://api.github.com/repos/MCSManager/PTY/releases/assets/374651727
fi
chmod +x "$LIB_DIR/pty_linux_arm64"
PTY_SHA="$(sha256sum "$LIB_DIR/pty_linux_arm64" 2>/dev/null | awk '{print $1}')"
if [ "$PTY_SHA" = "$PTY_SHA_EXPECT" ]; then
  echo "   OK  pty_linux_arm64  sha256 匹配 ($(stat -c%s "$LIB_DIR/pty_linux_arm64") bytes)"
else
  echo "   !!  pty_linux_arm64 sha256 不匹配："
  echo "       实际 $PTY_SHA"
  echo "       期望 $PTY_SHA_EXPECT"
fi
file -b "$LIB_DIR/pty_linux_arm64" | sed 's/^/       /'

# Zip-Tools / 7z（arm64）：MCSManager/Zip-Tools latest
for a in file_zip_linux_arm64 7z_linux_arm64; do
  if [ ! -f "$LIB_DIR/$a" ]; then
    echo "   下载 $a ..."
    wget -q --tries=3 -O "$LIB_DIR/$a" \
      "https://github.com/MCSManager/Zip-Tools/releases/latest/download/$a"
  fi
  chmod +x "$LIB_DIR/$a"
  file -b "$LIB_DIR/$a" | sed 's/^/       /'
done

# ---------- 5) 清理旧的 x64 包装残留（server/data/lib 下） ----------
rm -rf "$GSM_RUN/server/data/lib"
ln -sfn "$LIB_DIR" "$GSM_RUN/server/data/lib"

echo
echo "==================== 完成 ===================="
echo "重启面板（必须重启，伪装脚本已改）："
echo "   docker exec box64-gsm pkill -f 'server/index.js' || true"
echo "   docker exec -d  box64-gsm $GSM_RUN/start-box64.sh"
echo "确认："
echo "   docker exec box64-gsm ps -aux | grep -i node"
echo "   docker exec box64-gsm ls -la $LIB_DIR"
echo "日志里应出现：终端管理器初始化完成，PTY路径: .../data/lib/pty_linux_arm64"
echo "=============================================="
