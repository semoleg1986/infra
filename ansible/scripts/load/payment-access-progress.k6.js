import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const authBaseUrl = (__ENV.AUTH_BASE_URL || 'http://127.0.0.1:8000').replace(/\/$/, '');
const usersBaseUrl = (__ENV.USERS_BASE_URL || 'http://127.0.0.1:8002').replace(/\/$/, '');
const courseBaseUrl = (__ENV.COURSE_BASE_URL || 'http://127.0.0.1:8001').replace(/\/$/, '');
const paymentsBaseUrl = (__ENV.PAYMENTS_BASE_URL || 'http://127.0.0.1:8004').replace(/\/$/, '');
const commercialCatalogBaseUrl = (__ENV.COMMERCIAL_CATALOG_BASE_URL || 'http://127.0.0.1:8007').replace(/\/$/, '');
const bonusBaseUrl = (__ENV.BONUS_BASE_URL || 'http://127.0.0.1:8006').replace(/\/$/, '');
const serviceToken = __ENV.SERVICE_TOKEN || 'sometokencourse';
const bonusServiceToken = __ENV.BONUS_SERVICE_TOKEN || serviceToken;
const vus = Number(__ENV.K6_VUS || 5);
const duration = __ENV.K6_DURATION || '2m';
const thinkTimeSeconds = Number(__ENV.K6_THINK_TIME_SECONDS || 0.2);
const setupTimeout = __ENV.K6_SETUP_TIMEOUT || '20m';
const scenarioPoolSize = Number(__ENV.K6_USER_POOL_SIZE || Math.max(vus, 5));
const adminEmail = __ENV.ADMIN_EMAIL || 'admin@example.com';
const adminPassword = __ENV.ADMIN_PASSWORD || 'admin12345';
const studentPassword = __ENV.STUDENT_PASSWORD || 'student12345';
const parentPassword = __ENV.PARENT_PASSWORD || 'parent12345';
const paymentOfferId = __ENV.K6_PAYMENT_OFFER_ID || '';
const learningEnabled = (__ENV.K6_LEARNING_ENABLED || '1') === '1';
const learningLesson1Id = __ENV.K6_LEARNING_LESSON1_ID || '';
const learningLesson2Id = __ENV.K6_LEARNING_LESSON2_ID || '';
const bonusEnabled = (__ENV.K6_BONUS_ENABLED || '0') === '1';
const bonusAmount = Number(__ENV.K6_BONUS_AMOUNT || 30);

const paymentCreateDuration = new Trend('payment_create_duration_ms');
const paymentApproveDuration = new Trend('payment_approve_duration_ms');
const accessCheckDuration = new Trend('payment_access_check_duration_ms');
const lessonCompleteDuration = new Trend('learning_complete_duration_ms');
const studentProgressDuration = new Trend('learning_student_progress_duration_ms');
const parentProgressDuration = new Trend('learning_parent_progress_duration_ms');
const parentCompletedDuration = new Trend('learning_parent_completed_duration_ms');
const bonusAccrualDuration = new Trend('bonus_accrual_duration_ms');
const successRate = new Rate('payment_access_progress_success_rate');

const paymentCreateFailures = new Counter('payment_create_failures_total');
const paymentApproveFailures = new Counter('payment_approve_failures_total');
const accessCheckFailures = new Counter('payment_access_check_failures_total');
const learningFailures = new Counter('learning_progress_failures_total');
const bonusAccrualFailures = new Counter('bonus_accrual_failures_total');
const paymentCreate409s = new Counter('payment_create_status_409_total');
const paymentCreate400s = new Counter('payment_create_status_400_total');
const paymentCreate401s = new Counter('payment_create_status_401_total');
const paymentCreate403s = new Counter('payment_create_status_403_total');
const paymentCreate422s = new Counter('payment_create_status_422_total');
const paymentCreate429s = new Counter('payment_create_status_429_total');
const paymentCreate5xxs = new Counter('payment_create_status_5xx_total');
const paymentCreateOtherErrors = new Counter('payment_create_status_other_total');
const paymentApproveAlreadyActive = new Counter('payment_approve_already_active_total');
const paymentApproveOtherErrors = new Counter('payment_approve_status_other_total');
const paymentApproveExpectedStatuses = http.expectedStatuses({ min: 200, max: 299 }, 400);

export const options = {
  vus,
  duration,
  setupTimeout,
  thresholds: {
    http_req_failed: ['rate<0.01'],
    payment_access_progress_success_rate: ['rate>0.99'],
    payment_create_duration_ms: ['p(95)<500'],
    payment_approve_duration_ms: ['p(95)<500'],
    payment_access_check_duration_ms: ['p(95)<250'],
    bonus_accrual_duration_ms: ['p(95)<300'],
    learning_complete_duration_ms: ['p(95)<500'],
    learning_student_progress_duration_ms: ['p(95)<250'],
    learning_parent_progress_duration_ms: ['p(95)<250'],
    learning_parent_completed_duration_ms: ['p(95)<250'],
  },
};

function jsonHeaders(extra = {}) {
  const headers = { 'Content-Type': 'application/json' };
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

function isAlreadyActiveAccessError(response) {
  return (
    response.status === 400 &&
    typeof response.body === 'string' &&
    response.body.indexOf('уже существует active доступ') !== -1
  );
}

function classifyPaymentCreateFailure(response) {
  if (response.status === 409) {
    paymentCreate409s.add(1);
  } else if (response.status === 400) {
    paymentCreate400s.add(1);
  } else if (response.status === 401) {
    paymentCreate401s.add(1);
  } else if (response.status === 403) {
    paymentCreate403s.add(1);
  } else if (response.status === 422) {
    paymentCreate422s.add(1);
  } else if (response.status === 429) {
    paymentCreate429s.add(1);
  } else if (response.status >= 500) {
    paymentCreate5xxs.add(1);
  } else {
    paymentCreateOtherErrors.add(1);
  }
}

function register(email, password, defaultRole) {
  const response = http.post(
    `${authBaseUrl}/v1/auth/register`,
    JSON.stringify({
      email,
      password,
      default_role: defaultRole,
    }),
    { headers: jsonHeaders(), tags: { endpoint: 'auth_register' } },
  );
  require2xx(response, `register ${email}`);
}

function login(email, password, fingerprint, clientName) {
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

function authMe(accessToken) {
  const response = http.get(`${authBaseUrl}/v1/auth/me`, {
    headers: { Authorization: `Bearer ${accessToken}` },
    tags: { endpoint: 'auth_me' },
  });
  require2xx(response, 'auth me');
  return response.json();
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
    JSON.stringify({
      parent_id: parentId,
      student_id: studentId,
      note: 'load-baseline',
    }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${accessToken}` }),
      tags: { endpoint: 'users_admin_link' },
    },
  );
  require2xx(response, `create parent-student link ${parentId}:${studentId}`);
}

function resolveOfferSnapshot(offerId) {
  const response = http.get(`${commercialCatalogBaseUrl}/internal/v1/offers/${offerId}`, {
    headers: { 'X-Service-Token': serviceToken },
    tags: { endpoint: 'commercial_catalog_offer_snapshot' },
  });
  require2xx(response, `resolve offer snapshot ${offerId}`);
  const courseId = response.json('course_id') || '';
  if (!courseId) {
    throw new Error(`offer snapshot ${offerId} returned empty course_id`);
  }
  return { courseId };
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
    accessCheckDuration.add(response.timings.duration);
    require2xx(response, `internal access check ${studentId}`);
    if (response.json('has_access') === true) {
      return;
    }
    sleep(0.2);
  }
  throw new Error(`internal access check did not become ready for student ${studentId}`);
}

function accrueBonus(parentId, suffix) {
  const response = http.post(
    `${bonusBaseUrl}/internal/v1/bonus/accruals`,
    JSON.stringify({
      parent_id: parentId,
      amount: bonusAmount,
      reason_code: 'k6_smoke_reward',
      reference_id: `k6-pay-${suffix}-${__VU}-${__ITER}`,
      idempotency_key: `k6-bonus-${suffix}-${__VU}-${__ITER}`,
    }),
    {
      headers: jsonHeaders({ 'X-Service-Token': bonusServiceToken }),
      tags: { endpoint: 'bonus_internal_accrual' },
    },
  );
  bonusAccrualDuration.add(response.timings.duration);
  const accrualOk = check(response, {
    'bonus accrual status is 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  if (!accrualOk) {
    bonusAccrualFailures.add(1);
    throw new Error(`bonus accrual failed: HTTP ${response.status} ${response.body}`);
  }
}

function buildScenario(index, adminToken) {
  const suffix = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}-${index}`;
  const parentEmail = `parent.pay.${suffix}@example.com`;
  register(parentEmail, parentPassword, 'parent');
  const parentToken = login(parentEmail, parentPassword, `k6-pay-parent-${suffix}`, 'k6-pay-parent');
  const parentMe = authMe(parentToken);
  const parentId = parentMe.account_id;
  createAdminUser(adminToken, {
    user_id: parentId,
    email: parentEmail,
    display_name: `Load Parent ${suffix}`,
    roles: ['parent'],
  });

  const studentEmail = `student.pay.${suffix}@example.com`;
  register(studentEmail, studentPassword, 'student');
  const studentToken = login(studentEmail, studentPassword, `k6-pay-student-${suffix}`, 'k6-pay-student');
  const studentMe = authMe(studentToken);
  const studentId = studentMe.user_id;
  createAdminUser(adminToken, {
    user_id: studentId,
    email: studentEmail,
    display_name: `Load Student ${suffix}`,
    roles: ['student'],
  });
  createParentStudentLink(adminToken, parentId, studentId);

  return {
    suffix,
    parentId,
    parentToken,
    studentId,
    studentToken,
  };
}

export function setup() {
  if (!paymentOfferId) {
    throw new Error('K6_PAYMENT_OFFER_ID is required');
  }
  if (learningEnabled && (!learningLesson1Id || !learningLesson2Id)) {
    throw new Error('K6_LEARNING_LESSON1_ID and K6_LEARNING_LESSON2_ID are required when K6_LEARNING_ENABLED=1');
  }

  const adminToken = login(adminEmail, adminPassword, `k6-pay-admin-${Date.now()}`, 'k6-pay-admin');
  const offer = resolveOfferSnapshot(paymentOfferId);
  const scenarios = [];
  for (let i = 0; i < scenarioPoolSize; i += 1) {
    scenarios.push({
      ...buildScenario(i + 1, adminToken),
      offerId: paymentOfferId,
      courseId: offer.courseId,
      lesson1Id: learningLesson1Id,
      lesson2Id: learningLesson2Id,
    });
  }
  return { adminToken, scenarios };
}

export default function (data) {
  const scenarios = data.scenarios || [];
  if (scenarios.length === 0) {
    throw new Error('setup did not provide scenarios');
  }
  const scenario = scenarios[(__VU - 1) % scenarios.length];

  if (bonusEnabled) {
    try {
      accrueBonus(scenario.parentId, scenario.suffix);
    } catch (_) {
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }
  }

  const paymentResponse = http.post(
    `${paymentsBaseUrl}/v1/parent/payments/intents`,
    JSON.stringify({
      parent_id: scenario.parentId,
      student_id: scenario.studentId,
      offer_id: scenario.offerId,
      bonus_amount: bonusEnabled ? bonusAmount : 0,
      idempotency_key: `k6-pay-${scenario.suffix}-${__VU}-${__ITER}`,
    }),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${scenario.parentToken}` }),
      tags: { endpoint: 'payments_create_intent' },
    },
  );
  paymentCreateDuration.add(paymentResponse.timings.duration);
  const paymentCreateOk = check(paymentResponse, {
    'payment intent status is 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  if (!paymentCreateOk) {
    paymentCreateFailures.add(1);
    classifyPaymentCreateFailure(paymentResponse);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }
  const paymentIntentId = paymentResponse.json('payment_intent_id') || '';
  if (!paymentIntentId) {
    paymentCreateFailures.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  const approveResponse = http.post(
    `${paymentsBaseUrl}/v1/admin/payments/${paymentIntentId}/approve`,
    JSON.stringify({}),
    {
      headers: jsonHeaders({ Authorization: `Bearer ${data.adminToken}` }),
      tags: { endpoint: 'payments_approve_intent' },
      responseCallback: paymentApproveExpectedStatuses,
    },
  );
  paymentApproveDuration.add(approveResponse.timings.duration);
  const approveStatus2xx = check(approveResponse, {
    'payment approve status is 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  const approveAlreadyActive = isAlreadyActiveAccessError(approveResponse);
  if (approveAlreadyActive) {
    paymentApproveAlreadyActive.add(1);
  }
  const approveOk = approveStatus2xx || approveAlreadyActive;
  if (!approveOk) {
    paymentApproveFailures.add(1);
    paymentApproveOtherErrors.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  try {
    waitForAccess(scenario.courseId, scenario.studentId);
  } catch (_) {
    accessCheckFailures.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  let complete1Ok = true;
  let complete2Ok = true;
  let studentProgressOk = true;
  let parentProgressOk = true;
  let parentCompletedOk = true;

  if (learningEnabled) {
    const complete1Response = http.post(
      `${courseBaseUrl}/v1/student/courses/${scenario.courseId}/lessons/${scenario.lesson1Id}/complete`,
      null,
      {
        headers: { Authorization: `Bearer ${scenario.studentToken}` },
        tags: { endpoint: 'student_complete_lesson_1' },
      },
    );
    lessonCompleteDuration.add(complete1Response.timings.duration);
    complete1Ok = check(complete1Response, {
      'complete lesson 1 status is 2xx': (r) => r.status >= 200 && r.status < 300,
    });
    if (!complete1Ok) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }

    const complete2Response = http.post(
      `${courseBaseUrl}/v1/student/courses/${scenario.courseId}/lessons/${scenario.lesson2Id}/complete`,
      null,
      {
        headers: { Authorization: `Bearer ${scenario.studentToken}` },
        tags: { endpoint: 'student_complete_lesson_2' },
      },
    );
    lessonCompleteDuration.add(complete2Response.timings.duration);
    complete2Ok = check(complete2Response, {
      'complete lesson 2 status is 2xx': (r) => r.status >= 200 && r.status < 300,
      'complete lesson 2 returns completed course': (r) => r.json('course_status') === 'completed',
    });
    if (!complete2Ok) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }

    const studentProgressResponse = http.get(
      `${courseBaseUrl}/v1/student/courses/${scenario.courseId}/progress`,
      {
        headers: { Authorization: `Bearer ${scenario.studentToken}` },
        tags: { endpoint: 'student_progress' },
      },
    );
    studentProgressDuration.add(studentProgressResponse.timings.duration);
    studentProgressOk = check(studentProgressResponse, {
      'student progress status is 200': (r) => r.status === 200,
      'student progress is 100': (r) => r.json('progress_percent') === 100 || r.json('progress_percent') === 100.0,
    });
    if (!studentProgressOk) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }

    const parentProgressResponse = http.get(
      `${courseBaseUrl}/v1/parent/students/${scenario.studentId}/courses/progress?status=completed&limit=10&offset=0`,
      {
        headers: { Authorization: `Bearer ${data.adminToken}` },
        tags: { endpoint: 'parent_progress' },
      },
    );
    parentProgressDuration.add(parentProgressResponse.timings.duration);
    parentProgressOk = check(parentProgressResponse, {
      'parent progress status is 200': (r) => r.status === 200,
      'parent progress contains completed course': (r) =>
        (r.json('items') || []).some(
          (item) => item.course_id === scenario.courseId && item.status === 'completed',
        ),
    });
    if (!parentProgressOk) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }

    const parentCompletedResponse = http.get(
      `${courseBaseUrl}/v1/parent/students/${scenario.studentId}/courses/completed?limit=10&offset=0`,
      {
        headers: { Authorization: `Bearer ${data.adminToken}` },
        tags: { endpoint: 'parent_completed' },
      },
    );
    parentCompletedDuration.add(parentCompletedResponse.timings.duration);
    parentCompletedOk = check(parentCompletedResponse, {
      'parent completed status is 200': (r) => r.status === 200,
      'parent completed contains course': (r) =>
        (r.json('items') || []).some(
          (item) => item.course_id === scenario.courseId && Boolean(item.completed_at),
        ),
    });
    if (!parentCompletedOk) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }
  }

  successRate.add(
    paymentCreateOk &&
      approveOk &&
      complete1Ok &&
      complete2Ok &&
      studentProgressOk &&
      parentProgressOk &&
      parentCompletedOk,
  );
  sleep(thinkTimeSeconds);
}
