// Studio TanStack runtime launcher (copied to apps/studio/server.js).
//
// - loads .env like the Next standalone server did;
// - points the API-first server entry (see tanstack-api-first.py) at the
//   prerendered SPA shell so documents never reach TanStack's router;
// - Nitro reads HOST/NITRO_HOST, not HOSTNAME, which the CLI and Next's
//   standalone server use, so map it unless HOST is already set.
import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

process.loadEnvFile(new URL('.env', import.meta.url))

const shell = fileURLToPath(new URL('./.output/public/_shell.html', import.meta.url))
if (!existsSync(shell)) {
  throw new Error(`Studio SPA shell missing: ${shell}`)
}
process.env.STUDIO_SPA_SHELL ??= shell

if (process.env.HOSTNAME && !process.env.HOST && !process.env.NITRO_HOST) {
  process.env.HOST = process.env.HOSTNAME
}

await import('./.output/server/index.mjs')
