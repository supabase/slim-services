#!/usr/bin/env python3
"""Rewrite Studio's TanStack Start server entry into an API-first, shell-first one.

Upstream's `apps/studio/server.ts` hands every request to TanStack Start's
`handler.fetch`, which loads the router chunk (every page, all API route
modules) plus Sentry/OTel before it can answer anything, including a
`/api/platform/profile` call. For a self-hosted Studio that is megabytes of
resident JS the request never needed.

This script generates a replacement entry from the source tree itself:

* `/api/*` requests are matched against a manifest generated from
  `apps/studio/routes/api/**` (the `createFileRoute('...')` literal of each
  file -> a dynamic import of just that module) and answered by calling the
  route's own `server.handlers[METHOD]`, never loading the router, the other
  API modules, Sentry or instrument.server.mjs.
* When `STUDIO_SPA_SHELL` points at the prerendered `_shell.html`, document
  requests (GET/HEAD, not `/api/`, not `/_serverFn/`, no `.` in the last path
  segment) are answered from those bytes. Unset (as during the build's own
  prerender) the entry behaves as upstream.
* Everything else, and every case the fast path cannot prove it handles
  identically (hosted mode, unmatched path, non-plain `handlers`, route
  middleware), lazily loads `instrument.server.mjs`, Sentry and
  `@tanstack/react-start/server-entry` and delegates exactly as upstream did.

`createServerEntry` is deliberately not imported: it lives in the same module
as TanStack's default start handler, so a static import would pull the whole
React/router/SSR graph. It is an identity wrapper (`{ fetch }`), inlined here.

Every assumption about upstream's shape is checked and a mismatch exits
non-zero with a message, so a changed upstream fails the build instead of
silently shipping the slow path.
"""

from __future__ import annotations

import pathlib
import re
import sys

TAG = "tanstack-api-first"

SERVER_ENTRY_IMPORT = re.compile(r"""from\s+['"]@tanstack/react-start/server-entry['"]""")
DEFAULT_EXPORT = re.compile(r"export\s+default\s+createServerEntry\s*\(")
INSTRUMENT_IMPORT = re.compile(r"""import\s+['"]\./instrument\.server\.mjs['"]""")
SENTRY_WRAP = re.compile(r"\bwrapFetchWithSentry\s*\(")
CREATE_FILE_ROUTE_CALL = re.compile(r"\bcreateFileRoute\s*\(")
CREATE_FILE_ROUTE_LITERAL = re.compile(r"""\bcreateFileRoute\s*\(\s*(['"])([^'"\\`]*)\1\s*\)""")
# What the generated matcher understands: static segments, `$param`, and a
# trailing bare `$` splat. Anything else (optional params, prefixes/suffixes,
# pathless layouts) must stop the build rather than be misrouted.
SEGMENT_OK = re.compile(r"^(?:[A-Za-z0-9_.~-]+|\$[A-Za-z_][A-Za-z0-9_]*|\$)$")
# Per-route features the fast path does not replicate.
UNSUPPORTED_ROUTE_OPTIONS = re.compile(r"\b(middleware|beforeLoad|parseParams)\b|\bparams\s*:\s*\{\s*parse\b")


def fail(message: str) -> "None":
    raise SystemExit(f"{TAG}: {message}")


def find_routes(studio: pathlib.Path) -> list[tuple[str, str]]:
    """Return (route path literal, import specifier) for every api route file."""
    api_dir = studio / "routes" / "api"
    if not api_dir.is_dir():
        fail(f"{api_dir} not found (upstream route layout changed)")

    routes: list[tuple[str, str]] = []
    seen: dict[str, pathlib.Path] = {}
    files = sorted(p for p in api_dir.rglob("*") if p.is_file())
    for file in files:
        rel = file.relative_to(studio)
        if file.suffix not in (".ts", ".tsx"):
            fail(f"{rel}: unexpected non-TypeScript file under routes/api")
        text = file.read_text(encoding="utf-8")

        calls = CREATE_FILE_ROUTE_CALL.findall(text)
        literals = CREATE_FILE_ROUTE_LITERAL.findall(text)
        if len(calls) != 1 or len(literals) != 1:
            fail(
                f"{rel}: expected exactly one createFileRoute('<string literal>') call, "
                f"found {len(calls)} call(s) and {len(literals)} literal(s)"
            )
        route_path = literals[0][1]

        if not route_path.startswith("/api/"):
            fail(f"{rel}: route path {route_path!r} is outside /api/")
        segments = [s for s in route_path.split("/") if s]
        for index, segment in enumerate(segments):
            if not SEGMENT_OK.match(segment):
                fail(f"{rel}: unsupported route segment {segment!r} in {route_path!r}")
            if segment == "$" and index != len(segments) - 1:
                fail(f"{rel}: splat segment must be last in {route_path!r}")
        if UNSUPPORTED_ROUTE_OPTIONS.search(text):
            fail(f"{rel}: route declares middleware/beforeLoad/params parsing, which the fast path skips")

        normalized = "/" + "/".join(segments)
        if normalized in seen:
            fail(f"{rel}: route {route_path!r} duplicates {seen[normalized].relative_to(studio)}")
        seen[normalized] = file

        specifier = "./" + rel.with_suffix("").as_posix()
        routes.append((route_path, specifier))

    if not routes:
        fail(f"{api_dir} contains no route files")
    return routes


def check_server_entry(text: str, path: pathlib.Path) -> None:
    checks = [
        (SERVER_ENTRY_IMPORT, "import from '@tanstack/react-start/server-entry'"),
        (DEFAULT_EXPORT, "'export default createServerEntry(...)'"),
        (INSTRUMENT_IMPORT, "side-effect import of './instrument.server.mjs'"),
        (SENTRY_WRAP, "wrapFetchWithSentry(...) around the fetch handler"),
    ]
    for pattern, description in checks:
        if not pattern.search(text):
            fail(f"{path}: expected {description}; upstream server entry changed")


TEMPLATE = r"""// GENERATED by services/studio/tanstack-api-first.py (slim-services build patch).
// Replaces upstream's server entry so that, on a self-hosted build:
//  - `/api/*` is answered by importing only the matched route module;
//  - documents come from the prerendered SPA shell (when STUDIO_SPA_SHELL is set);
//  - anything else loads instrument.server.mjs, Sentry and TanStack's server
//    entry on first use and delegates exactly like upstream.
// Nothing above the dynamic imports may statically import Sentry, the instrument
// module or '@tanstack/react-start/server-entry': each drags in the router graph.
import { readFileSync } from 'node:fs'

type Params = Record<string, string>
type HandlerContext = {
  request: Request
  params: Params
  pathname: string
  context: Record<string, unknown>
  handlerType: 'router'
}
type RouteHandler = (ctx: HandlerContext) => unknown
type RouteModule = {
  Route?: { options?: { server?: { handlers?: unknown } } }
}

const STATIC = 0
const PARAM = 1
const SPLAT = 2

type Segment = { kind: number; value: string }
type ApiRoute = { segments: Segment[]; load: () => Promise<unknown> }

// [TanStack route path, lazy loader of exactly that route module]
const MANIFEST: Array<[string, () => Promise<unknown>]> = [
@@MANIFEST@@
]

const API_ROUTES: ApiRoute[] = MANIFEST.map(([path, load]) => ({
  load,
  segments: path
    .split('/')
    .filter(Boolean)
    .map((segment) =>
      segment === '$'
        ? { kind: SPLAT, value: '_splat' }
        : segment.startsWith('$')
          ? { kind: PARAM, value: segment.slice(1) }
          : { kind: STATIC, value: segment }
    ),
})).sort((a, b) => {
  // Static segments outrank `$param`, which outranks a splat, left to right.
  const length = Math.min(a.segments.length, b.segments.length)
  for (let i = 0; i < length; i++) {
    if (a.segments[i].kind !== b.segments[i].kind) return a.segments[i].kind - b.segments[i].kind
  }
  return 0
})

function matchRoute(route: ApiRoute, parts: string[]): Params | null {
  const params: Params = {}
  for (let i = 0; i < route.segments.length; i++) {
    const segment = route.segments[i]
    if (segment.kind === SPLAT) {
      params[segment.value] = parts.slice(i).join('/')
      return params
    }
    if (i >= parts.length) return null
    if (segment.kind === STATIC) {
      if (parts[i] !== segment.value) return null
    } else {
      params[segment.value] = parts[i]
    }
  }
  return parts.length === route.segments.length ? params : null
}

function decodeParts(pathname: string): string[] | null {
  try {
    return pathname
      .split('/')
      .filter(Boolean)
      .map((part) => decodeURIComponent(part))
  } catch {
    return null
  }
}

function stripBasePath(pathname: string): string {
  const base = process.env.NEXT_PUBLIC_BASE_PATH
  if (base && (pathname === base || pathname.startsWith(`${base}/`))) {
    return pathname.slice(base.length) || '/'
  }
  return pathname
}

// Returns null whenever the original request path must run instead.
async function handleApi(request: Request, pathname: string): Promise<Response | null> {
  // The hosted-mode allowlist guard (start.ts) only exists on the original path.
  if (process.env.NEXT_PUBLIC_IS_PLATFORM === 'true') return null

  const parts = decodeParts(pathname)
  if (!parts) return null
  let params: Params | null = null
  let route: ApiRoute | undefined
  for (const candidate of API_ROUTES) {
    params = matchRoute(candidate, parts)
    if (params) {
      route = candidate
      break
    }
  }
  if (!route || !params) return null

  const handlers = ((await route.load()) as RouteModule).Route?.options?.server?.handlers
  if (!handlers || typeof handlers !== 'object') return null
  const table = handlers as Record<string, RouteHandler | { handler?: RouteHandler; middleware?: unknown[] } | undefined>

  const method = request.method.toUpperCase()
  const entry =
    method === 'HEAD'
      ? (table.HEAD ?? table.GET ?? table.ANY)
      : (table[method] ?? table.ANY)
  if (!entry) {
    const allow = Object.keys(table).filter((name) => name !== 'ANY')
    return new Response('Method Not Allowed', {
      status: 405,
      headers: { allow: allow.join(', ') },
    })
  }
  if (typeof entry !== 'function' && entry.middleware?.length) return null
  const handler = typeof entry === 'function' ? entry : entry.handler
  if (typeof handler !== 'function') return null

  try {
    const result = await handler({ request, params, pathname, context: {}, handlerType: 'router' })
    if (result instanceof Response) return result
  } catch (error) {
    if (error instanceof Response) return error
    throw error
  }
  return new Response('Internal Server Error', { status: 500 })
}

let shellBytes: Uint8Array | undefined
function serveShell(request: Request, pathname: string): Response | null {
  const shellPath = process.env.STUDIO_SPA_SHELL
  if (!shellPath) return null
  if (request.method !== 'GET' && request.method !== 'HEAD') return null
  if (
    pathname === '/api' ||
    pathname.startsWith('/api/') ||
    pathname === '/_serverFn' ||
    pathname.startsWith('/_serverFn/')
  ) {
    return null
  }
  const last = pathname.slice(pathname.lastIndexOf('/') + 1)
  if (last.includes('.')) return null

  shellBytes ??= readFileSync(shellPath)
  return new Response(request.method === 'HEAD' ? null : shellBytes, {
    headers: { 'content-type': 'text/html; charset=utf-8' },
  })
}

type Fetcher = { fetch(request: Request): Promise<Response> | Response }
let original: Promise<Fetcher> | undefined
function loadOriginal(): Promise<Fetcher> {
  original ??= (async () => {
    // Sentry's init must run before the route tree evaluates, as upstream.
    await import('./instrument.server.mjs')
    const { wrapFetchWithSentry } = await import('@sentry/tanstackstart-react')
    const { default: handler } = await import('@tanstack/react-start/server-entry')
    return wrapFetchWithSentry({
      fetch(request: Request) {
        return handler.fetch(request)
      },
    }) as Fetcher
  })()
  return original
}

async function fetchRequest(request: Request): Promise<Response> {
  const pathname = stripBasePath(new URL(request.url).pathname)
  if (pathname.startsWith('/api/')) {
    const response = await handleApi(request, pathname)
    if (response) return response
  } else {
    const response = serveShell(request, pathname)
    if (response) return response
  }
  return (await loadOriginal()).fetch(request)
}

// Same shape as TanStack's `createServerEntry`, which is an identity wrapper
// around `{ fetch }`; importing it would load the whole start graph.
// eslint-disable-next-line no-restricted-exports
export default { fetch: fetchRequest }
"""


def render(routes: list[tuple[str, str]]) -> str:
    import json

    lines = [
        f"  [{json.dumps(path)}, () => import({json.dumps(specifier)})],"
        for path, specifier in routes
    ]
    return TEMPLATE.replace("@@MANIFEST@@", "\n".join(lines))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} STUDIO_APP_DIR", file=sys.stderr)
        return 2
    studio = pathlib.Path(argv[1])
    server_ts = studio / "server.ts"
    if not server_ts.is_file():
        fail(f"{server_ts} not found")
    if not (studio / "instrument.server.mjs").is_file():
        fail(f"{studio / 'instrument.server.mjs'} not found")

    check_server_entry(server_ts.read_text(encoding="utf-8"), server_ts)
    routes = find_routes(studio)
    server_ts.write_text(render(routes), encoding="utf-8")
    print(f"[slim] {server_ts}: API-first server entry generated ({len(routes)} api routes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
