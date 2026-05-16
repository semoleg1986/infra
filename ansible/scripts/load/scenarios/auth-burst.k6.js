import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import {
  authMeResponse,
  loginResponse,
  register,
} from '../shared/http.js';

const authBaseUrl = (__ENV.AUTH_BASE_URL || 'http://127.0.0.1:8000').replace(/\/$/, '');
const registerEnabled = (__ENV.AUTH_REGISTER_ENABLED || 'true').toLowerCase() !== 'false';
const vus = Number(__ENV.K6_VUS || 50);
const duration = __ENV.K6_DURATION || '3m';
const thinkTimeSeconds = Number(__ENV.K6_THINK_TIME_SECONDS || 0.2);
const userPoolSize = Number(__ENV.K6_USER_POOL_SIZE || Math.max(vus * 50, 1000));
const setupTimeout = __ENV.K6_SETUP_TIMEOUT || '15m';

const loginDuration = new Trend('auth_login_duration_ms');
const meDuration = new Trend('auth_me_duration_ms');
const loginFailures = new Counter('auth_login_failures_total');
const meFailures = new Counter('auth_me_failures_total');
const login429s = new Counter('auth_login_status_429_total');
const login5xxs = new Counter('auth_login_status_5xx_total');
const loginOtherErrors = new Counter('auth_login_status_other_total');
const successRate = new Rate('auth_flow_success_rate');

export const options = {
  vus,
  duration,
  setupTimeout,
  thresholds: {
    http_req_failed: ['rate<0.01'],
    auth_flow_success_rate: ['rate>0.99'],
    auth_login_duration_ms: ['p(95)<500'],
    auth_me_duration_ms: ['p(95)<250'],
  },
};

function uniqueUser() {
  const suffix = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  return {
    email: `load.auth.${suffix}@example.com`,
    password: __ENV.AUTH_PASSWORD || 'LoadTest12345!',
    defaultRole: __ENV.AUTH_DEFAULT_ROLE || 'parent',
  };
}

export function setup() {
  const configuredEmail = __ENV.AUTH_EMAIL || '';
  const configuredPassword = __ENV.AUTH_PASSWORD || '';
  const defaultRole = __ENV.AUTH_DEFAULT_ROLE || 'parent';

  if (configuredEmail && configuredPassword) {
    return { users: [{ email: configuredEmail, password: configuredPassword, defaultRole }] };
  }

  if (!registerEnabled) {
    throw new Error('AUTH_EMAIL/AUTH_PASSWORD are required when AUTH_REGISTER_ENABLED=false');
  }

  const users = [];
  for (let i = 0; i < userPoolSize; i += 1) {
    const user = uniqueUser();
    register({ authBaseUrl, email: user.email, password: user.password, defaultRole: user.defaultRole });
    users.push(user);
  }
  return { users };
}

export default function (data) {
  const users = data.users || [];
  const user = users[__ITER % users.length];
  const loginResult = loginResponse({
    authBaseUrl,
    email: user.email,
    password: user.password,
    fingerprint: `k6-${__VU}-${__ITER}`,
    clientName: 'k6-load-baseline',
  });

  loginDuration.add(loginResult.timings.duration);
  const loginStatusOk = check(loginResult, {
    'login status is 200': (r) => r.status === 200,
  });
  if (!loginStatusOk) {
    loginFailures.add(1);
    if (loginResult.status === 429) {
      login429s.add(1);
    } else if (loginResult.status >= 500) {
      login5xxs.add(1);
    } else {
      loginOtherErrors.add(1);
    }
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  let accessToken = '';
  try {
    accessToken = loginResult.json('access_token') || '';
  } catch (_) {
    accessToken = '';
  }
  const loginTokenOk = check(loginResult, {
    'login returns access token': () => Boolean(accessToken),
  });
  if (!loginTokenOk) {
    loginFailures.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  const meResponse = authMeResponse({ authBaseUrl, accessToken });
  meDuration.add(meResponse.timings.duration);
  let meEmail = '';
  try {
    meEmail = meResponse.json('email') || '';
  } catch (_) {
    meEmail = '';
  }
  const meOk = check(meResponse, {
    'me status is 200': (r) => r.status === 200,
    'me returns same email': () => meEmail === user.email,
  });
  if (!meOk) {
    meFailures.add(1);
  }

  successRate.add(loginTokenOk && meOk);
  sleep(thinkTimeSeconds);
}
