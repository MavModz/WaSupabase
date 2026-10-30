// ============================================================
// Typed plan-limit error, mapped to HTTP 402 on dashboard routes and
// /api/v1 alike (REQ-X6, N-4). A seat-blocked downgrade is 409: paying
// more wouldn't change it, only freeing seats would.
//
// Dashboard: { error: <localized>, code, resource, usage, limit, … }
// /api/v1:   { error: { code, message: <English>, resource, usage, limit, … } }
// ============================================================

import { NextResponse } from 'next/server';

import { getT } from '@/lib/i18n/translate';
import { parsePlanError } from './parse';
import type { PlanErrorCode, PlanErrorDetail } from './types';

const KNOWN_RESOURCES = new Set([
  'seats',
  'contacts',
  'broadcast_recipients',
  'automations_active',
  'automations_total',
  'flows_active',
  'flows_total',
  'api_keys',
  'public_api',
  'webhook_endpoints',
  'ai_auto_reply',
  'ai_drafts',
  'kb_documents',
  'pipelines',
  'messages',
]);

function resourceLabel(resource: string): string {
  if (!KNOWN_RESOURCES.has(resource)) return resource;
  return getT('Api')(`plan.resources.${resource}`);
}

function localizedMessage(d: PlanErrorDetail): string {
  const t = getT('Api');
  if (d.code === 'downgrade_blocked') {
    return t('plan.downgradeBlocked', { count: d.to_free ?? 0 });
  }
  if (d.reason === 'account_restricted') return t('plan.accountRestricted');
  if (d.reason === 'account_locked') return t('plan.accountLocked');
  if (d.code === 'plan_feature_unavailable') {
    return t('plan.featureUnavailable', { resource: resourceLabel(d.resource) });
  }
  if (d.resource === 'broadcast_recipients' && d.remaining !== undefined) {
    return t('plan.broadcastOverAllowance', {
      requested: d.requested ?? 0,
      remaining: d.remaining,
      date: (d.resets_at ?? '').slice(0, 10),
    });
  }
  return t('plan.limitReached', { limit: d.limit ?? 0, resource: resourceLabel(d.resource) });
}

/** English, for the public API and the MCP server (REQ-X7). */
function apiMessage(d: PlanErrorDetail): string {
  const name = d.resource.replace(/_/g, ' ');
  if (d.code === 'downgrade_blocked') {
    return `Free ${d.to_free ?? 0} seat(s) before changing to this plan`;
  }
  if (d.reason === 'account_restricted') return `Account restricted: ${name} is paused`;
  if (d.reason === 'account_locked') return `Account locked: ${name} is unavailable`;
  if (d.code === 'plan_feature_unavailable') return `${name} is not available on this plan`;
  return `Plan limit reached for ${name}: ${d.usage ?? 0} of ${d.limit ?? 0} used`;
}

export class PlanLimitError extends Error {
  readonly code: PlanErrorCode;
  readonly status: number;
  readonly detail: PlanErrorDetail;

  constructor(detail: PlanErrorDetail) {
    super(apiMessage(detail));
    this.name = 'PlanLimitError';
    this.code = detail.code;
    this.status = detail.code === 'downgrade_blocked' ? 409 : 402;
    this.detail = detail;
  }

  dashboardBody() {
    return { ...this.detail, error: localizedMessage(this.detail) };
  }

  apiBody() {
    return { error: { ...this.detail, message: this.message } };
  }
}

/** A WA00x error from Supabase as a {@link PlanLimitError}, else null. */
export function fromPostgrestError(err: unknown): PlanLimitError | null {
  const detail = parsePlanError(err);
  return detail ? new PlanLimitError(detail) : null;
}

/**
 * For dashboard routes that handle their own Supabase errors: the 402
 * when `err` is a plan error, else null so the route's existing handling
 * runs. Pure, so it costs nothing with the switch off.
 */
export function planErrorResponse(err: unknown): NextResponse | null {
  const planErr = fromPostgrestError(err);
  return planErr
    ? NextResponse.json(planErr.dashboardBody(), { status: planErr.status })
    : null;
}
