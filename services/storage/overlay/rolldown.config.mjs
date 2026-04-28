import { builtinModules } from 'node:module'
import { defineConfig } from 'rolldown'
import { optionalExternalPackages, runtimeExternalPackages } from './bundle-manifest.mjs'

const external = [
  ...builtinModules,
  ...builtinModules.map((moduleName) => `node:${moduleName}`),
  ...runtimeExternalPackages,
  ...optionalExternalPackages,
]

export default defineConfig([
  {
    platform: 'node',
    preserveEntrySignatures: false,
    external,
    input: './dist/start/server.js',
    output: {
      file: 'dist-bundle/start/server.js',
      format: 'cjs',
      sourcemap: false,
      exports: 'auto',
      codeSplitting: false,
    },
  },
  {
    platform: 'node',
    preserveEntrySignatures: false,
    external,
    input: './dist/internal/monitoring/logflare.js',
    output: {
      file: 'dist-bundle/start/logflare.js',
      format: 'cjs',
      sourcemap: false,
      exports: 'auto',
      codeSplitting: false,
    },
  },
])
