import type { HeartRateSample, MonitoringSettings } from './types.ts';

export interface HeartRateFinding {
  direction: 'high' | 'low';
  firstAbnormalAt: string;
  lastAbnormalAt: string;
  readings: number;
  extremeBpm: number;
}

/**
 * Evaluates the trailing run of consecutive abnormal readings (same direction) ending at the
 * newest sample. Readings from Apple Watch are periodic, not continuous, so "persistence" is
 * measured between the first and last abnormal reading in the run. A persistence of 0 means a
 * single abnormal reading is enough.
 */
export function evaluateHeartRate(
  samples: HeartRateSample[],
  thresholds: MonitoringSettings['heartRate'],
): HeartRateFinding | null {
  if (!thresholds.enabled || samples.length === 0) return null;
  const sorted = [...samples].sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
  const classify = (bpm: number): 'high' | 'low' | null =>
    bpm > thresholds.upperBpm ? 'high' : bpm < thresholds.lowerBpm ? 'low' : null;

  const newest = sorted[sorted.length - 1];
  if (!newest) return null;
  const direction = classify(newest.bpm);
  if (!direction) return null;

  let first = newest;
  let extreme = newest.bpm;
  let readings = 0;
  for (let i = sorted.length - 1; i >= 0; i--) {
    const s = sorted[i];
    if (!s || classify(s.bpm) !== direction) break;
    first = s;
    readings++;
    extreme = direction === 'high' ? Math.max(extreme, s.bpm) : Math.min(extreme, s.bpm);
  }
  const spanSeconds = (Date.parse(newest.timestamp) - Date.parse(first.timestamp)) / 1000;
  if (thresholds.persistenceSeconds > 0 && (readings < 2 || spanSeconds < thresholds.persistenceSeconds)) {
    return null;
  }
  return {
    direction,
    firstAbnormalAt: first.timestamp,
    lastAbnormalAt: newest.timestamp,
    readings,
    extremeBpm: extreme,
  };
}
