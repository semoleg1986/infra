import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { loginResponse, register } from '../shared/http.js';
import { setup as successSetup } from './auth-success-baseline.k6.js';

const authBaseUrl = (__ENV.AUTH_BASE_URL || 'http://127.0.0.1:8000').replace(/\/$/, '');
const registerEnabled = (__ENV.AUTH_REGISTER_ENABLED || 'true').toLowerCase() !== 'false';
const vus = Number(__ENV.LOAD_VUS || __ENV.K6_VUS || 20);
const duration = __ENV.LOAD_DURATION || __ENV.K6_DURATION || '2m';
const thinkTimeSeconds = Number(__ENV.LOAD_THINK_TIME_SECONDS || __ENV.K6_THINK_TIME_SECONDS || 0.2);
const setupTimeout = __ENV.LOAD_SETUP_TIMEOUT || __ENV.K6_SETUP_TIMEOUT || '15m';

const loginDuration = new Trend('auth_login_duration_ms');
const login200Rate = new Rate('auth_login_200_rate');
const throttle429Rate = new Rate('auth_throttle_429_rate');
const loginFailures = new Counter('auth_login_failures_total');
const login429s = new Counter('auth_login_status_429_total');
const login5xxs = new Counter('auth_login_status_5xx_total');
const loginOtherErrors = new Counter('auth_login_status_other_total');

export const options = {
  vus,
  duration,
  setupTimeout,
  thresholds: {
    auth_throttle_429_rate: ['rate>0'],
    auth_login_status_5xx_total: ['count==0'],
  },
};

function uniqueUser() {
  const suffix = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  return {
    email: `load.auth.guard.${suffix}@example.com`,
    password: __ENV.AUTH_PASSWORD || 'LoadTest12345!',
    defaultRole: __ENV.AUTH_DEFAULT_ROLE || 'parent',
  };
}

export function setup() {
  const configuredEmail = __ENV.AUTH_EMAIL || '';
  const configuredPassword = __ENV.AUTH_PASSWORD || '';
  if (configuredEmail && configuredPassword) {
    return successSetup();
  }

  if (!registerEnabled) {
    throw new Error('AUTH_EMAIL/AUTH_PASSWORD are required when AUTH_REGISTER_ENABLED=false');
  }

  const throttleUser = uniqueUser();
  register({
    authBaseUrl,
    email: throttleUser.email,
    password: throttleUser.password,
    defaultRole: throttleUser.defaultRole,
  });
  return { users: [throttleUser] };
}

export default function (data) {
  const users = data.users || [];
  if (users.length === 0) {
    throw new Error('setup did not provide users');
  }
  const user = users[__ITER % users.length];
  const loginResult = loginResponse({
    authBaseUrl,
    email: user.email,
    password: user.password,
    fingerprint: `k6-throttle-${__VU}-${__ITER}`,
    clientName: 'k6-auth-throttle-guard',
  });

  loginDuration.add(loginResult.timings.duration);
  const is200 = loginResult.status === 200;
  const is429 = loginResult.status === 429;
  const statusRecognized = check(loginResult, {
    'login status is 200 or 429': (r) => r.status === 200 || r.status === 429,
  });

  login200Rate.add(is200);
  throttle429Rate.add(is429);

  if (is429) {
    login429s.add(1);
  } else if (loginResult.status >= 500) {
    loginFailures.add(1);
    login5xxs.add(1);
  } else if (!is200) {
    loginFailures.add(1);
    loginOtherErrors.add(1);
  }

  if (!statusRecognized) {
    loginFailures.add(1);
  }

  sleep(thinkTimeSeconds);
}
