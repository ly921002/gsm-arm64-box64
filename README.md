# 在 box64 容器里手动部署 GSM（GameServerManager）+ SteamCMD

## 三个关键点

1. **让 `process.arch` / `os.arch()` 返回 `x64`——但面板本体跑 arm64 原生 Node**

   GSM 的架构门槛全部来自运行期 API：
   ```ts
   // architectureSupport.ts
   isX64Architecture(arch = os.arch())   // x64 / x86_64 / amd64 才放行
   assertSteamCMDSupported()             // 否则抛 UnsupportedArchitectureError
   // ptyAssets.ts / zipToolsManager.ts
   getPtyAsset(process.platform, process.arch)   -> pty_linux_x64
   file_zip_linux_x64 / 7z_linux_x64
   ```
   后端依赖全是**纯 JS**（express / socket.io / axios / archiver…，没有 `.node` 原生模块），
   所以「arm64 跑 + 把 arch 报成 x64」完全成立。做法：
   ```bash
   node --require /root/gsm/arch-x64.cjs server/index.js
   ```
   `arch-x64.cjs` 用 `Object.defineProperty` 覆盖 `process.arch`，并直接替换 `os.arch()`。
   已在 Node 22 上验证：两个 API 都能可靠覆盖。

   > ⚠️ **已弃用方案**：早期让 x86_64 Node 经 box64 跑面板。实测
   > `[BOX64] SIGSEGV @ ... (x64pc=.../"box64/raise") ... Segmentation fault`，启动即 abort。
   > 面板只是 JS，没必要套 box64——架构只影响「判断」和「下载哪个资产」。

2. **让 x86_64 二进制能被直接执行（免特权、免 binfmt）**
   你选的是显式 box64 路线、不用特权/内核 binfmt。面板会直接调 `./steamcmd`，
   内核是 arm64，直接 exec x86_64 ELF 会 `Exec format error`。
   做法：**box64 包装脚本** —— 真二进制改名 `*.bin`，同名脚本 `exec box64 <真二进制> "$@"`。
   SteamCMD、PTY、zip、7z 都这样处理。

3. **必须在「包根目录」启动，不能 `cd` 进 `server/`**
   `server/.env` 里 `DATA_DIR=./data`，且 `zipToolsManager.ts` 的 lib 候选路径是：
   ```ts
   path.join(process.cwd(), 'data', 'lib')           // 打包后
   path.join(process.cwd(), 'server', 'data', 'lib') // 开发用
   ```
   官方 `start.sh` 也正是在包根目录执行 `node/bin/node server/index.js`。
   **错误写法** `cd /root/gsm/server && node index.js` 会让 cwd 变成 `server/`，
   于是 `./data` 指向 `server/data`（空目录）、lib 资产找不到 → 面板起不来/功能残缺。

## 步骤

```bash
docker login ghcr.io
docker compose up -d
docker cp deploy-gsm.sh box64-gsm:/root/deploy-gsm.sh
docker exec -it box64-gsm bash /root/deploy-gsm.sh      # 构建 GSM、写伪装脚本、装 SteamCMD/PTY/zip

# 自测 SteamCMD（关键验证）
docker exec -it box64-gsm /root/steamcmd/steamcmd +quit

# 启动面板
docker exec -d  box64-gsm /root/gsm/start-box64.sh
# 排错时先前台跑，直接看报错：
docker exec -it box64-gsm /root/gsm/start-box64.sh
# 等价：cd /root/gsm && node --require /root/gsm/arch-x64.cjs server/index.js

# 确认面板进程在跑
docker exec box64-gsm ps -aux | grep -i node
# 访问 http://<宿主IP>:3001
```

`deploy-gsm.sh` 做了：装 arm64 Node（构建 + 运行都是它）→ 克隆并构建 GSM
（`npm run install:all` + `package:linux:x64:no-zip`）→ 写 `arch-x64.cjs` 架构伪装脚本 →
生成 `start-box64.sh` 启动器 → 补齐 `data/` →
装 SteamCMD 并包装 → 下载并包装 x64 的 PTY / zip / 7z。脚本幂等，可重复执行。

> 已经用旧版跑过构建、只想修「面板起不来」的情况，用 `fix-arch.sh`（免重建）：
> ```bash
> docker cp fix-arch.sh box64-gsm:/root/fix-arch.sh
> docker exec -it box64-gsm bash /root/fix-arch.sh
> docker exec -d  box64-gsm /root/gsm/start-box64.sh
> ```

## 目录结构（容器内）

```
/root/gsm                 <- 包根目录，必须在这里启动
  ├ start-box64.sh        <- 启动器：arm64 node --require arch-x64.cjs server/index.js
  ├ arch-x64.cjs          <- 架构伪装（process.arch / os.arch() -> x64）
  ├ start.sh              <- 官方脚本（硬编码 node/bin/node，勿用）
  ├ server/index.js       <- 后端入口
  ├ public/               <- 前端（client/dist）
  └ data/
      ├ games/ gameconfig/ plugins/ rcon/
      └ lib/              <- pty_linux_x64 / file_zip_linux_x64 / 7z_linux_x64（已 box64 包装）
/root/steamcmd            <- SteamCMD（steamcmd 已 box64 包装）
/opt/node-arm64           <- arm64 原生 Node（构建 + 运行面板）
```

## 排错

- **`ps -aux` 里没有 node 进程**：说明没启动或启动即退出。前台跑一次看报错（上面命令）。
- **`Cannot find module`**：启动目录错了，`start-box64.sh` 已内置 `cd /root/gsm`，别手动 cd 到 `server/`。
- **box64 `SIGSEGV ... "box64/raise" ... Segmentation fault`**：说明你在用 x86_64 Node 跑面板（已弃用），
  改用 `start-box64.sh` / `fix-arch.sh`。若一定要走 x86_64 Node，可试
  `BOX64_DYNAREC=0`、`BOX64_DYNAREC_STRONGMEM=0`、`BOX64_LOG=2` 定位，或换 Node 20。
- **端口不通**：确认 compose 映射了 `3001:3001`（`server/.env` 的 `SERVER_PORT=3001`），
  且容器内 `ss -ltnp | grep 3001` 有监听。
- **部署游戏时报「缺少 32 位 ELF loader / `linux32/steamcmd: cannot execute: required file not found`」**
  见下一节，跑 `fix-steamcmd.sh`。**不要**按面板提示装 `libc6:i386` —— arm64 内核没有 i386 支持，装了也没用。

## SteamCMD 的 32 位问题（必看）

Valve 的 `steamcmd_linux.tar.gz` **只提供 32 位（i386）二进制 `linux32/steamcmd`，没有 linux64 版**。
所以面板提示的 `dpkg --add-architecture i386 && apt-get install -y libc6:i386 ...` 在 arm64 上
**根本不成立**（内核无 i386 支持，box64 也只翻译 x86_64…除非开了 BOX32）。

**本镜像的 box64 是用 `-D BOX32=ON -D BOX32_BINFMT=ON` 编的，box32 兼容层可以直接跑 i386**
（`box64 ./32bit_program`）。所以正确修法是走 box64，而不是装 i386 运行库：

```bash
docker cp fix-steamcmd.sh box64-gsm:/root/fix-steamcmd.sh
docker exec -it box64-gsm bash /root/fix-steamcmd.sh
# 然后回面板重试部署
```

GSM 的预检逻辑在 `server/src/routes/gameDeployment.ts` 的 `checkLinuxSteamCMDRuntime()`，会检查：
`<steamcmdDir>/linux32/steamcmd` 存在、`/lib/ld-linux.so.2` 等 i386 loader 存在、`ldd` 无 "not found"。
`fix-steamcmd.sh` 对应三招：

1. 造 `/lib/ld-linux.so.2` 占位文件（纯标记，只为过存在性检查，arm64 不会被当解释器用）；
2. **保留** `linux32/steamcmd` 为原始 i386 ELF —— 这样 `ldd` 只报 `wrong ELF class`，
   不会出现 "not found"；
3. 改写 `steamcmd.sh`（原版备份为 `steamcmd.sh.valve`），让它 `exec box64 linux32/steamcmd`，
   GSM 在 Linux 上调的正是 `steamcmd.sh`。

> 若启动时卡在库加载，试 `GSM_STEAMCMD_NO_LP=1 ./steamcmd.sh +quit`
> （不继承 Valve 的 `LD_LIBRARY_PATH=$STEAMROOT/linux32`）。
> 若 box64 明确说不支持 32 位，说明镜像没开 BOX32，需要重建 `docker-empty:box64`。
> GSM 重新下载/更新 SteamCMD 会覆盖 `steamcmd.sh`，届时需重跑本脚本。

补充实测：**SteamCMD 自更新完成后会生成 `linux64/`（真正的 x86_64 版）**，
`fix-steamcmd.sh` 生成的包装脚本会优先跑 `box64 linux64/steamcmd`，没有才回退
`box64 linux32/steamcmd.bin`（BOX32 转 i386）。

## 部署游戏服务端

SteamCMD 已验证可完整下载安装（实测 Don't Starve Together / AppID 343050，4.49 GB，
`Success! App '343050' fully installed.`）。

**服务端是 x86_64，免特权模式下启动命令必须加 `box64` 前缀。** 以饥荒联机版为例：

> ⚠️ **坑：工作目录必须是 `bin64/`，不是安装根目录。**
> DST 服务端会 `../data` 去取 `databundles/*.zip`。cwd 在根目录时会报
> `Error, failed to change working directory to ../data` →
> `Mounting file system databundles/*.zip skipped` → `Could not load lua file scripts/main.lua`。
>
> GSM 实例设置：
> - 工作目录：`/home/steam/games/Dont_Starve_Together/bin64`
> - 启动命令：`box64 ./dontstarve_dedicated_server_nullrenderer_x64 -cluster Cluster_1 -shard Master`
>
> 若没有工作目录字段，启动命令写成：
> `cd /home/steam/games/Dont_Starve_Together/bin64 && box64 ./dontstarve_dedicated_server_nullrenderer_x64 -cluster Cluster_1 -shard Master`

验证：

```bash
docker exec -it box64-gsm bash -c 'cd /home/steam/games/Dont_Starve_Together/bin64 && box64 ./dontstarve_dedicated_server_nullrenderer_x64 -cluster Cluster_1 -shard Master'
# 成功标志：Machine Arch: x86_64 / Mode: 64-bit /
#           Renderer initialize: Okay / AnimManager initialize: Okay / LOADING LUA
```

已知无害日志（不用管）：`Error loading needed lib libsteam.so`、
`[S_API FAIL] STEAMUGC_INTERFACE_VERSION016`、退出时 `Sigfault/Segbus while quitting`。

```bash
# 1) 看有哪些二进制、分别是什么架构
docker exec box64-gsm bash -c 'cd /home/steam/games/Dont_Starve_Together && file bin*/dontstarve* 2>/dev/null'

缺库排查（最常见是 `libcurl-gnutls.so.4`，镜像装的是 `libcurl4:amd64`，名字不同）：

```bash
docker exec -it box64-gsm bash -c 'apt-get update && apt-get install -y libcurl3-gnutls:amd64'
# 装不到就软链
docker exec -it box64-gsm ln -sf /lib/x86_64-linux-gnu/libcurl.so.4 \
                                 /lib/x86_64-linux-gnu/libcurl-gnutls.so.4
# 看还缺什么
docker exec -it box64-gsm bash -c 'cd /home/steam/games/Dont_Starve_Together && BOX64_LOG=1 box64 ./bin64/dontstarve_dedicated_server_nullrenderer 2>&1 | grep -i "not found"'
```

## 最终架构（已验收）

```
面板本体        arm64 原生 Node  +  --require arch-spoof.cjs（只改 os.arch()）
                                -> 解锁 SteamCMD，process.arch 仍为 arm64
PTY / zip / 7z  arm64 原生资产（pty_linux_arm64 / file_zip_linux_arm64 / 7z_linux_arm64）
                                -> 通过固定清单 size+SHA256 可信校验，无需 box64
SteamCMD        box64 包装（优先 linux64 的 x86_64，回退 BOX32 跑 i386 linux32）
游戏服务端      x86_64，实例启动命令需写 box64 ./<服务端二进制>
```

验收日志应出现：
```
PTY 资产已通过校验: /root/gsm/data/lib/pty_linux_arm64
PTY 已就绪 / 终端管理器初始化完成，PTY路径: .../data/lib/pty_linux_arm64
Zip-Tools 已就绪 / 7z 已就绪
GSM3服务器启动成功!  地址: http://:::3001
```

## 已知限制

- **游戏服务端**：SteamCMD 下载下来的是 x86_64 动态二进制。免特权模式下内核无法透明执行，
  需在 GSM 里把该游戏的**启动命令**写成 `box64 ./<服务端二进制>`（GSM 支持自定义启动命令）。
  若想透明运行（不用写前缀），需要 `privileged: true` + 容器内注册 box64 binfmt。
- **首次构建** GSM 较慢（npm install + 打包），脚本只跑一次即可，之后 `/root` 已在卷里持久化。
- 仅 **arm64 宿主**有效。

## 文件

- `deploy-gsm.sh` —— 容器内一键部署 GSM（构建 + 架构伪装 + arm64 原生资产 + SteamCMD）
- `fix-arch.sh` —— 修「PTY 能力不可用」：只伪装 `os.arch()` + 安装 arm64 原生 PTY/zip/7z + 生成启动器
- `fix-steamcmd.sh` —— 修「缺少 32 位 ELF loader」：把 `linux32/steamcmd`、`linuxarm64/steamcmd`、
  `steamcmd.sh` 全部包装成 box64 入口（优先 linux64 的 x86_64，回退 BOX32 转 i386）
- `docker-compose.yml` —— box64 容器（映射 3001、持久化 `/root`）
