# Cloudflare Worker + D1

## 本地验证

```bash
npm install
cp .dev.vars.example .dev.vars
npx wrangler d1 migrations apply healthkit-sync --local
npm test
npm run check
```

## 创建并部署

```bash
npx wrangler login
npx wrangler d1 create healthkit-sync
```

把命令返回的 `database_id` 写入 `wrangler.jsonc`，然后执行：

```bash
npx wrangler d1 migrations apply healthkit-sync --remote
npx wrangler secret put UPLOAD_TOKEN
npx wrangler secret put SYNC_TOKEN
npx wrangler deploy
```

建议用以下命令生成两个不同的随机 Token：

```bash
openssl rand -base64 32
```

部署成功后，在 iOS App 设置中填写：

```text
https://healthkit-sync-api.looplearngotoloop.workers.dev/v1/activities
```

以及 `UPLOAD_TOKEN`。`SYNC_TOKEN` 只应保存到 GitHub Actions Secrets。

## 上传前去重

iOS App 使用 `UPLOAD_TOKEN` 批量检查 HealthKit UUID，接口不会返回活动详情：

```http
POST /v1/activities/existence
Authorization: Bearer <upload token>
Content-Type: application/json

{"healthkit_uuids":["123e4567-e89b-42d3-a456-426614174000"]}
```

每次最多提交 500 个 UUID。响应只包含数据库中已经存在的 UUID：

```json
{"healthkit_uuids":["123e4567-e89b-42d3-a456-426614174000"]}
```
