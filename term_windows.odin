#+build windows
package olio

// Windows implementation of the tiny terminal layer that olio needs.
// This replaces the POSIX `termios` raw-mode dance from olio.odin with the
// equivalent Win32 console calls, and gets the window size from the console
// API instead of a "cursor position report" escape sequence query.

import "core:fmt"
import "core:os"
import win32 "core:sys/windows"

/*
File IO without Odin's `os.open`.

`os._open_internal` always passes `FILE_FLAG_BACKUP_SEMANTICS` and
`CREATE_ALWAYS`. Endpoint agents (ransomware / DLP heuristics) commonly read
that combination -- "backup-style" handle + truncate + write -- as suspicious
and silently deny it, which shows up as `Permission_Denied` even though a normal
program may write the same file. Using a plain `CreateFileW` keeps olio's file
access indistinguishable from any other application's.
*/

write_file_raw :: proc(path: string, data: []byte) -> (written: int, err: string) {
	wide := win32.utf8_to_wstring_alloc(path, context.temp_allocator)
	if wide == nil do return 0, "cannot convert the path"

	h := win32.CreateFileW(
		wide,
		win32.FILE_GENERIC_WRITE,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		nil,
		win32.CREATE_ALWAYS,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win32.INVALID_HANDLE {
		return 0, fmt.tprintf("CreateFileW failed (%v)", win32.GetLastError())
	}
	defer win32.CloseHandle(h)

	for written < len(data) {
		n: win32.DWORD
		if !win32.WriteFile(h, raw_data(data[written:]), u32(len(data) - written), &n, nil) {
			return written, fmt.tprintf("WriteFile failed (%v)", win32.GetLastError())
		}
		if n == 0 do break
		written += int(n)
	}
	return written, ""
}

read_file_raw :: proc(path: string) -> (data: []byte, err: string) {
	wide := win32.utf8_to_wstring_alloc(path, context.temp_allocator)
	if wide == nil do return nil, "cannot convert the path"

	h := win32.CreateFileW(
		wide,
		win32.FILE_GENERIC_READ,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win32.INVALID_HANDLE {
		return nil, fmt.tprintf("CreateFileW failed (%v)", win32.GetLastError())
	}
	defer win32.CloseHandle(h)

	buf := make([dynamic]byte, 0, 64 * 1024)
	chunk: [64 * 1024]byte
	for {
		n: win32.DWORD
		if !win32.ReadFile(h, rawptr(&chunk[0]), u32(len(chunk)), &n, nil) {
			delete(buf)
			return nil, fmt.tprintf("ReadFile failed (%v)", win32.GetLastError())
		}
		if n == 0 do break
		append(&buf, ..chunk[:int(n)])
	}
	return buf[:], ""
}

// Stand-in for `posix.termios`: the console modes we must restore on exit.
Term_Mode :: struct {
	input:  win32.DWORD,
	output: win32.DWORD,
}

_std_handles :: proc() -> (inp, out: win32.HANDLE) {
	return win32.GetStdHandle(win32.STD_INPUT_HANDLE),
	       win32.GetStdHandle(win32.STD_OUTPUT_HANDLE)
}

enable_raw_mode :: proc() {
	inp, out := _std_handles()
	if inp == win32.INVALID_HANDLE || out == win32.INVALID_HANDLE {
		die("stdin/stdout is not a console")
	}
	if !win32.GetConsoleMode(inp, &E.origin_mode.input) do die("GetConsoleMode(stdin) error")
	if !win32.GetConsoleMode(out, &E.origin_mode.output) do die("GetConsoleMode(stdout) error")

	// Raw input: no echo, no line buffering, and no Ctrl-C/Ctrl-S processing,
	// while keeping virtual terminal input so escape sequences (arrow keys) arrive.
	raw := E.origin_mode.input
	raw &~= win32.ENABLE_ECHO_INPUT
	raw &~= win32.ENABLE_LINE_INPUT
	raw &~= win32.ENABLE_PROCESSED_INPUT
	raw |= win32.ENABLE_VIRTUAL_TERMINAL_INPUT
	if !win32.SetConsoleMode(inp, raw) do die("SetConsoleMode(stdin) error")

	// Virtual terminal output so all the ANSI escape sequences olio emits render.
	if !win32.SetConsoleMode(out, E.origin_mode.output | win32.ENABLE_PROCESSED_OUTPUT | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING) {
		die("SetConsoleMode(stdout) error")
	}
	// Bracketed paste, same sequence as on POSIX. Windows Terminal honors it.
	os.write_string(os.stdout, "\x1b[?2004h")
}

disable_raw_mode :: proc() {
	os.write_string(os.stdout, "\x1b[?2004l")
	inp, out := _std_handles()
	if inp == win32.INVALID_HANDLE || out == win32.INVALID_HANDLE do return
	win32.SetConsoleMode(inp, E.origin_mode.input)
	win32.SetConsoleMode(out, E.origin_mode.output)
}

get_window_size :: proc(conf: ^Config) -> Result {
	_, out := _std_handles()
	info: win32.CONSOLE_SCREEN_BUFFER_INFO
	if !win32.GetConsoleScreenBufferInfo(out, &info) do return .Err

	width  := int(info.srWindow.Right - info.srWindow.Left) + 1
	height := int(info.srWindow.Bottom - info.srWindow.Top) + 1
	if width <= 0 || height <= 0 do return .Err

	conf.screen_col = width
	conf.screen_row = height
	return .Ok
}

// Cheap resize check, called on every redraw (no escape-sequence round-trip).
poll_window_size :: proc() -> (rows, cols: int, ok: bool) {
	_, out := _std_handles()
	if out == win32.INVALID_HANDLE do return 0, 0, false

	info: win32.CONSOLE_SCREEN_BUFFER_INFO
	if !win32.GetConsoleScreenBufferInfo(out, &info) do return 0, 0, false

	width  := int(info.srWindow.Right - info.srWindow.Left) + 1
	height := int(info.srWindow.Bottom - info.srWindow.Top) + 1
	if width <= 0 || height <= 0 do return 0, 0, false

	return height, width, true
}

// Wait up to 100ms so Escape can be told apart from an escape sequence, and
// so a resize is noticed without a key. Window-size records are not bytes;
// they are discarded here and reported as a timeout so the editor remeasures.
read_input :: proc() -> (b: byte, ok, timed_out: bool) {
	inp, _ := _std_handles()
	for {
		r := win32.WaitForSingleObject(inp, 100)
		if r == win32.WAIT_TIMEOUT do return 0, false, true
		if r != win32.WAIT_OBJECT_0 do return 0, false, false

		rec: win32.INPUT_RECORD
		n: win32.DWORD
		if !win32.PeekConsoleInputW(inp, &rec, 1, &n) do return 0, false, false
		if n == 0 do continue
		if rec.EventType != .KEY_EVENT {
			win32.ReadConsoleInputW(inp, &rec, 1, &n)
			if rec.EventType == .WINDOW_BUFFER_SIZE_EVENT do return 0, false, true
			continue
		}
		if !rec.Event.KeyEvent.bKeyDown {
			win32.ReadConsoleInputW(inp, &rec, 1, &n)
			continue
		}
		buf: [1]byte
		got: win32.DWORD
		if !win32.ReadFile(inp, rawptr(&buf[0]), 1, &got, nil) || got == 0 {
			return 0, false, false
		}
		return buf[0], true, false
	}
}

// The real Windows clipboard. Ctrl-C / Ctrl-V talk to other programs.
clipboard_set :: proc(data: []byte) -> bool {
	u16s: []u16
	if len(data) > 0 {
		u16s = win32.utf8_to_utf16(string(data), context.temp_allocator)
		if u16s == nil do return false
	}
	if !win32.OpenClipboard(nil) do return false
	defer win32.CloseClipboard()

	nchars := len(u16s) + 1
	nbytes := win32.SIZE_T(nchars * 2)
	mem := win32.GlobalAlloc(win32.GHND, nbytes)
	if mem == nil do return false
	hg := cast(win32.HGLOBAL)mem
	ptr := win32.GlobalLock(hg)
	if ptr == nil {
		win32.GlobalFree(mem)
		return false
	}
	if len(u16s) > 0 {
		mem_copy(ptr, raw_data(u16s), len(u16s) * 2)
	}
	win32.GlobalUnlock(hg)
	// Empty only once the replacement is ready, so a failed alloc leaves
	// the previous clipboard contents alone.
	win32.EmptyClipboard()
	if win32.SetClipboardData(win32.CF_UNICODETEXT, cast(win32.HANDLE)hg) == nil {
		win32.GlobalFree(mem)
		return false
	}
	return true
}

clipboard_get :: proc() -> (data: []byte, ok: bool) {
	if !win32.OpenClipboard(nil) do return nil, false
	defer win32.CloseClipboard()
	h := win32.GetClipboardData(win32.CF_UNICODETEXT)
	if h == nil do return nil, false
	hg := cast(win32.HGLOBAL)h
	ptr := win32.GlobalLock(hg)
	if ptr == nil do return nil, false
	defer win32.GlobalUnlock(hg)
	ws := cast(win32.wstring)ptr
	s, err := win32.wstring_to_utf8_alloc(ws, -1, context.allocator)
	if err != nil do return nil, false
	out := make([]byte, len(s))
	copy(out, s)
	delete(s)
	return out, true
}

mem_copy :: proc(dst, src: rawptr, n: int) {
	if n <= 0 || dst == nil || src == nil do return
	d := ([^]byte)(dst)
	s := ([^]byte)(src)
	for i in 0 ..< n do d[i] = s[i]
}
