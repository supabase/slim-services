#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-runtime-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

literal="$test_dir/literal"
mkdir -p "$literal"
printf '%s\n' 'FROM node:22 AS build' 'FROM node:22-slim' > "$literal/Dockerfile"
printf '%s\n' 'v22' > "$literal/.nvmrc"
printf '%s\n' '{"engines":{"node":">=20"}}' > "$literal/package.json"
[[ "$(upstream_node_major "$literal")" == "22" ]]

argument="$test_dir/argument"
mkdir -p "$argument"
printf '%s\n' 'ARG NODE_VERSION=24' 'FROM node:${NODE_VERSION}-alpine AS build' > "$argument/Dockerfile"
printf '%s\n' '{"engines":{"node":">=24.0.0"},"packageManager":"npm@11.12.1"}' > "$argument/package.json"
[[ "$(upstream_node_major "$argument")" == "24" ]]
[[ "$(upstream_package_manager_version "$argument" npm)" == "11.12.1" ]]

conflict="$test_dir/conflict"
cp -R "$literal" "$conflict"
printf '%s\n' 'v20' > "$conflict/.nvmrc"
if upstream_node_major "$conflict" >"$test_dir/conflict.out" 2>"$test_dir/conflict.err"; then
  fail "conflicting upstream Node declarations unexpectedly passed"
fi
grep -q 'Dockerfile=22, .nvmrc=20' "$test_dir/conflict.err"

multiple="$test_dir/multiple"
mkdir -p "$multiple"
printf '%s\n' 'FROM node:20 AS build' 'FROM node:22-slim' > "$multiple/Dockerfile"
if upstream_node_major "$multiple" >"$test_dir/multiple.out" 2>"$test_dir/multiple.err"; then
  fail "multiple upstream Node majors unexpectedly passed"
fi
grep -q 'exactly one Node major' "$test_dir/multiple.err"

missing_manager="$test_dir/missing-manager"
mkdir -p "$missing_manager"
printf '%s\n' 'FROM node:22' > "$missing_manager/Dockerfile"
printf '%s\n' '{"engines":{"node":">=22"}}' > "$missing_manager/package.json"
if upstream_package_manager_version "$missing_manager" npm \
  >"$test_dir/manager.out" 2>"$test_dir/manager.err"; then
  fail "missing exact package manager unexpectedly passed"
fi
grep -q 'exact packageManager for npm' "$test_dir/manager.err"

echo "upstream runtime resolver tests passed"
