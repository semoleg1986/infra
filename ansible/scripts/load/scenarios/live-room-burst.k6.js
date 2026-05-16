import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { authMe, login, register } from '../shared/http.js';
import { createAdminUser, createParentStudentLink } from '../shared/users.js';
import { resolveOfferSnapshot } from '../shared/catalog.js';
import { approvePaymentIntent, createPaymentIntent, waitForAccess } from '../shared/payments.js';
import { createRoom, getRoomVersion, joinRoom, leaveRoom, readAttendance } from '../shared/live.js';

const authBaseUrl = (__ENV.AUTH_BASE_URL || 'http://127.0.0.1:8000').replace(/\/$/, '');
const usersBaseUrl = (__ENV.USERS_BASE_URL || 'http://127.0.0.1:8002').replace(/\/$/, '');
const paymentsBaseUrl = (__ENV.PAYMENTS_BASE_URL || 'http://127.0.0.1:8004').replace(/\/$/, '');
const liveBaseUrl = (__ENV.LIVE_BASE_URL || 'http://127.0.0.1:8010').replace(/\/$/, '');
const commercialCatalogBaseUrl = (__ENV.COMMERCIAL_CATALOG_BASE_URL || 'http://127.0.0.1:8007').replace(/\/$/, '');
const serviceToken = __ENV.SERVICE_TOKEN || 'sometokencourse';
const adminEmail = __ENV.ADMIN_EMAIL || 'admin@example.com';
const adminPassword = __ENV.ADMIN_PASSWORD || 'admin12345';
const studentPassword = __ENV.STUDENT_PASSWORD || 'student12345';
const parentPassword = __ENV.PARENT_PASSWORD || 'parent12345';
const offerId = __ENV.K6_LIVE_OFFER_ID || __ENV.K6_PAYMENT_OFFER_ID || '';
const forcedCourseId = __ENV.K6_LIVE_COURSE_ID || '';
const lessonId = __ENV.K6_LIVE_LESSON_ID || '';
const vus = Number(__ENV.K6_VUS || 10);
const duration = __ENV.K6_DURATION || '2m';
const thinkTimeSeconds = Number(__ENV.K6_THINK_TIME_SECONDS || 0.2);
const setupTimeout = __ENV.K6_SETUP_TIMEOUT || '20m';
const studentPoolSize = Number(__ENV.K6_USER_POOL_SIZE || Math.max(vus, 10));
const roomPoolSize = Number(__ENV.K6_ROOM_POOL_SIZE || Math.max(vus, 1));

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

function buildStudentScenario(index, adminToken, parentToken, parentId, courseId) {
  const suffix = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}-${index}`;
  const email = `student.live.${suffix}@example.com`;
  register({ authBaseUrl, email, password: studentPassword, defaultRole: 'student' });
  const studentToken = login({ authBaseUrl, email, password: studentPassword, fingerprint: `k6-live-student-${suffix}`, clientName: 'k6-live-load-baseline' });
  const studentMe = authMe({ authBaseUrl, accessToken: studentToken });
  const studentUserId = studentMe.user_id;
  createAdminUser({
    usersBaseUrl,
    accessToken: adminToken,
    payload: { user_id: studentUserId, email, display_name: `Load Student ${suffix}`, roles: ['student'] },
  });
  createParentStudentLink({ usersBaseUrl, accessToken: adminToken, parentId, studentId: studentUserId });

  const payment = createPaymentIntent({
    paymentsBaseUrl,
    parentToken,
    parentId,
    studentId: studentUserId,
    offerId,
    idempotencyKey: `live-load-pay-${suffix}`,
  });
  if (!payment.ok || !payment.paymentIntentId) {
    throw new Error(`create payment intent failed for live student ${studentUserId}: ${payment.response.status} ${payment.response.body}`);
  }

  const approval = approvePaymentIntent({
    paymentsBaseUrl,
    adminToken,
    paymentIntentId: payment.paymentIntentId,
  });
  if (!approval.ok) {
    throw new Error(`approve payment intent failed for live student ${studentUserId}: ${approval.response.status} ${approval.response.body}`);
  }

  waitForAccess({ paymentsBaseUrl, serviceToken, courseId, studentId: studentUserId, sleepFn: sleep });
  return { userId: studentUserId, email, accessToken: studentToken };
}

export function setup() {
  if (!offerId) {
    throw new Error('K6_LIVE_OFFER_ID or K6_PAYMENT_OFFER_ID is required');
  }
  if (!lessonId) {
    throw new Error('K6_LIVE_LESSON_ID is required');
  }

  const adminToken = login({ authBaseUrl, email: adminEmail, password: adminPassword, fingerprint: `k6-live-admin-${Date.now()}`, clientName: 'k6-live-load-baseline' });
  const snapshot = resolveOfferSnapshot({ commercialCatalogBaseUrl, serviceToken, offerId });
  const courseId = forcedCourseId || snapshot.courseId;

  const parentSuffix = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const parentEmail = `parent.live.${parentSuffix}@example.com`;
  register({ authBaseUrl, email: parentEmail, password: parentPassword, defaultRole: 'parent' });
  const parentToken = login({ authBaseUrl, email: parentEmail, password: parentPassword, fingerprint: `k6-live-parent-${parentSuffix}`, clientName: 'k6-live-load-baseline' });
  const parentMe = authMe({ authBaseUrl, accessToken: parentToken });
  const parentUserId = parentMe.account_id;
  createAdminUser({
    usersBaseUrl,
    accessToken: adminToken,
    payload: { user_id: parentUserId, email: parentEmail, display_name: `Load Parent ${parentSuffix}`, roles: ['parent'] },
  });

  const students = [];
  for (let i = 0; i < studentPoolSize; i += 1) {
    students.push(buildStudentScenario(i + 1, adminToken, parentToken, parentUserId, courseId));
  }

  const rooms = [];
  for (let i = 0; i < roomPoolSize; i += 1) {
    const room = createRoom({ liveBaseUrl, adminToken, courseId, lessonId, participantsLimit: studentPoolSize + 20 });
    rooms.push(room.roomId);
  }

  return { adminToken, students, rooms };
}

export default function (data) {
  const students = data.students || [];
  const rooms = data.rooms || [];
  if (students.length === 0) {
    throw new Error('setup did not provide students');
  }
  if (rooms.length === 0) {
    throw new Error('setup did not provide rooms');
  }

  const student = students[(__VU - 1) % students.length];
  const roomId = rooms[(__VU - 1) % rooms.length];
  const roomState = getRoomVersion({ liveBaseUrl, accessToken: student.accessToken, roomId });
  const expectedVersion = roomState.version;

  const joined = joinRoom({ liveBaseUrl, studentToken: student.accessToken, roomId, expectedVersion });
  joinDuration.add(joined.response.timings.duration);
  if (!joined.ok) {
    joinFailures.add(1);
    if (joined.response.status === 403) {
      join403s.add(1);
    } else if (joined.response.status === 409) {
      join409s.add(1);
    } else {
      joinOtherErrors.add(1);
    }
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }
  if (typeof joined.version !== 'number') {
    joinFailures.add(1);
    joinOtherErrors.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  const left = leaveRoom({ liveBaseUrl, studentToken: student.accessToken, roomId, expectedVersion: joined.version });
  leaveDuration.add(left.response.timings.duration);
  if (!left.ok) {
    leaveFailures.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  const attendance = readAttendance({ liveBaseUrl, adminToken: data.adminToken, roomId });
  attendanceDuration.add(attendance.response.timings.duration);
  if (!attendance.ok) {
    attendanceFailures.add(1);
  }

  successRate.add(joined.ok && left.ok && attendance.ok);
  sleep(thinkTimeSeconds);
}
