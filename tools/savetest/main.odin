package main

// Throwaway probe: replicate exactly what editor_save does for a set of paths.

import "core:fmt"
import "core:os"

payload: []byte = { 'h', 'e', 'l', 'l', 'o', '\n' }

try :: proc(label: string, path: string) {
	fd, err := os.open(path, os.O_RDWR | os.O_CREATE | os.O_TRUNC, os.perm(0o644))
	if err != nil {
		fmt.printf("%-46s -> open error %v\n", label, err)
		return
	}
	defer os.close(fd)

	n, werr := os.write(fd, payload)
	if werr != nil {
		fmt.printf("%-46s -> write error %v\n", label, werr)
		return
	}
	fmt.printf("%-46s -> ok (%d bytes)\n", label, n)
}

main :: proc() {
	base, _ := os.lookup_env("TEMP", context.allocator)
	defer delete(base)

	new_dir := fmt.tprintf("%s\\olio-save-probe", base)
	os.make_directory_all(new_dir)

	try("new file in writable dir", fmt.tprintf("%s\\new.txt", new_dir))
	try("new file, nested missing dir", fmt.tprintf("%s\\no\\such\\dir\\new.txt", new_dir))
	try("existing writable file", fmt.tprintf("%s\\exists.txt", new_dir))
	try("path is a directory", new_dir)
	try("name with a quote", fmt.tprintf("%s\\a\"b.txt", new_dir))
	try("name with a colon", fmt.tprintf("%s\\a:b.txt", new_dir))
	try("name with a trailing space", fmt.tprintf("%s\\a .txt", new_dir))
	try("quoted path string", fmt.tprintf("\"%s\\quoted.txt\"", new_dir))
	try("dot-dot relative path", "..\\olio-save-probe\\rel.txt")

	if home, ok := os.lookup_env("USERPROFILE", context.allocator); ok {
		try("onedrive desktop", fmt.tprintf("%s\\OneDrive - EY CHINA\\Desktop\\olio-save-probe.txt", home))
		try("reserved name CON", fmt.tprintf("%s\\CON.txt", new_dir))
	}
}
