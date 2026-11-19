# Windows port notes

Upstream olio is a POSIX terminal application: it uses `core:sys/posix` for raw
mode (`tcgetattr`/`tcsetattr`) and queries the window size with a "cursor
position report" escape sequence. That cannot compile or run on Windows, so this
tree carries a small platform split plus three fixes for newer Odin nightlies.

Everything else is upstream code, untouched.

## Platform split

| File | Contents |
| --- | --- |
| `olio.odin` | Editor core. No longer imports `core:sys/posix`; the terminal layer moved out. |
| `term_windows.odin` | `#+build windows`. Raw mode via `GetConsoleMode`/`SetConsoleMode` (no echo, no line buffering, no Ctrl-C/Ctrl-S processing, `ENABLE_VIRTUAL_TERMINAL_INPUT` so arrow keys arrive as escape sequences, `ENABLE_VIRTUAL_TERMINAL_PROCESSING` so the editor's ANSI drawing renders). Window size via `GetConsoleScreenBufferInfo`. |
| `term_unix.odin` | `#+build linux, darwin, netbsd, openbsd, freebsd`. The original POSIX implementation, moved verbatim. |

`Config.origin_termios: posix.termios` became `Config.origin_mode: Term_Mode`,
which each platform defines (`posix.termios` on Unix, the two saved console
modes on Windows).

## Fixes for the current Odin toolchain / cross-platform correctness

1. `os.read_entire_file` was removed — now `os.read_entire_file_from_path(path, context.allocator)`,
   which returns `([]byte, os.Error)`.
2. `os.open` takes `os.Permissions` — the plain `0o644` literal no longer converts, so it
   is wrapped: `os.perm(0o644)`.
3. `editor_open` stripped `\r` using the wrong indices
   (`content[len(line)-1]` / `content[:len(line)-1]` instead of
   `line[len(line)-1]` / `line[:len(line)-1]`), so CRLF files kept the `\r` inside each
   row. olio renders control characters as `@`+code, i.e. a bright `M` for CR, and the
   stray CR also reset the cursor column mid-row — every line looked garbled. Fixed, so
   ordinary Windows CRLF files now display correctly.

## Build and run

```powershell
odin build . -out:olio.exe
.\olio.exe olio.odin
```

Note that `odin build .` compiles *every* `.odin` file in the directory, so keep
scratch files out of the package folder (the helpers live in `tools/`).

Inside the editor: `Ctrl-S` save, `Ctrl-Q` quit (press it 3x if the buffer is
dirty), `Ctrl-F` find.

## Verification helpers

- `tools/grab_window.py` — launches olio in its own console window and saves a PNG of
  the client area.
- `tools/interact.py` — launches olio, types two lines via focus-guarded key injection,
  saves with `Ctrl-S`, quits with `Ctrl-Q`, then dumps the saved file. Output lands in
  `screenshots/`.
