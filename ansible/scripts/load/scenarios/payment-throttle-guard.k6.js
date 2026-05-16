import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { createPaymentIntent } from '../shared/payments.js';
import { setup as successSetup, options as successOptions } from './payment-access-progress.k6.js';

const vus = Number(__ENV.K6_VUS || 5);
const duration = __ENV.K6_DURATION || '2m';
const thinkTimeSeconds = Number(__ENV.K6_THINK_TIME_SECONDS || 0.2);
const paymentCreateDuration = new Trend('payment_create_duration_ms');
const paymentCreate429Rate = new Rate('payment_create_429_rate');
const paymentCreate2xxRate = new Rate('payment_create_2xx_rate');
const paymentCreate5xxTotal = new Counter('payment_create_status_5xx_total');
const paymentCreateOtherErrors = new Counter('payment_create_status_other_total');

export const options = {
  vus,
  duration,
  setupTimeout: successOptions.setupTimeout,
  thresholds: {
    payment_create_429_rate: ['rate>0'],
    payment_create_status_5xx_total: ['count==0'],
  },
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

  const payment = createPaymentIntent({
    paymentsBaseUrl: (__ENV.PAYMENTS_BASE_URL || 'http://127.0.0.1:8004').replace(/\/$/, ''),
    parentToken: scenario.parentToken,
    parentId: scenario.parentId,
    studentId: scenario.studentId,
    offerId: scenario.offerId,
    bonusAmount: (__ENV.K6_BONUS_ENABLED || '0') === '1' ? Number(__ENV.K6_BONUS_AMOUNT || 30) : 0,
    idempotencyKey: `k6-throttle-${scenario.suffix}-${__VU}-${__ITER}`,
  });
  paymentCreateDuration.add(payment.response.timings.duration);
  const is2xx = payment.response.status >= 200 && payment.response.status < 300;
  const is429 = payment.response.status === 429;
  paymentCreate2xxRate.add(is2xx);
  paymentCreate429Rate.add(is429);
  check(payment.response, {
    'payment intent status is 2xx or 429': (r) => (r.status >= 200 && r.status < 300) || r.status === 429,
  });
  if (payment.response.status >= 500) {
    paymentCreate5xxTotal.add(1);
  } else if (!is2xx && !is429) {
    paymentCreateOtherErrors.add(1);
  }
  sleep(thinkTimeSeconds);
}
