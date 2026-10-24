// Structured logging. Only identifiers, types and counts are logged — never coordinates,
// heart-rate values, names, phone numbers or tokens. Reviewers: keep it that way.

type Fields = Record<string, string | number | boolean | undefined>;

export interface Logger {
  info(event: string, fields?: Fields): void;
  warn(event: string, fields?: Fields): void;
  error(event: string, fields?: Fields): void;
}

export const consoleLogger: Logger = {
  info: (event, fields) => console.log(JSON.stringify({ level: 'info', event, ...fields })),
  warn: (event, fields) => console.warn(JSON.stringify({ level: 'warn', event, ...fields })),
  error: (event, fields) => console.error(JSON.stringify({ level: 'error', event, ...fields })),
};

export const silentLogger: Logger = { info: () => {}, warn: () => {}, error: () => {} };
