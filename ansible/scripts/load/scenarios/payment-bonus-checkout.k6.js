import paymentAccessProgressDefault, {
  options as paymentAccessProgressOptions,
  setup as paymentAccessProgressSetup,
} from './payment-access-progress.k6.js';

export const options = paymentAccessProgressOptions;

export function setup() {
  return paymentAccessProgressSetup();
}

export default paymentAccessProgressDefault;
