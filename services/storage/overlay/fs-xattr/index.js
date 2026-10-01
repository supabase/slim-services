// Stands in for fs-xattr so Storage's file backend keeps object metadata on
// filesystems that reject extended attributes, such as Docker Desktop's macOS
// file sharing. Native attributes stay authoritative; the sidecar store answers
// ENOTSUP and native misses, so a directory keeps its metadata across engines.
import crypto from 'node:crypto'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'
import * as native from './native/index.js'

// Storage only creates its internal bucket and multiparts/ at the root, so this
// never collides with an object path.
const SIDECAR_DIR = '.slim-xattr'
const SWEEP_STAMP = '.last-sweep'
const SWEEP_CURSOR = '.sweep-cursor'
const SWEEP_LOCK = '.sweep-lock'
const SWEEP_DELAY_MS = 30_000
const SWEEP_INTERVAL_MS = 60 * 60_000
const SWEEP_BATCH = 50
const SWEEP_PAUSE_MS = 100
// A stopped container never releases its lock; a live sweeper refreshes it
// after every batch, so a short expiry lets the next wake resume quickly.
const SWEEP_LOCK_STALE_MS = 2 * 60_000
const STALE_TEMPORARY_MS = 60 * 60_000
const SHARDS = Array.from({ length: 256 }, (_, index) => index.toString(16).padStart(2, '0'))

function isUnsupported(error) {
  return error?.code === 'ENOTSUP'
}

function isMissing(error) {
  return error?.code === 'ENODATA' || error?.code === 'ENOATTR'
}

function missingAttribute() {
  return Object.assign(new Error('The extended attribute does not exist.'), {
    code: process.platform === 'darwin' ? 'ENOATTR' : 'ENODATA',
  })
}

// Test hook: behave as if the filesystem rejected every extended attribute.
function callNative(call) {
  if (process.env.SLIM_STORAGE_XATTR_SIDECAR === 'force') {
    throw Object.assign(new Error('Extended attributes disabled by SLIM_STORAGE_XATTR_SIDECAR'), {
      code: 'ENOTSUP',
    })
  }
  return call()
}

// Same precedence as Storage's storageFilePath config.
function storageRoot() {
  const root = process.env.STORAGE_FILE_BACKEND_PATH || process.env.FILE_STORAGE_BACKEND_PATH
  return root ? path.resolve(root) : undefined
}

function relativeInside(root, file) {
  const relative = path.relative(root, path.resolve(root, file))
  const outside =
    relative === '' ||
    relative === '..' ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  return outside ? undefined : relative
}

function sidecarPath(file) {
  const root = storageRoot()
  if (root === undefined) return undefined
  const relative = relativeInside(root, file)
  if (relative === undefined) return undefined
  const digest = crypto.createHash('sha256').update(relative).digest('hex')
  return { path: path.join(root, SIDECAR_DIR, digest.slice(0, 2), `${digest}.json`), relative }
}

// Returns the sidecar that can answer for `error`, or rethrows it.
function sidecarFor(file, error) {
  const sidecar = isUnsupported(error) || isMissing(error) ? sidecarPath(file) : undefined
  if (sidecar === undefined) throw error
  // Native calls fail with ENOENT for a missing file; keep that for the sidecar path.
  if (isUnsupported(error)) fs.statSync(file)
  return sidecar
}

function readValues(sidecar) {
  try {
    return JSON.parse(fs.readFileSync(sidecar.path, 'utf8')).attributes
  } catch (error) {
    if (error?.code === 'ENOENT') return {}
    throw error
  }
}

// The relative path is recorded so sweepSidecars can map an entry back to its
// file: deletes never go through fs-xattr, so their sidecars are left behind.
function writeValues(sidecar, values) {
  if (Object.keys(values).length === 0) {
    fs.rmSync(sidecar.path, { force: true })
    return
  }
  fs.mkdirSync(path.dirname(sidecar.path), { recursive: true })
  const temporary = `${sidecar.path}.${process.pid}.${crypto.randomUUID()}.tmp`
  fs.writeFileSync(temporary, JSON.stringify({ path: sidecar.relative, attributes: values }))
  fs.renameSync(temporary, sidecar.path)
}

// Drops a sidecar copy of `attr` so a later native miss cannot answer with it.
function dropSidecarCopy(sidecar, attr) {
  if (sidecar === undefined) return false
  const values = readValues(sidecar)
  if (!Object.hasOwn(values, attr)) return false
  delete values[attr]
  writeValues(sidecar, values)
  return true
}

export function getAttributeSync(file, attr) {
  try {
    return callNative(() => native.getAttributeSync(file, attr))
  } catch (error) {
    const values = readValues(sidecarFor(file, error))
    if (!Object.hasOwn(values, attr)) throw isUnsupported(error) ? missingAttribute() : error
    return Buffer.from(values[attr], 'base64')
  }
}

export function setAttributeSync(file, attr, value) {
  try {
    callNative(() => native.setAttributeSync(file, attr, value))
  } catch (error) {
    if (!isUnsupported(error)) throw error
    const sidecar = sidecarFor(file, error)
    const values = readValues(sidecar)
    values[attr] = Buffer.from(value).toString('base64')
    writeValues(sidecar, values)
    return
  }
  // Multipart parts are rewritten in place, possibly from another engine.
  dropSidecarCopy(sidecarPath(file), attr)
}

export function removeAttributeSync(file, attr) {
  let nativeError
  try {
    callNative(() => native.removeAttributeSync(file, attr))
  } catch (error) {
    if (!isUnsupported(error) && !isMissing(error)) throw error
    nativeError = error
  }
  const sidecar = nativeError === undefined ? sidecarPath(file) : sidecarFor(file, nativeError)
  if (!dropSidecarCopy(sidecar, attr) && nativeError !== undefined) {
    throw isUnsupported(nativeError) ? missingAttribute() : nativeError
  }
}

export function listAttributesSync(file) {
  let names = []
  let nativeError
  try {
    names = callNative(() => native.listAttributesSync(file))
  } catch (error) {
    if (!isUnsupported(error)) throw error
    nativeError = error
  }
  const sidecar = nativeError === undefined ? sidecarPath(file) : sidecarFor(file, nativeError)
  if (sidecar === undefined) return names
  return [...new Set([...names, ...Object.keys(readValues(sidecar))])]
}

// Storage only uses the sync API; the async forms delegate to it.
export const getAttribute = async (file, attr) => getAttributeSync(file, attr)
export const setAttribute = async (file, attr, value) => setAttributeSync(file, attr, value)
export const removeAttribute = async (file, attr) => removeAttributeSync(file, attr)
export const listAttributes = async (file) => listAttributesSync(file)

const exists = (file) =>
  fsp.stat(file).then(
    () => true,
    (error) => error?.code !== 'ENOENT'
  )

const modifiedAt = (file) =>
  fsp.stat(file).then(
    (stat) => stat.mtimeMs,
    () => undefined
  )

// Uploads, copies and multipart parts write fresh versioned paths, so a missing
// file normally stays gone. Unversioned paths (the Iceberg S3 PutObject route)
// can be rewritten: a delete and re-upload landing between the stat and the rm
// loses that object's metadata.
async function sweepEntry(root, entry, now) {
  if (entry.endsWith('.tmp')) {
    const modified = await modifiedAt(entry)
    if (modified !== undefined && now - modified > STALE_TEMPORARY_MS) {
      await fsp.rm(entry, { force: true })
    }
    return
  }
  if (!entry.endsWith('.json')) return
  let relative
  try {
    relative = JSON.parse(await fsp.readFile(entry, 'utf8')).path
  } catch {
    return
  }
  if (typeof relative !== 'string' || relativeInside(root, relative) === undefined) return
  if (!(await exists(path.resolve(root, relative)))) await fsp.rm(entry, { force: true })
}

// Best-effort single sweeper per directory: two processes taking over the same
// stale lock can both sweep, which only duplicates idempotent removals. The
// token keeps each from releasing a lock it no longer holds.
async function acquireLock(lock, retry = true) {
  const token = `${process.pid}.${crypto.randomUUID()}`
  try {
    await fsp.writeFile(lock, token, { flag: 'wx' })
    return token
  } catch (error) {
    if (error?.code !== 'EEXIST') return undefined
  }
  const modified = await modifiedAt(lock)
  if (!retry || (modified !== undefined && Date.now() - modified < SWEEP_LOCK_STALE_MS)) {
    return undefined
  }
  await fsp.rm(lock, { force: true })
  return acquireLock(lock, false)
}

async function releaseLock(lock, token) {
  if ((await fsp.readFile(lock, 'utf8').catch(() => undefined)) === token) {
    await fsp.rm(lock, { force: true })
  }
}

// Removes sidecars whose file is gone, in the background: async I/O, one entry
// at a time, pausing after every batch (longer when the filesystem is slow).
// A pass interrupted by idle sleep resumes after the last entry its cursor
// records (`<shard>/<entry>`, or `<shard>` for a shard not yet started);
// a completed pass stamps the directory and is not repeated within the
// interval. Not part of fs-xattr's API.
export async function sweepSidecars({ force = false, pauseMs = SWEEP_PAUSE_MS } = {}) {
  const root = storageRoot()
  if (root === undefined) return
  const dir = path.join(root, SIDECAR_DIR)
  if (!(await exists(dir))) return
  const cursorFile = path.join(dir, SWEEP_CURSOR)
  const cursor = await fsp.readFile(cursorFile, 'utf8').catch(() => undefined)
  const stamped = await modifiedAt(path.join(dir, SWEEP_STAMP))
  // The slack absorbs clock skew between the container and a bind mount's host.
  if (!force && cursor === undefined && stamped !== undefined) {
    if (Date.now() - stamped < SWEEP_INTERVAL_MS - 60_000) return
  }
  const lock = path.join(dir, SWEEP_LOCK)
  const token = await acquireLock(lock)
  if (token === undefined) return
  try {
    const now = Date.now()
    let batchStarted = Date.now()
    let processed = 0
    const [cursorShard, resumeAfter] = (cursor?.trim() ?? '').split('/')
    const start = Math.max(0, SHARDS.indexOf(cursorShard))
    for (const shard of SHARDS.slice(start)) {
      const names = (await fsp.readdir(path.join(dir, shard)).catch(() => [])).sort()
      const pending =
        shard === cursorShard && resumeAfter ? names.filter((name) => name > resumeAfter) : names
      for (const name of pending) {
        await sweepEntry(root, path.join(dir, shard, name), now).catch(() => {})
        processed += 1
        if (processed % SWEEP_BATCH === 0 && pauseMs > 0) {
          const pause = Math.max(pauseMs, 2 * (Date.now() - batchStarted))
          await fsp.writeFile(cursorFile, `${shard}/${name}`)
          await fsp.utimes(lock, new Date(), new Date()).catch(() => {})
          await sleep(pause, undefined, { ref: false })
          await fsp.utimes(lock, new Date(), new Date()).catch(() => {})
          batchStarted = Date.now()
        }
      }
      const next = SHARDS[SHARDS.indexOf(shard) + 1]
      if (next !== undefined) await fsp.writeFile(cursorFile, next)
      await fsp.utimes(lock, new Date(), new Date()).catch(() => {})
    }
    await fsp.writeFile(path.join(dir, SWEEP_STAMP), '')
    await fsp.rm(cursorFile, { force: true })
  } finally {
    await releaseLock(lock, token)
  }
}

// Every wake from idle sleep is a fresh process, so the first pass waits out
// the requests that woke it; later passes repeat while the process lives.
// Test hook: SLIM_STORAGE_XATTR_SWEEP=immediate skips the delay and interval.
const immediateSweep = process.env.SLIM_STORAGE_XATTR_SWEEP === 'immediate'
function scheduleSweep(delay) {
  setTimeout(async () => {
    await sweepSidecars({ force: immediateSweep }).catch((error) => {
      console.warn(`fs-xattr sidecar sweep failed: ${error?.message ?? error}`)
    })
    scheduleSweep(SWEEP_INTERVAL_MS)
  }, delay).unref()
}
scheduleSweep(immediateSweep ? 0 : SWEEP_DELAY_MS)
