#+build linux, darwin, netbsd, openbsd, freebsd
package olio

// POSIX implementation of the terminal layer, moved verbatim out of olio.odin
// so that the editor core is platform independent.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

Term_Mode :: posix.termios

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
}

disable_raw_mode :: proc() {
	if posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &E.origin_mode) != posix.result.OK do die("tcsetattr error")
}

get_cursor_pos :: proc(conf: ^Config) -> Result {
	buf: [dynamic]byte
	if _, err := os.write_string(os.stdout, "\x1b[6n"); err != nil do return .Err // report active position
	fmt.printf("\r\n")
	for i in 0..<size_of(buf) - 1 {
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
	if _, err := os.write_string(os.stdout, "\x1b[999C\x1b[999B"); err != nil do return .Err
	return get_cursor_pos(conf)
}
