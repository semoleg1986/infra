import http from 'k6/http';
import { check } from 'k6';
import { jsonHeaders, require2xx } from './http.js';

export function createPaymentIntent({ paymentsBaseUrl, parentToken, parentId, studentId, offerId, bonusAmount = 0, idempotencyKey }) {
  const response = http.post(
    `${paymentsBaseUrl}/v1/parent/payments/intents`,
    JSON.stringify({
      parent_id: parentId,
      student_id: studentId,
      offer_id: offerId,
      bonus_amount: bonusAmount,
      idempotency_key: idempotencyKey,
    }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${parentToken}` }),
      tags: { endpoint: 'payments_create_intent' },
    },
  );
  return {
    response,
    ok: check(response, {
      'payment intent status is 2xx': (r) => r.status >= 200 && r.status < 300,
    }),
    paymentIntentId: response.json('payment_intent_id') || '',
  };
}

export function isAlreadyActiveAccessError(response) {
  return (
    response.status === 400 &&
    typeof response.body === 'string' &&
    response.body.indexOf('уже существует active доступ') !== -1
  );
}

export function approvePaymentIntent({ paymentsBaseUrl, adminToken, paymentIntentId, responseCallback }) {
  const response = http.post(
    `${paymentsBaseUrl}/v1/admin/payments/${paymentIntentId}/approve`,
    JSON.stringify({}),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${adminToken}` }),
      tags: { endpoint: 'payments_approve_intent' },
      responseCallback,
    },
  );
  const ok2xx = check(response, {
    'payment approve status is 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  const alreadyActive = isAlreadyActiveAccessError(response);
  return { response, ok: ok2xx || alreadyActive, ok2xx, alreadyActive };
}

export function waitForAccess({ paymentsBaseUrl, serviceToken, courseId, studentId, attempts = 10, sleepFn }) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const response = http.get(`${paymentsBaseUrl}/internal/v1/access/${courseId}/${studentId}`, {
      headers: { 'X-Service-Token': serviceToken },
      tags: { endpoint: 'payments_internal_access' },
    });
    require2xx(response, `internal access check ${studentId}`);
    if (response.json('has_access') === true) {
      return response;
    }
    sleepFn(0.2);
  }
  throw new Error(`internal access check did not become ready for student ${studentId}`);
}
