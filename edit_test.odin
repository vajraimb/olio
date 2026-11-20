package olio

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

g_test_mu: sync.Mutex

lock_editor :: proc() {
	sync.lock(&g_test_mu)
	reset_test_editor()
}

unlock_editor :: proc() {
	reset_test_editor()
	if len(search_query) > 0 {
		delete(search_query)
		search_query = ""
	}
	sync.unlock(&g_test_mu)
}

reset_test_editor :: proc() {
	for &r in E.row do free_row(&r)
	delete(E.row)
	free_edits(&E.undo)
	free_edits(&E.redo)
	if len(E.filename) > 0 do delete(E.filename)
	if len(E.status_msg) > 0 do delete(E.status_msg)
	E = {}
	E.crlf = false
	search_case = false
}

@(test)
test_utf8_steps :: proc(t: ^testing.T) {
	lock_editor()
	defer unlock_editor()
	line := []byte{ 'a', 0xC3, 0xA9, 'b' } // a é b
	testing.expect_value(t, next_rune_start(line, 0), 1)
	testing.expect_value(t, next_rune_start(line, 1), 3)
	testing.expect_value(t, prev_rune_start(line, 3), 1)
	testing.expect_value(t, prev_rune_start(line, 1), 0)
}

@(test)
test_undo_is_per_rune :: proc(t: ^testing.T) {
	lock_editor()
	defer unlock_editor()
	insert_char(0xC3)
	insert_char(0xA9)
	insert_char('x')
	testing.expect_value(t, len(E.undo), 2)
	testing.expect_value(t, E.row[0].size, 3)
	undo_edit()
	testing.expect_value(t, E.row[0].size, 2)
	testing.expect_value(t, E.row[0].chars[0], byte(0xC3))
	undo_edit()
	testing.expect_value(t, E.row[0].size, 0)
	redo_edit()
	testing.expect_value(t, E.row[0].size, 2)
}

@(test)
test_backspace_removes_rune :: proc(t: ^testing.T) {
	lock_editor()
	defer unlock_editor()
	insert_char(0xC3)
	insert_char(0xA9)
	backspace()
	testing.expect_value(t, E.num_rows, 1)
	testing.expect_value(t, E.row[0].size, 0)
	testing.expect_value(t, E.cx, 0)
}

@(test)
test_newline_keeps_indent :: proc(t: ^testing.T) {
	lock_editor()
	defer unlock_editor()
	insert_char(' ')
	insert_char(' ')
	insert_char('x')
	newline_indent()
	testing.expect_value(t, E.num_rows, 2)
	testing.expect_value(t, string(E.row[0].chars[:]), "  x")
	testing.expect_value(t, string(E.row[1].chars[:]), "  ")
	testing.expect_value(t, E.cy, 1)
	testing.expect_value(t, E.cx, 2)
}

@(test)
test_replace_and_undo :: proc(t: ^testing.T) {
	lock_editor()
	defer unlock_editor()
	for c in "Foo foo" do insert_char(byte(c))
	search_case = false
	replace_all("foo", "bar")
	got := buffer_snapshot()
	defer delete(got)
	testing.expect_value(t, string(got), "bar bar")
	undo_edit()
	again := buffer_snapshot()
	defer delete(again)
	testing.expect_value(t, string(again), "Foo foo")
}

@(test)
test_find_case_fold :: proc(t: ^testing.T) {
	lock_editor()
	defer unlock_editor()
	search_case = false
	testing.expect_value(t, find_in(str_bytes("xxAbCyy"), str_bytes("abc"), 0), 2)
	search_case = true
	testing.expect_value(t, find_in(str_bytes("xxAbCyy"), str_bytes("abc"), 0), -1)
	search_case = false
}

@(test)
test_crlf_roundtrip :: proc(t: ^testing.T) {
	lock_editor()
	defer unlock_editor()
	path := "/tmp/olio-crlf-test.txt"
	werr := os.write_entire_file(path, "a\r\nb\r\n")
	testing.expect(t, werr == nil)
	ok := editor_open(path)
	testing.expect(t, ok)
	testing.expect(t, E.crlf)
	testing.expect_value(t, E.num_rows, 2)
	testing.expect_value(t, string(E.row[0].chars[:]), "a")
	testing.expect_value(t, string(E.row[1].chars[:]), "b")
	insert_char('c')
	data, _ := rows_to_string()
	defer delete(data)
	testing.expect_value(t, string(data), "ca\r\nb\r\n")
}

@(test)
test_select_delete :: proc(t: ^testing.T) {
	lock_editor()
	defer unlock_editor()
	for c in "hello" do insert_char(byte(c))
	select_all()
	backspace()
	testing.expect_value(t, E.row[0].size, 0)
	undo_edit()
	snap := buffer_snapshot()
	defer delete(snap)
	testing.expect_value(t, string(snap), "hello")
}

@(test)
test_find_next :: proc(t: ^testing.T) {
	lock_editor()
	defer unlock_editor()
	for c in "foo" do insert_char(byte(c))
	newline_indent()
	for c in "bar" do insert_char(byte(c))
	search_query = strings.clone("bar")
	E.cy = 0
	E.cx = 0
	find_move(1)
	testing.expect_value(t, E.cy, 1)
	testing.expect_value(t, E.cx, 0)
}
