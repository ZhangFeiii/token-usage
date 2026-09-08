# Token Usage

Token Usage 是一个原生 macOS 菜单栏用量面板。菜单栏入口显示 Token Usage 图标和当天累计成本（人民币）；左键点击后打开面板，右键点击后打开应用菜单。

## 功能

- 菜单栏显示图标与当天人民币成本，例如 `¥12.36`。
- 左键点击菜单栏入口打开或关闭主面板；点击面板外部收起面板。
- 主面板只保留五个 Tab：`Overview`、`Activity`、`Models`、`Projects`、`Sessions`。
- `Overview` 展示今日成本、缓存命中、今日 Token 明细和 Pace；不展示公司流量限制相关的 `THIS HOUR`、`DAILY USED`、`HOURLY LIMIT`。
- `Activity` 展示最近 20 周的每日费用热力图、最近 90 天统计和最近 12 周趋势。热力图强度使用每日人民币费用，`Less → More` 的分档从本机历史非零费用按分位数动态推算。
- `Models` 展示最近 90 天各模型/Agent 的人民币成本占比、Token 汇总和明细。
- `Projects` 展示最近 90 天按“项目路径 + Agent”分组的成本、请求数、Token 数、活跃天数和最后使用日期。
- `Sessions` 支持按本地日期前后切换，展示会话标题、模型、时间、成本、请求数、Token 组成、缓存命中率和近似 Token/s。来源无法可靠提供的字段显示 `—`。
- 右键菜单提供“重启 Token Usage”和“退出 Token Usage”。
- 各来源每次启动和刷新时独立采集，单个来源缺失或格式不兼容不会阻断其他来源和已有数据。

## 数据链路与来源

Token Usage 不读取任何第三方统计数据库。数据链路固定为：

```text
Agent 本地会话记录（只读）
    → 来源解析器与价格计算
    → 归一化 UsageRecord
    → Token Usage 自有 SQLite
    → 五个 Tab 的聚合查询
```

内置采集器读取以下本地来源：

```text
~/.codex/archived_sessions/*.jsonl
~/.codex/sessions/**/*.jsonl
~/.local/share/opencode/opencode.db
~/.dsh/sessions/**/session.jsonl.zstd
~/.dsh_desktop/*/sessions/**/session.jsonl.zstd
```

- Codex 同时扫描归档会话和 Codex 8.x 使用的活跃会话目录。会话文件名作为稳定来源 ID，重复刷新或在两个目录间移动都不会重复累计；为避免首次启动解析无限历史，只读取足以覆盖面板窗口的近期文件。
- OpenCode 以只读方式读取 `opencode.db` 的 `session` 表。不同 OpenCode 版本的可选列会按实际 schema 读取；可取得的标题、项目路径、时间和 Token 字段会进入会话聚合。
- DeepSeek Harness 读取 CLI 和桌面会话的 zstd 压缩日志，按 `(turn, step)` 去重。解压需要本机可执行的 `zstd`（优先查找 Homebrew、系统路径和 `PATH`）；没有 `zstd` 时仅跳过该来源并保留其他数据。
- 第三方 Agent 还可以把规范化 JSON 写入：

  ```text
  ~/Library/Application Support/TokenBall/imports/*.json
  ```

  支持单个 `UsageRecord`、记录数组或 `{ "records": [...] }`。文件在刷新时导入并按稳定 ID upsert。

采集器只读 Agent 的原始记录，写入的只有 Token Usage 自己的存储。旧版由 CC Switch 统计源写入的 `cc-switch:` 记录会在采集时清理，以免与新来源重复计数；应用本身不依赖 CC Switch，因此可以直接卸载 CC Switch。若仍使用 CC Switch 管理其他模型/API 配置，那部分管理功能不属于 Token Usage。

### 刷新与缓存

- 成功导入的源文件指纹会保存到 `source-fingerprints.json`，并与当前 SQLite 文件身份绑定；应用重启后不会重新解析未变化的 Codex/DSH/JSON 历史文件。解析器升级或数据库被替换时缓存自动失效。
- 每分钟刷新先检查来源指纹；有新增数据、汇率变化、跨日或时区变化时才重建完整仪表盘。
- 没有数据变化的分钟只执行一条带时间索引的近 60 分钟费用查询，用于让 Pace 随时间窗口正确衰减，不重复聚合 140 天记录。
- Sessions 切换日期时只查询目标本地日，并在本次运行中缓存已经打开过的日期；不会重新采集来源或重算 Activity、Models、Projects。

## 成本与人民币换算

面板和菜单栏的成本统一以人民币显示，便于跨 Agent、跨模型比较 Token 价值。

- Codex、OpenCode 中按美元计价的模型先按对应模型价格计算 USD，再换算为 CNY。
- DeepSeek Harness，以及 Codex/OpenCode 路由的 DeepSeek 模型使用其人民币峰谷价格估算；缓存写入按未命中输入价格估算，因为来源没有单独公开缓存写入费率。
- 没有公开价格的模型会明确标记为“未计价”，不会再用 `¥0` 暗示它是免费模型。
- 每个本地日最多请求一次欧洲央行（ECB）每日欧元参考汇率 XML：

  ```text
  https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml
  ```

  USD→CNY 按 `CNY/EUR ÷ USD/EUR` 计算。
- 成功汇率缓存于：

  ```text
  ~/Library/Application Support/TokenBall/exchange-rate-usd-cny.json
  ```

  当天请求失败时复用最近一次成功值；首次运行且没有可用缓存时使用 `7.2`（人民币/美元）作为 fallback。缓存会记住当天已经尝试过请求，避免刷新时重复访问 ECB。

内部成本以百万分之一保存：`costMicrosUSD` 是 USD，`costMicrosCNY` 是来源直接提供的 CNY；仪表盘聚合时使用当天有效 USD→CNY 汇率，避免把历史记录锁死在旧汇率上。

## 数据库与旧版兼容

为了保留原 TokenBall 的历史数据，应用继续使用同一个数据库路径：

```text
~/Library/Application Support/TokenBall/usage.sqlite3
```

`TokenBall` 目录名和 `TokenBallCore` 模块名是数据/API 兼容约定，不代表应用仍使用旧的界面或统计来源。

首次打开数据库时，Token Usage 会创建自己的 `tokenball_usage_records` 表和索引。若发现旧版表缺少新字段，会在原表上执行幂等的 `ALTER TABLE ... ADD COLUMN` 迁移，不删除、不重建、不覆盖已有记录。迁移补充的字段包括：

- USD/CNY 成本字段；
- `session_id`、`session_title` 和 `project_path`；
- `session_started_at`、`session_ended_at`；
- `request_count`。

旧记录的新增字段按数据库默认值（成本为 `0`，会话元数据为空）处理，因此仍可参与历史 Token 聚合；缺失的会话级细节在 UI 中显示 `—`。升级前不需要删除 `usage.sqlite3`，建议在进行系统级操作前自行备份该文件。

## 面向未来 Agent 的扩展接口

核心存储不绑定任何 Agent 的原始 schema。规范化记录 `UsageRecord` 包含稳定 ID、Agent、模型、四类 Token、USD/CNY 成本、时间，以及可选的会话和项目元数据。`UsageRecordStore` 提供幂等单条写入和事务批量 upsert。

最轻量的接入方式是写入规范化 JSON：

```json
{
  "records": [
    {
      "id": "my-agent:request-42",
      "agent": "my-agent",
      "model": "my-model",
      "freshInputTokens": 1200,
      "outputTokens": 320,
      "cacheReadTokens": 800,
      "cacheWriteTokens": 100,
      "costMicrosUSD": 1250000,
      "recordedAt": "2026-08-18T08:30:45Z"
    }
  ]
}
```

`freshInputTokens` 必须排除已经计入缓存字段的 Token。`recordedAt` 接受 ISO 8601、Unix 秒或 Unix 毫秒。第三方写入器应先写临时文件，再原子重命名为 `.json`，避免刷新时读到半个文件。

如果来源不是规范化 JSON，可以在外部模块实现 `JSONUsageAdapter`，将自己的 `Decodable` payload 转为 `[UsageRecord]`，再交给 `GenericJSONUsageParser` 验证。未来需要原生读取某个 Agent 的本地数据库或日志时，只需在采集层增加 provider；核心 SQLite schema、人民币聚合和五个 Tab 的数据接口保持不变。

## 构建、测试与打包

要求 macOS 13 或更高版本，并安装 Xcode Command Line Tools（或完整 Xcode）。DeepSeek Harness 的读取是可选的；要启用它还需要本机安装 `zstd`。

运行测试：

```bash
mkdir -p .build/ModuleCache
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --package-path "$PWD" --disable-sandbox
```

生成未进行发布签名的 macOS App：

```bash
./scripts/package-app.sh
open "dist/Token Usage.app"
```

`package-app.sh` 会执行 `swift build --configuration release`，把 `TokenUsage` 可执行文件和 `Info.plist` 组装为：

```text
dist/Token Usage.app/
└── Contents/
    ├── Info.plist
    └── MacOS/
        └── TokenUsage
```

脚本对包含空格的路径全部使用引号，并显式设置 `Contents/MacOS/TokenUsage` 的可执行权限。脚本不调用 `codesign`，只生成 `dist/Token Usage.app`，不会安装或复制到 `/Applications`；需要发布或长期使用时请在自己的发布流程中处理签名、权限和安装。

也可以直接运行 SwiftPM 可执行文件进行开发调试：

```bash
swift run --package-path "$PWD" TokenUsage
```

## 项目结构

```text
Package.swift                  Swift package：TokenUsage
Sources/TokenBall               macOS App target（内部目标名保留兼容）
Sources/TokenBallCore           数据模型、采集器、价格、汇率和 SQLite 仓库
Sources/TokenBall/Resources     App 的 Info.plist
Tests/TokenBallCoreTests        采集、存储、聚合、价格和格式化测试
scripts/package-app.sh          release 构建与 .app 组装脚本
```

## 常见问题

- 没有数据：确认对应的 Codex、OpenCode 或 DeepSeek Harness 本地目录存在；首次采集可能需要等待一次刷新。
- DeepSeek Harness 未显示：确认 `zstd` 在 `/opt/homebrew/bin/zstd`、`/usr/local/bin/zstd`、`/usr/bin/zstd` 或 `PATH` 中可执行。
- 汇率请求失败：应用会先使用最近成功的 ECB 缓存；没有缓存时显示基于 `7.2` fallback 的人民币成本。
- 旧数据库提示字段缺失：正常启动会执行加列迁移。请先备份数据库；不要为了升级删除 `~/Library/Application Support/TokenBall/usage.sqlite3`。
- 成本重复：来源必须为每条有效用量使用稳定 ID；内置采集器和 JSON 导入均使用 upsert 去重。
