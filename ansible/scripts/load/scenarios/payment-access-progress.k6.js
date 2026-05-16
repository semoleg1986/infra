import { check, sleep } from 'k6';
import http from 'k6/http';
import exec from 'k6/execution';
import { Counter, Rate, Trend } from 'k6/metrics';
import { authMe, login, register } from '../shared/http.js';
import { createAdminUser, createParentStudentLink } from '../shared/users.js';
import { resolveOfferSnapshot } from '../shared/catalog.js';
import { approvePaymentIntent, createPaymentIntent, waitForAccess } from '../shared/payments.js';
import { accrueBonus } from '../shared/bonus.js';
import { checkParentCompleted, checkParentProgress, checkStudentProgress, completeLesson } from '../shared/learning.js';

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
  scenarios: {
    default: {
      executor: 'shared-iterations',
      vus: Math.min(vus, scenarioPoolSize),
      iterations: scenarioPoolSize,
      maxDuration: duration,
    },
  },
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

function buildScenario(index, adminToken) {
  const suffix = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}-${index}`;
  const parentEmail = `parent.pay.${suffix}@example.com`;
  register({ authBaseUrl, email: parentEmail, password: parentPassword, defaultRole: 'parent' });
  const parentToken = login({ authBaseUrl, email: parentEmail, password: parentPassword, fingerprint: `k6-pay-parent-${suffix}`, clientName: 'k6-pay-parent' });
  const parentMe = authMe({ authBaseUrl, accessToken: parentToken });
  const parentId = parentMe.account_id;
  createAdminUser({
    usersBaseUrl,
    accessToken: adminToken,
    payload: { user_id: parentId, email: parentEmail, display_name: `Load Parent ${suffix}`, roles: ['parent'] },
  });

  const studentEmail = `student.pay.${suffix}@example.com`;
  register({ authBaseUrl, email: studentEmail, password: studentPassword, defaultRole: 'student' });
  const studentToken = login({ authBaseUrl, email: studentEmail, password: studentPassword, fingerprint: `k6-pay-student-${suffix}`, clientName: 'k6-pay-student' });
  const studentMe = authMe({ authBaseUrl, accessToken: studentToken });
  const studentId = studentMe.user_id;
  createAdminUser({
    usersBaseUrl,
    accessToken: adminToken,
    payload: { user_id: studentId, email: studentEmail, display_name: `Load Student ${suffix}`, roles: ['student'] },
  });
  createParentStudentLink({ usersBaseUrl, accessToken: adminToken, parentId, studentId });

  return { suffix, parentId, parentToken, studentId, studentToken };
}

export function setup() {
  if (!paymentOfferId) {
    throw new Error('K6_PAYMENT_OFFER_ID is required');
  }
  if (learningEnabled && (!learningLesson1Id || !learningLesson2Id)) {
    throw new Error('K6_LEARNING_LESSON1_ID and K6_LEARNING_LESSON2_ID are required when K6_LEARNING_ENABLED=1');
  }

  const adminToken = login({ authBaseUrl, email: adminEmail, password: adminPassword, fingerprint: `k6-pay-admin-${Date.now()}`, clientName: 'k6-pay-admin' });
  const offer = resolveOfferSnapshot({ commercialCatalogBaseUrl, serviceToken, offerId: paymentOfferId });
  const scenarios = [];
  for (let i = 0; i < scenarioPoolSize; i += 1) {
    const scenario = buildScenario(i + 1, adminToken);
    scenario.offerId = paymentOfferId;
    scenario.courseId = offer.courseId;
    scenario.lesson1Id = learningLesson1Id;
    scenario.lesson2Id = learningLesson2Id;
    scenarios.push(scenario);
  }
  return { adminToken, scenarios };
}

export default function (data) {
  const scenarios = data.scenarios || [];
  if (scenarios.length === 0) {
    throw new Error('setup did not provide scenarios');
  }
  const scenarioIndex = exec.scenario.iterationInTest;
  const scenario = scenarios[scenarioIndex];
  if (!scenario) {
    throw new Error(`setup scenario missing for iteration ${scenarioIndex}`);
  }

  if (bonusEnabled) {
    const accrual = accrueBonus({ bonusBaseUrl, bonusServiceToken, parentId: scenario.parentId, amount: bonusAmount, suffix: scenario.suffix, vu: __VU, iter: __ITER });
    bonusAccrualDuration.add(accrual.response.timings.duration);
    if (!accrual.ok) {
      bonusAccrualFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }
  }

  const payment = createPaymentIntent({
    paymentsBaseUrl,
    parentToken: scenario.parentToken,
    parentId: scenario.parentId,
    studentId: scenario.studentId,
    offerId: scenario.offerId,
    bonusAmount: bonusEnabled ? bonusAmount : 0,
    idempotencyKey: `k6-pay-${scenario.suffix}-${__VU}-${__ITER}`,
  });
  paymentCreateDuration.add(payment.response.timings.duration);
  if (!payment.ok) {
    paymentCreateFailures.add(1);
    classifyPaymentCreateFailure(payment.response);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }
  if (!payment.paymentIntentId) {
    paymentCreateFailures.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  const approval = approvePaymentIntent({
    paymentsBaseUrl,
    adminToken: data.adminToken,
    paymentIntentId: payment.paymentIntentId,
    responseCallback: paymentApproveExpectedStatuses,
  });
  paymentApproveDuration.add(approval.response.timings.duration);
  if (approval.alreadyActive) {
    paymentApproveAlreadyActive.add(1);
  }
  if (!approval.ok) {
    paymentApproveFailures.add(1);
    paymentApproveOtherErrors.add(1);
    successRate.add(false);
    sleep(thinkTimeSeconds);
    return;
  }

  try {
    const accessResponse = waitForAccess({ paymentsBaseUrl, serviceToken, courseId: scenario.courseId, studentId: scenario.studentId, sleepFn: sleep });
    accessCheckDuration.add(accessResponse.timings.duration);
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
    const complete1 = completeLesson({ courseBaseUrl, studentToken: scenario.studentToken, courseId: scenario.courseId, lessonId: scenario.lesson1Id, endpointTag: 'student_complete_lesson_1' });
    lessonCompleteDuration.add(complete1.response.timings.duration);
    complete1Ok = complete1.ok;
    if (!complete1Ok) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }

    const complete2 = completeLesson({ courseBaseUrl, studentToken: scenario.studentToken, courseId: scenario.courseId, lessonId: scenario.lesson2Id, endpointTag: 'student_complete_lesson_2', expectedCourseStatus: 'completed' });
    lessonCompleteDuration.add(complete2.response.timings.duration);
    complete2Ok = complete2.ok;
    if (!complete2Ok) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }

    const studentProgress = checkStudentProgress({ courseBaseUrl, studentToken: scenario.studentToken, courseId: scenario.courseId });
    studentProgressDuration.add(studentProgress.response.timings.duration);
    studentProgressOk = studentProgress.ok;
    if (!studentProgressOk) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }

    const parentProgress = checkParentProgress({ courseBaseUrl, adminToken: data.adminToken, studentId: scenario.studentId, courseId: scenario.courseId });
    parentProgressDuration.add(parentProgress.response.timings.duration);
    parentProgressOk = parentProgress.ok;
    if (!parentProgressOk) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }

    const parentCompleted = checkParentCompleted({ courseBaseUrl, adminToken: data.adminToken, studentId: scenario.studentId, courseId: scenario.courseId });
    parentCompletedDuration.add(parentCompleted.response.timings.duration);
    parentCompletedOk = parentCompleted.ok;
    if (!parentCompletedOk) {
      learningFailures.add(1);
      successRate.add(false);
      sleep(thinkTimeSeconds);
      return;
    }
  }

  successRate.add(payment.ok && approval.ok && complete1Ok && complete2Ok && studentProgressOk && parentProgressOk && parentCompletedOk);
  sleep(thinkTimeSeconds);
}
