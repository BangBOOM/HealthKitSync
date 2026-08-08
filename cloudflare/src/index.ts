const MAX_BODY_BYTES = 1_900_000;
const MAX_PAGE_SIZE = 500;
const MAX_EXISTENCE_UUIDS = 500;

type ActivityInput = {
  schema_version: number;
  healthkit_uuid: string;
  name: string;
  workout_type: string;
  started_at: string;
  ended_at: string;
  distance_m: number | null;
  moving_time_s: number;
  elevation_gain_m: number | null;
  average_heart_rate: number | null;
  average_speed_mps: number | null;
  route_polyline: string | null;
  source_device: string | null;
};

type ActivityRow = ActivityInput & {
  id: number;
  created_at: string;
  updated_at: string;
};

type Cursor = { updatedAt: string; id: number };

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (request.method === "GET" && url.pathname === "/health") {
        await env.DB.prepare("SELECT 1").first();
        return json({ ok: true });
      }

      if (request.method === "POST" && url.pathname === "/v1/activities") {
        if (!(await isAuthorized(request, env.UPLOAD_TOKEN))) return unauthorized();
        return await upsertActivity(request, env.DB);
      }

      if (request.method === "POST" && url.pathname === "/v1/activities/existence") {
        if (!(await isAuthorized(request, env.UPLOAD_TOKEN))) return unauthorized();
        return await findExistingActivities(request, env.DB);
      }

      if (request.method === "GET" && url.pathname === "/v1/activities") {
        if (!(await isAuthorized(request, env.SYNC_TOKEN))) return unauthorized();
        return await listActivities(url, env.DB);
      }

      return json({ error: "not_found" }, 404);
    } catch (error) {
      if (error instanceof ClientError) {
        return json({ error: error.code }, error.status);
      }
      console.error(JSON.stringify({
        message: "request_failed",
        method: request.method,
        path: url.pathname,
        error: error instanceof Error ? error.message : String(error),
      }));
      return json({ error: "internal_server_error" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function findExistingActivities(request: Request, db: D1Database): Promise<Response> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    return json({ error: "content_type_must_be_json" }, 415);
  }

  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (declaredLength > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);

  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES) {
    return json({ error: "payload_too_large" }, 413);
  }

  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  if (!isRecord(value) || !Array.isArray(value.healthkit_uuids)) {
    return json({ error: "invalid_healthkit_uuids" }, 422);
  }

  const requestedUUIDs = value.healthkit_uuids;
  if (requestedUUIDs.length > MAX_EXISTENCE_UUIDS ||
      !requestedUUIDs.every((uuid): uuid is string => typeof uuid === "string" && isUUID(uuid))) {
    return json({ error: "invalid_healthkit_uuids" }, 422);
  }
  const uuids = [...new Set(requestedUUIDs)];
  if (uuids.length === 0) return json({ healthkit_uuids: [] });

  const placeholders = uuids.map((_, index) => `?${index + 1}`).join(", ");
  const result = await db.prepare(`
    SELECT healthkit_uuid
    FROM activities
    WHERE healthkit_uuid IN (${placeholders})
  `).bind(...uuids).all<{ healthkit_uuid: string }>();

  return json({ healthkit_uuids: result.results.map((row) => row.healthkit_uuid) });
}

async function upsertActivity(request: Request, db: D1Database): Promise<Response> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    return json({ error: "content_type_must_be_json" }, 415);
  }

  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (declaredLength > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);

  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES) {
    return json({ error: "payload_too_large" }, 413);
  }

  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const parsed = parseActivity(value);
  if (!parsed.ok) return json({ error: "invalid_activity", fields: parsed.fields }, 422);
  const activity = parsed.value;

  const result = await db.prepare(`
    INSERT INTO activities (
      healthkit_uuid, schema_version, name, workout_type, started_at, ended_at,
      distance_m, moving_time_s, elevation_gain_m, average_heart_rate,
      average_speed_mps, route_polyline, source_device
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
    ON CONFLICT(healthkit_uuid) DO UPDATE SET
      schema_version = excluded.schema_version,
      name = excluded.name,
      workout_type = excluded.workout_type,
      started_at = excluded.started_at,
      ended_at = excluded.ended_at,
      distance_m = excluded.distance_m,
      moving_time_s = excluded.moving_time_s,
      elevation_gain_m = excluded.elevation_gain_m,
      average_heart_rate = excluded.average_heart_rate,
      average_speed_mps = excluded.average_speed_mps,
      route_polyline = excluded.route_polyline,
      source_device = excluded.source_device,
      updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    RETURNING id, healthkit_uuid, updated_at
  `).bind(
    activity.healthkit_uuid,
    activity.schema_version,
    activity.name,
    activity.workout_type,
    activity.started_at,
    activity.ended_at,
    activity.distance_m,
    activity.moving_time_s,
    activity.elevation_gain_m,
    activity.average_heart_rate,
    activity.average_speed_mps,
    activity.route_polyline,
    activity.source_device,
  ).first<{ id: number; healthkit_uuid: string; updated_at: string }>();

  if (!result) throw new Error("D1 upsert returned no row");
  console.log(JSON.stringify({ message: "activity_upserted", activityId: result.id }));
  return json({ ok: true, activity: result });
}

async function listActivities(url: URL, db: D1Database): Promise<Response> {
  const requestedLimit = Number(url.searchParams.get("limit") ?? 100);
  const limit = Number.isFinite(requestedLimit)
    ? Math.min(MAX_PAGE_SIZE, Math.max(1, Math.trunc(requestedLimit)))
    : 100;
  const cursor = decodeCursor(url.searchParams.get("cursor"));

  const result = await db.prepare(`
    SELECT id, healthkit_uuid, schema_version, name, workout_type, started_at,
      ended_at, distance_m, moving_time_s, elevation_gain_m, average_heart_rate,
      average_speed_mps, route_polyline, source_device, created_at, updated_at
    FROM activities
    WHERE updated_at > ?1 OR (updated_at = ?1 AND id > ?2)
    ORDER BY updated_at ASC, id ASC
    LIMIT ?3
  `).bind(cursor.updatedAt, cursor.id, limit).all<ActivityRow>();

  const rows = result.results;
  const last = rows.at(-1);
  const nextCursor = rows.length === limit && last
    ? encodeCursor({ updatedAt: last.updated_at, id: last.id })
    : null;
  return json({ activities: rows, next_cursor: nextCursor });
}

function parseActivity(value: unknown):
  | { ok: true; value: ActivityInput }
  | { ok: false; fields: string[] } {
  if (!isRecord(value)) return { ok: false, fields: ["body"] };
  const fields: string[] = [];
  const requiredStrings = ["healthkit_uuid", "name", "workout_type", "started_at", "ended_at"] as const;
  for (const key of requiredStrings) {
    if (typeof value[key] !== "string" || value[key].length === 0) fields.push(key);
  }
  if (typeof value.schema_version !== "number" || value.schema_version !== 1) fields.push("schema_version");
  if (!isNonNegativeNumber(value.moving_time_s)) fields.push("moving_time_s");
  for (const key of ["distance_m", "elevation_gain_m", "average_heart_rate", "average_speed_mps"] as const) {
    if (!isOptionalNonNegativeNumber(value[key])) fields.push(key);
  }
  if (!isOptionalString(value.route_polyline) || (typeof value.route_polyline === "string" && value.route_polyline.length > 1_800_000)) fields.push("route_polyline");
  if (!isOptionalString(value.source_device)) fields.push("source_device");
  if (!isISODate(value.started_at)) fields.push("started_at");
  if (!isISODate(value.ended_at)) fields.push("ended_at");
  if (typeof value.healthkit_uuid === "string" && !isUUID(value.healthkit_uuid)) fields.push("healthkit_uuid");
  if (fields.length > 0) return { ok: false, fields: [...new Set(fields)] };

  return { ok: true, value: {
    schema_version: value.schema_version as number,
    healthkit_uuid: value.healthkit_uuid as string,
    name: value.name as string,
    workout_type: value.workout_type as string,
    started_at: value.started_at as string,
    ended_at: value.ended_at as string,
    distance_m: (value.distance_m as number | null | undefined) ?? null,
    moving_time_s: value.moving_time_s as number,
    elevation_gain_m: (value.elevation_gain_m as number | null | undefined) ?? null,
    average_heart_rate: (value.average_heart_rate as number | null | undefined) ?? null,
    average_speed_mps: (value.average_speed_mps as number | null | undefined) ?? null,
    route_polyline: (value.route_polyline as string | null | undefined) ?? null,
    source_device: (value.source_device as string | null | undefined) ?? null,
  }};
}

async function isAuthorized(request: Request, expected: string): Promise<boolean> {
  if (typeof expected !== "string" || expected.length < 32) return false;
  const header = request.headers.get("authorization") ?? "";
  const provided = header.startsWith("Bearer ") ? header.slice(7) : "";
  const encoder = new TextEncoder();
  const [providedHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  return crypto.subtle.timingSafeEqual(providedHash, expectedHash);
}

function encodeCursor(cursor: Cursor): string {
  return btoa(JSON.stringify(cursor));
}

function decodeCursor(value: string | null): Cursor {
  if (!value) return { updatedAt: "1970-01-01T00:00:00.000Z", id: 0 };
  try {
    const parsed: unknown = JSON.parse(atob(value));
    if (isRecord(parsed) && isISODate(parsed.updatedAt) && Number.isInteger(parsed.id) && Number(parsed.id) >= 0) {
      return { updatedAt: String(parsed.updatedAt), id: Number(parsed.id) };
    }
  } catch {
    // Invalid cursors intentionally fall through to a client error.
  }
  throw new ClientError("invalid_cursor", 400);
}

class ClientError extends Error {
  constructor(readonly code: string, readonly status: number) { super(code); }
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}

function unauthorized(): Response {
  return json({ error: "unauthorized" }, 401);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonNegativeNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function isOptionalNonNegativeNumber(value: unknown): value is number | null | undefined {
  return value === null || value === undefined || isNonNegativeNumber(value);
}

function isOptionalString(value: unknown): value is string | null | undefined {
  return value === null || value === undefined || typeof value === "string";
}

function isISODate(value: unknown): value is string {
  return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}
