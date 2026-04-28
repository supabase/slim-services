export const runtimeExternalPackages = ['pg-format', 'pgsql-parser', '@sentry/profiling-node']

export const bundlePackageJson = {
  private: true,
  type: 'module',
  main: 'server/server.js',
}
