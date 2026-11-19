#+build windows
package olio

// Windows implementation of the tiny terminal layer that olio needs.
// This replaces the POSIX `termios` raw-mode dance from olio.odin with the
// equivalent Win32 console calls, and gets the window size from the console
// API instead of a "cursor position report" escape sequence query.

import "core:fmt"
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
}

disable_raw_mode :: proc() {
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
