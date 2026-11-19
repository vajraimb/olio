package hello

import "core:fmt"

main :: proc() {
	fmt.println("hello from olio's Ctrl-T")
	for i in 1 ..= 3 {
		fmt.println("line", i)
	}
}
