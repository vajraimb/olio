package olio

import "core:os"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:bytes"
import "core:time"
import "core:math"
import "core:unicode/utf8"

E_Row :: struct {
    idx: int,
    size: int,
    rsize: int,
    chars: [dynamic]byte,
    render: [dynamic]byte,
    hl: [dynamic]Highlight,
    hl_open_comment: bool
}

Config :: struct {      // editor's config
    cx, cy: int,        // cursor's position
    rx: int, 
    screen_row: int,
    screen_col: int,
    rowoff, coloff: int,    // offset
    num_rows: int,
    dirty: int,         // be modified
    row: [dynamic]E_Row,
    origin_mode: Term_Mode,
    filename: string,
    status_msg: string,
    status_msg_time: time.Time,
    syntax: ^Syntax,
    undo, redo: [dynamic]Edit,
    saved_undo_len: int,
    sel_on: bool,
    sel_cx, sel_cy: int,
    want_rx: int,
    crlf: bool,
}

Buffer :: bytes.Buffer  // append buffer

E: Config

Result :: enum {
    Err,
    Ok,
}

Highlight :: enum {
    Hl_Normal,
    Hl_Comment,
    Hl_Mlcomment,
    Hl_Keyword1,
    Hl_Keyword2,
    Hl_Number,
    Hl_String,
    Hl_Escape,
    Hl_Match
}

Key :: union {
    byte,
    Arrow
}

Arrow :: enum {
    Backspace = 127,
    Arrow_Left = 1000,
    Arrow_Right,
    Arrow_Up,
    Arrow_Down,
    Page_Up,
    Page_Down,
    Home_Key,
    End_Key,
    Del_Key,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    Paste,
    Resize,
}

Syntax_Flag :: enum {
    Hl_Highlight_Numbers,
    Hl_Highlight_String,
    Hl_Highlight_Escape,
}

Syntax :: struct {
    filetype: string,
    filematch: []string,
    keywords: []string,
    singleline_comment_start: string,
    multiline_comment_start: string,
    multiline_comment_end: string,
    flags: bit_set[Syntax_Flag; u32]
}

C_Hl_Extensions := []string {".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".hxx"}
C_Hl_Keywords := []string {
    "switch", "if", "while", "for", "break", "continue", "return", "else", "struct", "union", "typedef", "static", "enum", "class", "case",
    "int|", "long|", "double|", "float|", "char|", "unsigned|", "signed|", "void|"
}

Py_Hl_Extensions := []string {".py"}
Py_Hl_Keywords := []string {
    "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
    "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
    "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
    "return", "try", "while", "with", "yield",
    "False|", "None|", "True|", "int|", "float|", "str|", "bool|", "list|", "dict|", "set|", "tuple|",
}

Sh_Hl_Extensions := []string {".sh", ".bash", ".zsh"}
Sh_Hl_Keywords := []string {
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
    "case", "esac", "function", "return", "exit", "break", "continue", "in", "local",
}

Json_Hl_Extensions := []string {".json"}

Md_Hl_Extensions := []string {".md", ".markdown"}

Html_Hl_Extensions := []string {".html", ".htm"}
Html_Hl_Keywords := []string {"html|", "head|", "body|", "div|", "span|", "script|", "style|"}

Make_Hl_Extensions := []string {".mk"}
Make_Hl_Keywords := []string {
    "include", "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "define", "endef",
}

Odin_Hl_Extensions := []string {".odin"}
Odin_Hl_Keywords := []string {
    "if", "else", "for", "switch", "case", "break", "continue", "return", "defer", 
    "do", "when", "where", "fallthrough", "proc", "struct", "enum", "union", 
    "bit_field", "bit_set", "map", "dynamic", "import", "export", "foreign", 
    "package", "using", "distinct", "opaque", "inline", "no_inline", "asm", 
    "context", "cast", "auto_cast", "transmute", "in", "notin", "not_in",
    "size_of", "offset_of", "type_info_of", "typeid_of", "type_of", "align_of",
    "or_return", "or_else", "or_break", "or_continue",

    "int|", "uint|", "uintptr|", "i8|", "i16|", "i32|", "i64|", "i128|", 
    "u8|", "u16|", "u32|", "u64|", "u128|", "f16|", "f32|", "f64|", 
    "bool|", "b8|", "b16|", "b32|", "b64|", "string|", "cstring|", "rune|", 
    "any|", "rawptr|", "typeid|", "complex32|", "complex64|", "complex128|",
    "quaternion64|", "quaternion128|", "quaternion256|", "matrix|",
    "i16le|", "i32le|", "i64le|", "i128le|", "u16le|", "u32le|", "u64le|", "u128le|",
    "i16be|", "i32be|", "i64be|", "i128be|", "u16be|", "u32be|", "u64be|", "u128be|",
    "f16le|", "f32le|", "f64le|", "f16be|", "f32be|", "f64be|",
    "true|", "false|", "nil|",
}

Hl_Db := []Syntax {
    Syntax {
        "c", 
        C_Hl_Extensions,
        C_Hl_Keywords,
        "//", "/*", "*/",
        {.Hl_Highlight_Numbers, .Hl_Highlight_String, .Hl_Highlight_Escape}
    },
    Syntax {
        "odin",
        Odin_Hl_Extensions,
        Odin_Hl_Keywords,
        "//", "/*", "*/",
        {.Hl_Highlight_Numbers, .Hl_Highlight_String, .Hl_Highlight_Escape}
    },
    Syntax {
        "python",
        Py_Hl_Extensions,
        Py_Hl_Keywords,
        "#", "\"\"\"", "\"\"\"",
        {.Hl_Highlight_Numbers, .Hl_Highlight_String, .Hl_Highlight_Escape}
    },
    Syntax {
        "shell",
        Sh_Hl_Extensions,
        Sh_Hl_Keywords,
        "#", "", "",
        {.Hl_Highlight_Numbers, .Hl_Highlight_String}
    },
    Syntax {
        "json",
        Json_Hl_Extensions,
        nil,
        "", "", "",
        {.Hl_Highlight_Numbers, .Hl_Highlight_String, .Hl_Highlight_Escape}
    },
    Syntax {
        "markdown",
        Md_Hl_Extensions,
        nil,
        "", "", "",
        {}
    },
    Syntax {
        "html",
        Html_Hl_Extensions,
        Html_Hl_Keywords,
        "", "<!--", "-->",
        {.Hl_Highlight_String}
    },
    Syntax {
        "make",
        Make_Hl_Extensions,
        Make_Hl_Keywords,
        "#", "", "",
        {}
    },
}

Olio_Version := "0.5.0"
Tab_Stop := 4
Quit_Times := 3

append_row :: proc(line: []byte) {
    e := E_Row {0, len(line), 0, slice.clone_to_dynamic(line), {}, {}, false}
    append(&E.row, e)
    editor_update_row(&E.row[E.num_rows])
    E.num_rows = len(E.row)
    E.dirty += 1
}

/*** file IO ***/

// An editor that reads everything into memory should say no at some point.
Max_File_Bytes :: 64 * 1024 * 1024

is_binary :: proc(content: []byte) -> bool {
    n := min(len(content), 8192)
    for i in 0 ..< n {
        if content[i] == 0 do return true
    }
    return false
}

editor_open :: proc (path: string) -> bool {
    if fi, serr := os.stat(path, context.allocator); serr == nil && fi.size > Max_File_Bytes {
        set_status_message("%s is too large for olio (%v MB)", path_base(path), fi.size / (1024 * 1024))
        return false
    }

    content, rerr := read_file_raw(path)
    if rerr != "" {
        set_status_message("Cannot open %s: %s", path, rerr)
        return false
    }
    defer delete(content)

    if is_binary(content) {
        set_status_message("%s looks like a binary file", path_base(path))
        return false
    }

    E.filename = strings.clone(path)
    select_syntax_highlight()

    // Skip a UTF-8 BOM, which Windows editors like to add.
    file_start := 0
    if len(content) >= 3 && content[0] == 0xEF && content[1] == 0xBB && content[2] == 0xBF {
        file_start = 3
    }

    E.crlf = false
    if len(content) > file_start + 1 {
        for i in file_start ..< len(content) - 1 {
            if content[i] == '\r' && content[i + 1] == '\n' {
                E.crlf = true
                break
            }
        }
    }
    if len(content) == file_start {
        E.crlf = ODIN_OS == .Windows
    }

    start := file_start
    for i := file_start; i < len(content); i += 1 {
        if content[i] == '\n' {
            line := content[start:i]
            if len(line) > 0 && line[len(line)-1] == '\r' do line = line[:len(line)-1]
            insert_row(E.num_rows, line)
            start = i + 1
        }
    }
    if start < len(content) {   // handle last line
        line := content[start:]
        if len(line) > 0 && line[len(line)-1] == '\r' do line = line[:len(line)-1]
        insert_row(E.num_rows, line)
    }
    reset_history()
    clear_sel()
    recent_note(E.filename)
    return true
}

rows_to_string :: proc() -> ([]byte, int) {
    totlen := 0
    buf : [dynamic]byte
    for r in E.row {
        append(&buf, ..r.chars[:])
        if E.crlf do append(&buf, '\r')
        append(&buf, '\n')
        totlen += r.size + 1
        if E.crlf do totlen += 1
    }
    return buf[:], totlen
} 

// Creates and removes a probe file, to tell "this folder refuses writes" apart
// from "this particular name was refused". Uses the same raw writer as the real
// save so both agree.
dir_writable :: proc(dir: string) -> bool {
    if dir == "" do return false
    probe := path_join(dir, ".olio-write-probe")
    defer delete(probe)

    payload: []byte = {'x'}
    _, err := write_file_raw(probe, payload)
    if err != "" do return false
    os.remove(probe)
    return true
}

save_reason :: proc(path: string) -> string {
    dir := path_dir(path)
    if !dir_writable(dir) {
        return fmt.tprintf(
            "the folder %s refuses writes - protected folder, no permission, or application control blocking unsigned programs (on such machines start olio with \"Run as administrator\")", dir)
    }
    if fi, serr := os.stat(path, context.allocator); serr == nil && fi.type != .Directory {
        return "the file exists but cannot be written - read-only, or open in another program"
    }
    return "this name was refused in a writable folder - try another name"
}

editor_save :: proc() {
    was_unnamed := len(E.filename) == 0
    if was_unnamed {
        name, name_ok := editor_prompt("Save as: %s (ESC to cancel)", nil)
        if !name_ok || name == "" {
            delete(name)
            set_status_message("Save aborted")
            return
        }
        E.filename = name
    }

    path := path_norm(abs_path(E.filename))
    defer delete(path)

    // Pre-flight: report what is actually wrong before attempting the write.
    if fi, serr := os.stat(path, context.allocator); serr == nil {
        if fi.type == .Directory {
            set_status_message("Can't save: %s is a directory", path)
            return
        }
    } else {
        if dir := path_dir(path); dir != "" {
            if dfi, derr := os.stat(dir, context.allocator); derr != nil || dfi.type != .Directory {
                set_status_message("Can't save: no such directory %s", dir)
                return
            }
        }
    }

    data, _ := rows_to_string()
    defer delete(data)

    written, werr := write_file_raw(path, data)
    if werr != "" {
        set_status_message("Can't save %s: %s - %s", path, werr, save_reason(path))
        if was_unnamed {
            // Let Ctrl-S ask for a name again instead of retrying the bad one.
            delete(E.filename)
            E.filename = ""
        }
        return
    }

    set_status_message("%d bytes written to %s", written, path)
    mark_saved()
    select_syntax_highlight()
    recent_note(path)
}

// One byte from the terminal. `timed_out` means the wait expired with no
// input, so the caller can poll the window size and try again. A hard read
// error reports ok=false and timed_out=false.
read_key :: proc() -> Key {
    key_mods = {}
    for {
        b, ok, timed_out := read_input()
        if timed_out {
            if rows, cols, wok := poll_window_size(); wok {
                if rows != IDE.win_row || cols != IDE.win_col {
                    return .Resize
                }
            }
            continue
        }
        if !ok do die("read byte error")
        if b == '\x1b' do return parse_escape()
        if b == 127 do return .Backspace
        return b
    }
}

read_seq_byte :: proc() -> (byte, bool) {
    b, ok, timed_out := read_input()
    if timed_out || !ok do return 0, false
    return b, true
}

xterm_mods :: proc(n: int) -> bit_set[Mod] {
    // xterm modifier parameter is 1 + shift + 2*alt + 4*ctrl.
    if n <= 1 do return {}
    m := n - 1
    r: bit_set[Mod]
    if m & 1 != 0 do r += {.Shift}
    if m & 2 != 0 do r += {.Alt}
    if m & 4 != 0 do r += {.Ctrl}
    return r
}

parse_escape :: proc() -> Key {
    b, ok := read_seq_byte()
    if !ok do return '\x1b'
    if b == '[' do return parse_csi()
    if b == 'O' do return parse_ss3()
    key_mods += {.Alt}
    if b == 127 do return .Backspace
    return b
}

parse_ss3 :: proc() -> Key {
    b, ok := read_seq_byte()
    if !ok do return '\x1b'
    switch b {
    case 'A': return .Arrow_Up
    case 'B': return .Arrow_Down
    case 'C': return .Arrow_Right
    case 'D': return .Arrow_Left
    case 'H': return .Home_Key
    case 'F': return .End_Key
    case 'P': return .F1
    case 'Q': return .F2
    case 'R': return .F3
    case 'S': return .F4
    }
    return '\x1b'
}

parse_csi :: proc() -> Key {
    buf: [64]byte
    n := 0
    for n < len(buf) {
        b, ok := read_seq_byte()
        if !ok do return '\x1b'
        buf[n] = b
        n += 1
        if b >= 0x40 && b <= 0x7E do break
    }
    if n == 0 do return '\x1b'
    final := buf[n - 1]
    params := string(buf[:n - 1])
    if final == '~' && (params == "200" || strings.has_prefix(params, "200;")) {
        read_bracketed_paste()
        return .Paste
    }

    semi := strings.last_index(params, ";")
    if semi >= 0 {
        if mod_n, mok := strconv_parse_int(params[semi + 1:]); mok {
            key_mods = xterm_mods(mod_n)
        }
    }
    num_s := params
    if semi >= 0 do num_s = params[:semi]
    num, _ := strconv_parse_int(num_s)

    if final == '~' {
        switch num {
        case 1, 7: return .Home_Key
        case 3: return .Del_Key
        case 4, 8: return .End_Key
        case 5: return .Page_Up
        case 6: return .Page_Down
        case 11, 23: return .F1
        case 12, 24: return .F2
        case 13, 25: return .F3
        case 14, 26: return .F4
        case 15, 28: return .F5
        case 17, 29: return .F6
        case 18, 31: return .F7
        case 19, 32: return .F8
        case 20, 33: return .F9
        case 21, 34: return .F10
        }
        // Shifted function keys are often reported as 25~ etc. Keep the key
        // and the modifier already parsed from the second parameter.
        return '\x1b'
    }
    switch final {
    case 'A': return .Arrow_Up
    case 'B': return .Arrow_Down
    case 'C': return .Arrow_Right
    case 'D': return .Arrow_Left
    case 'H': return .Home_Key
    case 'F': return .End_Key
    case 'P': return .F1
    case 'Q': return .F2
    case 'R': return .F3
    case 'S': return .F4
    case:
        return '\x1b'
    }
}

// Local wrapper so this file does not need to import strconv just for CSI.
strconv_parse_int :: proc(s: string) -> (int, bool) {
    n := 0
    if len(s) == 0 do return 0, false
    for i in 0 ..< len(s) {
        c := s[i]
        if c < '0' || c > '9' do return 0, false
        n = n * 10 + int(c - '0')
    }
    return n, true
}

read_bracketed_paste :: proc() {
    clear(&paste_buf)
    // Bracketed paste ends at ESC [ 201 ~
    end := []byte{'\x1b', '[', '2', '0', '1', '~'}
    raw := make([dynamic]byte, 0, 256)
    defer delete(raw)
    for len(raw) < 8 * 1024 * 1024 {
        b, ok, timed_out := read_input()
        if !ok && !timed_out do break
        if timed_out do continue
        append(&raw, b)
        if len(raw) >= len(end) && string(raw[len(raw) - len(end):]) == string(end) {
            resize(&raw, len(raw) - len(end))
            break
        }
    }
    for i := 0; i < len(raw); i += 1 {
        if raw[i] == '\r' {
            append(&paste_buf, '\n')
            if i + 1 < len(raw) && raw[i + 1] == '\n' do i += 1
        } else {
            append(&paste_buf, raw[i])
        }
    }
}

/*** input ***/

quit_times := Quit_Times

request_quit :: proc() {
    if E.dirty != 0 && quit_times > 0 {
        set_status_message("WARNING!!! File has unsaved changes. Press Ctrl-Q %d more times to quit.", quit_times)
        quit_times -= 1
        return
    }
    exit(0)
}

handle_keypress :: proc() {
    c := read_key()
    if a, ok := c.(Arrow); ok && a == .Resize do return

    // Ctrl-Q is handled here (not in the IDE layer) because it is the only key
    // that must *not* reset `quit_times`: repeated presses have to accumulate.
    if v, ok := c.(byte); ok && v == cntl_key('q') {
        request_quit()
        return
    }

    if IDE.overlay == .Help {
        help_on_key(c)
        return
    }
    if IDE.overlay == .Recent {
        recent_on_key(c)
        return
    }
    quit_times = Quit_Times

    if ide_handle_key(c) do return

    extend := .Shift in key_mods
    ctrl := .Ctrl in key_mods
    switch v in c {
    case Arrow:
        switch v {
        case .Page_Up, .Page_Down:
            begin_move(extend)
            if v == .Page_Up do E.cy = E.rowoff
            else {
                E.cy = E.rowoff + E.screen_row - 1
                if E.cy > E.num_rows do E.cy = E.num_rows
            }
            step := v == .Page_Up ? -1 : 1
            for _ in 0 ..< E.screen_row do v_step(step, extend)
        case .Home_Key:
            if ctrl do jump_buffer_edge(true, extend)
            else do move_home(extend)
        case .End_Key:
            if ctrl do jump_buffer_edge(false, extend)
            else do move_end(extend)
        case .Arrow_Left:
            if ctrl do move_word(-1, extend)
            else do h_step(-1, extend)
        case .Arrow_Right:
            if ctrl do move_word(1, extend)
            else do h_step(1, extend)
        case .Arrow_Up: v_step(-1, extend)
        case .Arrow_Down: v_step(1, extend)
        case .Backspace: backspace()
        case .Del_Key: delete_forward()
        case .F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12, .Paste, .Resize:
        }
    case byte:
        if .Alt in key_mods do return
        switch v {
        case '\r': newline_indent()
        case cntl_key('h'): backspace()
        case '\x1b':
            if E.sel_on do clear_sel()
        case cntl_key('f'): editor_find()
        case cntl_key('z'): undo_edit()
        case cntl_key('y'): redo_edit()
        case cntl_key('a'): select_all()
        case cntl_key('c'): copy_selection()
        case cntl_key('x'): cut_selection()
        case cntl_key('v'): paste_clip()
        case cntl_key('d'): duplicate_line()
        case cntl_key('l'): select_line()
        case: if !is_cntl(v) do insert_char(v)
        }
    }
}

pop_prompt_rune :: proc(buf: ^[dynamic]byte) {
    if len(buf) == 0 do return
    resize(buf, prev_rune_start(buf[:], len(buf)))
}

// `ok` is false when the user cancels with Esc. An empty confirmation is
// returned only when `allow_empty` is set.
editor_prompt :: proc(prompt: string, callback: proc([]byte, Key) = nil, seed: string = "", allow_empty := false) -> (string, bool) {
    buf: [dynamic]byte
    defer delete(buf)
    if len(seed) > 0 do append(&buf, ..str_bytes(seed))
    for {
        body := string(buf[:])
        label := fmt.tprintf(prompt, body)
        if strings.contains(prompt, "Search") || strings.contains(prompt, "Replace") {
            mode := search_case ? "case-sensitive" : "case-insensitive"
            label = fmt.tprintf("%s  [%s]", label, mode)
        }
        set_status_message("%s", label)
        refresh_screen()

        c := read_key()
        if a, ok := c.(Arrow); ok && a == .Resize do continue
        switch v in c {
        case Arrow:
            if v == .Paste {
                append(&buf, ..paste_buf[:])
                clear(&paste_buf)
            } else if v == .Del_Key || v == .Backspace {
                pop_prompt_rune(&buf)
            } else if v == .Arrow_Left || v == .Arrow_Right || v == .Arrow_Up || v == .Arrow_Down {
                // delivered to the find callback below
            }
        case byte:
            if .Alt in key_mods && (v == 'c' || v == 'C') {
                search_case = !search_case
            } else if v == cntl_key('h') {
                pop_prompt_rune(&buf)
            } else if v == '\x1b' {
                set_status_message("")
                if callback != nil do callback(buf[:], c)
                return "", false
            } else if v == '\r' {
                if len(buf) != 0 || allow_empty {
                    set_status_message("")
                    if callback != nil do callback(buf[:], c)
                    return strings.clone_from_bytes(buf[:]), true
                }
            } else if !is_cntl(v) {
                append(&buf, v)
            }
        }
        if callback != nil do callback(buf[:], c)
    }
}

editor_scroll :: proc() {
    E.rx = 0
    if E.cy < E.num_rows do E.rx = row_cx_to_rx(&E.row[E.cy], E.cx)
    if E.cy < E.rowoff do E.rowoff = E.cy
    if E.cy >= E.rowoff + E.screen_row do E.rowoff = E.cy - E.screen_row + 1
    line_len := get_num_len(f64(E.num_rows))
    text_width := E.screen_col - (line_len + 3)
    if text_width < 1 do text_width = 1
    if E.rx < E.coloff do E.coloff = E.rx
    if E.rx >= E.coloff + text_width do E.coloff = E.rx - text_width + 1
}

editor_update_row :: proc(row: ^E_Row) {
    tabs := 0
    for j in 0..<row.size do if row.chars[j] == '\t' do tabs += 1

    resize(&row.render, row.size + tabs*(Tab_Stop - 1))

    idx := 0
    for j in 0..<row.size {
        if row.chars[j] == '\t' {
            row.render[idx] = ' '
            idx += 1
            for idx % Tab_Stop != 0 {
                row.render[idx] = ' '
                idx += 1
            }
        } else {
            row.render[idx] = row.chars[j]
            idx += 1
        }
    }
    row.rsize = idx
    update_syntax(row)
}

set_status_message :: proc(format: string, args: ..any) {
    if len(E.status_msg) != 0 do delete(E.status_msg)
    E.status_msg = strings.clone(fmt.tprintf(format, ..args))
    E.status_msg_time = time.now()
}

/*** row operations ***/

// Display columns from the start of the row up to byte offset `cx`.
// Tabs expand to Tab_Stop. Every other codepoint, including CJK, is one column.
row_cx_to_rx :: proc(row: ^E_Row, cx: int) -> int {
    rx := 0
    j := 0
    limit := cx
    if limit > row.size do limit = row.size
    if limit < 0 do limit = 0
    for j < limit {
        if row.chars[j] == '\t' {
            rx += Tab_Stop - (rx % Tab_Stop)
            j += 1
            continue
        }
        _, n := utf8.decode_rune(row.chars[j:])
        if n <= 0 do n = 1
        if j + n > limit {
            rx += 1
            break
        }
        rx += 1
        j += n
    }
    return rx
}

row_rx_to_cx :: proc(row: ^E_Row, rx: int) -> int {
    cur_rx := 0
    j := 0
    for j < row.size {
        w := 1
        n := 1
        if row.chars[j] == '\t' {
            w = Tab_Stop - (cur_rx % Tab_Stop)
        } else {
            _, n = utf8.decode_rune(row.chars[j:])
            if n <= 0 do n = 1
        }
        if cur_rx + w > rx do return j
        cur_rx += w
        j += n
    }
    return row.size
}

free_row :: proc(row: ^E_Row) {
    delete(row.render)
    delete(row.chars)
    delete(row.hl)
} 

del_row :: proc(at: int) {
    if at < 0 || at >= E.num_rows do return
    free_row(&E.row[at])
    ordered_remove(&E.row, at)
    for j in at..<E.num_rows-1 do E.row[j].idx -= 1
    E.num_rows = len(E.row)
    E.dirty += 1
}

insert_row :: proc(at: int, s: []byte) {
    if at < 0 || at > E.num_rows do return 
    new_row := E_Row {at, len(s), 0, slice.clone_to_dynamic(s), {}, {}, false}
    inject_at(&E.row, at, new_row)
    // `at+1..=E.num_rows` walks backward on the current compiler when the
    // buffer was empty (1..=0), and indexes off the end. Only the rows that
    // shifted right need a new index.
    for j in at + 1 ..< len(E.row) do E.row[j].idx += 1
    editor_update_row(&E.row[at])
    E.num_rows += 1
    E.dirty += 1
}

/*** terminal ***/

// Platform-specific: enable_raw_mode, disable_raw_mode, get_window_size and
// the Term_Mode type live in term_unix.odin / term_windows.odin.

die :: proc(msg: string) {
    disable_raw_mode()
    fmt.println(msg)
    os.exit(1)
}

exit :: proc(code: int) {
    disable_raw_mode()
    os.exit(code)
}

/*** syntax highlighting ***/

update_syntax :: proc(row: ^E_Row) {
    resize(&row.hl, row.rsize)
    if E.syntax == nil do return
    if E.syntax.filetype == "markdown" {
        update_markdown(row)
        return
    } 
    keywords := E.syntax.keywords
    scs := E.syntax.singleline_comment_start
    mcs := E.syntax.multiline_comment_start
    mce := E.syntax.multiline_comment_end
    prev_sep := true
    in_string: byte = 0     // ' or " 
    in_comment := row.idx > 0 && E.row[row.idx - 1].hl_open_comment
    for i := 0; i < row.rsize; i += 1 {
        c := row.render[i]
        prev_hl := (i > 0) ? row.hl[i - 1] : .Hl_Normal
    
        if len(scs) != 0 && in_string == 0 && !in_comment {
            if strings.has_prefix(string(row.render[i:]), scs) {
                for j in i..<row.rsize {
                    row.hl[j] = .Hl_Comment
                }
                break
            }
        }

        if len(mcs) != 0 && len(mce) != 0 && in_string == 0 {
            if in_comment {
                row.hl[i] = .Hl_Mlcomment
                if strings.has_prefix(string(row.render[i:]), mce) {
                    for j in i..<i+len(mce) do row.hl[j] = .Hl_Mlcomment
                    i += len(mce) - 1
                    in_comment, prev_sep = false, true
                    continue
                } else do continue
            } else if strings.has_prefix(string(row.render[i:]), mcs) {
                for j in i..<i+len(mcs) do row.hl[j] = .Hl_Mlcomment
                i += len(mcs) - 1
                in_comment = true
                continue
            }
        }

        if .Hl_Highlight_String in E.syntax.flags {
            if in_string != 0 {
                row.hl[i] = .Hl_String
                if c == '\\' && i + 1 < row.rsize {
                    if .Hl_Highlight_Escape in E.syntax.flags {
                        row.hl[i] = .Hl_Escape
                        row.hl[i+1] = .Hl_Escape
                    } else do row.hl[i+1] = .Hl_String
                    i += 1
                    continue
                }
                if c == in_string do in_string = 0
                prev_sep = true
                continue
            } else {
                if c == '"' || c == '\'' {
                    in_string = c
                    row.hl[i] = .Hl_String
                    continue
                }
            }
        }
        if .Hl_Highlight_Numbers in E.syntax.flags {
            if (is_digit(c) && (prev_sep || prev_hl == .Hl_Number)) || (c == '.' && prev_hl == .Hl_Number){
                row.hl[i] = .Hl_Number
                prev_sep = false
                continue
            } else do row.hl[i] = .Hl_Normal
        }

        if prev_sep {
            found_kw := false
            for keyword in keywords {
                idx := strings.last_index(keyword, "|")
                kw := idx >= 0 ? keyword[:idx] : keyword
                kw_len := len(kw)
                if strings.has_prefix(string(row.render[i:]), kw) {
                    next_char_idx := i + kw_len
                    is_end_or_sep := next_char_idx >= row.rsize || is_separator(row.render[next_char_idx])
                    if is_end_or_sep { 
                        for j in i..<i + kw_len do row.hl[j] = idx >= 0 ? .Hl_Keyword2 : .Hl_Keyword1
                        i += kw_len - 1
                        found_kw = true
                        break
                    }
                }
            }
            if found_kw {
                prev_sep = false
                continue
            }
        }
        prev_sep = is_separator(c)
    }

    changed := row.hl_open_comment != in_comment
    row.hl_open_comment = in_comment
    if changed && row.idx + 1 < E.num_rows do update_syntax(&E.row[row.idx + 1])
}

syntax_to_color :: proc(hl: Highlight) -> int {
    #partial switch hl {
    case .Hl_Comment, .Hl_Mlcomment: return 32
    case .Hl_Keyword1: return 33
    case .Hl_Keyword2: return 34
    case .Hl_Number: return 31
    case .Hl_Match: return 36
    case .Hl_String: return 35
    case .Hl_Escape: return 34
    case: return 37
    }
}

is_separator :: proc(c: byte) -> bool {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' do return true
    switch c {
    case '\x00', ',', '.', '(', ')', '+', '-', '/', '*', '=', '~', '%', '<', '>', '[', ']', ';': return true
    case: return false
    }
}

file_has_suffix :: proc(name, suf: string) -> bool {
    if len(name) < len(suf) do return false
    tail := name[len(name) - len(suf):]
    when ODIN_OS == .Windows {
        for i in 0 ..< len(suf) {
            a, b := tail[i], suf[i]
            if a >= 'A' && a <= 'Z' do a += 32
            if b >= 'A' && b <= 'Z' do b += 32
            if a != b do return false
        }
        return true
    } else {
        return tail == suf
    }
}

base_is :: proc(name: string, opts: ..string) -> bool {
    base := path_base(name)
    for opt in opts {
        when ODIN_OS == .Windows {
            if len(base) != len(opt) do continue
            same := true
            for i in 0 ..< len(base) {
                a, b := base[i], opt[i]
                if a >= 'A' && a <= 'Z' do a += 32
                if b >= 'A' && b <= 'Z' do b += 32
                if a != b {
                    same = false
                    break
                }
            }
            if same do return true
        } else {
            if base == opt do return true
        }
    }
    return false
}

update_markdown :: proc(row: ^E_Row) {
    for i in 0 ..< row.rsize do row.hl[i] = .Hl_Normal
    line := row.render[:]
    trim := 0
    for trim < len(line) && (line[trim] == ' ' || line[trim] == '\t') do trim += 1
    prev := row.idx > 0 && row.idx - 1 < E.num_rows && E.row[row.idx - 1].hl_open_comment
    fence := trim + 2 < len(line) && line[trim] == '`' && line[trim + 1] == '`' && line[trim + 2] == '`'
    if fence {
        for i in 0 ..< row.rsize do row.hl[i] = .Hl_Comment
        row.hl_open_comment = !prev
        return
    }
    if prev {
        for i in 0 ..< row.rsize do row.hl[i] = .Hl_Comment
        row.hl_open_comment = true
        return
    }
    row.hl_open_comment = false
    if trim < len(line) && line[trim] == '#' {
        for i in 0 ..< row.rsize do row.hl[i] = .Hl_Keyword1
        return
    }
    in_code := false
    for i in 0 ..< len(line) {
        if line[i] == '`' {
            row.hl[i] = .Hl_String
            in_code = !in_code
            continue
        }
        if in_code && i < len(row.hl) do row.hl[i] = .Hl_String
    }
}

select_syntax_highlight :: proc() {
    E.syntax = nil
    if E.filename == "" do return
    if base_is(E.filename, "Makefile", "makefile", "GNUmakefile") {
        for &e in Hl_Db {
            if e.filetype == "make" {
                E.syntax = &e
                for r in 0 ..< E.num_rows do update_syntax(&E.row[r])
                return
            }
        }
    }
    for &e in Hl_Db {
        for ft in e.filematch {
            if file_has_suffix(E.filename, ft) {
                E.syntax = &e
                for r in 0 ..< E.num_rows do update_syntax(&E.row[r])
                return
            }
        }
    }
}

/*** util ***/

is_cntl :: proc(b: byte) -> bool {
    return b <= 31 || b == 127
}

cntl_key :: proc(b: byte) -> byte {
    return b & 0x1f
}

is_digit :: proc(b: byte) -> bool {
    return b >= '0' && b <= '9'
}

get_num_len :: proc(n: f64) -> int {
    if n <= 0. do return 1
    else do return int(math.log10(n)) + 1
}

/*** init ***/

init_editor :: proc() {
    E.cx, E.cy, E.num_rows, E.rowoff, E.coloff, E.rx = 0, 0, 0, 0, 0, 0
    E.dirty, E.syntax = 0, nil
    E.filename, E.status_msg, E.status_msg_time = "", "", time.now()
    E.crlf = ODIN_OS == .Windows
    E.sel_on = false
    E.want_rx = 0
    if get_window_size(&E) == .Err do die("get window size error")
    ide_init()   // the IDE layer derives the text area from the window size
}

main :: proc() {
    defer disable_raw_mode()
    enable_raw_mode()
    init_editor()

    // Show the default hint first, so anything the command line reports
    // ("New file", "looks like a binary file", ...) is what the user ends up seeing.
    set_status_message("Ctrl-S save | Ctrl-F find | Ctrl-Z undo | F1 help | Ctrl-Q quit")

    // `olio`            -> current directory as the project
    // `olio path/dir`   -> that directory as the project
    // `olio some.txt`   -> open it; if it does not exist, edit it as a new file
    if len(os.args) >= 2 {
        arg := abs_path(os.args[1])
        defer delete(arg)

        if fi, err := os.stat(arg, context.allocator); err == nil {
            if fi.type == .Directory {
                ide_set_root(arg)
            } else if buf_open(arg) {
                ide_set_root_from_file(arg)
            }
        } else {
            buf_open_new(arg)
            ide_set_root_from_file(arg)
        }
    }

    for {
        refresh_screen()
        handle_keypress()
        free_all(context.temp_allocator)
    }
}

