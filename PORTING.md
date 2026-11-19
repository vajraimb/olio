# Porting and IDE notes

Upstream olio is a POSIX terminal application: it uses `core:sys/posix` for raw
mode (`tcgetattr`/`tcsetattr`) and queries the window size with a "cursor
position report" escape sequence. That cannot compile or run on Windows, so this
tree carries a small platform split, a few fixes for newer Odin nightlies, and a
new IDE layer on top of the editor core.

## Files

| File | Contents |
| --- | --- |
| `olio.odin` | Editor core. No longer imports `core:sys/posix` and no longer owns the screen layout. |
| `ide.odin` | Buffers, file tree, build runner, diagnostics, layout and all drawing. |
| `term_windows.odin` | `#+build windows`. Raw mode via `GetConsoleMode`/`SetConsoleMode` (no echo, no line buffering, no Ctrl-C/Ctrl-S processing, `ENABLE_VIRTUAL_TERMINAL_INPUT` so arrow keys arrive as escape sequences, `ENABLE_VIRTUAL_TERMINAL_PROCESSING` so the ANSI drawing renders). Window size and resize polling via `GetConsoleScreenBufferInfo`. |
| `term_unix.odin` | `#+build linux, darwin, netbsd, openbsd, freebsd`. The original POSIX implementation, moved out verbatim. |

`Config.origin_termios: posix.termios` became `Config.origin_mode: Term_Mode`,
which each platform defines (`posix.termios` on Unix, the two saved console
modes on Windows).

## How the IDE layer hangs off the editor

The editor core still edits exactly one buffer in the global `E`, so none of the
editing code had to change. A buffer is a saved snapshot of that state:

```odin
Ide_Buf :: struct { filename: string, rows: [dynamic]E_Row, num_rows: int, ... }
```

`E` is the live state of `IDE.bufs[IDE.active]`. Switching buffers does
`buf_stash()` (copy `E` into the current slot) followed by `buf_load(i)` (copy
slot `i` back into `E`); the row arrays are *moved*, never duplicated.

Layout is derived from the window size every redraw:

```
row 1            tab bar
rows 2 .. 1+H    editor text (optionally backed by the file tree on the left)
rows ..          build panel (when open)
row win-1        status bar
row win           message bar
```

`E.screen_row`/`E.screen_col` keep their upstream meaning ("size of the text
area"), which is why the scrolling code did not need to change either.

## Fixes for the current Odin toolchain / cross-platform correctness

1. `os.read_entire_file` was removed — now `os.read_entire_file_from_path(path, context.allocator)`,
   which returns `([]byte, os.Error)`.
2. `os.open` takes `os.Permissions` — the plain `0o644` literal no longer converts, so it
   is wrapped: `os.perm(0o644)`.
3. `editor_open` stripped `\r` using the wrong indices
   (`content[len(line)-1]` / `content[:len(line)-1]` instead of
   `line[len(line)-1]` / `line[:len(line)-1]`), so CRLF files kept the `\r` inside
   each row. olio renders control characters as `@`+code, i.e. a bright `M` for CR, and
   the stray CR also reset the cursor column mid-row — every line looked garbled. Fixed.
4. `editor_open` skips a leading UTF-8 BOM and no longer treats an empty file as a
   read error, and returns `bool` instead of calling `die()`, so a bad path is a
   status message rather than a crash.

## Memory ownership notes (easy to get wrong with Odin slices)

- `parse_diag` returns a path slice *into* the compiler's captured stdout, so
  `build_add_line` clones it; `build_clear` frees both the text and the path.
- Never store a `fmt.tprintf` result in a struct field: it is temp-allocated.
  `set_build_status` clones instead.
- `path_dir` returns a slice into its argument, so `IDE.root` clones it.
- Odin reports `/` separators even on Windows, so buffer keys are compared with
  `path_norm` + `paths_equal` (case-insensitive on Windows). Without this, jumping
  to a diagnostic opened a duplicate tab for the file already on screen.

## Build and run

```powershell
odin build . -out:olio.exe
.\olio.exe olio.odin
```

`odin build .` compiles *every* `.odin` file in the directory, so scratch files
must live outside the package directory (the helper scripts do).

## Verification helpers

`tools/` contains the harness used to check the UI without a human at the
keyboard. It launches olio in its own console window, injects real key events
(focus-guarded), and screenshots the client area with Pillow:

- `tools/grab_window.py` — launch and screenshot.
- `tools/drive_ide.py` — the scripted tour: open the tree, open a file, build,
  jump to a diagnostic, cycle buffers. `mode=error` uses `tools/scratch`, a tiny
  package with a deliberate type error.
- `tools/interact.py` — type two lines, `Ctrl-S`, `Ctrl-Q`, then dump the file.

Sandbox note: ConPTY (`CreatePseudoConsole`) and `AttachConsole` are denied in
this environment, which is why the harness drives a real console window instead.
