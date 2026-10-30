import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// The postgres backend talks to the service-role client; the memory
// tests never reach it. `h.rpc` decides what rate_limit_hit returns.
const h = vi.hoisted(() => ({
  rpc: vi.fn(),
}));
vi.mock("@/lib/automations/admin-client", () => ({
  supabaseAdmin: () => ({
    rpc: (fn: string, args: unknown) => ({
      abortSignal: () => h.rpc(fn, args),
    }),
  }),
}));

import {
  __resetRateLimitForTests,
  checkRateLimit,
  getClientIp,
  rateLimitBackend,
  rateLimitResponse,
} from "./rate-limit";

const OPTS = { limit: 3, windowMs: 60_000 };

describe("checkRateLimit", () => {
  beforeEach(() => {
    __resetRateLimitForTests();
  });

  it("permits the first request and decrements remaining", async () => {
    const result = await checkRateLimit("user:1", OPTS);
    expect(result).toMatchObject({
      success: true,
      remaining: 2,
      limit: 3,
    });
    expect(result.reset).toBeGreaterThan(Date.now());
  });

  it("permits exactly `limit` requests then rejects the next", async () => {
    expect((await checkRateLimit("user:1", OPTS)).success).toBe(true);
    expect((await checkRateLimit("user:1", OPTS)).success).toBe(true);
    expect((await checkRateLimit("user:1", OPTS)).success).toBe(true);
    const over = await checkRateLimit("user:1", OPTS);
    expect(over.success).toBe(false);
    expect(over.remaining).toBe(0);
  });

  it("keeps separate counters per key", async () => {
    await checkRateLimit("user:1", OPTS);
    await checkRateLimit("user:1", OPTS);
    await checkRateLimit("user:1", OPTS);
    // user:1 is at the cap, user:2 should still be unaffected.
    const other = await checkRateLimit("user:2", OPTS);
    expect(other.success).toBe(true);
    expect(other.remaining).toBe(2);
  });

  it("opens a fresh window after `windowMs` elapses", async () => {
    vi.useFakeTimers();
    try {
      const t0 = new Date("2026-05-01T00:00:00Z").getTime();
      vi.setSystemTime(t0);
      __resetRateLimitForTests();

      await checkRateLimit("user:1", OPTS);
      await checkRateLimit("user:1", OPTS);
      await checkRateLimit("user:1", OPTS);
      expect((await checkRateLimit("user:1", OPTS)).success).toBe(false);

      // Jump just past the window.
      vi.setSystemTime(t0 + OPTS.windowMs + 1);
      const refreshed = await checkRateLimit("user:1", OPTS);
      expect(refreshed.success).toBe(true);
      expect(refreshed.remaining).toBe(2);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("rateLimitResponse", () => {
  it("returns a 429 with retry / X-RateLimit headers", async () => {
    const reset = Date.now() + 30_000;
    const res = rateLimitResponse({
      success: false,
      remaining: 0,
      reset,
      limit: 60,
    });
    expect(res.status).toBe(429);
    expect(res.headers.get("X-RateLimit-Limit")).toBe("60");
    expect(res.headers.get("X-RateLimit-Remaining")).toBe("0");
    expect(Number(res.headers.get("Retry-After"))).toBeGreaterThan(0);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/rate limit/i);
  });

  it("clamps Retry-After to a minimum of 1 second", () => {
    // Reset already in the past — the ceiling math would otherwise give 0.
    const res = rateLimitResponse({
      success: false,
      remaining: 0,
      reset: Date.now() - 5_000,
      limit: 10,
    });
    expect(Number(res.headers.get("Retry-After"))).toBeGreaterThanOrEqual(1);
  });
});

describe("RATE_LIMITS presets", () => {
  it("send and broadcast are budgeted per minute", async () => {
    __resetRateLimitForTests();
    // Importing here so the presets stay close to their assertions.
    const { RATE_LIMITS } = await import("./rate-limit");
    expect(RATE_LIMITS.send.windowMs).toBe(60_000);
    expect(RATE_LIMITS.broadcast.windowMs).toBe(60_000);
  });

  it("the broadcast budget carries a campaign's per-batch call pattern", async () => {
    __resetRateLimitForTests();
    const { RATE_LIMITS } = await import("./rate-limit");
    // A campaign is NOT one call: the wizard posts a batch of 10
    // recipients roughly every 1–2 s, so it needs ~45+ calls of headroom
    // per minute. Sized below that, every batch past the cap comes back
    // 429 and its recipients are written off as failed (issue #472).
    expect(RATE_LIMITS.broadcast.limit).toBeGreaterThanOrEqual(45);
  });
});

afterEach(() => {
  __resetRateLimitForTests();
});

describe("getClientIp", () => {
  const req = (headers: Record<string, string>) =>
    new Request("https://x.test/api/invitations/t/peek", { headers });

  it("prefers x-real-ip over x-forwarded-for", () => {
    expect(
      getClientIp(req({ "x-real-ip": "203.0.113.7", "x-forwarded-for": "1.1.1.1" })),
    ).toBe("203.0.113.7");
  });

  it("uses the rightmost x-forwarded-for hop, which the last proxy appended", () => {
    expect(
      getClientIp(req({ "x-forwarded-for": "6.6.6.6, 198.51.100.4" })),
    ).toBe("198.51.100.4");
  });

  it("cannot be rotated by a client-supplied leftmost entry", () => {
    const first = getClientIp(req({ "x-forwarded-for": "10.0.0.1, 198.51.100.4" }));
    const second = getClientIp(req({ "x-forwarded-for": "10.0.0.2, 198.51.100.4" }));
    expect(first).toBe(second);
  });

  it("ignores empty hops and blank headers", () => {
    expect(getClientIp(req({ "x-forwarded-for": "198.51.100.4, " }))).toBe(
      "198.51.100.4",
    );
    expect(getClientIp(req({ "x-real-ip": "  ", "x-forwarded-for": " , " }))).toBe(
      "unknown",
    );
  });

  it("falls back to a constant with no proxy headers", () => {
    expect(getClientIp(req({}))).toBe("unknown");
  });
});

describe("checkRateLimit — postgres backend (RATE_LIMIT_BACKEND=postgres)", () => {
  beforeEach(() => {
    __resetRateLimitForTests();
    vi.stubEnv("RATE_LIMIT_BACKEND", "postgres");
    h.rpc.mockReset();
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  it("selects the backend from the env, defaulting to memory", () => {
    expect(rateLimitBackend()).toBe("postgres");
    vi.stubEnv("RATE_LIMIT_BACKEND", "");
    expect(rateLimitBackend()).toBe("memory");
    vi.stubEnv("RATE_LIMIT_BACKEND", "redis");
    expect(rateLimitBackend()).toBe("memory");
  });

  it("maps the rate_limit_hit row onto the result shape", async () => {
    const resetAt = "2026-11-01T00:01:00.000Z";
    h.rpc.mockResolvedValue({
      data: [{ allowed: false, remaining: 0, reset_at: resetAt }],
      error: null,
    });
    const result = await checkRateLimit("send:user-1", OPTS);
    expect(h.rpc).toHaveBeenCalledWith("rate_limit_hit", {
      p_key: "send:user-1",
      p_limit: 3,
      p_window_ms: 60_000,
    });
    expect(result).toEqual({
      success: false,
      remaining: 0,
      reset: Date.parse(resetAt),
      limit: 3,
    });
  });

  it("caps the key at the column's 256 characters", async () => {
    h.rpc.mockResolvedValue({
      data: [{ allowed: true, remaining: 2, reset_at: new Date().toISOString() }],
      error: null,
    });
    await checkRateLimit("k".repeat(400), OPTS);
    expect((h.rpc.mock.calls[0][1] as { p_key: string }).p_key).toHaveLength(256);
  });

  it("falls back to the in-memory counter on an RPC error, and logs once", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    h.rpc.mockResolvedValue({ data: null, error: { message: "down", code: "08006" } });

    const results = [];
    for (let i = 0; i < 4; i++) results.push(await checkRateLimit("user:9", OPTS));

    // Still limited — per instance — rather than open or closed.
    expect(results.map((r) => r.success)).toEqual([true, true, true, false]);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(String(spy.mock.calls[0][0])).toContain("rate_limit.backend_error");
  });

  it("falls back when the RPC rejects (timeout / network)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    h.rpc.mockRejectedValue(new Error("The operation was aborted due to timeout"));
    const result = await checkRateLimit("user:10", OPTS);
    expect(result).toMatchObject({ success: true, remaining: 2, limit: 3 });
  });

  it("falls back on an unexpected payload", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    h.rpc.mockResolvedValue({ data: [], error: null });
    const result = await checkRateLimit("user:11", OPTS);
    expect(result.success).toBe(true);
  });
});
