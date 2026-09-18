import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    // Tests must not depend on a developer's local .dev.vars or deployed secret.
    miniflare: { bindings: {
      UPLOAD_TOKEN: "local-test-upload-token-0000000000000000",
      SYNC_TOKEN: "local-test-sync-token-000000000000000000",
    } },
  })],
});
