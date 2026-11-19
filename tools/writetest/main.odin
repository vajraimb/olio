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

check_token :: proc() {
	tok: win32.HANDLE
	if !win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &tok) {
		fmt.printf("token: OpenProcessToken failed (%v)\n", win32.GetLastError())
		return
	}
	defer win32.CloseHandle(tok)

	size: win32.DWORD
	win32.GetTokenInformation(tok, .TokenRestrictedSids, nil, 0, &size)
	if size > 0 {
		buf := make([]byte, int(size))
		defer delete(buf)
		if win32.GetTokenInformation(tok, .TokenRestrictedSids, raw_data(buf), size, &size) {
			count := (^u32)(raw_data(buf))^
			fmt.printf("token: restricted SIDs = %d%s\n", count, count > 0 ? "  <-- restricted token, writes are limited" : "")
		}
	} else {
		fmt.println("token: restricted SIDs = 0")
	}

	elev: win32.DWORD
	esize: win32.DWORD
	if win32.GetTokenInformation(tok, .TokenElevation, &elev, win32.DWORD(size_of(win32.DWORD)), &esize) {
		fmt.printf("token: elevated = %v\n", elev != 0)
	}
	etype: win32.DWORD
	if win32.GetTokenInformation(tok, .TokenElevationType, &etype, win32.DWORD(size_of(win32.DWORD)), &esize) {
		fmt.printf("token: elevation type = %d (1=default 2=full 3=limited)\n", etype)
	}
}

main :: proc() {
	fmt.println("olio writetest")
	fmt.println("==============")
	check_token()
	try_write("C:\\Users\\Michael.Bi\\.pie\\keys")
	try_write("C:\\Users\\Michael.Bi\\AppData\\Local\\Temp")
	fmt.println()
	fmt.println("Press Enter to close.")
	buf: [8]byte
	os.read(os.stdin, buf[:])
}
