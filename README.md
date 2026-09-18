# HealthKitSync

一个小型 SwiftUI iOS App，用于从 Apple 健康手动选择运动记录并上传到自建的 Cloudflare Worker API。

默认打开俯卧撑/平板支撑的聊天记录页，配有只读趋势页和本机 Pi 文本助手。今日汇总、缓存趋势和健康上传不依赖模型配置；新增、修改与删除通过聊天完成。配置、构建、测试与部署顺序见 [个人记录与助手说明](docs/personal-records.md)。

## 项目背景

这个项目最初是为了解决个人运动数据同步链路失效的问题。过去，Apple Watch
记录的运动会先通过 iPhone 同步到 Apple 健康，再上传至 Strava，最后由
GitHub Actions 每天调用 Strava API 拉取数据并更新个人运动主页。随着 Strava
限制非会员的 API 访问，这条依赖第三方平台的自动同步链路无法继续稳定运行。

Apple Watch 产生的原始运动记录本来就保存在 HealthKit 中，因此没有必要再把
Strava 当作唯一的数据中转站。HealthKitSync 的目标是建立一条由用户自己控制的
数据链路：

```text
Apple Watch → Apple 健康 / HealthKit → HealthKitSync → Cloudflare Worker → D1
```

iOS App 负责在用户明确授权后读取并上传所选择的运动记录；Cloudflare Worker
负责鉴权和写入 D1；其他项目可以通过独立的只读接口增量同步这些数据。上传和
读取使用不同的 Token，运动记录以 HealthKit UUID 作为唯一标识执行 upsert，
从而支持重复上传、增量读取，并避免产生重复数据。

HealthKitSync 被设计为一个独立项目，而不是某个运动主页仓库的附属脚本。它只
负责安全地把个人 HealthKit 运动数据同步到自有存储，不约束数据之后如何展示或
消费。个人网站、数据分析、备份工具或其他自动化任务都可以接入同一个 API。同
时，现有的 Strava、Garmin 等历史数据源可以继续保留，并通过来源标签与
HealthKit 数据共存，无需覆盖或迁移原有记录。

当前版本从一个可验证的小型 MVP 开始：用户在 App 中手动选择运动并上传。后续
可以在保持用户授权、隐私和数据所有权边界的前提下，逐步增加自动同步、上传历史、
失败重试和更多 HealthKit 指标。

## MVP

- 请求 HealthKit 只读权限
- 列出最近 90 天的运动记录
- 多选并手动上传
- 读取平均心率与 Apple Watch 运动路线
- 将路线编码为 Google encoded polyline
- 将 Worker URL 与上传 Token 保存到 Keychain

## 要求

- Xcode 26+
- iOS 17+
- 真机（模拟器通常没有可用的 Apple Watch 健康数据）

## 真机运行

1. 用 Xcode 打开 `HealthKitSync.xcodeproj`。
2. 在 `HealthKitSync` target 的 Signing & Capabilities 中选择自己的 Team。
3. 确认 HealthKit capability 已启用；工程已经包含对应 entitlement。
4. 连接 iPhone 并运行，首次启动时允许读取健康数据。
5. 在设置中填写 Worker 的 HTTPS 上传地址和上传 Token。

## Worker 接口

App 向配置的 URL 发送 `POST` 请求：

```http
Authorization: Bearer <upload token>
Content-Type: application/json
```

请求体格式见 `WorkoutUpload.swift`。服务端应以 `healthkit_uuid` 为唯一键执行 upsert。

## Cloudflare Worker + D1

Worker 源码位于 `cloudflare/`，提供：

- `GET /health`
- `POST /v1/activities`（`UPLOAD_TOKEN`）
- `POST /v1/activities/existence`（`UPLOAD_TOKEN`，批量检查 HealthKit UUID 是否已上传）
- `GET /v1/activities`（`SYNC_TOKEN`，支持 cursor 分页）

本地验证和部署步骤见 `cloudflare/README.md`。
