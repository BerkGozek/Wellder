import { GetSecretValueCommand, SecretsManagerClient } from '@aws-sdk/client-secrets-manager';
import { ApnsPushProvider, type ApnsCredentials } from './notify/apns.ts';
import {
  DisabledPushProvider,
  DisabledSmsProvider,
  DisabledVoiceProvider,
  RecordingPushProvider,
  RecordingSmsProvider,
  RecordingVoiceProvider,
  type PushProvider,
  type SmsProvider,
  type VoiceProvider,
} from './notify/providers.ts';
import { TwilioSmsProvider, TwilioVoiceProvider, type TwilioCredentials } from './notify/twilio.ts';

export interface Providers {
  push: PushProvider;
  sms: SmsProvider;
  voice: VoiceProvider;
}

type Env = Record<string, string | undefined>;

async function readSecret<T>(arn: string | undefined, what: string): Promise<T> {
  if (!arn) throw new Error(`${what} selected but its secret ARN env var is not set`);
  const res = await new SecretsManagerClient({}).send(new GetSecretValueCommand({ SecretId: arn }));
  if (!res.SecretString) throw new Error(`${what} secret is empty`);
  return JSON.parse(res.SecretString) as T;
}

/**
 * Builds delivery providers from environment configuration. Defaults are the safe ones:
 * push is recorded locally, SMS and voice are disabled. Paid channels require BOTH an explicit
 * provider setting and credentials in AWS Secrets Manager.
 */
export async function providersFromEnv(env: Env): Promise<Providers> {
  const pushMode = env.PUSH_PROVIDER ?? 'log';
  const smsMode = env.SMS_PROVIDER ?? 'disabled';
  const voiceMode = env.VOICE_PROVIDER ?? 'disabled';

  const push: PushProvider =
    pushMode === 'apns'
      ? new ApnsPushProvider(await readSecret<ApnsCredentials>(env.APNS_SECRET_ARN, 'APNs'))
      : pushMode === 'log'
        ? new RecordingPushProvider()
        : new DisabledPushProvider();

  const twilio = smsMode === 'twilio' || voiceMode === 'twilio' ? await readSecret<TwilioCredentials>(env.TWILIO_SECRET_ARN, 'Twilio') : undefined;
  const sms: SmsProvider =
    smsMode === 'twilio' && twilio ? new TwilioSmsProvider(twilio) : smsMode === 'log' ? new RecordingSmsProvider() : new DisabledSmsProvider();
  const voice: VoiceProvider =
    voiceMode === 'twilio' && twilio ? new TwilioVoiceProvider(twilio) : voiceMode === 'log' ? new RecordingVoiceProvider() : new DisabledVoiceProvider();
  return { push, sms, voice };
}
