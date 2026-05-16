import http from 'k6/http';
import { require2xx } from './http.js';

export function resolveOfferSnapshot({ commercialCatalogBaseUrl, serviceToken, offerId }) {
  const response = http.get(`${commercialCatalogBaseUrl}/internal/v1/offers/${offerId}`, {
    headers: { 'X-Service-Token': serviceToken },
    tags: { endpoint: 'commercial_catalog_offer_snapshot' },
  });
  require2xx(response, `resolve offer snapshot ${offerId}`);
  const courseId = response.json('course_id') || '';
  if (!courseId) {
    throw new Error(`offer snapshot ${offerId} returned empty course_id`);
  }
  return { courseId, response };
}
