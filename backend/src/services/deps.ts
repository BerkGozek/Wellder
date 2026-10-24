import type { Providers } from '../config.ts';
import type { Logger } from '../log.ts';
import type { Repository } from '../store/repository.ts';

export interface Deps {
  repo: Repository;
  providers: Providers;
  log: Logger;
  now: () => Date;
  /** Deletes the sign-in identity (Cognito user / local dev credentials) on account deletion. */
  deleteIdentity?: (principal: { userId: string; email: string }) => Promise<void>;
}
