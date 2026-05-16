import http from 'k6/http';

export function jsonHeaders(extra = {}) {
  const headers = { 'Content-Type': 'application/json' };
  Object.keys(extra).forEach((key) => {
    headers[key] = extra[key];
  });
  return headers;
}

export function require2xx(response, step) {
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`${step} failed: HTTP ${response.status} ${response.body}`);
  }
}

export function registerResponse({ authBaseUrl, email, password, defaultRole }) {
  return http.post(
    `${authBaseUrl}/v1/auth/register`,
    JSON.stringify({ email, password, default_role: defaultRole }),
    { headers: jsonHeaders(), tags: { endpoint: 'auth_register' } },
  );
}

export function register({ authBaseUrl, email, password, defaultRole }) {
  const response = registerResponse({ authBaseUrl, email, password, defaultRole });
  require2xx(response, `register ${email}`);
  return response;
}

export function loginResponse({ authBaseUrl, email, password, fingerprint, clientName }) {
  return http.post(
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
}

export function login({ authBaseUrl, email, password, fingerprint, clientName }) {
  const response = loginResponse({ authBaseUrl, email, password, fingerprint, clientName });
  require2xx(response, `login ${email}`);
  const token = response.json('access_token') || '';
  if (!token) {
    throw new Error(`login ${email} returned empty access_token`);
  }
  return token;
}

export function authMeResponse({ authBaseUrl, accessToken }) {
  return http.get(`${authBaseUrl}/v1/auth/me`, {
    headers: { Authorization: `Bearer ${accessToken}` },
    tags: { endpoint: 'auth_me' },
  });
}

export function authMe({ authBaseUrl, accessToken }) {
  const response = authMeResponse({ authBaseUrl, accessToken });
  require2xx(response, 'auth me');
  return response.json();
}
