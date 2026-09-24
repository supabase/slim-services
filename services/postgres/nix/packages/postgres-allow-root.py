#!/usr/bin/env python3
"""Gate PostgreSQL's uid-0 refusal on SUPABASE_POSTGRES_ALLOW_ROOT=1.

The upstream checks stay in place. A sandbox that cannot drop privileges sets
the variable to 1; any other value, including unset, still refuses uid 0.
The real and effective user ID mismatch refusal stays unchanged.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ENV = "SUPABASE_POSTGRES_ALLOW_ROOT"
GATE = f'(getenv("{ENV}") == NULL || strcmp(getenv("{ENV}"), "1") != 0)'
MARKERS = (
    "cannot be run as root",
    'cannot be executed by \\"root\\"',
    "not permitted",
)
CONDITIONS = (
    "if (geteuid() == 0)",
    "if (os_user_effective_id == 0)",
)
# Expected number of refusal sites, not occurrences of the variable name.
REQUIRED = {
    "src/backend/main/main.c": 1,
    "src/bin/initdb/initdb.c": 1,
    "src/bin/pg_ctl/pg_ctl.c": 1,
    "src/bin/pg_resetwal/pg_resetwal.c": 1,
    "src/bin/pg_rewind/pg_rewind.c": 1,
    "src/bin/pg_upgrade/option.c": 1,
}
OPTIONAL = {
    "src/bin/pg_basebackup/pg_createsubscriber.c": 1,
}


def _window_has_marker(lines: list[str], index: int) -> bool:
    window = "\n".join(lines[index : index + 8])
    return any(marker in window for marker in MARKERS)


def _gate_line(line: str) -> str | None:
    if ENV in line:
        return None
    indent_len = len(line) - len(line.lstrip(" \t"))
    indent = line[:indent_len]
    body = line[indent_len:]
    for cond in CONDITIONS:
        if body.startswith(cond):
            inner = cond[len("if (") : -1]
            rest = body[len(cond) :]
            return f"{indent}if ({inner} && {GATE}){rest}"
    return None


def rewrite(text: str) -> str:
    raw = text.splitlines()
    out: list[str] = []
    for index, line in enumerate(raw):
        if _window_has_marker(raw, index):
            gated = _gate_line(line)
            if gated is not None:
                out.append(gated)
                continue
        out.append(line)
    rewritten = "\n".join(out)
    if text.endswith("\n"):
        rewritten += "\n"
    return rewritten


def _ungated_sites(text: str) -> list[int]:
    raw = text.splitlines()
    sites: list[int] = []
    for index, line in enumerate(raw):
        if ENV in line:
            continue
        body = line.lstrip(" \t")
        if any(body.startswith(cond) for cond in CONDITIONS) and _window_has_marker(raw, index):
            sites.append(index + 1)
    return sites


def _fail(message: str) -> None:
    raise SystemExit(f"postgres allow-root: {message}")


def apply_tree(root: Path) -> None:
    for rel, expected in {**REQUIRED, **OPTIONAL}.items():
        path = root / rel
        if not path.is_file():
            if rel in REQUIRED:
                _fail(f"missing {rel}")
            continue
        updated = rewrite(path.read_text())
        sites = updated.count(ENV) // 2
        if sites != expected or _ungated_sites(updated):
            _fail(f"{rel} gated {sites} refusal site(s), expected {expected}")
        if updated != path.read_text():
            path.write_text(updated)


def _self_test() -> None:
    snippets = {
        "src/backend/main/main.c": """\
static void
check_root(const char *progname)
{
#ifndef WIN32
	if (geteuid() == 0)
	{
		write_stderr("\\"root\\" execution of the PostgreSQL server is not permitted.\\n"
					 "The server must be started under an unprivileged user ID to prevent\\n"
					 "possible system security compromise.  See the documentation for\\n"
					 "more information on how to properly start the server.\\n");
		exit(1);
	}

	if (getuid() != geteuid())
	{
		write_stderr("%s: real and effective user IDs must match\\n",
					 progname);
		exit(1);
	}
#endif
}
""",
        "src/bin/initdb/initdb.c": """\
#ifndef WIN32
	if (geteuid() == 0)\t\t\t/* 0 is root's uid */
	{
		pg_log_error("cannot be run as root");
		pg_log_error_hint("Please log in (using, e.g., \\"su\\") as the (unprivileged) user that will own the server process.");
		exit(1);
	}
#endif
""",
        "src/bin/pg_ctl/pg_ctl.c": """\
#ifndef WIN32
	if (geteuid() == 0)
	{
		write_stderr(_("%s: cannot be run as root\\n"
					   "Please log in (using, e.g., \\"su\\") as the "
					   "(unprivileged) user that will\\n"
					   "own the server process.\\n"),
					 progname);
		exit(1);
	}
#endif
""",
        "src/bin/pg_resetwal/pg_resetwal.c": """\
#ifndef WIN32
	if (geteuid() == 0)
	{
		pg_log_error("cannot be executed by \\"root\\"");
		pg_log_error_hint("You must run %s as the PostgreSQL superuser.",
						  progname);
		exit(1);
	}
#endif
""",
        "src/bin/pg_rewind/pg_rewind.c": """\
#ifndef WIN32
	if (geteuid() == 0)
	{
		pg_log_error("cannot be executed by \\"root\\"");
		exit(1);
	}
#endif
""",
        "src/bin/pg_upgrade/option.c": """\
	/* Allow help and version to be run as root, so do the test here. */
	if (os_user_effective_id == 0)
		pg_fatal("%s: cannot be run as root\\n", os_info.progname);
""",
        "src/bin/pg_basebackup/pg_createsubscriber.c": """\
#ifndef WIN32
	if (geteuid() == 0)
	{
		pg_log_error("cannot be executed by \\"root\\"");
		exit(1);
	}
#endif
""",
    }
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for rel, text in snippets.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        decoy = root / "src/bin/pg_checksums/pg_checksums.c"
        decoy.parent.mkdir(parents=True, exist_ok=True)
        decoy_text = "\tif (geteuid() == 0)\n\t\tdo_other();\n"
        decoy.write_text(decoy_text)
        apply_tree(root)
        apply_tree(root)
        if decoy.read_text() != decoy_text:
            _fail("rewrote a geteuid check that is not a root refusal")
        initdb = (root / "src/bin/initdb/initdb.c").read_text()
        if "/* 0 is root's uid */" not in initdb:
            _fail("dropped the initdb uid comment")
        if f"if (geteuid() == 0 && {GATE})" not in initdb:
            _fail("initdb condition was not gated")
        main = (root / "src/backend/main/main.c").read_text()
        if "\tif (getuid() != geteuid())\n" not in main:
            _fail("removed the uid mismatch refusal")
        if ENV in main.split("if (getuid() != geteuid())", 1)[1]:
            _fail("gated the uid mismatch refusal")
        upgrade = (root / "src/bin/pg_upgrade/option.c").read_text()
        if f"if (os_user_effective_id == 0 && {GATE})" not in upgrade:
            _fail("pg_upgrade condition was not gated")
    with tempfile.TemporaryDirectory() as empty:
        try:
            apply_tree(Path(empty))
        except SystemExit:
            return
    _fail("accepted a tree with no PostgreSQL sources")


def main(argv: list[str]) -> None:
    if len(argv) > 1 and argv[1] == "--self-test":
        _self_test()
        return
    apply_tree(Path(argv[1]) if len(argv) > 1 else Path("."))


if __name__ == "__main__":
    main(sys.argv)
