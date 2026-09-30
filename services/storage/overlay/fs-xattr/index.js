// Stands in for fs-xattr so Storage's file backend keeps object metadata on
// filesystems that reject extended attributes, such as Docker Desktop's macOS
// file sharing. Native attributes stay authoritative; the sidecar store answers
// ENOTSUP and native misses, so a directory keeps its metadata across engines.
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import * as native from './native/index.js'

const SIDECAR_DIR = '.slim-xattr'

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

function sidecarPath(file) {
  const root = storageRoot()
  if (root === undefined) return undefined
  const relative = path.relative(root, path.resolve(file))
  if (
    relative === '' ||
    relative === '..' ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  ) {
    return undefined
  }
  const digest = crypto.createHash('sha256').update(relative).digest('hex')
  return { path: path.join(root, SIDECAR_DIR, `${digest}.json`), relative }
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

// The relative path is recorded so orphans (deleted objects, superseded
// versions, multipart parts) can be mapped back and swept.
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
    return callNative(() => native.setAttributeSync(file, attr, value))
  } catch (error) {
    if (!isUnsupported(error)) throw error
    const sidecar = sidecarFor(file, error)
    const values = readValues(sidecar)
    values[attr] = Buffer.from(value).toString('base64')
    writeValues(sidecar, values)
  }
}

export function removeAttributeSync(file, attr) {
  let nativeError
  try {
    callNative(() => native.removeAttributeSync(file, attr))
  } catch (error) {
    if (!isUnsupported(error) && !isMissing(error)) throw error
    nativeError = error
  }
  // Also drop a sidecar copy, or a later native miss would resurrect it.
  const sidecar = nativeError === undefined ? sidecarPath(file) : sidecarFor(file, nativeError)
  const values = sidecar === undefined ? {} : readValues(sidecar)
  if (Object.hasOwn(values, attr)) {
    delete values[attr]
    writeValues(sidecar, values)
  } else if (nativeError !== undefined) {
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
