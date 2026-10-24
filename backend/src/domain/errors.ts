export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const badRequest = (message: string) => new ApiError(400, 'bad_request', message);
export const unauthorized = (message = 'Authentication required') => new ApiError(401, 'unauthorized', message);
// Deliberately identical for "does not exist" and "not allowed" so callers cannot probe for Alpha IDs.
export const forbidden = (message = 'Not permitted') => new ApiError(403, 'forbidden', message);
export const notFound = (message = 'Not found') => new ApiError(404, 'not_found', message);
export const conflict = (message: string) => new ApiError(409, 'conflict', message);
export const tooManyRequests = (message: string) => new ApiError(429, 'rate_limited', message);
