import fs from 'node:fs/promises'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import {
  bundlePackageJson,
  runtimeExternalPackages,
} from '../bundle-manifest.mjs'

const rootPackageJson = JSON.parse(await fs.readFile(path.resolve('package.json'), 'utf8'))
const sourceNodeModules = path.resolve('node_modules')
const outputDir = path.resolve('dist-bundle')
const outputNodeModules = path.join(outputDir, 'node_modules')
const outputStaticDir = path.join(outputDir, 'static')
const outputStartStaticDir = path.join(outputDir, 'start', 'static')
const outputStartMigrationsDir = path.join(outputDir, 'start', 'migrations')
const outputScriptsMigrationsDir = path.join(outputDir, 'scripts', 'migrations')
const copiedPackages = new Set()

async function copyPackage(packageName) {
  if (copiedPackages.has(packageName)) {
    return
  }

  const sourceDir = path.join(sourceNodeModules, packageName)
  const packageJsonPath = path.join(sourceDir, 'package.json')
  const packageJson = JSON.parse(await fs.readFile(packageJsonPath, 'utf8'))

  copiedPackages.add(packageName)

  for (const dependency of Object.keys(packageJson.dependencies ?? {})) {
    await copyPackage(dependency)
  }

  const targetDir = path.join(outputNodeModules, packageName)
  await fs.mkdir(path.dirname(targetDir), { recursive: true })
  await fs.cp(sourceDir, targetDir, { recursive: true, force: true })
}

function dependencyVersion(packageName) {
  return (
    rootPackageJson.dependencies?.[packageName] ??
    rootPackageJson.optionalDependencies?.[packageName] ??
    rootPackageJson.devDependencies?.[packageName]
  )
}

await fs.mkdir(outputDir, { recursive: true })
await fs.rm(outputNodeModules, { recursive: true, force: true })
await fs.rm(outputStaticDir, { recursive: true, force: true })
await fs.rm(outputStartStaticDir, { recursive: true, force: true })
await fs.rm(outputStartMigrationsDir, { recursive: true, force: true })
await fs.rm(outputScriptsMigrationsDir, { recursive: true, force: true })

for (const packageName of runtimeExternalPackages) {
  await copyPackage(packageName)
}

// Replace fs-xattr with the sidecar-fallback wrapper; the real package moves
// to fs-xattr/native, which the wrapper imports by its entry file.
const fsXattrDir = path.join(outputNodeModules, 'fs-xattr')
const fsXattrPackage = JSON.parse(await fs.readFile(path.join(fsXattrDir, 'package.json'), 'utf8'))
if (fsXattrPackage.type !== 'module' || fsXattrPackage.exports !== './index.js') {
  throw new Error(
    `fs-xattr ${fsXattrPackage.version} changed its entry point; update the sidecar wrapper`
  )
}
const fsXattrStaging = path.join(outputNodeModules, '.fs-xattr-native')
await fs.rename(fsXattrDir, fsXattrStaging)
await fs.mkdir(fsXattrDir)
await fs.rename(fsXattrStaging, path.join(fsXattrDir, 'native'))
await fs.copyFile(
  path.resolve('scripts/slim-fs-xattr/index.js'),
  path.join(fsXattrDir, 'index.js')
)
await fs.writeFile(
  path.join(fsXattrDir, 'package.json'),
  `${JSON.stringify(
    {
      name: 'fs-xattr',
      version: fsXattrPackage.version,
      type: 'module',
      exports: './index.js',
    },
    null,
    2
  )}\n`
)
const importPackage = (entry) => import(pathToFileURL(path.join(fsXattrDir, entry)).href)
const wrapperExports = new Set(Object.keys(await importPackage('index.js')))
const unwrapped = Object.keys(await importPackage('native/index.js')).filter(
  (name) => !wrapperExports.has(name)
)
if (unwrapped.length > 0) {
  throw new Error(`fs-xattr wrapper is missing exports: ${unwrapped.join(', ')}`)
}

// postgres-migrations reads 0_create-migrations-table.sql from
// __dirname/migrations next to each bundled entry.
const bootstrapSql = path.join(
  sourceNodeModules,
  'postgres-migrations',
  'dist',
  'migrations',
  '0_create-migrations-table.sql'
)
for (const destDir of [outputStartMigrationsDir, outputScriptsMigrationsDir]) {
  await fs.mkdir(destDir, { recursive: true })
  await fs.copyFile(bootstrapSql, path.join(destDir, '0_create-migrations-table.sql'))
}

const swaggerUiStaticDir = path.join(sourceNodeModules, '@fastify', 'swagger-ui', 'static')
await fs.cp(swaggerUiStaticDir, outputStaticDir, { recursive: true, force: true })
await fs.cp(swaggerUiStaticDir, outputStartStaticDir, { recursive: true, force: true })

const bundleRuntimePackageJson = {
  name: `${rootPackageJson.name}-bundle`,
  ...bundlePackageJson,
  dependencies: Object.fromEntries(
    runtimeExternalPackages.map((packageName) => [packageName, dependencyVersion(packageName)])
  ),
}

await fs.writeFile(
  path.join(outputDir, 'package.json'),
  `${JSON.stringify(bundleRuntimePackageJson, null, 2)}\n`
)
