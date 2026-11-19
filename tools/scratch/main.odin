package scratch

import "core:fmt"

main :: proc() {
	fmt.println("olio ide demo")
	total := 1 + "two" // deliberate type error: the IDE must show and jump here
	fmt.println(total)
}
