#!/bin/sh
# Provision one Supavisor tenant from environment values without generating
# Elixir source. The Elixir helper is immutable service artifact data.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
export SUPABASE_POOLER_PROVISION_TENANT_FILE="$SCRIPT_DIR/../share/supabase-cli/provision-tenant.exs"

exec "$SCRIPT_DIR/supavisor" eval 'Code.eval_file(System.fetch_env!("SUPABASE_POOLER_PROVISION_TENANT_FILE"))'
