import http from 'k6/http';
import { check } from 'k6';
import { jsonHeaders } from './http.js';

export function accrueBonus({ bonusBaseUrl, bonusServiceToken, parentId, amount, suffix, vu, iter }) {
  const response = http.post(
    `${bonusBaseUrl}/internal/v1/bonus/accruals`,
    JSON.stringify({
      parent_id: parentId,
      amount,
      reason_code: 'k6_smoke_reward',
      reference_id: `k6-pay-${suffix}-${vu}-${iter}`,
      idempotency_key: `k6-bonus-${suffix}-${vu}-${iter}`,
    }),
    {
      headers: jsonHeaders({ 'X-Service-Token': bonusServiceToken }),
      tags: { endpoint: 'bonus_internal_accrual' },
    },
  );
  return {
    response,
    ok: check(response, {
      'bonus accrual status is 2xx': (r) => r.status >= 200 && r.status < 300,
    }),
  };
}
