import type { NextConfig } from 'next'

// A minimal, deliberately non-upstream config used to prove that
// backport-sharp-exclusion.py fails loudly instead of silently skipping a
// source whose next.config does not match the expected anchors.
const nextConfig = {
  output: 'standalone',
  transpilePackages: ['ui'],
} satisfies NextConfig

export default nextConfig
