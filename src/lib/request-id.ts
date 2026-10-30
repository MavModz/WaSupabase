// Request id helpers shared by the middleware and the server logger.
// Kept dependency-free (no node: imports) because the middleware may
// run on the edge runtime.

/** Header the middleware stamps on every request and echoes on the response. */
export const REQUEST_ID_HEADER = 'x-request-id'

// An inbound id (from a load balancer or a client retry) is kept only
// when it looks like an opaque token: it ends up in log lines and a
// response header, so anything with spaces, quotes or control
// characters is replaced instead of trusted.
const VALID_REQUEST_ID = /^[A-Za-z0-9._-]{8,128}$/

/** Keep a well-formed inbound id, otherwise mint a new one. */
export function resolveRequestId(inbound: string | null | undefined): string {
  const value = inbound?.trim()
  if (value && VALID_REQUEST_ID.test(value)) return value
  return crypto.randomUUID()
}
