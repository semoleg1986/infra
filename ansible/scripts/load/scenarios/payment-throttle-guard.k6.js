import { sleep } from 'k6';
import { createPaymentIntent } from '../shared/payments.js';
import { setup as successSetup, options as successOptions } from './payment-access-progress.k6.js';

const vus = Number(__ENV.K6_VUS || 5);
const duration = __ENV.K6_DURATION || '2m';
const thinkTimeSeconds = Number(__ENV.K6_THINK_TIME_SECONDS || 0.2);

export const options = {
  vus,
  duration,
  setupTimeout: successOptions.setupTimeout,
  thresholds: successOptions.thresholds,
};

export function setup() {
  return successSetup();
}

export default function (data) {
  const scenarios = data.scenarios || [];
  if (scenarios.length === 0) {
    throw new Error('setup did not provide scenarios');
  }
  const scenario = scenarios[(__VU - 1) % scenarios.length];

  createPaymentIntent({
    paymentsBaseUrl: (__ENV.PAYMENTS_BASE_URL || 'http://127.0.0.1:8004').replace(/\/$/, ''),
    parentToken: scenario.parentToken,
    parentId: scenario.parentId,
    studentId: scenario.studentId,
    offerId: scenario.offerId,
    bonusAmount: (__ENV.K6_BONUS_ENABLED || '0') === '1' ? Number(__ENV.K6_BONUS_AMOUNT || 30) : 0,
    idempotencyKey: `k6-throttle-${scenario.suffix}-${__VU}-${__ITER}`,
  });
  sleep(thinkTimeSeconds);
}
