#+build windows
package olio

// Windows implementation of the tiny terminal layer that olio needs.
// This replaces the POSIX `termios` raw-mode dance from olio.odin with the
// equivalent Win32 console calls, and gets the window size from the console
// API instead of a "cursor position report" escape sequence query.

import win32 "core:sys/windows"

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
