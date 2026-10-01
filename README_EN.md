# TyFPJDBC

[中文](README.md)

A general-purpose JDBC bridge for Free Pascal / Lazarus: one codebase reaches
25 databases with unchanged code, usable both as drag-and-drop components and
as pure code.

The Java `Bridge` is the single state machine (pools, connections,
statements, cursors all live in it); the Pascal side only holds `Int64`
handles and never touches JNI directly.

## Features

- 25-entry driver registry (PostgreSQL/MySQL/MSSQL/Oracle/SQLite/H2 and more);
  unknown drivers fail loudly, never silently fall back
- Generic dialect: paging, identifier quoting, and generated-key return are
  derived from driver descriptors — new databases need no source changes
- Pooled (HikariCP) and direct modes with a switch
- LCL design-time components: `TJdbcConnection` + `TJdbcConnQuery`,
  drop on a form and set properties
- Typed value contract: integers/floats/strings (incl. CJK)/dates/booleans/
  BLOBs behave per contract, empty kept distinct from NULL
- mautool: download, verify, and distribute driver jars and JRE runtimes

## Quickstart

```powershell
cd examples\ex20_contacts
lazbuild contacts.lpi
..\..\test-results\bin\mautool.exe --fetch-runtime --platform win64 --out runtime
..\..\test-results\bin\mautool.exe --fetch-driver sqlite --out drivers
.\contacts.exe --selftest
```

`TOTAL fails=0` means green. Double-click `contacts.exe` for the GUI contacts app.

## Prerequisites

Windows 64-bit + Lazarus (FPC 3.2.2). No JDK installation: a trimmed JRE
travels with the program (fetch via `mautool --fetch-runtime`, `jre/` next
to the exe).

## Minimal usage

```pascal
uses TyFPJDBC.JVM.Manager, TyFPJDBC.JNI.Bridge, TyFPJDBC.Engine,
  TyFPJDBC.Command, TyFPJDBC.Query;

TJVMManager.EnsureStarted(TJVMManager.FindLibJvm(''),
  TJVMManager.BuildDesktopArgs);
eng := TJdbcEngine.Create(TBridge.Create);
pool := eng.OpenPool(DefaultPoolCfg('jdbc:sqlite:' + DbPath, 'org.sqlite.JDBC'));
conn := eng.Borrow(pool);

q := TJdbcQuery.Create(nil);   // read: windowed query
q.OpenQuery(eng, conn, 't', 'SELECT id,name FROM t ORDER BY id', 200);

cmd := TJdbcCommand.Create(eng, conn);   // write: named params
cmd.SetSQL('INSERT INTO t(name) VALUES(:n)');
SetLength(r, 1); r[0] := BStr('hi');     // r: TBoundRow
cmd.ExecUpdate(r);
```

Always read/write text fields via `AsUTF8String`. Runnable examples live in
`examples/`.

## Examples

| Directory | Description |
|---|---|
| `examples/ex20_contacts/` | GUI contacts app (full LCL drag-and-drop app, self-tested) |
| `examples/ex11_code_first.lpr` | Pure code: pool, DDL, batch insert, windowed query |
| `examples/ex12_dbgrid.lpr` | Grid binding: browse, edit, append, persist, requery |
| `examples/ex10_json_config.lpr` | Read configs, list drivers and runtimes |
| `examples/ex01_connect_select.lpr` | Lazarus built-in `sqlite3conn` baseline (not this library) |

## Docs map

- Adding drivers / switching databases: `docs/DRIVER.md`
- Paging/quoting/key-return/binding contract: `docs/DIALECT-MATRIX.md`
- Errors/SQLStates/mojibake/leaks: `docs/TROUBLESHOOTING.md`
- Release design: `docs/superpowers/specs/`

## Releases

Runtimes (trimmed JRE + bridge jars) ship with GitHub Releases: a `runtime/*`
tag (or manual Actions dispatch) builds all 5 platform packages and fills
`configs/runtimes.json` back (per-platform sha256 + owning tag).
`mautool --fetch-runtime` downloads verified against the manifest;
`mautool --verify-manifests` checks manifest self-consistency.

## Development

```powershell
pwsh -NoProfile -File scripts/guard.ps1          # gate: no UI units in core, no artifacts beside sources
pwsh -NoProfile -File scripts/run-matrix.ps1     # full matrix (some sections need local PG/MySQL, SKIP otherwise)
```

Build output convention: `.o`/`.ppu` only to `test-results/work/units`,
`exe` only to `test-results/bin`; `zips/` never in git.

## License

MPL-2.0
