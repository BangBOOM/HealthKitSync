import { env, SELF } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

const activity = {
  schema_version: 1,
  healthkit_uuid: "123e4567-e89b-42d3-a456-426614174000",
  name: "骑行",
  workout_type: "cycling",
  started_at: "2026-08-08T01:00:00Z",
  ended_at: "2026-08-08T02:00:00Z",
  distance_m: 20000,
  moving_time_s: 3600,
  elevation_gain_m: 120,
  average_heart_rate: 140,
  average_speed_mps: 5.56,
  route_polyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
  source_device: "Apple Watch",
};

beforeAll(async () => {
  await env.DB.prepare(`
    CREATE TABLE IF NOT EXISTS activities (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      healthkit_uuid TEXT NOT NULL UNIQUE,
      schema_version INTEGER NOT NULL,
      name TEXT NOT NULL,
      workout_type TEXT NOT NULL,
      started_at TEXT NOT NULL,
      ended_at TEXT NOT NULL,
      distance_m REAL,
      moving_time_s INTEGER NOT NULL,
      elevation_gain_m REAL,
      average_heart_rate REAL,
      average_speed_mps REAL,
      route_polyline TEXT,
      source_device TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    )
  `).run();
});

describe("HealthKit Sync API", () => {
  it("reports health", async () => {
    const response = await SELF.fetch("https://example.test/health");
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ ok: true });
  });

  it("rejects uploads without a token", async () => {
    const response = await SELF.fetch("https://example.test/v1/activities", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(activity),
    });
    expect(response.status).toBe(401);
  });

  it("upserts an activity and returns it to the sync client", async () => {
    const firstUpload = await SELF.fetch("https://example.test/v1/activities", {
      method: "POST",
      headers: {
        authorization: "Bearer local-test-upload-token-0000000000000000",
        "content-type": "application/json",
      },
      body: JSON.stringify(activity),
    });
    expect(firstUpload.status).toBe(200);

    const secondUpload = await SELF.fetch("https://example.test/v1/activities", {
      method: "POST",
      headers: {
        authorization: "Bearer local-test-upload-token-0000000000000000",
        "content-type": "application/json",
      },
      body: JSON.stringify({ ...activity, name: "更新后的骑行" }),
    });
    expect(secondUpload.status).toBe(200);

    const list = await SELF.fetch("https://example.test/v1/activities", {
      headers: { authorization: "Bearer local-test-sync-token-000000000000000000" },
    });
    expect(list.status).toBe(200);
    const body = await list.json<{ activities: Array<{ name: string }> }>();
    expect(body.activities).toHaveLength(1);
    expect(body.activities[0]?.name).toBe("更新后的骑行");
  });

  it("accepts omitted optional HealthKit values", async () => {
    const { distance_m, elevation_gain_m, average_heart_rate, average_speed_mps, route_polyline, source_device, ...required } = activity;
    const response = await SELF.fetch("https://example.test/v1/activities", {
      method: "POST",
      headers: {
        authorization: "Bearer local-test-upload-token-0000000000000000",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        ...required,
        healthkit_uuid: "123e4567-e89b-42d3-a456-426614174001",
      }),
    });
    expect(response.status).toBe(200);
  });
});
