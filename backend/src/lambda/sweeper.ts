import { sweep } from '../services/sweeper.ts';
import { lambdaDeps } from './runtime.ts';

/** Invoked by an EventBridge schedule (rate 1 minute). */
export async function handler() {
  return sweep(await lambdaDeps());
}
