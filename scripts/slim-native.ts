/**
 * Shared native OCI tag names and digest shape. Publish and the ECR audit
 * must stay on the same target list.
 */

export const NATIVE_TARGETS = ["linux-arm64", "linux-amd64", "darwin-arm64"] as const;
export const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/;

export class ScriptError extends Error {
  readonly exitCode: number;
  constructor(message: string, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}
