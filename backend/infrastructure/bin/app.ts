import { App } from 'aws-cdk-lib';
import { WellderStack } from '../lib/stack.ts';

// Usage: npm run synth            (no AWS account needed; nothing is deployed)
//        npx cdk deploy -c stage=dev -c cognitoDomainPrefix=<unique> ...  (see docs/deployment.md)
const app = new App();
const stage = (app.node.tryGetContext('stage') as string | undefined) ?? 'dev';
if (!['dev', 'staging', 'prod'].includes(stage)) throw new Error(`Unknown stage "${stage}"`);

// Stack name kept from the project's original name: renaming it would create a second, empty
// backend (new table and user pool) instead of updating the deployed one.
new WellderStack(app, `AlphaBeta-${stage}`, {
  stage: stage as 'dev' | 'staging' | 'prod',
  cognitoDomainPrefix: (app.node.tryGetContext('cognitoDomainPrefix') as string | undefined) ?? `wellder-${stage}-change-me`,
  apnsSecretArn: app.node.tryGetContext('apnsSecretArn') as string | undefined,
  apnsEnvironmentDefault: 'sandbox',
  twilioSecretArn: app.node.tryGetContext('twilioSecretArn') as string | undefined,
  // Paid channels stay off unless explicitly enabled at deploy time.
  smsProvider: (app.node.tryGetContext('smsProvider') as string | undefined) === 'twilio' ? 'twilio' : 'disabled',
  voiceProvider: (app.node.tryGetContext('voiceProvider') as string | undefined) === 'twilio' ? 'twilio' : 'disabled',
  alarmEmail: app.node.tryGetContext('alarmEmail') as string | undefined,
  ...(process.env.CDK_DEFAULT_ACCOUNT ? { env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION } } : {}),
});
