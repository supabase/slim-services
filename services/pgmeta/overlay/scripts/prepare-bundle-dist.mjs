import fs from 'node:fs/promises'
import path from 'node:path'
import {
  bundlePackageJson,
  runtimeExternalPackages,
} from '../bundle-manifest.mjs'

const rootPackageJson = JSON.parse(await fs.readFile(path.resolve('package.json'), 'utf8'))
const sourceNodeModules = path.resolve('node_modules')
const outputDir = path.resolve('dist-bundle')
const outputNodeModules = path.join(outputDir, 'node_modules')
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

for (const packageName of runtimeExternalPackages) {
  await copyPackage(packageName)
}

const cpuProfilerLibDir = path.join(
  outputNodeModules,
  '@sentry-internal/node-cpu-profiler/lib'
)
try {
  const entries = await fs.readdir(cpuProfilerLibDir)
  await Promise.all(
    entries
      .filter((entry) => entry.endsWith('.node') && !entry.includes('linux-arm64-glibc-115'))
      .map((entry) => fs.rm(path.join(cpuProfilerLibDir, entry), { force: true }))
  )
} catch (error) {
  if (error?.code !== 'ENOENT') {
    throw error
  }
}

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
