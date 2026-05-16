import http from 'k6/http';
import { check } from 'k6';
import { jsonHeaders, require2xx } from './http.js';

export function getRoomVersion({ liveBaseUrl, accessToken, roomId }) {
  const response = http.get(`${liveBaseUrl}/v1/live/rooms/${roomId}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
    tags: { endpoint: 'live_room_get' },
  });
  require2xx(response, `get live room ${roomId}`);
  const version = response.json('version');
  if (typeof version !== 'number') {
    throw new Error(`live room ${roomId} returned invalid version`);
  }
  return { response, version };
}

export function createRoom({ liveBaseUrl, adminToken, courseId, lessonId, participantsLimit }) {
  const response = http.post(
    `${liveBaseUrl}/v1/live/rooms`,
    JSON.stringify({ courseId, lessonId, participantsLimit }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${adminToken}` }),
      tags: { endpoint: 'live_room_create' },
    },
  );
  require2xx(response, 'create live room');
  const roomId = response.json('roomId') || '';
  if (!roomId) {
    throw new Error('create live room returned empty roomId');
  }
  return { response, roomId };
}

export function joinRoom({ liveBaseUrl, studentToken, roomId, expectedVersion }) {
  const response = http.post(
    `${liveBaseUrl}/v1/live/rooms/${roomId}/join`,
    JSON.stringify({ expectedVersion }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${studentToken}` }),
      tags: { endpoint: 'live_join' },
    },
  );
  return {
    response,
    ok: check(response, {
      'live join status is 201': (r) => r.status === 201,
    }),
    version: response.json('version'),
  };
}

export function leaveRoom({ liveBaseUrl, studentToken, roomId, expectedVersion }) {
  const response = http.post(
    `${liveBaseUrl}/v1/live/rooms/${roomId}/leave`,
    JSON.stringify({ expectedVersion }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${studentToken}` }),
      tags: { endpoint: 'live_leave' },
    },
  );
  return {
    response,
    ok: check(response, {
      'live leave status is 201': (r) => r.status === 201,
    }),
  };
}

export function readAttendance({ liveBaseUrl, adminToken, roomId }) {
  const response = http.get(`${liveBaseUrl}/v1/live/rooms/${roomId}/attendance`, {
    headers: { Authorization: `Bearer ${adminToken}` },
    tags: { endpoint: 'live_attendance' },
  });
  return {
    response,
    ok: check(response, {
      'live attendance status is 200': (r) => r.status === 200,
    }),
  };
}
