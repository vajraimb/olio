package main

// One-off diagnostic: can a plain unsigned exe write where the user asks?
// Double-click writetest.exe and read the two result lines.

import "core:fmt"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"

try_write :: proc(dir: string) {
	path := strings.concatenate({dir, "\\writetest.txt"})
	defer delete(path)
	wide := win32.utf8_to_wstring_alloc(path, context.temp_allocator)

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
		fmt.printf("FAIL  %s  (CreateFileW error %v)\n", path, win32.GetLastError())
		return
	}
	defer win32.CloseHandle(h)

	n: win32.DWORD
	msg := "ok\n"
	ok := win32.WriteFile(h, rawptr(raw_data(msg)), u32(len(msg)), &n, nil)
	if !ok {
		fmt.printf("FAIL  %s  (WriteFile error %v)\n", path, win32.GetLastError())
		return
	}
	win32.CloseHandle(h)
	os.remove(path)
	fmt.printf("OK    %s\n", path)
	delete(path)
}

main :: proc() {
	fmt.println("olio writetest")
	fmt.println("==============")
	try_write("C:\\Users\\Michael.Bi\\.pie\\keys")
	try_write("C:\\Users\\Michael.Bi\\AppData\\Local\\Temp")
	fmt.println()
	fmt.println("Press Enter to close.")
	buf: [8]byte
	os.read(os.stdin, buf[:])
}
