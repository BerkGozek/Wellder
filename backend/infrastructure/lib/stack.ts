import { CfnOutput, Duration, RemovalPolicy, Stack, type StackProps } from 'aws-cdk-lib';
import { CorsHttpMethod, HttpApi, HttpMethod, HttpStage } from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpJwtAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import { Alarm, ComparisonOperator, TreatMissingData } from 'aws-cdk-lib/aws-cloudwatch';
import { SnsAction } from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import { AttributeType, BillingMode, Table, TableEncryption } from 'aws-cdk-lib/aws-dynamodb';
import { Rule, Schedule } from 'aws-cdk-lib/aws-events';
import { LambdaFunction } from 'aws-cdk-lib/aws-events-targets';
import { PolicyStatement } from 'aws-cdk-lib/aws-iam';
import { Architecture, Runtime } from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction, OutputFormat } from 'aws-cdk-lib/aws-lambda-nodejs';
import { LogGroup, RetentionDays } from 'aws-cdk-lib/aws-logs';
import { Secret } from 'aws-cdk-lib/aws-secretsmanager';
import { Topic } from 'aws-cdk-lib/aws-sns';
import { EmailSubscription } from 'aws-cdk-lib/aws-sns-subscriptions';
import type { Construct } from 'constructs';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export interface WellderStackProps extends StackProps {
  stage: 'dev' | 'staging' | 'prod';
  cognitoDomainPrefix: string;
  apnsSecretArn?: string; // JSON: { teamId, keyId, privateKey, bundleId }
  apnsEnvironmentDefault: 'sandbox' | 'production';
  twilioSecretArn?: string; // JSON: { accountSid, authToken, fromNumber }
  smsProvider: 'disabled' | 'twilio';
  voiceProvider: 'disabled' | 'twilio';
  alarmEmail?: string;
}

const backendRoot = fileURLToPath(new URL('../../', import.meta.url));
const src = (p: string) => fileURLToPath(new URL(`../../src/${p}`, import.meta.url));

export class WellderStack extends Stack {
  constructor(scope: Construct, id: string, props: WellderStackProps) {
    super(scope, id, props);
    const prod = props.stage === 'prod';

    // ---------- Data ----------
    // Single table; key design in src/store/repository.ts. Encrypted at rest with a KMS key,
    // point-in-time recovery on, telemetry expires via TTL.
    const table = new Table(this, 'Table', {
      partitionKey: { name: 'pk', type: AttributeType.STRING },
      sortKey: { name: 'sk', type: AttributeType.STRING },
      billingMode: BillingMode.PAY_PER_REQUEST,
      encryption: TableEncryption.AWS_MANAGED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      timeToLiveAttribute: 'ttl',
      deletionProtection: prod,
      removalPolicy: prod ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });
    for (const g of ['gsi1', 'gsi2']) {
      table.addGlobalSecondaryIndex({
        indexName: g,
        partitionKey: { name: `${g}pk`, type: AttributeType.STRING },
        sortKey: { name: `${g}sk`, type: AttributeType.STRING },
      });
    }

    // ---------- Identity ----------
    const userPool = new cognito.UserPool(this, 'Users', {
      selfSignUpEnabled: true,
      signInAliases: { email: true },
      autoVerify: { email: true },
      standardAttributes: { email: { required: true, mutable: true } },
      passwordPolicy: { minLength: 10, requireLowercase: true, requireUppercase: true, requireDigits: true, requireSymbols: false },
      mfa: cognito.Mfa.OPTIONAL,
      mfaSecondFactor: { otp: true, sms: false },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      // Essentials unlocks the modern Managed Login branding editor/API (the Lite plan only has
      // the legacy Hosted UI). See the managed-login branding block below.
      featurePlan: cognito.FeaturePlan.ESSENTIALS,
      removalPolicy: prod ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });
    // managedLoginVersion: NEWER_MANAGED_LOGIN serves the redesigned sign-in experience that the
    // CfnManagedLoginBranding below styles (CLASSIC_HOSTED_UI ignores managed-login branding).
    const domain = userPool.addDomain('Domain', {
      cognitoDomain: { domainPrefix: props.cognitoDomainPrefix },
      managedLoginVersion: cognito.ManagedLoginVersion.NEWER_MANAGED_LOGIN,
    });
    const callback = 'wellder://auth/callback';
    const appClient = userPool.addClient('IosApp', {
      generateSecret: false, // public native client: authorization code + PKCE
      authFlows: { userSrp: true },
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: [callback],
        logoutUrls: ['wellder://auth/signout'],
      },
      preventUserExistenceErrors: true,
      enableTokenRevocation: true,
      idTokenValidity: Duration.hours(1),
      accessTokenValidity: Duration.hours(1),
      refreshTokenValidity: Duration.days(30),
    });

    // Managed Login branding for the Hosted UI the iOS app opens via ASWebAuthenticationSession.
    // `settings` overrides the brand accents and `assets` supplies the logo (a hand-authored
    // welder's-mask SVG read + base64-encoded at synth time). Refine colours/logo here (not in the
    // console) so the look is reproducible and survives a dev-stack teardown.
    const brandColor = '#0A7E8C'; // Wellder accent; change to taste
    const logoSvg = readFileSync(fileURLToPath(new URL('../assets/welder-mask.svg', import.meta.url)));
    const branding = new cognito.CfnManagedLoginBranding(this, 'LoginBranding', {
      userPoolId: userPool.userPoolId,
      clientId: appClient.userPoolClientId,
      useCognitoProvidedValues: false,
      returnMergedResources: true,
      assets: [
        {
          category: 'FORM_LOGO',
          colorMode: 'DYNAMIC', // same asset in light and dark mode
          extension: 'svg',
          bytes: logoSvg.toString('base64'),
          resourceId: 'form-logo',
        },
      ],
      settings: {
        components: {
          primaryButton: {
            lightMode: {
              defaults: { backgroundColor: brandColor, textColor: 'ffffffff' },
              hover: { backgroundColor: '086975ff', textColor: 'ffffffff' },
            },
            darkMode: {
              defaults: { backgroundColor: brandColor, textColor: 'ffffffff' },
              hover: { backgroundColor: '0b96a6ff', textColor: 'ffffffff' },
            },
          },
        },
      },
    });
    // Branding reads the pool's managed-login version, so make the ordering explicit.
    branding.node.addDependency(domain);

    // ---------- Secrets (created out-of-band; never in this repo) ----------
    const apnsSecret = props.apnsSecretArn ? Secret.fromSecretCompleteArn(this, 'ApnsSecret', props.apnsSecretArn) : undefined;
    const twilioSecret = props.twilioSecretArn ? Secret.fromSecretCompleteArn(this, 'TwilioSecret', props.twilioSecretArn) : undefined;
    if ((props.smsProvider === 'twilio' || props.voiceProvider === 'twilio') && !twilioSecret) {
      throw new Error('smsProvider/voiceProvider=twilio requires -c twilioSecretArn=...');
    }

    // ---------- Compute ----------
    const environment: Record<string, string> = {
      TABLE_NAME: table.tableName,
      AUTH_MODE: 'cognito',
      STAGE: props.stage,
      PUSH_PROVIDER: apnsSecret ? 'apns' : 'disabled',
      SMS_PROVIDER: props.smsProvider,
      VOICE_PROVIDER: props.voiceProvider,
      ...(apnsSecret ? { APNS_SECRET_ARN: apnsSecret.secretArn } : {}),
      ...(twilioSecret ? { TWILIO_SECRET_ARN: twilioSecret.secretArn } : {}),
      NODE_OPTIONS: '--enable-source-maps',
    };
    const fn = (name: string, entry: string, timeout: Duration) => {
      const f = new NodejsFunction(this, name, {
        entry: src(entry),
        handler: 'handler',
        projectRoot: backendRoot,
        depsLockFilePath: `${backendRoot}package-lock.json`,
        runtime: Runtime.NODEJS_22_X,
        architecture: Architecture.ARM_64,
        memorySize: 512,
        timeout,
        environment,
        logGroup: new LogGroup(this, `${name}Logs`, {
          retention: prod ? RetentionDays.THREE_MONTHS : RetentionDays.TWO_WEEKS,
          removalPolicy: RemovalPolicy.DESTROY,
        }),
        bundling: {
          format: OutputFormat.ESM,
          target: 'node22',
          sourceMap: true,
          minify: true,
          externalModules: ['@aws-sdk/*'], // provided by the Lambda runtime
          banner: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);",
        },
      });
      table.grantReadWriteData(f); // scoped to this table and its indexes only
      apnsSecret?.grantRead(f);
      twilioSecret?.grantRead(f);
      return f;
    };
    const apiFn = fn('Api', 'lambda/api.ts', Duration.seconds(15));
    // Account deletion also removes the sign-in identity (only this pool, only this action).
    apiFn.addEnvironment('COGNITO_USER_POOL_ID', userPool.userPoolId);
    apiFn.addToRolePolicy(new PolicyStatement({ actions: ['cognito-idp:AdminDeleteUser'], resources: [userPool.userPoolArn] }));
    const sweeperFn = fn('Sweeper', 'lambda/sweeper.ts', Duration.seconds(55));

    new Rule(this, 'SweepEveryMinute', {
      schedule: Schedule.rate(Duration.minutes(1)),
      targets: [new LambdaFunction(sweeperFn, { retryAttempts: 0 })],
    });

    // ---------- API ----------
    const authorizer = new HttpJwtAuthorizer('Cognito', `https://cognito-idp.${this.region}.amazonaws.com/${userPool.userPoolId}`, {
      jwtAudience: [appClient.userPoolClientId],
    });
    const api = new HttpApi(this, 'HttpApi', {
      corsPreflight: { allowOrigins: [], allowMethods: [CorsHttpMethod.GET] }, // native app only; no browser origins
      createDefaultStage: false,
    });
    new HttpStage(this, 'DefaultStage', { httpApi: api, stageName: '$default', autoDeploy: true, throttle: { rateLimit: 50, burstLimit: 100 } });
    const integration = new HttpLambdaIntegration('ApiIntegration', apiFn);
    api.addRoutes({ path: '/v1/{proxy+}', methods: [HttpMethod.ANY], integration, authorizer });
    api.addRoutes({ path: '/health', methods: [HttpMethod.GET], integration });

    // ---------- Monitoring ----------
    const topic = new Topic(this, 'OpsAlarms');
    if (props.alarmEmail) topic.addSubscription(new EmailSubscription(props.alarmEmail));
    const alarm = (name: string, metric: ReturnType<typeof apiFn.metricErrors>, threshold: number) =>
      new Alarm(this, name, {
        metric,
        threshold,
        evaluationPeriods: 1,
        comparisonOperator: ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        treatMissingData: TreatMissingData.NOT_BREACHING,
      }).addAlarmAction(new SnsAction(topic));
    alarm('ApiErrors', apiFn.metricErrors({ period: Duration.minutes(5) }), 5);
    // The sweeper drives escalation; if it fails, alerts stop escalating. Page on any error.
    alarm('SweeperErrors', sweeperFn.metricErrors({ period: Duration.minutes(5) }), 1);
    new Alarm(this, 'SweeperNotRunning', {
      metric: sweeperFn.metricInvocations({ period: Duration.minutes(5), statistic: 'Sum' }),
      threshold: 1,
      evaluationPeriods: 1,
      comparisonOperator: ComparisonOperator.LESS_THAN_THRESHOLD,
      treatMissingData: TreatMissingData.BREACHING,
    }).addAlarmAction(new SnsAction(topic));

    new CfnOutput(this, 'ApiUrl', { value: api.apiEndpoint });
    new CfnOutput(this, 'UserPoolId', { value: userPool.userPoolId });
    new CfnOutput(this, 'AppClientId', { value: appClient.userPoolClientId });
    new CfnOutput(this, 'CognitoDomain', { value: domain.baseUrl() });
    new CfnOutput(this, 'TableName', { value: table.tableName });
  }
}
