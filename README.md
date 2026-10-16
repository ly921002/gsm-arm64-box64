# 在 arm64 主机上用 box64 容器部署 GSM3（GameServerManager）+ SteamCMD

在 `ghcr.io/ly921002/docker-empty:box64`（arm64 + box64，已带 `-D BOX32=ON`）容器里
手动部署 GSM3 面板，让它在 arm64 主机上能正常管理并部署 Steam 游戏服务端。
免特权、免内核 binfmt，全部走显式 `box64`。

## 最终架构

| 组件 | 方案 |
|---|---|
| 面板本体 | **arm64 原生 Node** + `--require arch-spoof.cjs`（只改 `os.arch()`）<br>→ 解锁 SteamCMD，`process.arch` 仍为 arm64 |
| PTY / Zip-Tools / 7z | **arm64 原生资产**（`pty_linux_arm64` / `file_zip_linux_arm64` / `7z_linux_arm64`）<br>→ 通过固定清单 size+SHA256 可信校验，**不需要 box64** |
| SteamCMD | **box64 包装**：优先跑自更新后生成的 `linux64/steamcmd`（x86_64），回退 BOX32 转 i386 |
| 游戏服务端 | x86_64 → 实例启动命令写 `box64 ./<服务端二进制>` |
| 容器 | `docker-empty:box64`，映射 3001，`/root` 持久化 |

## 前置条件

- arm64 宿主（已在 Oracle Cloud ARM64 / Ubuntu 24.04 aarch64 验证）
- 宿主已装好 Docker、`/usr/bin/runc` 可用
- 能访问 ghcr.io —— `ghcr.io/ly921002/docker-empty:box64` 是**公开镜像，无需 `docker login`**

## 部署步骤

### 1. 起容器

镜像 `ghcr.io/ly921002/docker-empty:box64` 为公开镜像，直接拉取即可（无需 `docker login`）。

```bash
docker compose up -d
```

### 2. 部署 GSM（构建 + 架构伪装 + 原生资产 + SteamCMD）

```bash
docker cp deploy-gsm.sh box64-gsm:/root/deploy-gsm.sh
docker exec -it box64-gsm bash /root/deploy-gsm.sh
```

脚本幂等，可重复执行。它会：装 arm64 Node → 克隆并构建 GSM
（`npm run install:all` + `package:linux:x64:no-zip`）→ 写 `arch-spoof.cjs` →
生成 `start-box64.sh` → 补齐 `data/` → 下载 SteamCMD → 下载 arm64 原生 PTY / zip / 7z。

首次构建较慢（npm install + 打包），跑一次即可，`/root` 已在卷里持久化。

### 3. 修复 SteamCMD（必须做）

```bash
docker cp fix-steamcmd.sh box64-gsm:/root/fix-steamcmd.sh
docker exec -it box64-gsm bash /root/fix-steamcmd.sh
```

不做这步，面板部署游戏时会报「缺少 32 位 ELF loader」（详见下方原理）。

### 4. 启动面板

```bash
docker exec -d  box64-gsm /root/gsm/start-box64.sh     # 后台常驻
docker exec -it box64-gsm /root/gsm/start-box64.sh     # 排错时前台跑，直接看日志

docker exec box64-gsm ps -aux | grep -i node
docker exec box64-gsm ss -ltnp | grep 3001
```

访问 `http://<宿主IP>:3001`。

### 5. 验收

启动日志里应出现：

```
PTY 资产已通过校验: /root/gsm/data/lib/pty_linux_arm64
PTY 已就绪
终端管理器初始化完成，PTY路径: /root/gsm/data/lib/pty_linux_arm64
Zip-Tools 已就绪
7z 已就绪
GSM3服务器启动成功!  地址: http://:::3001
```

SteamCMD 自测：

```bash
docker exec -it box64-gsm bash -c 'cd /root/steamcmd && ./steamcmd.sh +quit'
# 成功标志：Steam Console Client (c) Valve Corporation - version xxxx
#          Loading Steam API...OK
```

## 目录结构（容器内）

```
/root/gsm                     <- 包根目录，必须在这里启动
  ├ start-box64.sh            <- 启动器：cd /root/gsm && node --require arch-spoof.cjs server/index.js
  ├ arch-spoof.cjs            <- 架构伪装（只改 os.arch() -> x64）
  ├ start.sh                  <- 官方脚本（硬编码 node/bin/node，勿用）
  ├ server/index.js           <- 后端入口
  ├ public/                   <- 前端（client/dist）
  └ data/
      ├ games/ gameconfig/ plugins/ rcon/
      └ lib/pty_linux_arm64, file_zip_linux_arm64, 7z_linux_arm64   <- arm64 原生，不包装
/root/steamcmd                <- SteamCMD（linux32/steamcmd、linuxarm64/steamcmd、steamcmd.sh 均已包装）
/opt/node-arm64               <- arm64 原生 Node（构建 + 运行面板）
```

## 原理：三个关键点

### 1. 只伪装 `os.arch()`，绝不伪装 `process.arch`

GSM 的架构门槛全部来自运行期 API：

```ts
// architectureSupport.ts（决定能不能用 SteamCMD）
isX64Architecture(arch = os.arch())
assertSteamCMDSupported(platform = os.platform(), arch = os.arch())

// ptyAssets.ts / zipToolsManager.ts（决定用哪个二进制资产）
getPtyAsset(process.platform, process.arch)     -> pty_linux_arm64
getBinaryName() -> file_zip_linux_arm64 / 7z_linux_arm64
```

后端依赖全是**纯 JS**（express / socket.io / axios / archiver…，无 `.node` 原生模块），
所以「arm64 跑 + 把 `os.arch()` 报成 x64」完全成立。

> ⚠️ **如果连 `process.arch` 也伪装成 x64**，GSM 就会去校验 `pty_linux_x64`。
> 而 x86_64 二进制在免特权模式下必须包装成 box64 脚本，
> 包装后 `ptyAssets.verifyPtyAsset()` 的固定「大小 + SHA-256」校验必然失败 →
> `ptyPath` 为空 → **`PTY 能力不可用：可信 PTY 运行时未初始化`**。

### 2. 必须在「包根目录」启动

`server/.env` 里 `DATA_DIR=./data`，且 lib 目录按 `process.cwd()` 解析：

```ts
path.join(process.cwd(), 'data', 'lib')            // 打包后
path.join(process.cwd(), 'server', 'data', 'lib')  // 开发用
```

`start-box64.sh` 已内置 `cd /root/gsm`。
**错误写法** `cd /root/gsm/server && node index.js` 会让 cwd 变成 `server/`，
`./data` 指向空目录、lib 资产找不到。

### 3. SteamCMD：只有 i386 二进制，靠 box64 + 自更新后的 linux64

Valve 的 `steamcmd_linux.tar.gz` **只有 i386 的 `linux32/steamcmd`**，arm64 内核直接 exec 会
`Exec format error`。面板提示的 `apt-get install -y libc6:i386 ...` 在 arm64 上**完全无效**。

实测链路：

1. 本镜像 box64 带 `-D BOX32=ON`，能跑 `linux32/steamcmd` 完成自更新；
2. **自更新完成后会生成 `linux64/`（真正的 x86_64 SteamCMD）**；
3. 所以包装脚本优先 `box64 linux64/steamcmd`，没有才回退 `box64 linux32/steamcmd.bin`。

GSM 的预检在 `server/src/routes/gameDeployment.ts::checkLinuxSteamCMDRuntime()`，检查三项：
`<dir>/linux32/steamcmd` 存在、i386 loader 存在、`ldd` 输出无 "not found"。
`fix-steamcmd.sh` 对应处理：

1. 造 `/lib/ld-linux.so.2` 占位（纯标记，arm64 不会被当解释器用）；
2. 把 `linux32/steamcmd`、`linuxarm64/steamcmd`、`steamcmd.sh` **全部**写成 box64 包装脚本
   —— 注意不能只改 `steamcmd.sh`，**SteamCMD 自更新会把它覆盖回官方版**；
3. 包装脚本遇 `LD_TRACE_LOADED_OBJECTS`（GSM 的 `ldd` 预检）直接 `exit 0`，保证不出现 "not found"。

## 部署游戏服务端

SteamCMD 已验证可完整下载安装（实测 Don't Starve Together / AppID 343050，4.49 GB，
`Success! App '343050' fully installed.`）。

**服务端是 x86_64，启动命令必须加 `box64` 前缀。** 以饥荒联机版为例：

> ⚠️ **坑：工作目录必须是 `bin64/`，不是安装根目录。**
> DST 服务端用 `../data` 取 `databundles/*.zip`。cwd 在根目录时报
> `Error, failed to change working directory to ../data` →
> `Mounting file system databundles/*.zip skipped` → `Could not load lua file scripts/main.lua`。
>
> GSM 实例设置：
> - 工作目录：`/home/steam/games/Dont_Starve_Together/bin64`
> - 启动命令：`box64 ./dontstarve_dedicated_server_nullrenderer_x64 -cluster Cluster_1 -shard Master`
>
> 若没有工作目录字段：
> `cd /home/steam/games/Dont_Starve_Together/bin64 && box64 ./dontstarve_dedicated_server_nullrenderer_x64 -cluster Cluster_1 -shard Master`

验证：

```bash
docker exec -it box64-gsm bash -c 'cd /home/steam/games/Dont_Starve_Together/bin64 && box64 ./dontstarve_dedicated_server_nullrenderer_x64 -cluster Cluster_1 -shard Master'
# 成功标志：Machine Arch: x86_64 / Mode: 64-bit /
#           Renderer initialize: Okay / AnimManager initialize: Okay / LOADING LUA
```

已知无害日志：`Error loading needed lib libsteam.so`、
`[S_API FAIL] STEAMUGC_INTERFACE_VERSION016`、退出时 `Sigfault/Segbus while quitting`、
`WARNING: setlocale('en_US.UTF-8') failed`（想消掉可 `apt-get install -y locales && locale-gen en_US.UTF-8`）。

缺库排查：

```bash
docker exec box64-gsm bash -c 'cd /home/steam/games/Dont_Starve_Together && file bin*/dontstarve*'
docker exec -it box64-gsm bash -c 'cd /home/steam/games/Dont_Starve_Together/bin64 && BOX64_LOG=1 box64 ./dontstarve_dedicated_server_nullrenderer_x64 2>&1 | grep -i "not found"'
```

## 排错

- **`ps -aux` 里没有 node 进程**：没启动或启动即退出，前台跑一次看报错。
- **`Cannot find module`**：启动目录错了，用 `start-box64.sh`，别手动 cd 到 `server/`。
- **`PTY 能力不可用：可信 PTY 运行时未初始化`**
  → 检查 `docker exec box64-gsm ls -la /root/gsm/data/lib`，`pty_linux_arm64` 应为
  **2752664 字节的原始 ELF**（不是几十字节的脚本）。若是脚本说明被包装过，重跑 `deploy-gsm.sh`。
- **部署游戏时报「缺少 32 位 ELF loader」** → 跑 `fix-steamcmd.sh`。
  **不要**装 `libc6:i386`。
- **box64 `SIGSEGV ... "box64/raise"`** → 说明在用 x86_64 Node 跑面板，这条路走不通
  （Node 22 在 box64 下启动即 abort），必须用 `start-box64.sh`（arm64 原生 Node）。
- **端口不通** → 确认 compose 映射 `3001:3001`、容器内 `ss -ltnp | grep 3001` 有监听。
- **面板里「安装/更新 SteamCMD」后又不工作** → GSM 会下到自己的目录，
  装完再跑一次 `fix-steamcmd.sh`（它会 `find /root -name steamcmd.sh` 全量打补丁）。

## 已知限制

- **游戏服务端不能透明执行**：免特权模式下内核无法直接跑 x86_64 ELF，
  必须写 `box64 ./<服务端二进制>` 前缀。若想透明运行，需要 `privileged: true`
  + 容器内注册 box64 binfmt（本方案刻意不用，避免污染宿主内核）。
- **首次构建** GSM 较慢，只跑一次即可。
- 仅 **arm64 宿主**有效。

## 文件

- `deploy-gsm.sh` —— 容器内一键部署（构建 + 架构伪装 + arm64 原生资产 + SteamCMD）
- `fix-steamcmd.sh` —— 把 SteamCMD 各入口包装成 box64（修「缺少 32 位 ELF loader」），幂等
- `fix-arch.sh` —— 重装架构伪装与 arm64 原生资产并重建启动器（幂等，用于修复/重装）
- `docker-compose.yml` —— box64 容器（映射 3001、持久化 `/root`）
