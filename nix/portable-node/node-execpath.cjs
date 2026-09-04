// Node reports the ELF reached through the bundled loader as process.execPath.
// Keep that public value pointed at the wrapper so fork()/spawn() re-enter the
// same relative-loader path instead of executing .node-real with the host
// loader.
if (process.env.SLIM_NODE_WRAPPER) {
  process.execPath = process.env.SLIM_NODE_WRAPPER;
  // Keep process.argv[0] aligned for child_process consumers. process.argv0
  // intentionally remains Node's original executable path.
  process.argv[0] = process.execPath;
}
