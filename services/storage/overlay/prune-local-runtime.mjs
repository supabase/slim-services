#!/usr/bin/env node
import { rmSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const appDir = process.argv[2] || '/app'
const distDir = join(appDir, 'dist')
const nodeModulesDir = join(appDir, 'node_modules')

const remove = (...paths) => {
  for (const path of paths) {
    rmSync(path, { recursive: true, force: true })
  }
}

const write = (path, contents) => {
  mkdirSync(path.split('/').slice(0, -1).join('/'), { recursive: true })
  writeFileSync(path, contents)
}

remove(
  join(distDir, 'internal/monitoring/pprof'),
  join(distDir, 'scripts/pprof-client.js'),
  join(distDir, 'scripts/pprof-client.test.js')
)

write(
  join(distDir, 'internal/monitoring/otel-tracing.js'),
  `"use strict";
async function shutdownOtelTracing() {}
globalThis.__otelTracingShutdown = shutdownOtelTracing;
module.exports = { shutdownOtelTracing };
`
)

write(
  join(distDir, 'internal/monitoring/otel-metrics.js'),
  `"use strict";
async function shutdownOtelMetrics() {}
async function handleMetricsRequest(_request, reply) {
  reply.status(404).send("Metrics not enabled");
}
globalThis.__otelMetricsShutdown = shutdownOtelMetrics;
module.exports = { handleMetricsRequest, shutdownOtelMetrics };
`
)

write(
  join(distDir, 'http/routes/admin/pprof.js'),
  `"use strict";
async function pprofRoutes(_fastify) {}
module.exports = pprofRoutes;
module.exports.default = pprofRoutes;
`
)

write(
  join(distDir, 'http/routes/admin/index.js'),
  `"use strict";
const jwks = require("./jwks");
const metrics = require("./metrics");
const migrations = require("./migrations");
const objects = require("./objects");
const queue = require("./queue");
const s3 = require("./s3");
const tenants = require("./tenants");
async function pprof() {}
module.exports = {
  jwks: jwks.default || jwks,
  metricsConfig: metrics.default || metrics,
  migrations: migrations.default || migrations,
  objects: objects.default || objects,
  pprof,
  queue: queue.default || queue,
  s3Credentials: s3.default || s3,
  tenants: tenants.default || tenants,
};
`
)

remove(
  join(nodeModulesDir, '@fastify/otel'),
  join(nodeModulesDir, '@grpc'),
  join(nodeModulesDir, '@platformatic'),
  join(nodeModulesDir, '@datadog'),
  join(nodeModulesDir, '@opentelemetry'),
  join(nodeModulesDir, 'otlp-logger'),
  join(nodeModulesDir, 'pino-opentelemetry-transport'),
  join(nodeModulesDir, 'pprof-format'),
  join(nodeModulesDir, 'react-pprof')
)

const otelApiDir = join(nodeModulesDir, '@opentelemetry/api')
mkdirSync(otelApiDir, { recursive: true })
writeFileSync(
  join(otelApiDir, 'package.json'),
  `${JSON.stringify({ name: '@opentelemetry/api', version: '0.0.0-storage-slim', main: 'index.js' })}\n`
)
writeFileSync(
  join(otelApiDir, 'index.js'),
  `"use strict";
const noopInstrument = {
  add() {},
  record() {},
  observe() {},
  addCallback() {},
  removeCallback() {},
};
const noopMeter = {
  createHistogram: () => ({ ...noopInstrument }),
  createCounter: () => ({ ...noopInstrument }),
  createUpDownCounter: () => ({ ...noopInstrument }),
  createGauge: () => ({ ...noopInstrument }),
  createObservableGauge: () => ({ ...noopInstrument }),
  addBatchObservableCallback() {},
  removeBatchObservableCallback() {},
};
const noopSpan = {
  setAttribute() { return this; },
  setAttributes() { return this; },
  setStatus() { return this; },
  recordException() { return this; },
  end() {},
};
const noopTracer = {
  startSpan: () => noopSpan,
  startActiveSpan(_name, _options, _context, fn) {
    const cb = typeof _options === "function" ? _options : typeof _context === "function" ? _context : fn;
    return cb ? cb(noopSpan) : noopSpan;
  },
};
const noopContext = {};
module.exports = {
  SpanKind: { INTERNAL: 0, SERVER: 1, CLIENT: 2, PRODUCER: 3, CONSUMER: 4 },
  SpanStatusCode: { UNSET: 0, OK: 1, ERROR: 2 },
  ValueType: { INT: 0, DOUBLE: 1 },
  ROOT_CONTEXT: noopContext,
  context: {
    active: () => noopContext,
    with: (_context, fn, thisArg, ...args) => fn.apply(thisArg, args),
    bind: (_context, target) => target,
  },
  propagation: {
    inject() {},
    extract: (_context) => _context,
  },
  trace: {
    getActiveSpan: () => undefined,
    getSpan: () => undefined,
    setSpan: (context) => context,
    deleteSpan: (context) => context,
    getSpanContext: () => undefined,
    getTracer: () => noopTracer,
    getTracerProvider: () => ({ getTracer: () => noopTracer }),
    setGlobalTracerProvider() {},
  },
  metrics: {
    getMeter: () => noopMeter,
    getMeterProvider: () => ({ getMeter: () => noopMeter }),
    setGlobalMeterProvider() {},
    disable() {},
  },
  diag: {
    setLogger() {},
    error() {},
    warn() {},
    info() {},
    debug() {},
    verbose() {},
  },
  DiagLogLevel: { NONE: 0, ERROR: 30, WARN: 50, INFO: 60, DEBUG: 70, VERBOSE: 80, ALL: 9999 },
};
`
)

const globalsDir = join(nodeModulesDir, '@platformatic/globals')
mkdirSync(globalsDir, { recursive: true })
writeFileSync(
  join(globalsDir, 'package.json'),
  `${JSON.stringify({ name: '@platformatic/globals', version: '0.0.0-storage-slim', main: 'index.js' })}\n`
)
writeFileSync(
  join(globalsDir, 'index.js'),
  `"use strict";
function getGlobal() { return undefined; }
module.exports = { getGlobal };
`
)
