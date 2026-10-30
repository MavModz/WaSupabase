// ============================================================
// Structured server logger: one JSON line per call.
//
// Why not pino/winston: the platforms we deploy to (Vercel, Docker)
// already capture stdout/stderr per line, so a JSON line written
// through `console.log` / `console.error` is all a log drain needs.
// No dependency, no transport, no worker thread.
//
//   import { log } from '@/lib/log'
//   log.info('broadcast.batch_sent', { accountId, sent: 10 })
//   log.error('webhook.insert_failed', { err, conversationId })
//
// `event` is a stable dotted name to search on; free text belongs in
// `msg`. Log ids (accountId, conversationId, phone_number_id), never
// message bodies, phone numbers or credentials. Keys that look like a
// secret are redacted anyway as a backstop (`REDACT_KEY`).
//
// Request correlation: `src/middleware.ts` stamps every request with
// `x-request-id`. Code that does work for a request — including inside
// `after()` — wraps it in `withLogContext({ requestId }, fn)`, and every
// log line emitted underneath carries that id without threading a
// logger through function signatures (AsyncLocalStorage).
//
// Server-only: it imports `node:async_hooks`. Never import it from a
// client component or from the middleware.
//
// Env: LOG_LEVEL (debug|info|warn|error, default info) and LOG_FORMAT
// (json|pretty; default json in production, pretty elsewhere).
// ============================================================

import { AsyncLocalStorage } from 'node:async_hooks'

import { REQUEST_ID_HEADER } from '@/lib/request-id'

export type LogLevel = 'debug' | 'info' | 'warn' | 'error'
export type LogFields = Record<string, unknown>

const LEVEL_RANK: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 }

const contextStore = new AsyncLocalStorage<LogFields>()

// Key names whose values must never reach a log line. Matched on the
// key, case-insensitively, at any depth.
const REDACT_KEY =
  /(token|secret|password|passwd|authorization|api[_-]?key|apikey|cookie|encrypted|private[_-]?key|credential)/i

const MAX_DEPTH = 5

function minLevel(): LogLevel {
  const raw = (process.env.LOG_LEVEL ?? '').toLowerCase()
  return raw in LEVEL_RANK ? (raw as LogLevel) : 'info'
}

function pretty(): boolean {
  const raw = (process.env.LOG_FORMAT ?? '').toLowerCase()
  if (raw === 'json') return false
  if (raw === 'pretty') return true
  return process.env.NODE_ENV !== 'production'
}

/** Error → plain object. Stack only outside production (it can be long
 *  and, for driver errors, embeds query text). */
export function serializeError(err: unknown): LogFields {
  if (err instanceof Error) {
    const out: LogFields = { name: err.name, message: err.message }
    const code = (err as { code?: unknown }).code
    if (code !== undefined) out.code = code
    if (process.env.NODE_ENV !== 'production' && err.stack) out.stack = err.stack
    return out
  }
  if (err && typeof err === 'object') {
    // PostgrestError and friends are plain objects with message/code/details.
    return sanitize(err, 0) as LogFields
  }
  return { message: String(err) }
}

function sanitize(value: unknown, depth: number): unknown {
  if (value === null || value === undefined) return value
  if (value instanceof Error) return serializeError(value)
  if (typeof value === 'bigint') return value.toString()
  if (typeof value !== 'object') return value
  if (depth >= MAX_DEPTH) return '[truncated]'
  if (Array.isArray(value)) return value.map((v) => sanitize(v, depth + 1))
  const out: LogFields = {}
  for (const [k, v] of Object.entries(value as LogFields)) {
    out[k] = REDACT_KEY.test(k) ? '[redacted]' : sanitize(v, depth + 1)
  }
  return out
}

function emit(level: LogLevel, event: string, bound: LogFields, fields?: LogFields) {
  if (LEVEL_RANK[level] < LEVEL_RANK[minLevel()]) return

  const { err, ...rest } = { ...(contextStore.getStore() ?? {}), ...bound, ...(fields ?? {}) }
  const record: LogFields = {
    ts: new Date().toISOString(),
    level,
    event,
    ...(sanitize(rest, 0) as LogFields),
  }
  if (err !== undefined) record.err = serializeError(err)

  let line: string
  try {
    line = pretty()
      ? `${record.ts} ${level.toUpperCase()} ${event} ${JSON.stringify({ ...record, ts: undefined, level: undefined, event: undefined })}`
      : JSON.stringify(record)
  } catch {
    // Circular structure or similar: never let logging throw.
    line = JSON.stringify({ ts: record.ts, level, event, msg: '[unserializable log fields]' })
  }

  if (level === 'error') console.error(line)
  else if (level === 'warn') console.warn(line)
  else console.log(line)
}

export interface Logger {
  debug(event: string, fields?: LogFields): void
  info(event: string, fields?: LogFields): void
  warn(event: string, fields?: LogFields): void
  error(event: string, fields?: LogFields): void
  /** A logger whose lines all carry `fields`. */
  child(fields: LogFields): Logger
}

function makeLogger(bound: LogFields): Logger {
  return {
    debug: (event, fields) => emit('debug', event, bound, fields),
    info: (event, fields) => emit('info', event, bound, fields),
    warn: (event, fields) => emit('warn', event, bound, fields),
    error: (event, fields) => emit('error', event, bound, fields),
    child: (fields) => makeLogger({ ...bound, ...fields }),
  }
}

export const log: Logger = makeLogger({})

/**
 * Run `fn` with `ctx` merged into every log line emitted inside it,
 * including across awaits. Nested calls merge over the outer context.
 */
export function withLogContext<T>(ctx: LogFields, fn: () => T): T {
  return contextStore.run({ ...(contextStore.getStore() ?? {}), ...ctx }, fn)
}

export { REQUEST_ID_HEADER }

/** The request id the middleware stamped, if any. */
export function requestIdOf(request: Request): string | undefined {
  return request.headers.get(REQUEST_ID_HEADER) ?? undefined
}

/** The request id of the current log context, if any. */
export function currentRequestId(): string | undefined {
  const id = contextStore.getStore()?.requestId
  return typeof id === 'string' ? id : undefined
}
