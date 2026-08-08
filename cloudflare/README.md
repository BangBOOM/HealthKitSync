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
