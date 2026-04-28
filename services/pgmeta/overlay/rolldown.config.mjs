import { builtinModules } from 'node:module'
import { defineConfig } from 'rolldown'
import { runtimeExternalPackages } from './bundle-manifest.mjs'

const external = [
  ...builtinModules,
  ...builtinModules.map((moduleName) => `node:${moduleName}`),
  ...runtimeExternalPackages,
]

export default defineConfig({
  input: './dist/server/server.js',
  platform: 'node',
  preserveEntrySignatures: false,
  external,
  output: {
    file: 'dist-bundle/server/server.js',
    format: 'esm',
    sourcemap: false,
    codeSplitting: false,
  },
})
