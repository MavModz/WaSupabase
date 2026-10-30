import { afterEach, describe, expect, it, vi } from "vitest";

// getCurrentAccount resolves the caller's account context. The
// regression this file guards (issue #294): account loading must NOT
// depend on a PostgREST embedded FK join (`accounts!inner`), because a
// stale schema cache makes that embed fail hard and blanks the whole
// context. It must instead read the profile and then the account with
// two plain point queries.

// ------------------------------------------------------------
// Chainable Supabase query-builder mock. Each `.from(table)` hands back
// a thenable builder pre-loaded with the result queued for that table,
// so we can assert which tables were queried and with what filters.
// ------------------------------------------------------------
interface BuilderCall {
  table: string;
  columns?: string;
  eqArgs: [string, unknown][];
}

function makeClient(opts: {
  user: { id: string } | null;
  userErr?: unknown;
  // A list is consumed one result per query (last one repeats), for
  // tests where the same table is read twice.
  byTable: Record<
    string,
    { data: unknown; error: unknown } | { data: unknown; error: unknown }[]
  >;
  rpc?: (fn: string) => { data: unknown; error: unknown };
}) {
  const calls: BuilderCall[] = [];
  const rpcCalls: string[] = [];
  const reads: Record<string, number> = {};
  const resultFor = (table: string) => {
    const queued = opts.byTable[table];
    if (!Array.isArray(queued)) return queued ?? { data: null, error: null };
    const i = reads[table] ?? 0;
    reads[table] = i + 1;
    return queued[Math.min(i, queued.length - 1)];
  };

  const from = (table: string) => {
    const call: BuilderCall = { table, eqArgs: [] };
    calls.push(call);
    const builder = {
      select(columns: string) {
        call.columns = columns;
        return builder;
      },
      eq(col: string, val: unknown) {
        call.eqArgs.push([col, val]);
        return builder;
      },
      maybeSingle() {
        return Promise.resolve(resultFor(table));
      },
    };
    return builder;
  };

  return {
    calls,
    rpcCalls,
    client: {
      rpc: (fn: string) => {
        rpcCalls.push(fn);
        return Promise.resolve(
          opts.rpc ? opts.rpc(fn) : { data: null, error: null },
        );
      },
      auth: {
        getUser: () =>
          Promise.resolve({
            data: { user: opts.user },
            error: opts.userErr ?? null,
          }),
      },
      from,
    },
  };
}

const createClient = vi.fn();
vi.mock("@/lib/supabase/server", () => ({
  createClient: () => createClient(),
}));

const { getCurrentAccount, UnauthorizedError, ForbiddenError } = await import(
  "./account"
);

afterEach(() => {
  vi.clearAllMocks();
});

describe("getCurrentAccount", () => {
  it("resolves context via a plain accounts lookup, not an embedded join", async () => {
    const { client, calls } = makeClient({
      user: { id: "user-1" },
      byTable: {
        profiles: {
          data: { account_id: "acct-1", account_role: "owner" },
          error: null,
        },
        accounts: { data: { id: "acct-1", name: "Acme" }, error: null },
      },
    });
    createClient.mockReturnValue(client);

    const ctx = await getCurrentAccount();

    expect(ctx).toMatchObject({
      userId: "user-1",
      accountId: "acct-1",
      role: "owner",
      account: { id: "acct-1", name: "Acme" },
    });

    // Two queries: profiles by user_id, then accounts by id. Neither
    // selects an embedded relationship — the regression guard.
    expect(calls.map((c) => c.table)).toEqual(["profiles", "accounts"]);
    expect(calls[0].columns).not.toMatch(/accounts!/);
    expect(calls[0].eqArgs).toEqual([["user_id", "user-1"]]);
    expect(calls[1].columns).not.toMatch(/accounts!/);
    expect(calls[1].eqArgs).toEqual([["id", "acct-1"]]);
  });

  it("throws UnauthorizedError when there is no session", async () => {
    const { client } = makeClient({ user: null, byTable: {} });
    createClient.mockReturnValue(client);
    await expect(getCurrentAccount()).rejects.toBeInstanceOf(UnauthorizedError);
  });

  it("maps a profiles query error to 'Could not load account context'", async () => {
    const { client } = makeClient({
      user: { id: "user-1" },
      byTable: {
        profiles: { data: null, error: { code: "PGRST200" } },
      },
    });
    createClient.mockReturnValue(client);
    await expect(getCurrentAccount()).rejects.toThrow(
      "Could not load account context",
    );
  });

  it("maps an accounts query error to 'Could not load account context'", async () => {
    // The exact #294 shape if the embed were still in play, but now on
    // the decoupled accounts lookup: profile resolves, account read errors.
    const { client } = makeClient({
      user: { id: "user-1" },
      byTable: {
        profiles: {
          data: { account_id: "acct-1", account_role: "admin" },
          error: null,
        },
        accounts: { data: null, error: { code: "PGRST200" } },
      },
    });
    createClient.mockReturnValue(client);
    const err = await getCurrentAccount().catch((e) => e);
    expect(err).toBeInstanceOf(ForbiddenError);
    expect(err.message).toBe("Could not load account context");
  });

  it("rejects a profile not linked to an account", async () => {
    const { client } = makeClient({
      user: { id: "user-1" },
      byTable: {
        profiles: { data: { account_id: null, account_role: null }, error: null },
      },
    });
    createClient.mockReturnValue(client);
    await expect(getCurrentAccount()).rejects.toThrow(
      "Profile is not linked to an account",
    );
  });

  it("rejects an account_id that resolves to no readable account", async () => {
    const { client } = makeClient({
      user: { id: "user-1" },
      byTable: {
        profiles: {
          data: { account_id: "acct-1", account_role: "viewer" },
          error: null,
        },
        accounts: { data: null, error: null },
      },
    });
    createClient.mockReturnValue(client);
    await expect(getCurrentAccount()).rejects.toThrow(
      "Profile is not linked to an account",
    );
  });
});

describe("toErrorResponse", () => {
  it("passes typed auth errors through without an error_id", async () => {
    const { toErrorResponse } = await import("./account");
    const res = toErrorResponse(new ForbiddenError("nope"));
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "nope" });
  });

  it("collapses unknown errors to a generic 500 with an error_id that is logged", async () => {
    const { toErrorResponse } = await import("./account");
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const res = toErrorResponse(new Error("secret internal detail"));
    expect(res.status).toBe(500);
    const body = await res.json();
    expect(body.error).toBe("Internal server error");
    expect(body.error_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(JSON.stringify(body)).not.toContain("secret internal detail");
    // The same id is on the server log line, next to the real error.
    const line = String(spy.mock.calls[0][0]);
    expect(line).toContain(body.error_id);
    expect(line).toContain("secret internal detail");
    spy.mockRestore();
  });
});

describe("getCurrentAccount — signup self-heal (migration 064)", () => {
  it("provisions a user with no profile row via ensure_my_account, then resolves", async () => {
    const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { client, rpcCalls } = makeClient({
      user: { id: "user-1" },
      byTable: {
        profiles: [
          { data: null, error: null },
          { data: { account_id: "acct-1", account_role: "owner" }, error: null },
        ],
        accounts: { data: { id: "acct-1", name: "Mine" }, error: null },
      },
      rpc: () => ({ data: "acct-1", error: null }),
    });
    createClient.mockReturnValue(client);

    const ctx = await getCurrentAccount();

    expect(rpcCalls).toEqual(["ensure_my_account"]);
    expect(ctx.accountId).toBe("acct-1");
    expect(ctx.role).toBe("owner");
    expect(String(spy.mock.calls[0][0])).toContain("account.self_healed");
    spy.mockRestore();
  });

  it("stays forbidden (and logs) when the self-heal RPC fails", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const { client, rpcCalls } = makeClient({
      user: { id: "user-1" },
      byTable: { profiles: { data: null, error: null } },
      rpc: () => ({ data: null, error: { message: "boom", code: "XX000" } }),
    });
    createClient.mockReturnValue(client);

    await expect(getCurrentAccount()).rejects.toThrow(
      "Profile is not linked to an account",
    );
    expect(rpcCalls).toEqual(["ensure_my_account"]);
    expect(String(spy.mock.calls[0][0])).toContain("account.self_heal_failed");
    spy.mockRestore();
  });

  it("does not call the RPC when a profile exists", async () => {
    const { client, rpcCalls } = makeClient({
      user: { id: "user-1" },
      byTable: {
        profiles: { data: { account_id: "acct-1", account_role: "agent" }, error: null },
        accounts: { data: { id: "acct-1", name: "Team" }, error: null },
      },
    });
    createClient.mockReturnValue(client);
    await getCurrentAccount();
    expect(rpcCalls).toEqual([]);
  });

  it("does not call the RPC when the profile read itself errored", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const { client, rpcCalls } = makeClient({
      user: { id: "user-1" },
      byTable: { profiles: { data: null, error: { message: "timeout" } } },
    });
    createClient.mockReturnValue(client);
    await expect(getCurrentAccount()).rejects.toThrow(ForbiddenError);
    expect(rpcCalls).toEqual([]);
    spy.mockRestore();
  });
});
