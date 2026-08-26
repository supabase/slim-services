# Sourced by supabase-postgres-init.sh (the source line is inserted at build
# by the slim-services overlay in postgres-portable.nix) right after the main
# config templates are copied into PGDATA.
#
# The bundle's postgresql.conf.template is the docker.io image's
# postgresql.conf with its absolute /etc/postgresql* include targets rewritten
# to PGDATA-relative names, so this stages those include siblings next to the
# copied postgresql.conf, then appends the one path that cannot be relative:
# the supautils extension custom scripts directory inside the bundle.
#
# Expects BUNDLE_DIR and PGDATA from the including script; runs under its
# `set -Eeo pipefail`.
_shared_cfg="$BUNDLE_DIR/share/supabase-cli/config"
cp "$_shared_cfg/supautils.conf" "$PGDATA/supautils.conf"
cp "$_shared_cfg/logging.conf" "$PGDATA/logging.conf"
cp "$_shared_cfg/wal-g.conf" "$PGDATA/wal-g.conf"
cp "$_shared_cfg/read-replica.conf" "$PGDATA/read-replica.conf"
mkdir -p "$PGDATA/conf.d"
cp "$_shared_cfg/conf.d/"*.conf "$PGDATA/conf.d/"
chmod -R u+w "$PGDATA/conf.d" "$PGDATA/supautils.conf" "$PGDATA/logging.conf" \
	"$PGDATA/wal-g.conf" "$PGDATA/read-replica.conf"

cat >>"$PGDATA/postgresql.conf" <<EOF

# supautils extension custom scripts ship in the bundle (set by stage-shared-config.sh)
supautils.extension_custom_scripts_path = '$BUNDLE_DIR/share/supabase-cli/extension-custom-scripts'
EOF
unset _shared_cfg
