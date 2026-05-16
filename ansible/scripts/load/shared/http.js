import http from 'k6/http';

export function jsonHeaders(extra = {}) {
  return { 'Content-Type': 'application/json', ...extra };
}

export function require2xx(response, step) {
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`${step} failed: HTTP ${response.status} ${response.body}`);
  }
}

export function register({ authBaseUrl, email, password, defaultRole }) {
  const response = http.post(
    `${authBaseUrl}/v1/auth/register`,
    JSON.stringify({ email, password, default_role: defaultRole }),
    { headers: jsonHeaders(), tags: { endpoint: 'auth_register' } },
  );
  require2xx(response, `register ${email}`);
  return response;
}

export function login({ authBaseUrl, email, password, fingerprint, clientName }) {
  const response = http.post(
    `${authBaseUrl}/v1/auth/login`,
    JSON.stringify({
      email,
      password,
      session_fingerprint: fingerprint,
      client_name: clientName,
      auth_method: 'password',
    }),
    { headers: jsonHeaders(), tags: { endpoint: 'auth_login' } },
  );
  require2xx(response, `login ${email}`);
  const token = response.json('access_token') || '';
  if (!token) {
    throw new Error(`login ${email} returned empty access_token`);
  }
  return token;
}

export function authMe({ authBaseUrl, accessToken }) {
  const response = http.get(`${authBaseUrl}/v1/auth/me`, {
    headers: { Authorization: `Bearer ${accessToken}` },
    tags: { endpoint: 'auth_me' },
  });
  require2xx(response, 'auth me');
  return response.json();
}
