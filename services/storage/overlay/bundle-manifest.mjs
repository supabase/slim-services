export const runtimeExternalPackages = ['fs-xattr', 'pg-format', 'pino', 'pino-logflare']

export const optionalExternalPackages = [
  'better-sqlite3',
  'mysql',
  'mysql2',
  'oracledb',
  'pg-query-stream',
  'sqlite3',
  'tedious',
]

export const bundlePackageJson = {
  private: true,
  main: 'start/server.js',
}
