package olio

// The "IDE" layer: multiple buffers, a project file tree, an integrated Odin
// build with clickable diagnostics, and the whole screen layout.
//
// The editor core in olio.odin still edits exactly one buffer at a time in the
// global `E`. A buffer is just a saved snapshot of that state: switching
// snapshots in and out keeps the editor code untouched. `E` is always the live
// state of `IDE.bufs[IDE.active]` while we are in the editor.

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:time"
import "core:unicode/utf8"

/* ------------------------------------------------------------------ paths */

path_base :: proc(p: string) -> string {
    for i := len(p) - 1; i >= 0; i -= 1 {
        if p[i] == '/' || p[i] == '\\' do return p[i + 1:]
    }
    return p
}

path_dir :: proc(p: string) -> string {
    for i := len(p) - 1; i >= 0; i -= 1 {
        if p[i] == '/' || p[i] == '\\' do return p[:i]
    }
    return ""
}

path_join :: proc(a, b: string) -> string {
    if a == "" do return strings.clone(b)
    if b == "" do return strings.clone(a)
    if a[len(a) - 1] == '/' || a[len(a) - 1] == '\\' do return strings.concatenate({a, b})
    return strings.concatenate({a, "/", b})
}

is_abs_path :: proc(p: string) -> bool {
    if len(p) >= 2 && p[1] == ':' do return true
    if len(p) >= 1 && (p[0] == '/' || p[0] == '\\') do return true
    return false
}

abs_path :: proc(p: string) -> string {
    if is_abs_path(p) do return strings.clone(p)
    cwd, err := os.get_working_directory(context.allocator)
    if err != nil do return strings.clone(p)
    defer delete(cwd)
    return path_join(cwd, p)
}

// Odin reports paths with '/' even on Windows, so buffers are keyed on a
// normalized form ('\' on Windows, case-insensitive comparison).
path_norm :: proc(p: string) -> string {
    b := make([dynamic]byte, 0, len(p) + 1, context.allocator)
    defer delete(b)
    when ODIN_OS == .Windows {
        for i in 0..<len(p) {
            c := p[i]
            if c == '/' do c = '\\'
            append(&b, c)
        }
    } else {
        for i in 0..<len(p) do append(&b, p[i])
    }
    return strings.clone_from_bytes(b[:])
}

paths_equal :: proc(a, b: string) -> bool {
    when ODIN_OS == .Windows {
        if len(a) != len(b) do return false
        for i in 0..<len(a) {
            ca, cb := a[i], b[i]
            if ca >= 'A' && ca <= 'Z' do ca += 32
            if cb >= 'A' && cb <= 'Z' do cb += 32
            if ca != cb do return false
        }
        return true
    } else {
        return a == b
    }
}

/* ------------------------------------------------------------------ state */

Focus :: enum {
    Editor,
    Sidebar,
    Build,
}

Ide_Buf :: struct {
    filename: string,
    rows:     [dynamic]E_Row,
    num_rows: int,
    cx, cy:   int,
    rx:       int,
    rowoff:   int,
    coloff:   int,
    dirty:    int,
    syntax:   ^Syntax,
}

Sidebar_Entry :: struct {
    name:   string,
    path:   string,
    depth:  int,
    is_dir: bool,
}

Diag_Kind :: enum {
    Info,
    Warning,
    Error,
}

Build_Line :: struct {
    text: string,
    file: string,
    line: int,
    col:  int,
    kind: Diag_Kind,
}

Ide :: struct {
    win_row, win_col: int,
    focus:            Focus,

    bufs:             [dynamic]Ide_Buf,
    active:           int,
    root:             string,
    odin:             string,

    sidebar_visible:  bool,
    sidebar_width:    int,
    entries:          [dynamic]Sidebar_Entry,
    sel:              int,
    sidebar_off:      int,
    expanded:         map[string]bool,

    build_visible:    bool,
    build_height:     int,
    build_lines:      [dynamic]Build_Line,
    build_sel:        int,
    build_off:        int,
    build_status:     string,
    build_ok:         bool,
}

IDE: Ide

/* --------------------------------------------------------------- buffers */

buf_stash :: proc() {
    if len(IDE.bufs) == 0 do return
    b := &IDE.bufs[IDE.active]
    b.filename = E.filename
    b.rows = E.row
    b.num_rows = E.num_rows
    b.cx, b.cy = E.cx, E.cy
    b.rx = E.rx
    b.rowoff, b.coloff = E.rowoff, E.coloff
    b.dirty = E.dirty
    b.syntax = E.syntax
}

buf_load :: proc(i: int) {
    b := &IDE.bufs[i]
    E.filename = b.filename
    E.row = b.rows
    E.num_rows = b.num_rows
    E.cx, E.cy = b.cx, b.cy
    E.rx = b.rx
    E.rowoff, E.coloff = b.rowoff, b.coloff
    E.dirty = b.dirty
    E.syntax = b.syntax
    IDE.active = i
}

buf_switch :: proc(i: int) {
    if i == IDE.active || i < 0 || i >= len(IDE.bufs) do return
    buf_stash()
    buf_load(i)
}

// Drops the editor state without freeing it: the owning buffer slot keeps the
// memory (callers stash before calling this).
clear_editor :: proc() {
    E.row = {}
    E.num_rows = 0
    E.cx, E.cy, E.rx, E.rowoff, E.coloff = 0, 0, 0, 0, 0
    E.dirty = 0
    E.syntax = nil
    E.filename = ""
}

buf_open :: proc(path_in: string) -> bool {
    path := path_norm(abs_path(path_in))
    for b, i in IDE.bufs {
        if b.filename != "" && paths_equal(b.filename, path) {
            delete(path)
            buf_switch(i)
            return true
        }
    }

    buf_stash()

    reuse := len(IDE.bufs) == 1 && IDE.bufs[0].filename == "" && IDE.bufs[0].num_rows == 0
    if !reuse {
        append(&IDE.bufs, Ide_Buf{})
        IDE.active = len(IDE.bufs) - 1
    }
    clear_editor()

    if !editor_open(path) {
        delete(path)
        return false
    }

    if IDE.root == "" {
        // path_dir returns a slice into `path`, which is freed below.
        IDE.root = strings.clone(path_dir(path))
    }
    delete(path)
    buf_stash()
    return true
}

buf_close :: proc(i: int) {
    if i < 0 || i >= len(IDE.bufs) do return

    if len(IDE.bufs) == 1 {
        // Never leave the editor without a buffer: reset it instead.
        for &r in E.row do free_row(&r)
        clear_editor()
        buf_stash()
        set_status_message("Buffer cleared")
        return
    }

    b := &IDE.bufs[i]
    for &r in b.rows do free_row(&r)
    delete(b.rows)
    if b.filename != "" do delete(b.filename)
    ordered_remove(&IDE.bufs, i)

    if i == IDE.active {
        if IDE.active >= len(IDE.bufs) do IDE.active = len(IDE.bufs) - 1
        buf_load(IDE.active)
    } else if i < IDE.active {
        IDE.active -= 1
    }
    buf_stash()
}

buf_label :: proc(b: Ide_Buf) -> string {
    return b.filename == "" ? "[No Name]" : path_base(b.filename)
}

/* --------------------------------------------------------------- sidebar */

SKIP_DIRS := []string{".git", "bin", "target", "node_modules", ".olio", "vendor_"}
SKIP_EXTS := []string{".exe", ".obj", ".pdb", ".ilk", ".lib", ".dll", ".exp", ".o"}

sidebar_skip :: proc(name: string) -> bool {
    if name == "" do return true
    if name[0] == '.' do return true
    for d in SKIP_DIRS {
        if name == d do return true
    }
    for e in SKIP_EXTS {
        if len(name) > len(e) && name[len(name) - len(e):] == e do return true
    }
    return false
}

sidebar_rescan :: proc() {
    for &e in IDE.entries {
        delete(e.name)
        delete(e.path)
    }
    clear(&IDE.entries)
    if IDE.root != "" do sidebar_scan_dir(IDE.root, 0)
    if IDE.sel >= len(IDE.entries) do IDE.sel = max(0, len(IDE.entries) - 1)
}

sidebar_scan_dir :: proc(dir: string, depth: int) {
    if depth > 8 || len(IDE.entries) > 1500 do return

    infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    if err != nil do return

    slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
        ad := a.type == .Directory
        bd := b.type == .Directory
        if ad != bd do return ad
        return a.name < b.name
    })

    for fi in infos {
        if sidebar_skip(fi.name) do continue
        is_dir := fi.type == .Directory
        path := path_join(dir, fi.name)
        expanded := is_dir && IDE.expanded[path]
        append(&IDE.entries, Sidebar_Entry{strings.clone(fi.name), path, depth, is_dir})
        if expanded do sidebar_scan_dir(path, depth + 1)
    }
}

sidebar_toggle :: proc() {
    IDE.sidebar_visible = !IDE.sidebar_visible
    if IDE.sidebar_visible {
        if len(IDE.entries) == 0 do sidebar_rescan()
        IDE.focus = .Sidebar
        if IDE.build_visible do IDE.focus = .Sidebar
    } else if IDE.focus == .Sidebar {
        IDE.focus = .Editor
    }
}

sidebar_selected :: proc() -> (Sidebar_Entry, bool) {
    if IDE.sel < 0 || IDE.sel >= len(IDE.entries) do return Sidebar_Entry{}, false
    return IDE.entries[IDE.sel], true
}

sidebar_expand :: proc(toggle: bool) {
    e, ok := sidebar_selected()
    if !ok || !e.is_dir do return
    IDE.expanded[e.path] = toggle ? !IDE.expanded[e.path] : true
    sidebar_rescan()
}

sidebar_activate :: proc() {
    e, ok := sidebar_selected()
    if !ok do return
    if e.is_dir {
        IDE.expanded[e.path] = !IDE.expanded[e.path]
        sidebar_rescan()
        return
    }
    if buf_open(e.path) {
        IDE.focus = .Editor
        set_status_message("Opened %s", path_base(e.path))
    }
}

/* ----------------------------------------------------------------- build */

build_text :: proc(text: string) {
    if len(text) == 0 do return
    start := 0
    for i := 0; i <= len(text); i += 1 {
        if i == len(text) || text[i] == '\n' {
            line := text[start:i]
            if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
            if len(line) > 0 do build_add_line(line)
            start = i + 1
        }
    }
}

build_add_line :: proc(line: string) {
    kind := Diag_Kind.Info
    if strings.contains(line, "Error") || strings.contains(line, "error") {
        kind = .Error
    } else if strings.contains(line, "Warning") || strings.contains(line, "warning") {
        kind = .Warning
    }

    // NOTE: `file` would be a slice *into* `line`, which itself points into the
    // compiler's captured stdout buffer, so it has to be cloned to its own
    // allocation (and is freed in build_clear).
    file: string
    ln, col: int
    if f, l, c, ok := parse_diag(line); ok {
        file = strings.clone(f)
        ln, col = l, c
    }

    append(&IDE.build_lines, Build_Line{
        text = strings.clone(line),
        file = file,
        line = ln,
        col = col,
        kind = kind,
    })
}

// Parses Odin's `path/to/file.odin(12:5) Error: message` prefix.
parse_diag :: proc(text: string) -> (file: string, line: int, col: int, ok: bool) {
    open := strings.index(text, "(")
    if open <= 0 do return
    rest := text[open:]
    close := strings.index(rest, ")")
    if close < 0 do return
    inner := rest[1:close]

    sep := strings.index(inner, ":")
    if sep <= 0 || sep + 1 >= len(inner) do return
    l, lok := strconv.parse_int(inner[:sep])
    c, cok := strconv.parse_int(inner[sep + 1:])
    if !lok || !cok do return
    if l <= 0 do return

    return text[:open], l, c, true
}

build_clear :: proc() {
    for &l in IDE.build_lines {
        delete(l.text)
        if l.file != "" do delete(l.file)
    }
    clear(&IDE.build_lines)
    IDE.build_sel = 0
    IDE.build_off = 0
}

// `build_status` must own its memory: `fmt.tprintf` returns temp-allocated data.
set_build_status :: proc(s: string) {
    delete(IDE.build_status)
    IDE.build_status = strings.clone(s)
}

build_run :: proc() {
    if IDE.root == "" {
        set_status_message("No project root; open a file first")
        return
    }

    build_clear()
    IDE.build_visible = true
    set_build_status("building...")
    IDE.build_ok = false

    // Render the "building" state before blocking on the compiler.
    refresh_screen()

    td, terr := os.temp_directory(context.allocator)
    if terr != nil do td = strings.clone(".")
    defer delete(td)

    out_dir := path_join(td, "olio-build")
    defer delete(out_dir)
    os.make_directory_all(out_dir)

    base := path_base(IDE.root)
    if base == "" || base == "." do base = "app"
    exe_name: string
    when ODIN_OS == .Windows {
        exe_name = strings.concatenate({base, ".exe"})
    } else {
        exe_name = strings.clone(base)
    }
    defer delete(exe_name)

    out_file := path_join(out_dir, exe_name)
    defer delete(out_file)

    out_arg := strings.concatenate({"-out:", out_file})
    defer delete(out_arg)

    // A dynamic array (not a `[]string{...}` literal) so that it is definitely
    // heap allocated and safe to free. IDE.odin is owned by the IDE state.
    command := make([dynamic]string, 0, 4, context.allocator)
    defer delete(command)
    append(&command, IDE.odin)
    append(&command, "build")
    append(&command, ".")
    append(&command, out_arg)

    desc := os.Process_Desc {
        working_dir = IDE.root,
        command     = command[:],
    }

    t0 := time.now()
    state, stdout, stderr, err := os.process_exec(desc, context.allocator)
    elapsed := int(time.duration_milliseconds(time.since(t0)))
    defer delete(stdout)
    defer delete(stderr)

    if err != nil {
        set_build_status(fmt.tprintf("cannot run odin: %v", err))
        append(&IDE.build_lines, Build_Line{
            text = strings.clone(IDE.build_status),
            kind = .Error,
        })
        set_status_message("cannot run '%s' - is it on PATH?", IDE.odin)
        return
    }

    build_text(string(stdout))
    build_text(string(stderr))

    errors := 0
    for l in IDE.build_lines {
        if l.kind == .Error do errors += 1
    }

    if state.exit_code == 0 {
        IDE.build_ok = true
        set_build_status(fmt.tprintf("build ok  %d ms", elapsed))
        set_status_message("Build ok in %d ms", elapsed)
    } else {
        IDE.build_ok = false
        set_build_status(fmt.tprintf("%d errors  exit %d  %d ms", errors, state.exit_code, elapsed))
        set_status_message("Build failed: %d errors", errors)
    }

    // Focus the first diagnostic that points at a file.
    IDE.build_sel = 0
    for l, i in IDE.build_lines {
        if l.file != "" {
            IDE.build_sel = i
            IDE.focus = .Build
            break
        }
    }
    if len(IDE.build_lines) == 0 && state.exit_code == 0 {
        IDE.focus = .Editor
    }
}

build_activate :: proc() {
    if IDE.build_sel < 0 || IDE.build_sel >= len(IDE.build_lines) do return
    bl := IDE.build_lines[IDE.build_sel]
    if bl.file == "" {
        set_status_message("No source location on this line")
        return
    }

    path := bl.file
    if !is_abs_path(path) {
        path = path_join(IDE.root, path)
        defer delete(path)
    }

    if buf_open(path) {
        editor_goto(bl.line, bl.col)
        IDE.focus = .Editor
    }
}

editor_goto :: proc(line, col: int) {
    if line <= 0 do return
    E.cy = clamp(line - 1, 0, max(0, E.num_rows - 1))
    if col > 0 && E.cy < E.num_rows {
        E.cx = clamp(col - 1, 0, E.row[E.cy].size)
    } else {
        E.cx = 0
    }
    E.rx = 0
    E.rowoff = 0
    E.coloff = 0
    editor_scroll()
    E.rowoff = max(0, E.cy - E.screen_row / 2)
    editor_scroll()
}

/* ------------------------------------------------------------------ layout */

// Fills the text area geometry from the window size and panel visibility.
layout :: proc() {
    if rows, cols, ok := poll_window_size(); ok {
        IDE.win_row, IDE.win_col = rows, cols
    }
    if IDE.win_row < 8 do IDE.win_row = 8
    if IDE.win_col < 30 do IDE.win_col = 30

    E.screen_row = IDE.win_row - 3 // tab bar + status bar + message bar
    if IDE.build_visible do E.screen_row -= IDE.build_height
    if E.screen_row < 1 do E.screen_row = 1

    E.screen_col = IDE.win_col
    if IDE.sidebar_visible do E.screen_col -= IDE.sidebar_width + 1
    if E.screen_col < 10 do E.screen_col = 10
}

text_x0 :: proc() -> int {
    return IDE.sidebar_visible ? IDE.sidebar_width + 2 : 1
}

/* ---------------------------------------------------------------- drawing */

put :: proc(b: ^bytes.Buffer, s: string) {
    bytes.buffer_write_string(b, s)
}

put_repeat :: proc(b: ^bytes.Buffer, s: string, n: int) {
    for _ in 0..<n do bytes.buffer_write_string(b, s)
}

goto_rc :: proc(b: ^bytes.Buffer, row, col: int) {
    put(b, fmt.tprintf("\x1b[%d;%dH", row, col))
}

// Truncates to `width` runes (never splitting a UTF-8 sequence).
clip_runes :: proc(s: string, width: int) -> string {
    if width <= 0 do return ""
    n, i := 0, 0
    for i < len(s) && n < width {
        _, size := utf8.decode_rune_in_string(s[i:])
        if size <= 0 do size = 1
        i += size
        n += 1
    }
    return s[:i]
}

put_padded :: proc(b: ^bytes.Buffer, s: string, width: int) {
    s := clip_runes(s, width)
    put(b, s)
    put_repeat(b, " ", width - utf8.rune_count(s))
}

draw_tab_bar :: proc(b: ^bytes.Buffer) {
    goto_rc(b, 1, 1)
    put(b, "\x1b[0m\x1b[K")

    used := 0
    for buf, i in IDE.bufs {
        dirty := buf.dirty != 0 ? " +" : ""
        label := fmt.tprintf(" %d %s%s ", i + 1, buf_label(buf), dirty)
        w := utf8.rune_count(label)
        if used + w > IDE.win_col - 16 do break
        if i == IDE.active {
            put(b, "\x1b[1;7m")
            put(b, label)
            put(b, "\x1b[0m")
        } else {
            put(b, "\x1b[90m")
            put(b, label)
            put(b, "\x1b[0m")
        }
        used += w
    }

    // Right-aligned project / build indicator.
    right := IDE.build_status
    if right == "" do right = IDE.root
    if right == "" do return
    right = path_base(right)
    tag := fmt.tprintf(" %s ", clip_runes(right, 14))
    tw := utf8.rune_count(tag)
    if used + tw + 1 <= IDE.win_col {
        goto_rc(b, 1, IDE.win_col - tw + 1)
        if IDE.build_ok {
            put(b, "\x1b[32m")
        } else if strings.contains(IDE.build_status, "error") || strings.contains(IDE.build_status, "fail") {
            put(b, "\x1b[31m")
        } else {
            put(b, "\x1b[90m")
        }
        put(b, tag)
        put(b, "\x1b[0m")
    }
}

draw_sidebar :: proc(b: ^bytes.Buffer) {
    if !IDE.sidebar_visible do return
    w := IDE.sidebar_width
    rows := E.screen_row

    if IDE.sel < IDE.sidebar_off do IDE.sidebar_off = IDE.sel
    if IDE.sel >= IDE.sidebar_off + rows do IDE.sidebar_off = IDE.sel - rows + 1
    if IDE.sidebar_off < 0 do IDE.sidebar_off = 0

    for r in 0..<rows {
        goto_rc(b, 2 + r, 1)
        idx := IDE.sidebar_off + r
        if idx < len(IDE.entries) {
            e := IDE.entries[idx]
            indent := 1 + e.depth * 2
            icon := "  "
            if e.is_dir do icon = IDE.expanded[e.path] ? "v " : "> "

            line := strings.concatenate({repl_spaces(indent), icon, e.name}, context.temp_allocator)
            line = clip_runes(line, w)

            selected := IDE.focus == .Sidebar && idx == IDE.sel
            if selected {
                put(b, "\x1b[7m")
            } else if e.is_dir {
                put(b, "\x1b[94m")
            } else if e.name != "" && strings.has_suffix(e.name, ".odin") {
                put(b, "\x1b[0m")
            } else {
                put(b, "\x1b[90m")
            }
            put(b, line)
            put_repeat(b, " ", w - utf8.rune_count(line))
            put(b, "\x1b[0m")
        } else {
            put_repeat(b, " ", w)
        }
        put(b, "\x1b[90m|\x1b[0m")
    }
}

repl_spaces :: proc(n: int) -> string {
    s, _ := strings.repeat(" ", n, context.temp_allocator)
    return s
}

// Editor text rows, adapted from olio's original draw_rows, positioned inside
// the content area and clipped to its width.
draw_editor_rows :: proc(b: ^bytes.Buffer) {
    x0 := text_x0()
    lines_len := get_num_len(f64(E.num_rows))
    text_width := E.screen_col - (lines_len + 3)

    for r in 0..<E.screen_row {
        goto_rc(b, 2 + r, x0)
        filerow := r + E.rowoff

        if filerow >= E.num_rows {
            if E.num_rows == 0 && r == E.screen_row / 3 {
                wel := fmt.tprintf("Olio IDE -- version %s", Olio_Version)
                if len(wel) > E.screen_col do wel = strings.cut(wel, 0, E.screen_col)
                padding := (E.screen_col - len(wel)) / 2
                if padding > 0 {
                    put(b, "~ |")
                    padding -= 1
                }
                put_repeat(b, " ", padding)
                put(b, "\x1b[1m")
                put(b, wel)
                put(b, "\x1b[0m")
            } else {
                put(b, "\x1b[90m~")
            }
        } else {
            put(b, "\x1b[90m")
            line_f := fmt.tprintf("% *d | ", lines_len, r + 1 + E.rowoff)
            put(b, line_f)
            put(b, "\x1b[m")

            if E.coloff < E.row[filerow].rsize {
                remain := E.row[filerow].rsize - E.coloff
                n := min(remain, text_width)
                c := E.row[filerow].render[E.coloff:]
                hl := E.row[filerow].hl[E.coloff:]
                current_color := -1
                for j in 0..<n {
                    if is_cntl(c[j]) {
                        sym := c[j] <= 26 ? '@' + c[j] : byte('?')
                        put(b, "\x1b[7m")
                        bytes.buffer_write_byte(b, sym)
                        put(b, "\x1b[m")
                        if current_color != -1 {
                            put(b, fmt.tprintf("\x1b[%dm", current_color))
                        }
                    } else if hl[j] == .Hl_Normal {
                        if current_color != -1 {
                            put(b, "\x1b[39m")
                            current_color = -1
                        }
                        bytes.buffer_write_byte(b, c[j])
                    } else {
                        color := syntax_to_color(hl[j])
                        if color != current_color {
                            current_color = color
                            put(b, fmt.tprintf("\x1b[%dm", color))
                        }
                        bytes.buffer_write_byte(b, c[j])
                    }
                }
            }
            put(b, "\x1b[39m")
        }
        put(b, "\x1b[0m\x1b[K")
    }
}

draw_build_panel :: proc(b: ^bytes.Buffer) {
    if !IDE.build_visible do return

    top := 2 + E.screen_row
    h := IDE.build_height

    // Header.
    goto_rc(b, top, 1)
    put(b, "\x1b[0m\x1b[K")
    hint := "Ctrl-R build | Enter jump | Ctrl-E close"
    title := fmt.tprintf(" %s", IDE.build_status)
    if IDE.build_ok {
        put(b, "\x1b[32m")
    } else if IDE.build_status == "building..." {
        put(b, "\x1b[36m")
    } else {
        put(b, "\x1b[31m")
    }
    put(b, title)
    put(b, "\x1b[0m")
    room := IDE.win_col - utf8.rune_count(title) - 2
    if room > len(hint) {
        goto_rc(b, top, IDE.win_col - len(hint))
        put(b, "\x1b[90m")
        put(b, hint)
        put(b, "\x1b[0m")
    }

    // Lines.
    rows := h - 1
    if IDE.build_sel < IDE.build_off do IDE.build_off = IDE.build_sel
    if IDE.build_sel >= IDE.build_off + rows do IDE.build_off = IDE.build_sel - rows + 1
    if IDE.build_off < 0 do IDE.build_off = 0

    for r in 0..<rows {
        goto_rc(b, top + 1 + r, 1)
        idx := IDE.build_off + r
        if idx < len(IDE.build_lines) {
            bl := IDE.build_lines[idx]
            line := clip_runes(bl.text, IDE.win_col - 1)
            selected := IDE.focus == .Build && idx == IDE.build_sel
            if selected {
                put(b, "\x1b[7m")
            } else {
                switch bl.kind {
                case .Error:   put(b, "\x1b[91m")
                case .Warning: put(b, "\x1b[93m")
                case .Info:    put(b, "\x1b[90m")
                }
            }
            put(b, " ")
            put(b, line)
            put_repeat(b, " ", IDE.win_col - 1 - utf8.rune_count(line))
            put(b, "\x1b[0m")
        } else {
            put(b, "\x1b[K")
        }
    }
}

draw_status_bar :: proc(b: ^bytes.Buffer) {
    goto_rc(b, IDE.win_row - 1, 1)
    put(b, "\x1b[7m")

    name := E.filename != "" ? path_base(E.filename) : "[No Name]"
    if E.dirty != 0 do name = strings.concatenate({name, " +"}, context.temp_allocator)

    left := fmt.tprintf(" %s  %d lines", name, E.num_rows)
    ft := E.syntax != nil ? E.syntax.filetype : "text"
    right := fmt.tprintf("%s | Ln %d, Col %d | %d/%d | %s ",
        ft, E.cy + 1, E.cx + 1, IDE.active + 1, len(IDE.bufs), IDE.focus == .Sidebar ? "files" : IDE.focus == .Build ? "build" : "edit")

    lw := utf8.rune_count(left)
    rw := utf8.rune_count(right)
    if lw + rw > IDE.win_col {
        left = clip_runes(left, max(0, IDE.win_col - rw))
        lw = utf8.rune_count(left)
    }
    put(b, left)
    put_repeat(b, " ", max(0, IDE.win_col - lw - rw))
    if lw + rw <= IDE.win_col do put(b, right)
    put(b, "\x1b[0m")
}

draw_msg_bar :: proc(b: ^bytes.Buffer) {
    goto_rc(b, IDE.win_row, 1)
    put(b, "\x1b[K")
    if len(E.status_msg) == 0 do return
    if time.since(E.status_msg_time) > 5 * time.Second do return
    put(b, clip_runes(E.status_msg, IDE.win_col))
}

refresh_screen :: proc() {
    layout()
    editor_scroll()
    buf_stash() // keep the active tab's label/dirty flag in sync with `E`

    b: Buffer
    defer bytes.buffer_destroy(&b)

    put(&b, "\x1b[?25l")
    draw_tab_bar(&b)
    draw_sidebar(&b)
    draw_editor_rows(&b)
    draw_build_panel(&b)
    draw_status_bar(&b)
    draw_msg_bar(&b)

    if IDE.focus == .Editor {
        row := 2 + (E.cy - E.rowoff)
        lines_len := get_num_len(f64(E.num_rows))
        col := text_x0() + (lines_len + 3) + (E.rx - E.coloff)
        row = clamp(row, 2, 1 + E.screen_row)
        col = clamp(col, text_x0(), IDE.win_col)
        goto_rc(&b, row, col)
    }
    put(&b, "\x1b[?25h")

    os.write_string(os.stdout, bytes.buffer_to_string(&b))
}

/* --------------------------------------------------------------- key input */

ide_handle_key :: proc(k: Key) -> bool {
    // Chords that work from any panel.
    #partial switch v in k {
    case byte:
        switch v {
        case cntl_key('b'):
            sidebar_toggle()
            return true
        case cntl_key('r'):
            build_run()
            return true
        case cntl_key('e'):
            IDE.build_visible = !IDE.build_visible
            if IDE.build_visible {
                IDE.focus = .Build
            } else if IDE.focus == .Build {
                IDE.focus = .Editor
            }
            return true
        case cntl_key('s'):
            editor_save()
            buf_stash()
            return true
        case cntl_key('o'):
            ide_open_prompt()
            return true
        case cntl_key('g'):
            ide_goto_prompt()
            return true
        case cntl_key('n'):
            if len(IDE.bufs) > 1 do buf_switch((IDE.active + 1) % len(IDE.bufs))
            return true
        case cntl_key('p'):
            if len(IDE.bufs) > 1 do buf_switch((IDE.active - 1 + len(IDE.bufs)) % len(IDE.bufs))
            return true
        case cntl_key('w'):
            buf_close(IDE.active)
            return true
        case cntl_key('q'):
            request_quit()
            return true
        case '\x1b':
            if IDE.focus != .Editor {
                IDE.focus = .Editor
                return true
            }
        }
    }

    switch IDE.focus {
    case .Sidebar: return sidebar_key(k)
    case .Build:   return build_key(k)
    case .Editor:
    }

    return false
}

sidebar_key :: proc(k: Key) -> bool {
    #partial switch v in k {
    case Arrow:
        switch v {
        case .Arrow_Up:      if IDE.sel > 0 do IDE.sel -= 1
        case .Arrow_Down:    if IDE.sel + 1 < len(IDE.entries) do IDE.sel += 1
        case .Page_Up:       IDE.sel = max(0, IDE.sel - E.screen_row)
        case .Page_Down:     IDE.sel = min(len(IDE.entries) - 1, IDE.sel + E.screen_row)
        case .Home_Key:      IDE.sel = 0
        case .End_Key:       IDE.sel = max(0, len(IDE.entries) - 1)
        case .Arrow_Right:   sidebar_expand(true)
        case .Arrow_Left:
            e, ok := sidebar_selected()
            if ok && e.is_dir && IDE.expanded[e.path] {
                IDE.expanded[e.path] = false
                sidebar_rescan()
            }
        case .Backspace, .Del_Key:
        }
        return true
    case byte:
        if v == '\r' {
            sidebar_activate()
            return true
        }
        if v == 'r' {
            sidebar_rescan()
            set_status_message("File tree reloaded")
            return true
        }
    }
    // Swallow everything else so keystrokes in the tree never edit the buffer.
    return true
}

build_key :: proc(k: Key) -> bool {
    rows := IDE.build_height - 1
    #partial switch v in k {
    case Arrow:
        #partial switch v {
        case .Arrow_Up:   if IDE.build_sel > 0 do IDE.build_sel -= 1
        case .Arrow_Down: if IDE.build_sel + 1 < len(IDE.build_lines) do IDE.build_sel += 1
        case .Page_Up:    IDE.build_sel = max(0, IDE.build_sel - rows)
        case .Page_Down:  IDE.build_sel = min(len(IDE.build_lines) - 1, IDE.build_sel + rows)
        case .Home_Key:   IDE.build_sel = 0
        case .End_Key:    IDE.build_sel = max(0, len(IDE.build_lines) - 1)
        case:
        }
        return true
    case byte:
        if v == '\r' {
            build_activate()
            return true
        }
        if v == 'c' {
            build_clear()
            IDE.build_status = ""
            return true
        }
    }
    return true
}

ide_open_prompt :: proc() {
    name := editor_prompt("Open: %s (ESC to cancel)", nil)
    defer delete(name)
    if name == "" do return
    if buf_open(name) {
        IDE.focus = .Editor
        set_status_message("Opened %s", path_base(name))
    }
}

ide_goto_prompt :: proc() {
    s := editor_prompt("Go to line: %s", nil)
    defer delete(s)
    if s == "" do return
    n, ok := strconv.parse_int(s)
    if !ok do return
    editor_goto(n, 0)
}

/* ------------------------------------------------------------------- init */

ide_init :: proc() {
    IDE.win_row = E.screen_row
    IDE.win_col = E.screen_col
    IDE.focus = .Editor
    IDE.sidebar_width = 26
    IDE.build_height = 9
    IDE.expanded = make(map[string]bool)

    IDE.odin = "odin"
    if v, ok := os.lookup_env("OLIO_ODIN", context.allocator); ok do IDE.odin = v
    if v, err := os.get_working_directory(context.allocator); err == nil {
        IDE.root = v
    }

    append(&IDE.bufs, Ide_Buf{})
    IDE.active = 0
    buf_stash()
}

ide_set_root_from_file :: proc(path: string) {
    dir := path_dir(path)
    if dir == "" do return
    if IDE.root != "" && IDE.root == dir do return
    if IDE.root == "" || len(IDE.bufs) <= 1 {
        delete(IDE.root)
        IDE.root = strings.clone(dir)
        if IDE.sidebar_visible do sidebar_rescan()
    }
}
