import { sleep } from 'k6';
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
const offerId = __ENV.LOAD_LIVE_OFFER_ID || __ENV.K6_LIVE_OFFER_ID || __ENV.LOAD_PAYMENT_OFFER_ID || __ENV.K6_PAYMENT_OFFER_ID || '';
const forcedCourseId = __ENV.LOAD_LIVE_COURSE_ID || __ENV.K6_LIVE_COURSE_ID || '';
const lessonId = __ENV.LOAD_LIVE_LESSON_ID || __ENV.K6_LIVE_LESSON_ID || '';
const vus = Number(__ENV.LOAD_VUS || __ENV.K6_VUS || 20);
const duration = __ENV.LOAD_DURATION || __ENV.K6_DURATION || '2m';
const thinkTimeSeconds = Number(__ENV.LOAD_THINK_TIME_SECONDS || __ENV.K6_THINK_TIME_SECONDS || 0.2);
const setupTimeout = __ENV.LOAD_SETUP_TIMEOUT || __ENV.K6_SETUP_TIMEOUT || '20m';
const studentPoolSize = Number(__ENV.LOAD_USER_POOL_SIZE || __ENV.K6_USER_POOL_SIZE || Math.max(vus, 10));
const roomPoolSize = Number(__ENV.LOAD_ROOM_POOL_SIZE || __ENV.K6_ROOM_POOL_SIZE || Math.max(vus, 1));

const joinDuration = new Trend('live_join_duration_ms');
const attendanceDuration = new Trend('live_attendance_duration_ms');
const join2xxRate = new Rate('live_join_2xx_rate');
const join429Rate = new Rate('live_join_429_rate');
const join5xxTotal = new Counter('live_join_status_5xx_total');
const attendance2xxRate = new Rate('live_attendance_2xx_rate');
const attendance429Rate = new Rate('live_attendance_429_rate');
const attendance5xxTotal = new Counter('live_attendance_status_5xx_total');

export const options = {
  vus,
  duration,
  setupTimeout,
  thresholds: {
    live_join_429_rate: ['rate>0'],
    live_join_status_5xx_total: ['count==0'],
    live_attendance_status_5xx_total: ['count==0'],
  },
};

function buildStudentScenario(index, adminToken, parentToken, parentId, courseId) {
  const suffix = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}-${index}`;
  const email = `student.live.${suffix}@example.com`;
  register({ authBaseUrl, email, password: studentPassword, defaultRole: 'student' });
  const studentToken = login({ authBaseUrl, email, password: studentPassword, fingerprint: `k6-live-student-${suffix}`, clientName: 'k6-live-throttle-guard' });
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

  const adminToken = login({ authBaseUrl, email: adminEmail, password: adminPassword, fingerprint: `k6-live-admin-${Date.now()}`, clientName: 'k6-live-throttle-guard' });
  const snapshot = resolveOfferSnapshot({ commercialCatalogBaseUrl, serviceToken, offerId });
  const courseId = forcedCourseId || snapshot.courseId;

  const parentSuffix = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const parentEmail = `parent.live.${parentSuffix}@example.com`;
  register({ authBaseUrl, email: parentEmail, password: parentPassword, defaultRole: 'parent' });
  const parentToken = login({ authBaseUrl, email: parentEmail, password: parentPassword, fingerprint: `k6-live-parent-${parentSuffix}`, clientName: 'k6-live-throttle-guard' });
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
  join2xxRate.add(joined.response.status === 201);
  join429Rate.add(joined.response.status === 429);
  if (joined.response.status >= 500) {
    join5xxTotal.add(1);
  }

  if (joined.response.status === 201 && typeof joined.version === 'number') {
    leaveRoom({ liveBaseUrl, studentToken: student.accessToken, roomId, expectedVersion: joined.version });
  }

  const attendance = readAttendance({ liveBaseUrl, adminToken: data.adminToken, roomId });
  attendanceDuration.add(attendance.response.timings.duration);
  attendance2xxRate.add(attendance.response.status === 200);
  attendance429Rate.add(attendance.response.status === 429);
  if (attendance.response.status >= 500) {
    attendance5xxTotal.add(1);
  }

  sleep(thinkTimeSeconds);
}
