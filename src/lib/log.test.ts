import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { currentRequestId, log, requestIdOf, serializeError, withLogContext } from './log'
import { resolveRequestId } from './request-id'

// The logger writes one JSON line per call through console.*. These tests
// pin the line shape (what a log drain parses), redaction, level
// filtering and AsyncLocalStorage context inheritance.

let logSpy: ReturnType<typeof vi.spyOn>
let warnSpy: ReturnType<typeof vi.spyOn>
let errorSpy: ReturnType<typeof vi.spyOn>

beforeEach(() => {
  vi.stubEnv('LOG_FORMAT', 'json')
  vi.stubEnv('LOG_LEVEL', '')
  logSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
  warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
  errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
})

afterEach(() => {
  vi.unstubAllEnvs()
  vi.restoreAllMocks()
})

function lastLine(spy: ReturnType<typeof vi.spyOn>): Record<string, unknown> {
  const calls = spy.mock.calls
  return JSON.parse(String(calls[calls.length - 1][0]))
}

describe('log', () => {
  it('writes one JSON line with ts, level, event and fields', () => {
    log.info('broadcast.batch_sent', { accountId: 'acct-1', sent: 10 })
    const line = lastLine(logSpy)
    expect(line).toMatchObject({ level: 'info', event: 'broadcast.batch_sent', accountId: 'acct-1', sent: 10 })
    expect(typeof line.ts).toBe('string')
  })

  it('routes warn and error to console.warn / console.error', () => {
    log.warn('a.warn')
    log.error('a.error')
    expect(lastLine(warnSpy).level).toBe('warn')
    expect(lastLine(errorSpy).level).toBe('error')
  })

  it('drops lines below LOG_LEVEL', () => {
    vi.stubEnv('LOG_LEVEL', 'warn')
    log.info('quiet')
    log.debug('quieter')
    expect(logSpy).not.toHaveBeenCalled()
    log.warn('loud')
    expect(warnSpy).toHaveBeenCalledTimes(1)
  })

  it('redacts secret-looking keys at any depth', () => {
    log.info('x', {
      access_token: 'tok',
      nested: { apiKey: 'k', Authorization: 'Bearer z', keep: 'ok' },
      list: [{ password: 'p' }],
    })
    const line = lastLine(logSpy)
    expect(line.access_token).toBe('[redacted]')
    expect(line.nested).toEqual({ apiKey: '[redacted]', Authorization: '[redacted]', keep: 'ok' })
    expect(line.list).toEqual([{ password: '[redacted]' }])
  })

  it('serializes an Error passed as err', () => {
    const err = Object.assign(new Error('boom'), { code: '23505' })
    log.error('db.failed', { err })
    const line = lastLine(errorSpy)
    expect(line.err).toMatchObject({ name: 'Error', message: 'boom', code: '23505' })
  })

  it('omits the stack in production', () => {
    vi.stubEnv('NODE_ENV', 'production')
    expect(serializeError(new Error('x')).stack).toBeUndefined()
  })

  it('serializes a plain PostgREST-style error object', () => {
    expect(serializeError({ message: 'm', code: 'PGRST116' })).toEqual({ message: 'm', code: 'PGRST116' })
    expect(serializeError('just text')).toEqual({ message: 'just text' })
  })

  it('child loggers bind fields', () => {
    log.child({ route: 'whatsapp.webhook' }).info('received')
    expect(lastLine(logSpy)).toMatchObject({ route: 'whatsapp.webhook', event: 'received' })
  })

  it('withLogContext fields reach lines emitted across awaits', async () => {
    await withLogContext({ requestId: 'req-12345678' }, async () => {
      await Promise.resolve()
      log.info('inside')
      expect(currentRequestId()).toBe('req-12345678')
    })
    expect(lastLine(logSpy).requestId).toBe('req-12345678')
    log.info('outside')
    expect(lastLine(logSpy).requestId).toBeUndefined()
    expect(currentRequestId()).toBeUndefined()
  })

  it('never throws on a circular structure', () => {
    const a: Record<string, unknown> = {}
    a.self = a
    expect(() => log.info('circular', { a })).not.toThrow()
  })
})

describe('request id helpers', () => {
  it('keeps a well-formed inbound id', () => {
    expect(resolveRequestId('abc-123_DEF.456')).toBe('abc-123_DEF.456')
  })

  it('replaces a missing, short or unsafe id with a uuid', () => {
    for (const bad of [null, undefined, '', 'short', 'has space here', 'x'.repeat(129), 'a"b<c>d\r\ne']) {
      expect(resolveRequestId(bad)).toMatch(/^[0-9a-f-]{36}$/)
    }
  })

  it('requestIdOf reads the header', () => {
    expect(requestIdOf(new Request('https://x.test', { headers: { 'x-request-id': 'rid-12345678' } }))).toBe(
      'rid-12345678',
    )
    expect(requestIdOf(new Request('https://x.test'))).toBeUndefined()
  })
})
