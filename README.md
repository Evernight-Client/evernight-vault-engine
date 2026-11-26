# evernight-vault-engine

不祥宝库战利品预测引擎（`vaulttool`）的独立仓库：我们的 CLI、针对 loot 核心的补丁、golden 对拍数据与发布流水线。

战利品生成核心**不在这里维护**：构建时拉取固定版本的 [xpple/cubiomes](https://github.com/xpple/cubiomes)
原始提交，再打上 `patches/` 里的补丁。上游升级 = 改 `upstream.conf` 的 commit + 重新对齐补丁。

仓库内不提交任何编译产物；Evernight 在构建期从本仓库的 release 下载各平台可执行文件，
打进 jar 的 `assets/evernight/vault/`。

## 目录

| 路径 | 内容 |
| --- | --- |
| `src/vaulttool.c` | 引擎 CLI（来自 FO 模组，CC0；本仓库改为 MSVC/POSIX 双线程层） |
| `patches/cubiomes-loot-patches.diff` | 相对上游的全部改动（12 个文件，`-p2` 应用） |
| `upstream.conf` | 上游仓库地址、固定 commit、补丁 strip 级别 |
| `scripts/prepare-upstream.sh` | 拉取上游固定 commit 到 `build/cubiomes` 并打补丁（幂等） |
| `scripts/build.sh` | 交叉/本机构建，产物 `dist/vaulttool-<target>[.exe]` |
| `scripts/build-msvc.bat` | Windows 原生 MSVC 构建 |
| `scripts/check-golden.sh` | 用参考二进制生成的 golden 数据逐字节对拍 |
| `golden/` | `pred` / `matches` / `narrow` / `detect` / `search` 对拍样本 |
| `docs/ORIGIN.md` | 源码包原始说明（来源、协议、算法要点） |
| `VERSION.txt` | 固定的上游 commit、参考二进制 SHA-256、目标游戏版本 |

## 补丁内容

`patches/cubiomes-loot-patches.diff` 修掉 loot 表生成器的两处索引错误，并做了 MSVC 兼容改写：

1. `subtable_pool_offset[N] = offset[N-1] + count[N]` 应为 `+ count[N-1]`（生成器索引写错）。
2. `merge_loot_pools` 不更新父表 `pool_count`，unique 池（附魔金苹果 / 沉重核心所在池）只能靠
   `subtable_pool_offset` 按需生成。
3. MSVC 适配：VLA → 固定 `[64]`、补未命名形参、`__builtin_popcountll` → `__popcnt64`（`#ifdef` 保留非 MSVC 分支）、
   零长数组/静态初始化改为运行时赋值。

GCC/Clang 只需要 1、2 两处语义修复；3 只是为了让 MSVC 能编译，不影响结果。

## 构建

```bash
# 自动拉取上游 + 打补丁 + 构建本机平台
bash scripts/build.sh

# 指定目标，输出到 dist/
bash scripts/build.sh linux-x86_64       dist
bash scripts/build.sh linux-aarch64      dist
bash scripts/build.sh windows-x86_64     dist
bash scripts/build.sh macos-universal    dist
bash scripts/build.sh android-arm64      dist
bash scripts/build.sh android-x86_64     dist
```

依赖：

- Linux：`gcc`、`git`；交叉到 aarch64 需要 `gcc-aarch64-linux-gnu`；Windows 目标需要 `gcc-mingw-w64-x86-64`。
- macOS：Xcode 命令行工具（`clang`，支持 `-arch arm64 -arch x86_64` 通用二进制）。
- Android：`ANDROID_NDK_HOME` 指向已安装的 NDK（用 NDK 里的 clang，目标 API 21）。
- Windows 原生：先跑一次 `scripts/prepare-upstream.sh`，再用 `scripts/build-msvc.bat`（MSVC，需要 VS Build Tools）。

产物名固定为 `vaulttool-<target>[.exe]`，CI 与 Evernight 的下载脚本都按这个名字取。

## 对拍

```bash
bash scripts/build.sh linux-x86_64 dist
bash scripts/check-golden.sh dist/vaulttool-linux-x86_64
```

逐个比对 `golden/` 下的 `pred` / `matches` / `narrow` / `detect` / `search` 输出（换行统一 LF）；
`matches` 会扫 200 万次开箱，缓存文件写在临时目录，不污染仓库。

## 升级上游

1. 改 `upstream.conf` 的 `UPSTREAM_COMMIT`。
2. `bash scripts/prepare-upstream.sh --force` 拉取；对每个补丁文件用 `git apply --check -p2` 或人工 `git apply -3` 重新对齐。
3. 跑 `check-golden.sh`。算法行为变了（上游 loot 表或 RNG 语义变化）就必须重新生成 golden，
   并同步检查 Evernight 侧的 `VaultPredictionModule`。

## CLI

```
vaulttool pred    <seed> <ominous 0|1> <offset> <count>
vaulttool matches <seed> <ominous> <maxScan> <itemspec>
vaulttool narrow  <seed> <ominous> <rangeStart> <rangeEnd> <delta> <itemspec> <candidates.txt>
vaulttool detect  <seed> <ominous> <start> <maxAttempts> <itemspec>
vaulttool search  <seed> <ominous> <start> <limit> <amount> <targets>
```

- `itemspec`：按开出顺序的物品清单，`minecraft:book:1;minecraft:diamond:3`；比对时会再试一次整体倒序。
- `matches` 输出 `M <offset>`，`narrow` 输出 `KEEP <offset>`，`detect` 输出 `MATCH <offset> STATE <32 hex>` 或 `NOMATCH`（exit 4），
  `search` 输出 `HIT <offset> <item> <count>`。
- 扫描每 100 万次把随机状态缓存到当前目录的 `vault-state-<seed>-<ominous>.bin`，下次从缓存继续，
  并按 CPU 核数分块多线程；并行只影响速度，结果与单线程一致。

## 发布

打 `v*` tag 时 CI 会把 6 个平台的产物挂到 release：

```
vaulttool-windows-x86_64.exe
vaulttool-linux-x86_64
vaulttool-linux-aarch64
vaulttool-macos-universal
vaulttool-android-arm64
vaulttool-android-x86_64
```

Evernight 侧按 `github.repository_owner/<repo>` 的 latest release 下载，因此仓库名建议保持 `evernight-vault-engine`。
