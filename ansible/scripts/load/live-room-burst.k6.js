import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const authBaseUrl = (__ENV.AUTH_BASE_URL || 'http://127.0.0.1:8000').replace(/\/$/, '');
const usersBaseUrl = (__ENV.USERS_BASE_URL || 'http://127.0.0.1:8002').replace(/\/$/, '');
const courseBaseUrl = (__ENV.COURSE_BASE_URL || 'http://127.0.0.1:8001').replace(/\/$/, '');
const paymentsBaseUrl = (__ENV.PAYMENTS_BASE_URL || 'http://127.0.0.1:8004').replace(/\/$/, '');
const liveBaseUrl = (__ENV.LIVE_BASE_URL || 'http://127.0.0.1:8010').replace(/\/$/, '');
const vus = Number(__ENV.K6_VUS || 10);
const duration = __ENV.K6_DURATION || '2m';
const thinkTimeSeconds = Number(__ENV.K6_THINK_TIME_SECONDS || 0.2);
const setupTimeout = __ENV.K6_SETUP_TIMEOUT || '20m';
const studentPoolSize = Number(__ENV.K6_USER_POOL_SIZE || Math.max(vus, 10));
const serviceToken = __ENV.SERVICE_TOKEN || 'sometokencourse';
const adminEmail = __ENV.ADMIN_EMAIL || 'admin@example.com';
const adminPassword = __ENV.ADMIN_PASSWORD || 'admin12345';
const studentPassword = __ENV.STUDENT_PASSWORD || 'student12345';
const parentPassword = __ENV.PARENT_PASSWORD || 'parent12345';

const joinDuration = new Trend('live_join_duration_ms');
const leaveDuration = new Trend('live_leave_duration_ms');
const attendanceDuration = new Trend('live_attendance_duration_ms');
const successRate = new Rate('live_flow_success_rate');
const joinFailures = new Counter('live_join_failures_total');
const leaveFailures = new Counter('live_leave_failures_total');
const attendanceFailures = new Counter('live_attendance_failures_total');
const join403s = new Counter('live_join_status_403_total');
const join409s = new Counter('live_join_status_409_total');
const joinOtherErrors = new Counter('live_join_status_other_total');

export const options = {
  vus,
  duration,
  setupTimeout,
  thresholds: {
    http_req_failed: ['rate<0.01'],
    live_flow_success_rate: ['rate>0.99'],
    live_join_duration_ms: ['p(95)<750'],
    live_leave_duration_ms: ['p(95)<500'],
    live_attendance_duration_ms: ['p(95)<500'],
  },
};

function jsonHeaders(extra = {}) {
  const headers = {
    'Content-Type': 'application/json',
  };
  Object.keys(extra).forEach((key) => {
    headers[key] = extra[key];
  });
  return headers;
}

function require2xx(response, step) {
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`${step} failed: HTTP ${response.status} ${response.body}`);
  }
}

function login(email, password, fingerprint) {
  const response = http.post(
    `${authBaseUrl}/v1/auth/login`,
    JSON.stringify({
      email,
      password,
      session_fingerprint: fingerprint,
      client_name: 'k6-live-load-baseline',
      auth_method: 'password',
    }),
    {
      headers: jsonHeaders(),
      tags: { endpoint: 'auth_login' },
    },
  );
  require2xx(response, `login ${email}`);
  const accessToken = response.json('access_token') || '';
  if (!accessToken) {
    throw new Error(`login ${email} returned empty access_token`);
  }
  return accessToken;
}

function authMe(accessToken) {
  const response = http.get(`${authBaseUrl}/v1/auth/me`, {
    headers: { Authorization: `Bearer ${accessToken}` },
    tags: { endpoint: 'auth_me' },
  });
  require2xx(response, 'auth me');
  return response.json();
}

function register(email, password, defaultRole) {
  const response = http.post(
    `${authBaseUrl}/v1/auth/register`,
    JSON.stringify({
      email,
      password,
      default_role: defaultRole,
    }),
    {
      headers: jsonHeaders(),
      tags: { endpoint: 'auth_register' },
    },
  );
  require2xx(response, `register ${email}`);
}

function createAdminUser(accessToken, payload) {
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

function createParentStudentLink(accessToken, parentId, studentId) {
  const response = http.post(
    `${usersBaseUrl}/v1/admin/links`,
    JSON.stringify({ parent_id: parentId, student_id: studentId }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${accessToken}` }),
      tags: { endpoint: 'users_admin_link' },
    },
  );
  require2xx(response, `create parent-student link ${parentId}:${studentId}`);
}

function createCourse(accessToken, teacherId, suffix) {
  const courseResponse = http.post(
    `${courseBaseUrl}/v1/admin/courses`,
    JSON.stringify({
      title: `Load Live Course ${suffix}`,
      teacher_id: teacherId,
      starts_at: '2026-09-01T09:00:00Z',
      duration_days: 30,
    }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${accessToken}` }),
      tags: { endpoint: 'course_create' },
    },
  );
  require2xx(courseResponse, 'create course');
  const courseId = courseResponse.json('course_id') || '';
  if (!courseId) {
    throw new Error('create course returned empty course_id');
  }

  const moduleId = `module-load-${suffix}`;
  const lessonId = `lesson-load-${suffix}-1`;

  const moduleResponse = http.post(
    `${courseBaseUrl}/v1/admin/courses/${courseId}/modules`,
    JSON.stringify({
      module_id: moduleId,
      title: `Load Module ${suffix}`,
      description: 'load',
      is_required: true,
    }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${accessToken}` }),
      tags: { endpoint: 'course_module_create' },
    },
  );
  require2xx(moduleResponse, 'create module');

  const lessonResponse = http.post(
    `${courseBaseUrl}/v1/admin/courses/${courseId}/modules/${moduleId}/lessons`,
    JSON.stringify({
      lesson_id: lessonId,
      title: 'Load Lesson 1',
      description: 'load',
      content_type: 'video',
      content_ref: `cdn://load/${suffix}/1`,
      duration_minutes: 15,
      is_preview: false,
    }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${accessToken}` }),
      tags: { endpoint: 'course_lesson_create' },
    },
  );
  require2xx(lessonResponse, 'create lesson');

  const lessonPublishResponse = http.patch(
    `${courseBaseUrl}/v1/admin/courses/${courseId}/modules/${moduleId}/lessons/${lessonId}`,
    JSON.stringify({
      status: 'published',
    }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${accessToken}` }),
      tags: { endpoint: 'course_lesson_publish' },
    },
  );
  require2xx(lessonPublishResponse, 'publish lesson');

  const modulePublishResponse = http.patch(
    `${courseBaseUrl}/v1/admin/courses/${courseId}/modules/${moduleId}`,
    JSON.stringify({
      status: 'published',
    }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${accessToken}` }),
      tags: { endpoint: 'course_module_publish' },
    },
  );
  require2xx(modulePublishResponse, 'publish module');

  const publishResponse = http.post(
    `${courseBaseUrl}/v1/admin/courses/${courseId}/publish`,
    null,
    {
      headers: { Authorization: `Bearer ${accessToken}` },
      tags: { endpoint: 'course_publish' },
    },
  );
  require2xx(publishResponse, 'publish course');

  return { courseId, lessonId };
}

function createPaymentAccess(parentToken, adminToken, parentId, courseId, studentId, suffix) {
  const paymentIntentResponse = http.post(
    `${paymentsBaseUrl}/v1/parent/payments/intents`,
    JSON.stringify({
      parent_id: parentId,
      student_id: studentId,
      course_id: courseId,
      amount_minor: 10000,
      currency: 'RUB',
      idempotency_key: `live-load-pay-${suffix}`,
    }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${parentToken}` }),
      tags: { endpoint: 'payments_create_intent' },
    },
  );
  require2xx(paymentIntentResponse, `create payment intent ${studentId}`);
  const paymentIntentId = paymentIntentResponse.json('payment_intent_id') || '';
  if (!paymentIntentId) {
    throw new Error(`payment intent for ${studentId} returned empty id`);
  }

  const approveResponse = http.post(
    `${paymentsBaseUrl}/v1/admin/payments/${paymentIntentId}/approve`,
    JSON.stringify({ reason: 'load baseline approve' }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${adminToken}` }),
      tags: { endpoint: 'payments_approve_intent' },
    },
  );
  require2xx(approveResponse, `approve payment intent ${paymentIntentId}`);
}

function waitForAccess(courseId, studentId) {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const response = http.get(
      `${paymentsBaseUrl}/internal/v1/access/${courseId}/${studentId}`,
      {
        headers: { 'X-Service-Token': serviceToken },
        tags: { endpoint: 'payments_internal_access' },
      },
    );
    require2xx(response, `internal access check ${studentId}`);
    const hasAccess = response.json('has_access');
    if (hasAccess === true) {
      return;
    }
    sleep(0.2);
  }
  throw new Error(`internal access check did not become ready for student ${studentId}`);
}

function createRoom(adminToken, courseId, lessonId, participantsLimit) {
  const response = http.post(
    `${liveBaseUrl}/v1/live/rooms`,
    JSON.stringify({
      courseId,
      lessonId,
      participantsLimit,
    }),
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
  return roomId;
}

export function setup() {
  const suffix = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const adminToken = login(adminEmail, adminPassword, `k6-live-admin-${suffix}`);

  const teacher = createAdminUser(adminToken, {
    user_id: `teacher-live-${suffix}`,
    email: `teacher.live.${suffix}@example.com`,
    display_name: `Load Teacher ${suffix}`,
    roles: ['teacher'],
  });

  const { courseId, lessonId } = createCourse(adminToken, teacher.user_id, suffix);

  register(`parent.live.${suffix}@example.com`, parentPassword, 'parent');
  const parentToken = login(
    `parent.live.${suffix}@example.com`,
    parentPassword,
    `k6-live-parent-${suffix}`,
  );
  const parentMe = authMe(parentToken);
  const parentUserId = parentMe.account_id;
  createAdminUser(adminToken, {
    user_id: parentUserId,
    email: `parent.live.${suffix}@example.com`,
    display_name: `Load Parent ${suffix}`,
    roles: ['parent'],
  });

  const students = [];
  for (let i = 0; i < studentPoolSize; i += 1) {
    const studentSuffix = `${suffix}-${i + 1}`;
    const email = `student.live.${studentSuffix}@example.com`;
    const accountLoginFingerprint = `k6-live-student-${studentSuffix}`;
    register(email, studentPassword, 'student');
    const studentToken = login(email, studentPassword, accountLoginFingerprint);
    const studentMe = authMe(studentToken);
    const studentUserId = studentMe.user_id;
    createAdminUser(adminToken, {
      user_id: studentUserId,
      email,
      display_name: `Load Student ${studentSuffix}`,
      roles: ['student'],
    });
    createParentStudentLink(adminToken, parentUserId, studentUserId);
    createPaymentAccess(
      parentToken,
      adminToken,
      parentUserId,
      courseId,
      studentUserId,
      studentSuffix,
    );
    waitForAccess(courseId, studentUserId);
    students.push({
      userId: studentUserId,
      email,
      accessToken: studentToken,
    });
  }

  const roomId = createRoom(adminToken, courseId, lessonId, studentPoolSize + 20);
  return {
    adminToken,
    roomId,
    students,
  };
}

export default function (data) {
  const students = data.students || [];
  if (students.length === 0) {
    throw new Error('setup did not provide students');
  }
  const student = students[(__VU - 1) % students.length];

  const joinResponse = http.post(
    `${liveBaseUrl}/v1/live/rooms/${data.roomId}/join`,
    null,
    {
      headers: jsonHeaders({ Authorization: `Bearer ${student.accessToken}` }),
      tags: { endpoint: 'live_join' },
    },
  );
  joinDuration.add(joinResponse.timings.duration);
  const joinOk = check(joinResponse, {
    'live join status is 200': (r) => r.status === 200,
  });
  if (!joinOk) {
    joinFailures.add(1);
    if (joinResponse.status === 403) {
      join403s.add(1);
    } else if (joinResponse.status === 409) {
      join409s.add(1);
    } else {
      joinOtherErrors.add(1);
    }
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  const leaveResponse = http.post(
    `${liveBaseUrl}/v1/live/rooms/${data.roomId}/leave`,
    JSON.stringify({}),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${student.accessToken}` }),
      tags: { endpoint: 'live_leave' },
    },
  );
  leaveDuration.add(leaveResponse.timings.duration);
  const leaveOk = check(leaveResponse, {
    'live leave status is 200': (r) => r.status === 200,
  });
  if (!leaveOk) {
    leaveFailures.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  const attendanceResponse = http.get(
    `${liveBaseUrl}/v1/live/rooms/${data.roomId}/attendance`,
    {
      headers: { Authorization: `Bearer ${data.adminToken}` },
      tags: { endpoint: 'live_attendance' },
    },
  );
  attendanceDuration.add(attendanceResponse.timings.duration);
  const attendanceOk = check(attendanceResponse, {
    'live attendance status is 200': (r) => r.status === 200,
  });
  if (!attendanceOk) {
    attendanceFailures.add(1);
  }

  successRate.add(joinOk && leaveOk && attendanceOk);
  sleep(thinkTimeSeconds);
}
