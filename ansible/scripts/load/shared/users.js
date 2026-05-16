import http from 'k6/http';
import { jsonHeaders, require2xx } from './http.js';

export function createAdminUser({ usersBaseUrl, accessToken, payload }) {
  const response = http.post(
    `${usersBaseUrl}/v1/admin/users`,
    JSON.stringify(payload),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${accessToken}` }),
      tags: { endpoint: 'users_admin_create' },
    },
  );
  require2xx(response, `create user ${payload.user_id}`);
  return response.json();
}

export function createParentStudentLink({ usersBaseUrl, accessToken, parentId, studentId, note = 'load-baseline' }) {
  const response = http.post(
    `${usersBaseUrl}/v1/admin/links`,
    JSON.stringify({ parent_id: parentId, student_id: studentId, note }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${accessToken}` }),
      tags: { endpoint: 'users_admin_link' },
    },
  );
  require2xx(response, `create parent-student link ${parentId}:${studentId}`);
  return response;
}
