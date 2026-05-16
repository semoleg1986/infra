import http from 'k6/http';
import { check } from 'k6';

export function completeLesson({ courseBaseUrl, studentToken, courseId, lessonId, endpointTag, expectedCourseStatus = null }) {
  const response = http.post(
    `${courseBaseUrl}/v1/student/courses/${courseId}/lessons/${lessonId}/complete`,
    null,
    {
      headers: { Authorization: `Bearer ${studentToken}` },
      tags: { endpoint: endpointTag },
    },
  );
  const checks = {
    [`${endpointTag} status is 2xx`]: (r) => r.status >= 200 && r.status < 300,
  };
  if (expectedCourseStatus) {
    checks[`${endpointTag} course status matches`] = (r) => r.json('course_status') === expectedCourseStatus;
  }
  return { response, ok: check(response, checks) };
}

export function checkStudentProgress({ courseBaseUrl, studentToken, courseId }) {
  const response = http.get(`${courseBaseUrl}/v1/student/courses/${courseId}/progress`, {
    headers: { Authorization: `Bearer ${studentToken}` },
    tags: { endpoint: 'student_progress' },
  });
  return {
    response,
    ok: check(response, {
      'student progress status is 200': (r) => r.status === 200,
      'student progress is 100': (r) => r.json('progress_percent') === 100 || r.json('progress_percent') === 100.0,
    }),
  };
}

export function checkParentProgress({ courseBaseUrl, adminToken, studentId, courseId }) {
  const response = http.get(
    `${courseBaseUrl}/v1/parent/students/${studentId}/courses/progress?status=completed&limit=10&offset=0`,
    {
      headers: { Authorization: `Bearer ${adminToken}` },
      tags: { endpoint: 'parent_progress' },
    },
  );
  return {
    response,
    ok: check(response, {
      'parent progress status is 200': (r) => r.status === 200,
      'parent progress contains completed course': (r) =>
        (r.json('items') || []).some((item) => item.course_id === courseId && item.status === 'completed'),
    }),
  };
}

export function checkParentCompleted({ courseBaseUrl, adminToken, studentId, courseId }) {
  const response = http.get(
    `${courseBaseUrl}/v1/parent/students/${studentId}/courses/completed?limit=10&offset=0`,
    {
      headers: { Authorization: `Bearer ${adminToken}` },
      tags: { endpoint: 'parent_completed' },
    },
  );
  return {
    response,
    ok: check(response, {
      'parent completed status is 200': (r) => r.status === 200,
      'parent completed contains course': (r) =>
        (r.json('items') || []).some((item) => item.course_id === courseId && Boolean(item.completed_at)),
    }),
  };
}
