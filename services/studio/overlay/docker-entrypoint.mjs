#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { constants as osConstants } from 'node:os'

function fileEnv(name, defaultValue = '') {
  const value = process.env[name]
  const fileValue = process.env[`${name}_FILE`]

  if (value && fileValue) {
    console.error(`error: both ${name} and ${name}_FILE are set (but are exclusive)`)
    process.exit(1)
  }

  let resolved = defaultValue
  if (value) {
    resolved = value
  } else if (fileValue) {
    resolved = readFileSync(fileValue, 'utf8').trimEnd()
  }

  process.env[name] = resolved
  delete process.env[`${name}_FILE`]
}

fileEnv('POSTGRES_PASSWORD')
fileEnv('SUPABASE_ANON_KEY')
fileEnv('SUPABASE_SERVICE_KEY')

const args = process.argv.slice(2)
const command = args.length > 0 ? args[0] : '/nodejs/bin/node'
const commandArgs = args.length > 0 ? args.slice(1) : ['apps/studio/server.js']

const child = spawn(command, commandArgs, {
  env: process.env,
  stdio: 'inherit',
})

const forwardSignal = (signal) => {
  if (!child.killed) {
    child.kill(signal)
  }
}

process.on('SIGTERM', forwardSignal)
process.on('SIGINT', forwardSignal)

child.on('exit', (code, signal) => {
  if (signal) {
    const signalNumber = osConstants.signals[signal] ?? 1
    process.exit(128 + signalNumber)
  }

  process.exit(code ?? 1)
})
