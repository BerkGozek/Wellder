// Domain model shared by every backend component.
// The Swift mirror of these types lives in packages/WellderKit/Sources/SharedModels.
// Keep the two in sync; the JSON wire format is the contract (see docs/api.md).

export type Role = 'alpha' | 'beta';

export interface UserProfile {
  userId: string;
  name: string;
  email: string;
  phoneNumber?: string;
  roles: Role[];
  authenticationProvider: 'cognito' | 'dev';
  createdAt: string;
  updatedAt: string;
}

// ---------- Relationships ----------

export const PERMISSIONS = [
  'viewLocation',
  'viewMovementHistory',
  'viewHeartRate',
  'viewActivity',
  'receiveAlerts',
  'manageSettings',
  'manageEmergencyContacts',
] as const;
export type Permission = (typeof PERMISSIONS)[number];
export type PermissionSet = Record<Permission, boolean>;

export type RelationshipStatus = 'pendingAlphaApproval' | 'active' | 'rejected' | 'revoked';

export interface MonitoringRelationship {
  relationshipId: string; // `${alphaId}.${betaId}` — deterministic, one per pair
  alphaId: string;
  betaId: string;
  alphaName: string;
  betaName: string;
  betaEmail: string;
  permissions: PermissionSet;
  status: RelationshipStatus;
  createdAt: string;
  approvedAt?: string;
  revokedAt?: string;
  revokedBy?: 'alpha' | 'beta';
}

export interface Invitation {
  invitationId: string;
  alphaId: string;
  alphaName: string;
  permissions: PermissionSet;
  createdAt: string;
  expiresAt: string;
  codeHint: string; // last 2 characters only; the full code is never stored
}

// ---------- Devices ----------

export type MonitoringState =
  | 'active'
  | 'reduced'
  | 'night'
  | 'temporarilyDisconnected'
  | 'permissionsUnavailable'
  | 'dataStale'
  | 'disabled';

export interface DeviceCapabilities {
  healthKit: boolean;
  heartRate: boolean;
  backgroundLocation: boolean;
  motionActivity: boolean;
  pedometer: boolean;
  systemFallDetection: boolean; // CMFallDetectionManager (requires Apple-granted entitlement)
  experimentalFallDetection: boolean;
  pushNotifications: boolean;
}

export interface Device {
  deviceId: string;
  userId: string;
  deviceType: 'iPhone' | 'appleWatch';
  model?: string;
  osVersion?: string;
  appVersion: string;
  apnsToken?: string;
  apnsEnvironment?: 'sandbox' | 'production';
  capabilities: DeviceCapabilities;
  monitoringState: MonitoringState;
  batteryLevel?: number; // 0...1
  lastSeen: string;
}

// ---------- Telemetry ----------

export type ActivityType = 'stationary' | 'walking' | 'running' | 'cycling' | 'automotive' | 'unknown';
export type Confidence = 'low' | 'medium' | 'high';

interface SampleBase {
  sampleId: string; // client-generated UUID; makes uploads idempotent
  timestamp: string; // ISO-8601, when the measurement was taken (not when uploaded)
  simulated?: boolean;
}

export interface HeartRateSample extends SampleBase {
  kind: 'heartRate';
  bpm: number;
  sourceDevice: string;
}

export interface LocationSample extends SampleBase {
  kind: 'location';
  latitude: number;
  longitude: number;
  horizontalAccuracy: number; // metres
  source: 'standard' | 'significantChange' | 'visit';
}

export interface ActivitySample extends SampleBase {
  kind: 'activity';
  activityType: ActivityType;
  confidence: Confidence;
}

export interface StepsSample extends SampleBase {
  kind: 'steps';
  count: number;
  endTimestamp: string; // steps counted in [timestamp, endTimestamp)
}

export interface InteractionSample extends SampleBase {
  kind: 'interaction';
  source: 'app' | 'checkIn' | 'watchApp';
}

export type TelemetrySample = HeartRateSample | LocationSample | ActivitySample | StepsSample | InteractionSample;
export type SampleKind = TelemetrySample['kind'];

// Events are discrete, safety-relevant occurrences reported by the device.
export type DeviceEventType =
  | 'fallCandidate' // experimental detector fired; Alpha is being asked "Are you okay?"
  | 'systemFallDetected' // CMFallDetectionManager reported a fall (with its own resolution)
  | 'fallUserOk' // Alpha answered "I'm okay"
  | 'fallNeedHelp' // Alpha answered "I need help"
  | 'fallNoResponse' // countdown expired on the device without an answer
  | 'manualHelpRequest' // Alpha pressed the help button
  | 'lowBattery'
  | 'locationUnavailable';

export interface DeviceEvent {
  eventId: string; // client-generated UUID; idempotency key
  type: DeviceEventType;
  detectedAt: string;
  relatedEventId?: string; // e.g. fallUserOk refers to the fallCandidate it answers
  confidence?: number; // 0...1 for fall candidates
  countdownSeconds?: number; // how long the device will wait for an answer
  details?: Record<string, string | number | boolean>;
  simulated?: boolean;
}

// ---------- Alerts ----------

export type AlertType =
  | 'possibleFall'
  | 'heartRateHigh'
  | 'heartRateLow'
  | 'prolongedInactivity'
  | 'manualHelpRequest'
  | 'monitoringInterrupted'
  | 'deviceDisconnected'
  | 'lowBattery'
  | 'locationUnavailable';

export type AlertCategory = 'safety' | 'technical';
export type AlertSeverity = 'critical' | 'warning' | 'info';

// Lifecycle (see docs/architecture.md#alerts):
//   awaitingAlphaResponse → open → acknowledged → resolved
//   awaitingAlphaResponse → resolved (Alpha said "I'm okay")
export type AlertStatus = 'awaitingAlphaResponse' | 'open' | 'acknowledged' | 'resolved';

export interface Alert {
  alertId: string;
  alphaId: string;
  type: AlertType;
  category: AlertCategory;
  severity: AlertSeverity;
  status: AlertStatus;
  title: string;
  message: string;
  simulated: boolean;
  sourceEventId?: string;
  occurrences: number; // deduplicated repeats folded into this alert
  // Each stage is timestamped separately; one never implies another.
  detectedAt: string; // when the device / evaluator detected the condition
  receivedAt: string; // when the backend recorded it
  firstNotificationSentAt?: string; // a provider accepted a notification
  firstDeliveryConfirmedAt?: string; // only set when a channel can confirm delivery
  acknowledgedAt?: string;
  acknowledgedBy?: string;
  resolvedAt?: string;
  resolvedBy?: string;
  resolution?: 'alphaOk' | 'betaResolved' | 'conditionCleared' | 'falseAlarm';
  escalationStep: number;
  nextEscalationAt?: string;
  retentionDays: number;
  cooldownSeconds?: number; // started when the alert resolves
  evidence?: Record<string, string | number | boolean>;
}

export type DeliveryChannel = 'inApp' | 'push' | 'sms' | 'voice';
export type DeliveryStatus = 'sent' | 'delivered' | 'failed' | 'skipped';

export interface AlertDelivery {
  deliveryId: string;
  alertId: string;
  alphaId: string;
  betaId: string;
  channel: DeliveryChannel;
  escalationStep: number;
  status: DeliveryStatus;
  attemptedAt: string;
  deliveredAt?: string;
  providerMessageId?: string;
  detail?: string; // e.g. "SMS disabled in settings" — never contains health data
}

// ---------- Settings ----------

export interface SleepSchedule {
  enabled: boolean;
  bedtime: string; // "HH:mm" local
  wakeTime: string; // "HH:mm" local
  timeZone: string; // IANA identifier
  keepFallDetectionAtNight: boolean;
  override?: { mode: 'forceNight' | 'forceDay'; until: string };
}

export interface EmergencyContact {
  name: string;
  phoneNumber: string;
  relation?: string;
}

export interface MonitoringSettings {
  alphaId: string;
  version: number; // optimistic concurrency
  sleepSchedule: SleepSchedule;
  heartRate: {
    enabled: boolean;
    upperBpm: number;
    lowerBpm: number;
    persistenceSeconds: number; // abnormal readings must span at least this long
    cooldownSeconds: number;
  };
  movement: {
    enabled: boolean;
    locationEnabled: boolean;
    inactivityThresholdMinutes: number;
    locationHistoryRetentionDays: number;
  };
  fallDetection: {
    experimentalEnabled: boolean;
    systemFallDetectionEnabled: boolean;
    confirmationCountdownSeconds: number;
  };
  notifications: {
    push: boolean;
    sms: boolean;
    voice: boolean;
    escalationDelaySeconds: number;
    contactOrder: string[]; // betaIds, highest priority first
  };
  emergency: {
    // Automatic emergency-services contact is not implemented and cannot be enabled
    // through the API (see docs/architecture.md#emergency-services).
    automaticEmergencyServices: false;
    emergencyNumber: string; // used only by the manual "Call emergency services" button
    contacts: EmergencyContact[];
  };
  dataRetention: {
    telemetryDays: number;
    alertDays: number;
  };
  staleAfterMinutes: number;
  updatedAt: string;
  updatedBy: string;
}

export type SettingsSection = keyof Omit<MonitoringSettings, 'alphaId' | 'version' | 'updatedAt' | 'updatedBy'>;

export interface SettingsChangeRequest {
  requestId: string;
  alphaId: string;
  requestedBy: string;
  requestedByName: string;
  changes: Partial<Pick<MonitoringSettings, SettingsSection>>;
  reason?: string;
  status: 'pending' | 'approved' | 'rejected' | 'superseded';
  createdAt: string;
  decidedAt?: string;
}

export interface AuditEntry {
  auditId: string;
  alphaId: string;
  actorId: string;
  action: string; // e.g. "relationship.approved", "settings.updated"
  at: string;
  detail?: Record<string, string | number | boolean>;
}

// Per-Alpha snapshot that powers the dashboard without scanning telemetry.
export interface MonitorSnapshot {
  alphaId: string;
  lastSyncAt?: string;
  lastHeartRate?: { bpm: number; timestamp: string; sourceDevice: string };
  lastLocation?: { latitude: number; longitude: number; horizontalAccuracy: number; timestamp: string };
  lastActivity?: { activityType: ActivityType; confidence: Confidence; timestamp: string };
  lastMovementAt?: string;
  lastInteractionAt?: string;
  recentSteps?: { count: number; from: string; to: string };
  monitoringState?: MonitoringState;
  batteryLevel?: number;
  simulated?: boolean;
}
