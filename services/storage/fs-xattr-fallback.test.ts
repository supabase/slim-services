import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeEach, describe, expect, test } from "bun:test";

// The wrapper imports ./native/index.js; this stand-in keeps attributes in
// memory and fails with ENOTSUP while `supported` is false.
const FAKE_NATIVE = `
const state = (globalThis.fakeXattr ??= { supported: true, failWith: undefined, attrs: new Map() })
function call(path, run) {
  if (state.failWith) throw Object.assign(new Error(state.failWith), { code: state.failWith })
  if (!state.supported) throw Object.assign(new Error('unsupported'), { code: 'ENOTSUP' })
  return run(state.attrs.get(path) ?? state.attrs.set(path, new Map()).get(path))
}
function missing() {
  return Object.assign(new Error('missing'), { code: process.platform === 'darwin' ? 'ENOATTR' : 'ENODATA' })
}
export const getAttributeSync = (p, a) => call(p, (m) => { if (!m.has(a)) throw missing(); return m.get(a) })
export const setAttributeSync = (p, a, v) => call(p, (m) => { m.set(a, Buffer.from(v)) })
export const removeAttributeSync = (p, a) => call(p, (m) => { if (!m.delete(a)) throw missing() })
export const listAttributesSync = (p) => call(p, (m) => [...m.keys()])
`;

const MISSING_CODE = process.platform === "darwin" ? "ENOATTR" : "ENODATA";
const ATTR = "user.supabase.content-type";

const temp = mkdtempSync(join(tmpdir(), "slim-fs-xattr."));
const wrapperDir = join(temp, "fs-xattr");
mkdirSync(join(wrapperDir, "native"), { recursive: true });
writeFileSync(join(wrapperDir, "package.json"), '{"type":"module"}\n');
copyFileSync(join(import.meta.dir, "overlay", "fs-xattr", "index.js"), join(wrapperDir, "index.js"));
writeFileSync(join(wrapperDir, "native", "index.js"), FAKE_NATIVE);
const xattr = await import(join(wrapperDir, "index.js"));
const fake = (globalThis as any).fakeXattr;

const root = join(temp, "storage");
const object = join(root, "stub", "bucket", "key", "version");
const sidecarFiles = () =>
  existsSync(join(root, ".slim-xattr")) ? readdirSync(join(root, ".slim-xattr")) : [];
const codeOf = (run: () => unknown) => {
  try {
    run();
  } catch (error) {
    return (error as NodeJS.ErrnoException).code;
  }
  return undefined;
};

afterAll(() => rmSync(temp, { recursive: true, force: true }));

beforeEach(() => {
  rmSync(root, { recursive: true, force: true });
  mkdirSync(join(object, ".."), { recursive: true });
  writeFileSync(object, "body");
  fake.supported = true;
  fake.failWith = undefined;
  fake.attrs.clear();
  process.env.FILE_STORAGE_BACKEND_PATH = root;
  delete process.env.STORAGE_FILE_BACKEND_PATH;
  delete process.env.SLIM_STORAGE_XATTR_SIDECAR;
});

describe("fs-xattr sidecar fallback", () => {
  test("keeps native attributes native when the filesystem supports them", () => {
    xattr.setAttributeSync(object, ATTR, "text/plain");
    expect(xattr.getAttributeSync(object, ATTR).toString()).toBe("text/plain");
    expect(sidecarFiles()).toEqual([]);
  });

  test("stores attributes in a sidecar outside the object tree on ENOTSUP", () => {
    fake.supported = false;
    xattr.setAttributeSync(object, ATTR, "text/plain");
    xattr.setAttributeSync(object, "user.supabase.cache-control", Buffer.from("max-age=60"));

    expect(xattr.getAttributeSync(object, ATTR)).toEqual(Buffer.from("text/plain"));
    expect(xattr.listAttributesSync(object).sort()).toEqual([
      "user.supabase.cache-control",
      ATTR,
    ]);
    expect(readdirSync(join(object, ".."))).toEqual(["version"]);
    const [sidecar] = sidecarFiles();
    expect(JSON.parse(readFileSync(join(root, ".slim-xattr", sidecar!), "utf8")).path).toBe(
      "stub/bucket/key/version",
    );
  });

  test("reports a missing attribute, then removes the sidecar once empty", () => {
    fake.supported = false;
    expect(codeOf(() => xattr.getAttributeSync(object, ATTR))).toBe(MISSING_CODE);
    expect(codeOf(() => xattr.removeAttributeSync(object, ATTR))).toBe(MISSING_CODE);

    xattr.setAttributeSync(object, ATTR, "text/plain");
    xattr.removeAttributeSync(object, ATTR);
    expect(codeOf(() => xattr.getAttributeSync(object, ATTR))).toBe(MISSING_CODE);
    expect(sidecarFiles()).toEqual([]);
  });

  test("keeps ENOENT for a missing file", () => {
    fake.supported = false;
    expect(codeOf(() => xattr.setAttributeSync(join(root, "absent"), ATTR, "x"))).toBe("ENOENT");
    expect(codeOf(() => xattr.getAttributeSync(join(root, "absent"), ATTR))).toBe("ENOENT");
  });

  test("rethrows ENOTSUP outside the storage root or without one", () => {
    fake.supported = false;
    const outside = join(temp, "outside");
    writeFileSync(outside, "body");
    expect(codeOf(() => xattr.setAttributeSync(outside, ATTR, "x"))).toBe("ENOTSUP");
    delete process.env.FILE_STORAGE_BACKEND_PATH;
    expect(codeOf(() => xattr.setAttributeSync(object, ATTR, "x"))).toBe("ENOTSUP");
  });

  test("uses STORAGE_FILE_BACKEND_PATH before FILE_STORAGE_BACKEND_PATH", () => {
    fake.supported = false;
    process.env.STORAGE_FILE_BACKEND_PATH = root;
    process.env.FILE_STORAGE_BACKEND_PATH = join(temp, "elsewhere");
    xattr.setAttributeSync(object, ATTR, "text/plain");
    expect(sidecarFiles()).toHaveLength(1);
  });

  test("propagates other native errors", () => {
    fake.failWith = "EACCES";
    expect(codeOf(() => xattr.getAttributeSync(object, ATTR))).toBe("EACCES");
    expect(codeOf(() => xattr.setAttributeSync(object, ATTR, "x"))).toBe("EACCES");
    expect(sidecarFiles()).toEqual([]);
  });

  test("serves sidecar values after moving to a filesystem with xattrs", () => {
    fake.supported = false;
    xattr.setAttributeSync(object, ATTR, "text/plain");

    fake.supported = true;
    expect(xattr.getAttributeSync(object, ATTR).toString()).toBe("text/plain");
    expect(xattr.listAttributesSync(object)).toEqual([ATTR]);

    xattr.setAttributeSync(object, ATTR, "image/png");
    expect(xattr.getAttributeSync(object, ATTR).toString()).toBe("image/png");
    xattr.removeAttributeSync(object, ATTR);
    expect(codeOf(() => xattr.getAttributeSync(object, ATTR))).toBe(MISSING_CODE);
    expect(sidecarFiles()).toEqual([]);
  });

  test("SLIM_STORAGE_XATTR_SIDECAR=force bypasses native attributes", () => {
    process.env.SLIM_STORAGE_XATTR_SIDECAR = "force";
    xattr.setAttributeSync(object, ATTR, "text/plain");
    expect(fake.attrs.get(object)).toBeUndefined();
    expect(sidecarFiles()).toHaveLength(1);
  });

  test("async forms delegate to the sync implementation", async () => {
    fake.supported = false;
    await xattr.setAttribute(object, ATTR, "text/plain");
    expect((await xattr.getAttribute(object, ATTR)).toString()).toBe("text/plain");
    expect(await xattr.listAttributes(object)).toEqual([ATTR]);
    await xattr.removeAttribute(object, ATTR);
    await expect(xattr.getAttribute(object, ATTR)).rejects.toMatchObject({ code: MISSING_CODE });
  });
});
