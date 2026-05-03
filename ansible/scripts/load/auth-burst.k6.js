import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const authBaseUrl = (__ENV.AUTH_BASE_URL || 'http://127.0.0.1:8000').replace(/\/$/, '');
const registerEnabled = (__ENV.AUTH_REGISTER_ENABLED || 'true').toLowerCase() !== 'false';
const vus = Number(__ENV.K6_VUS || 50);
const duration = __ENV.K6_DURATION || '3m';
const thinkTimeSeconds = Number(__ENV.K6_THINK_TIME_SECONDS || 0.2);

const loginDuration = new Trend('auth_login_duration_ms');
const meDuration = new Trend('auth_me_duration_ms');
const loginFailures = new Counter('auth_login_failures_total');
const meFailures = new Counter('auth_me_failures_total');
const successRate = new Rate('auth_flow_success_rate');

export const options = {
  vus,
  duration,
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
    default_role: __ENV.AUTH_DEFAULT_ROLE || 'parent',
  };
}

export function setup() {
  const user = {
    email: __ENV.AUTH_EMAIL,
    password: __ENV.AUTH_PASSWORD,
    default_role: __ENV.AUTH_DEFAULT_ROLE || 'parent',
  };

  if (user.email && user.password) {
    return user;
  }

  if (!registerEnabled) {
    throw new Error(
      'AUTH_EMAIL/AUTH_PASSWORD are required when AUTH_REGISTER_ENABLED=false',
    );
  }

  const generated = uniqueUser();
  const response = http.post(
    `${authBaseUrl}/v1/auth/register`,
    JSON.stringify({
      email: generated.email,
      password: generated.password,
      default_role: generated.default_role,
    }),
    {
      headers: { 'Content-Type': 'application/json' },
      tags: { endpoint: 'auth_register' },
    },
  );

  check(response, {
    'register status is 200': (r) => r.status === 200,
  });

  if (response.status !== 200) {
    throw new Error(`register failed: HTTP ${response.status} ${response.body}`);
  }

  return generated;
}

export default function (user) {
  const loginResponse = http.post(
    `${authBaseUrl}/v1/auth/login`,
    JSON.stringify({
      email: user.email,
      password: user.password,
      session_fingerprint: `k6-${__VU}-${__ITER}`,
      client_name: 'k6-load-baseline',
      auth_method: 'password',
    }),
    {
      headers: { 'Content-Type': 'application/json' },
      tags: { endpoint: 'auth_login' },
    },
  );

  loginDuration.add(loginResponse.timings.duration);
  const loginOk = check(loginResponse, {
    'login status is 200': (r) => r.status === 200,
    'login returns access token': (r) => Boolean(r.json('access_token')),
  });

  if (!loginOk) {
    loginFailures.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  const accessToken = loginResponse.json('access_token');
  const meResponse = http.get(`${authBaseUrl}/v1/auth/me`, {
    headers: { Authorization: `Bearer ${accessToken}` },
    tags: { endpoint: 'auth_me' },
  });

  meDuration.add(meResponse.timings.duration);
  const meOk = check(meResponse, {
    'me status is 200': (r) => r.status === 200,
    'me returns same email': (r) => r.json('email') === user.email,
  });

  if (!meOk) {
    meFailures.add(1);
  }

  successRate.add(loginOk && meOk);
  sleep(thinkTimeSeconds);
}
