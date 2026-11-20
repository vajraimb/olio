#+build linux, darwin, netbsd, openbsd, freebsd
package olio

// POSIX implementation of the terminal layer, moved verbatim out of olio.odin
// so that the editor core is platform independent.

import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import clib "system:System"
} else {
	foreign import clib "system:c"
}

@(default_calling_convention = "c")
foreign clib {
	@(link_name = "ioctl")
	c_ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
}

Win_Size :: struct {
	row, col, xpixel, ypixel: u16,
}

// Linux 0x5413. Darwin/FreeBSD/NetBSD/OpenBSD use the same _IOR('t', 104, winsize).
TIOCGWINSZ :: c.ulong(0x5413) when ODIN_OS == .Linux else c.ulong(0x40087468)

Term_Mode :: posix.termios

// On POSIX there is no `FILE_FLAG_BACKUP_SEMANTICS` equivalent to avoid, so the
// regular os package is fine here (same signature as the Windows version).
write_file_raw :: proc(path: string, data: []byte) -> (written: int, err: string) {
	fd, oerr := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.perm(0o644))
	if oerr != nil do return 0, fmt.tprintf("%v", oerr)
	defer os.close(fd)

	for written < len(data) {
		n, werr := os.write(fd, data[written:])
		if werr != nil do return written, fmt.tprintf("%v", werr)
		if n <= 0 do break
		written += n
	}
	return written, ""
}

read_file_raw :: proc(path: string) -> (data: []byte, err: string) {
	content, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil do return nil, fmt.tprintf("%v", rerr)
	return content, ""
}

enable_raw_mode :: proc() {
	if posix.tcgetattr(posix.STDIN_FILENO, &E.origin_mode) != posix.result.OK do die("tcgetattr error")
	raw := E.origin_mode
	raw.c_iflag -= {
		posix.CInput_Flag_Bits.BRKINT,
		posix.CInput_Flag_Bits.ICRNL,
		posix.CInput_Flag_Bits.INPCK,
		posix.CInput_Flag_Bits.ISTRIP,
		posix.CInput_Flag_Bits.IXON,
	}
	raw.c_oflag -= {
		posix.COutput_Flag_Bits.OPOST,
	}
	raw.c_cflag -= {
		posix.CControl_Flag_Bits.CS8,
	}
	raw.c_lflag -= {
		posix.CLocal_Flag_Bits.ECHO,
		posix.CLocal_Flag_Bits.ICANON,
		posix.CLocal_Flag_Bits.IEXTEN,
		posix.CLocal_Flag_Bits.ISIG,
	}
	raw.c_cc[posix.Control_Char.VMIN] = 0
	raw.c_cc[posix.Control_Char.VTIME] = 1
	if posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &raw) != posix.result.OK do die("tcsetattr error")
	// Bracketed paste: the terminal wraps external pastes in ESC[200~ ... ESC[201~.
	os.write_string(os.stdout, "\x1b[?2004h")
}

disable_raw_mode :: proc() {
	os.write_string(os.stdout, "\x1b[?2004l")
	if posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &E.origin_mode) != posix.result.OK do die("tcsetattr error")
}

get_cursor_pos :: proc(conf: ^Config) -> Result {
	buf: [dynamic]byte
	if _, err := os.write_string(os.stdout, "\x1b[6n"); err != nil do return .Err // report active position
	fmt.printf("\r\n")
	for _ in 0 ..< 32 {
		b: [1]byte
		if _, err := os.read(os.stdin, b[:]); err != nil do break
		if b[0] == 'R' do break
		append(&buf, b[0])
	}
	if buf[0] != '\x1b' || buf[1] != '[' do return .Err // parse the response which is a escape sequence
	res := buf[2:]
	if ss := strings.split(string(res), ";"); len(ss) == 2 {
		if res, ok := strconv.parse_int(ss[0]); ok do conf.screen_row = res
		if res, ok := strconv.parse_int(ss[1]); ok do conf.screen_col = res
	}
	return .Ok
}

get_window_size :: proc(conf: ^Config) -> Result {
	if rows, cols, ok := poll_window_size(); ok {
		conf.screen_row = rows
		conf.screen_col = cols
		return .Ok
	}
	if _, err := os.write_string(os.stdout, "\x1b[999C\x1b[999B"); err != nil do return .Err
	return get_cursor_pos(conf)
}

poll_window_size :: proc() -> (rows, cols: int, ok: bool) {
	ws: Win_Size
	ret := c_ioctl(1, TIOCGWINSZ, &ws)
	if ret < 0 || ws.col == 0 || ws.row == 0 do return 0, 0, false
	return int(ws.row), int(ws.col), true
}

// VMIN 0 / VTIME 1: a read with no input returns after 100ms.
read_input :: proc() -> (b: byte, ok, timed_out: bool) {
	buf: [1]byte
	n, err := os.read(os.stdin, buf[:])
	if err != nil do return 0, false, false
	if n <= 0 do return 0, false, true
	return buf[0], true, false
}

// OSC 52 so terminals that support it (Windows Terminal, xterm, kitty, …)
// also update the system clipboard. Reading it back is not portable here;
// bracketed paste covers inbound text.
clipboard_set :: proc(data: []byte) -> bool {
	if len(data) == 0 || len(data) > 64 * 1024 do return false
	enc, err := base64.encode(data, allocator = context.temp_allocator)
	if err != nil do return false
	msg := fmt.tprintf("\x1b]52;c;%s\x07", enc)
	os.write_string(os.stdout, msg)
	return true
}

clipboard_get :: proc() -> ([]byte, bool) {
	return nil, false
}
