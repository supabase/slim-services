{
  pkgs,
  rootfs,
  name,
}:

let
  input = builtins.path {
    path = rootfs;
    name = "${name}-rootfs";
  };
in
pkgs.runCommand "${name}.tar.zst"
  {
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.zstd
    ];
    preferLocalBuild = true;
  }
  ''
    set -euo pipefail
    # NAR inputs preserve the executable bit but cannot carry arbitrary POSIX
    # modes. Normalize the resulting archive to the portable 0644/0755 shape,
    # then fix every tar property controlled by the builder. This makes the
    # archive independent of checkout paths, source mtimes, uid/gid, PAX side
    # data, and directory traversal order.
    tar \
      --sort=name \
      --mtime='UTC 1970-01-01' \
      --mode='u+rwX,go+rX' \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
      --format=posix \
      -C ${input} \
      -cf - . \
      | zstd --no-progress -19 -o "$out"
  ''
