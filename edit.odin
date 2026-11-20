package olio

// Editing operations that sit on olio's row buffer: codepoint motion, undo,
// selection, find/replace, and smart indent.
//
// The shape of these operations follows JOHN (João Carvalho, MIT), reimplemented
// here against olio's kilo-style rows rather than copied across. See README.md.

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

Mod :: enum {
	Shift,
	Alt,
	Ctrl,
}

key_mods: bit_set[Mod]

Edit_Kind :: enum {
	Ins,
	Del,
	Snap,
}

// One undo record. `text` is owned by the record.
// Ins/Del: `row`,`col` is where the text was inserted or removed.
// Snap: `text` is the whole buffer (rows joined by '\n') to restore.
Edit :: struct {
	kind:          Edit_Kind,
	row, col:      int,
	text:          []byte,
	cx0, cy0:      int,
	cx1, cy1:      int,
}

Undo_Max :: 200

clip: [dynamic]byte
clip_linewise: bool
clip_local_only: bool
paste_buf: [dynamic]byte

search_query: string
search_case: bool // false = case-insensitive, the default

/* ------------------------------------------------------------ utf-8 */

next_rune_start :: proc(line: []byte, i: int) -> int {
	if i >= len(line) do return len(line)
	if i < 0 do return 0
	_, n := utf8.decode_rune(line[i:])
	if n <= 0 do n = 1
	return i + n
}

prev_rune_start :: proc(line: []byte, i: int) -> int {
	at := i
	if at <= 0 do return 0
	if at > len(line) do at = len(line)
	j := at - 1
	for j > 0 && line[j] & 0xC0 == 0x80 do j -= 1
	return j
}

is_word_byte :: proc(c: byte) -> bool {
	if c >= 0x80 do return true
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

str_bytes :: proc(s: string) -> []byte {
	if len(s) == 0 do return nil
	return ([^]byte)(raw_data(s))[:len(s)]
}

/* -------------------------------------------------------------- undo */

free_edits :: proc(ed: ^[dynamic]Edit) {
	for &e in ed do delete(e.text)
	delete(ed^)
	ed^ = {}
}

clear_redo :: proc() {
	free_edits(&E.redo)
}

note_dirty :: proc() {
	E.dirty = len(E.undo) != E.saved_undo_len ? 1 : 0
}

reset_history :: proc() {
	free_edits(&E.undo)
	free_edits(&E.redo)
	E.saved_undo_len = 0
	E.dirty = 0
}

mark_saved :: proc() {
	E.saved_undo_len = len(E.undo)
	E.dirty = 0
}

push_undo :: proc(e: Edit) {
	if e.kind == .Ins && len(e.text) == 1 && e.text[0] & 0xC0 == 0x80 && len(E.undo) > 0 {
		last := &E.undo[len(E.undo) - 1]
		if last.kind == .Ins && len(last.text) > 0 && !utf8.valid_string(string(last.text)) {
			er, ec := span_end(last.row, last.col, last.text)
			if er == e.row && ec == e.col {
				n := make([]byte, len(last.text) + len(e.text))
				copy(n, last.text)
				copy(n[len(last.text):], e.text)
				delete(last.text)
				delete(e.text)
				last.text = n
				last.cx1, last.cy1 = e.cx1, e.cy1
				clear_redo()
				note_dirty()
				return
			}
		}
	}
	if len(E.undo) < E.saved_undo_len do E.saved_undo_len = -1
	append(&E.undo, e)
	for len(E.undo) > Undo_Max {
		delete(E.undo[0].text)
		ordered_remove(&E.undo, 0)
		if E.saved_undo_len > 0 do E.saved_undo_len -= 1
	}
	clear_redo()
	note_dirty()
}

span_end :: proc(row, col: int, text: []byte) -> (int, int) {
	r, c := row, col
	for b in text {
		if b == '\n' {
			r += 1
			c = 0
		} else {
			c += 1
		}
	}
	return r, c
}

reindex_rows :: proc() {
	for i in 0 ..< len(E.row) do E.row[i].idx = i
	E.num_rows = len(E.row)
}

clamp_cursor :: proc() {
	if E.num_rows == 0 {
		E.cy, E.cx = 0, 0
		return
	}
	if E.cy < 0 do E.cy = 0
	if E.cy > E.num_rows do E.cy = E.num_rows
	if E.cy >= E.num_rows {
		E.cx = 0
		return
	}
	if E.cx < 0 do E.cx = 0
	if E.cx > E.row[E.cy].size do E.cx = E.row[E.cy].size
	if E.cx > 0 && E.cx < E.row[E.cy].size && E.row[E.cy].chars[E.cx] & 0xC0 == 0x80 {
		E.cx = prev_rune_start(E.row[E.cy].chars[:], E.cx)
	}
}

sync_want :: proc() {
	if E.cy >= 0 && E.cy < E.num_rows {
		E.want_rx = row_cx_to_rx(&E.row[E.cy], E.cx)
	} else {
		E.want_rx = 0
	}
}

// Insert `text` (which may contain '\n') at row/col. Returns the cursor at the
// end of the inserted text. When `record` is set, one undo entry is pushed.
editor_insert_text :: proc(row, col: int, text: []byte, record: bool) -> (er, ec: int) {
	cx0, cy0 := E.cx, E.cy
	if len(text) == 0 {
		return row, col
	}
	if E.num_rows == 0 {
		append(&E.row, E_Row{})
		reindex_rows()
	}
	r := row
	if r < 0 do r = 0
	if r >= E.num_rows do r = E.num_rows - 1
	c := col
	if c < 0 do c = 0
	if c > E.row[r].size do c = E.row[r].size
	orig_r, orig_c := r, c

	start := 0
	first := true
	for i := 0; i <= len(text); i += 1 {
		if i == len(text) || text[i] == '\n' {
			seg := text[start:i]
			if first {
				line := &E.row[r]
				inject_at(&line.chars, c, ..seg)
				line.size = len(line.chars)
				c += len(seg)
				first = false
			} else {
				cur := &E.row[r]
				rest_len := len(cur.chars) - c
				rest := make([]byte, rest_len)
				if rest_len > 0 do copy(rest, cur.chars[c:])
				resize(&cur.chars, c)
				cur.size = c

				nr := E_Row {
					size  = len(seg) + rest_len,
					chars = make([dynamic]byte, 0, len(seg) + rest_len),
				}
				append(&nr.chars, ..seg)
				append(&nr.chars, ..rest)
				delete(rest)
				r += 1
				inject_at(&E.row, r, nr)
				c = len(seg)
			}
			start = i + 1
		}
	}
	reindex_rows()
	last := r
	if orig_r < 0 do orig_r = 0
	if last >= E.num_rows do last = E.num_rows - 1
	for i in orig_r ..= last {
		editor_update_row(&E.row[i])
	}
	if orig_r < E.num_rows do update_syntax(&E.row[orig_r])

	if record {
		owned := slice.clone(text)
		push_undo(Edit {
			kind = .Ins,
			row = orig_r, col = orig_c,
			text = owned,
			cx0 = cx0, cy0 = cy0,
			cx1 = c, cy1 = r,
		})
	}
	return r, c
}

// Delete the half-open span from (r1,c1) to (r2,c2). Cursor ends up at the
// start of the span.
editor_delete_range :: proc(row1, col1, row2, col2: int, record: bool) {
	if E.num_rows == 0 do return
	cx0, cy0 := E.cx, E.cy
	r1, c1, r2, c2 := row1, col1, row2, col2
	if r1 > r2 || (r1 == r2 && c1 > c2) {
		r1, c1, r2, c2 = r2, c2, r1, c1
	}
	if r1 < 0 do r1 = 0
	if r2 >= E.num_rows do r2 = E.num_rows - 1
	if r1 >= E.num_rows do return
	if c1 < 0 do c1 = 0
	if c1 > E.row[r1].size do c1 = E.row[r1].size
	if c2 < 0 do c2 = 0
	if c2 > E.row[r2].size do c2 = E.row[r2].size
	if r1 == r2 && c1 == c2 do return

	collected := make([dynamic]byte, 0, 64)
	if r1 == r2 {
		line := &E.row[r1]
		append(&collected, ..line.chars[c1:c2])
		remove_range(&line.chars, c1, c2)
		line.size = len(line.chars)
		editor_update_row(line)
	} else {
		append(&collected, ..E.row[r1].chars[c1:])
		append(&collected, '\n')
		for r in r1 + 1 ..< r2 {
			append(&collected, ..E.row[r].chars[:])
			append(&collected, '\n')
		}
		append(&collected, ..E.row[r2].chars[:c2])

		first := &E.row[r1]
		tail := E.row[r2].chars[c2:]
		resize(&first.chars, c1)
		append(&first.chars, ..tail)
		first.size = len(first.chars)

		for r := r2; r >= r1 + 1; r -= 1 {
			free_row(&E.row[r])
			ordered_remove(&E.row, r)
		}
		reindex_rows()
		if E.num_rows == 0 {
			append(&E.row, E_Row{})
			reindex_rows()
		}
		editor_update_row(&E.row[r1])
		update_syntax(&E.row[r1])
	}

	owned := slice.clone(collected[:])
	delete(collected)
	E.cx, E.cy = c1, r1
	clamp_cursor()
	sync_want()
	if record {
		push_undo(Edit {
			kind = .Del,
			row = r1, col = c1,
			text = owned,
			cx0 = cx0, cy0 = cy0,
			cx1 = E.cx, cy1 = E.cy,
		})
	} else {
		delete(owned)
	}
}

buffer_snapshot :: proc() -> []byte {
	b := make([dynamic]byte, 0, 256)
	for row, i in E.row {
		append(&b, ..row.chars[:])
		if i + 1 < len(E.row) do append(&b, '\n')
	}
	out := slice.clone(b[:])
	delete(b)
	return out
}

restore_snapshot :: proc(data: []byte) {
	for &row in E.row do free_row(&row)
	clear(&E.row)
	E.num_rows = 0
	if len(data) == 0 {
		append(&E.row, E_Row{})
		reindex_rows()
		editor_update_row(&E.row[0])
		return
	}
	start := 0
	for i in 0 ..= len(data) {
		if i == len(data) || data[i] == '\n' {
			line := data[start:i]
			nr := E_Row {
				size  = len(line),
				chars = slice.clone_to_dynamic(line),
			}
			append(&E.row, nr)
			start = i + 1
		}
	}
	reindex_rows()
	select_syntax_highlight()
	if E.syntax == nil {
		for i in 0 ..< E.num_rows do editor_update_row(&E.row[i])
	}
}

apply_undo :: proc(from, to: ^[dynamic]Edit, is_undo: bool) -> bool {
	if len(from) == 0 do return false
	e := pop(from)
	switch e.kind {
	case .Snap:
		now := buffer_snapshot()
		ncx, ncy := E.cx, E.cy
		restore_snapshot(e.text)
		delete(e.text)
		E.cx, E.cy = e.cx0, e.cy0
		clamp_cursor()
		sync_want()
		append(to, Edit{kind = .Snap, text = now, cx0 = ncx, cy0 = ncy})
	case .Ins:
		if is_undo {
			er, ec := span_end(e.row, e.col, e.text)
			editor_delete_range(e.row, e.col, er, ec, false)
			E.cx, E.cy = e.cx0, e.cy0
		} else {
			editor_insert_text(e.row, e.col, e.text, false)
			E.cx, E.cy = e.cx1, e.cy1
		}
		clamp_cursor()
		sync_want()
		append(to, e)
	case .Del:
		if is_undo {
			editor_insert_text(e.row, e.col, e.text, false)
			E.cx, E.cy = e.cx0, e.cy0
		} else {
			er, ec := span_end(e.row, e.col, e.text)
			editor_delete_range(e.row, e.col, er, ec, false)
			E.cx, E.cy = e.cx1, e.cy1
		}
		clamp_cursor()
		sync_want()
		append(to, e)
	}
	clear_sel()
	note_dirty()
	return true
}

undo_edit :: proc() {
	if !apply_undo(&E.undo, &E.redo, true) {
		set_status_message("Nothing to undo")
		return
	}
	set_status_message("Undo")
}

redo_edit :: proc() {
	if !apply_undo(&E.redo, &E.undo, false) {
		set_status_message("Nothing to redo")
		return
	}
	set_status_message("Redo")
}

/* --------------------------------------------------------- selection */

clear_sel :: proc() {
	E.sel_on = false
}

begin_move :: proc(extend: bool) {
	if extend {
		if !E.sel_on {
			E.sel_on = true
			E.sel_cy, E.sel_cx = E.cy, E.cx
		}
	} else {
		clear_sel()
	}
}

pos_before :: proc(ay, ax, by, bx: int) -> bool {
	if ay != by do return ay < by
	return ax < bx
}

selection_bounds :: proc() -> (y0, x0, y1, x1: int, ok: bool) {
	if !E.sel_on do return 0, 0, 0, 0, false
	if pos_before(E.sel_cy, E.sel_cx, E.cy, E.cx) {
		return E.sel_cy, E.sel_cx, E.cy, E.cx, true
	}
	if E.sel_cy == E.cy && E.sel_cx == E.cx do return 0, 0, 0, 0, false
	return E.cy, E.cx, E.sel_cy, E.sel_cx, true
}

// Display-column span of the selection on a file row. `to` is exclusive.
selection_cols :: proc(filerow: int) -> (from, to: int, ok: bool) {
	y0, x0, y1, x1, has := selection_bounds()
	if !has do return 0, 0, false
	if filerow < y0 || filerow > y1 do return 0, 0, false
	if filerow >= E.num_rows do return 0, 0, false
	row := &E.row[filerow]
	from = 0
	to = row_cx_to_rx(row, row.size)
	if filerow == y0 do from = row_cx_to_rx(row, x0)
	if filerow == y1 do to = row_cx_to_rx(row, x1)
	if from >= to do return 0, 0, false
	return from, to, true
}

selection_text :: proc() -> []byte {
	y0, x0, y1, x1, ok := selection_bounds()
	if !ok do return nil
	out := make([dynamic]byte, 0, 64)
	if y0 == y1 {
		append(&out, ..E.row[y0].chars[x0:x1])
	} else {
		append(&out, ..E.row[y0].chars[x0:])
		append(&out, '\n')
		for r in y0 + 1 ..< y1 {
			append(&out, ..E.row[r].chars[:])
			append(&out, '\n')
		}
		append(&out, ..E.row[y1].chars[:x1])
	}
	res := slice.clone(out[:])
	delete(out)
	return res
}

delete_selection :: proc() -> bool {
	y0, x0, y1, x1, ok := selection_bounds()
	if !ok do return false
	clear_sel()
	editor_delete_range(y0, x0, y1, x1, true)
	return true
}

select_all :: proc() {
	if E.num_rows == 0 do return
	E.sel_on = true
	E.sel_cy, E.sel_cx = 0, 0
	E.cy = E.num_rows - 1
	E.cx = E.row[E.cy].size
	sync_want()
}

select_line :: proc() {
	if E.cy >= E.num_rows do return
	E.sel_on = true
	E.sel_cy = E.cy
	E.sel_cx = 0
	if E.cy + 1 < E.num_rows {
		E.cy += 1
		E.cx = 0
	} else {
		E.cx = E.row[E.cy].size
	}
	sync_want()
}

set_clip :: proc(data: []byte, linewise: bool) {
	delete(clip)
	clip = slice.clone_to_dynamic(data)
	clip_linewise = linewise
	if clipboard_set(data) {
		clip_local_only = false
	} else {
		clip_local_only = true
	}
}

copy_selection :: proc() {
	if E.sel_on {
		text := selection_text()
		if text == nil {
			set_status_message("Nothing to copy")
			return
		}
		set_clip(text, false)
		delete(text)
		set_status_message("Copied selection")
		return
	}
	if E.cy >= E.num_rows do return
	line := E.row[E.cy].chars[:]
	text := make([]byte, len(line) + 1)
	copy(text, line)
	text[len(text) - 1] = '\n'
	set_clip(text, true)
	delete(text)
	set_status_message("Copied line")
}

cut_selection :: proc() {
	if E.sel_on {
		text := selection_text()
		if text == nil do return
		set_clip(text, false)
		delete(text)
		delete_selection()
		set_status_message("Cut selection")
		return
	}
	if E.cy >= E.num_rows do return
	line := E.row[E.cy].chars[:]
	text := make([]byte, len(line) + 1)
	copy(text, line)
	text[len(text) - 1] = '\n'
	set_clip(text, true)
	delete(text)
	if E.cy + 1 < E.num_rows {
		editor_delete_range(E.cy, 0, E.cy + 1, 0, true)
	} else if E.cy > 0 {
		editor_delete_range(E.cy - 1, E.row[E.cy - 1].size, E.cy, E.row[E.cy].size, true)
	} else {
		editor_delete_range(0, 0, 0, E.row[0].size, true)
	}
	set_status_message("Cut line")
}

normalize_newlines :: proc(text: []byte) -> []byte {
	out := make([dynamic]byte, 0, len(text))
	for i := 0; i < len(text); i += 1 {
		if text[i] == '\r' {
			append(&out, '\n')
			if i + 1 < len(text) && text[i + 1] == '\n' do i += 1
		} else {
			append(&out, text[i])
		}
	}
	res := slice.clone(out[:])
	delete(out)
	return res
}

paste_text :: proc(text: []byte) {
	if len(text) == 0 do return
	norm := normalize_newlines(text)
	defer delete(norm)
	delete_selection()
	if E.cy > E.num_rows do E.cy = E.num_rows
	er, ec := editor_insert_text(E.cy, E.cx, norm, true)
	E.cy, E.cx = er, ec
	clamp_cursor()
	sync_want()
}

paste_clip :: proc() {
	if !clip_local_only {
		if data, ok := clipboard_get(); ok {
			paste_text(data)
			delete(data)
			return
		}
	}
	if len(clip) == 0 {
		set_status_message("Clipboard is empty")
		return
	}
	if clip_linewise && E.cy <= E.num_rows {
		if E.cy == E.num_rows && E.num_rows > 0 do E.cy = E.num_rows - 1
		delete_selection()
		er, ec := editor_insert_text(E.cy, 0, clip[:], true)
		E.cy, E.cx = er, ec
		clamp_cursor()
		sync_want()
		return
	}
	paste_text(clip[:])
}

paste_pending :: proc() {
	if len(paste_buf) == 0 do return
	paste_text(paste_buf[:])
	clear(&paste_buf)
}

/* ------------------------------------------------------------- motion */

h_step :: proc(dir: int, extend: bool) {
	begin_move(extend)
	if E.num_rows == 0 do return
	if E.cy > E.num_rows do E.cy = E.num_rows
	if dir < 0 {
		if E.cy >= E.num_rows {
			E.cy = E.num_rows - 1
			E.cx = E.row[E.cy].size
			sync_want()
			return
		}
		if E.cx > 0 {
			E.cx = prev_rune_start(E.row[E.cy].chars[:], E.cx)
		} else if E.cy > 0 {
			E.cy -= 1
			E.cx = E.row[E.cy].size
		}
	} else if E.cy < E.num_rows {
		line := E.row[E.cy].chars[:]
		if E.cx < len(line) {
			E.cx = next_rune_start(line, E.cx)
		} else if E.cy < E.num_rows - 1 {
			E.cy += 1
			E.cx = 0
		}
	}
	sync_want()
}

v_step :: proc(dir: int, extend: bool) {
	begin_move(extend)
	if E.num_rows == 0 do return
	E.cy += dir
	if E.cy < 0 do E.cy = 0
	if E.cy > E.num_rows do E.cy = E.num_rows
	if E.cy < E.num_rows {
		E.cx = row_rx_to_cx(&E.row[E.cy], E.want_rx)
	} else {
		E.cx = 0
	}
}

move_home :: proc(extend: bool) {
	begin_move(extend)
	if E.cy >= E.num_rows {
		E.cx = 0
		sync_want()
		return
	}
	row := E.row[E.cy].chars[:]
	first := 0
	for first < len(row) && (row[first] == ' ' || row[first] == '\t') do first += 1
	if E.cx != first do E.cx = first
	else do E.cx = 0
	sync_want()
}

move_end :: proc(extend: bool) {
	begin_move(extend)
	if E.cy < E.num_rows do E.cx = E.row[E.cy].size
	sync_want()
}

jump_buffer_edge :: proc(home: bool, extend: bool) {
	begin_move(extend)
	if E.num_rows == 0 {
		E.cy, E.cx = 0, 0
		return
	}
	if home {
		E.cy, E.cx = 0, 0
	} else {
		E.cy = E.num_rows - 1
		E.cx = E.row[E.cy].size
	}
	sync_want()
}

move_word :: proc(dir: int, extend: bool) {
	begin_move(extend)
	if E.num_rows == 0 do return
	if E.cy >= E.num_rows do E.cy = E.num_rows - 1
	if dir > 0 {
		row := E.row[E.cy].chars[:]
		i := E.cx
		for i < len(row) && is_word_byte(row[i]) do i = next_rune_start(row, i)
		for i < len(row) && !is_word_byte(row[i]) do i = next_rune_start(row, i)
		if i == E.cx {
			if E.cy < E.num_rows - 1 {
				E.cy += 1
				E.cx = 0
			}
		} else {
			E.cx = i
		}
	} else {
		row := E.row[E.cy].chars[:]
		i := E.cx
		for i > 0 {
			j := prev_rune_start(row, i)
			if is_word_byte(row[j]) do break
			i = j
		}
		for i > 0 {
			j := prev_rune_start(row, i)
			if !is_word_byte(row[j]) do break
			i = j
		}
		if i == E.cx {
			if E.cy > 0 {
				E.cy -= 1
				E.cx = E.row[E.cy].size
			}
		} else {
			E.cx = i
		}
	}
	sync_want()
}

/* ------------------------------------------------------- text edits */

insert_char :: proc(c: byte) {
	delete_selection()
	if E.cy > E.num_rows do E.cy = E.num_rows
	er, ec := editor_insert_text(E.cy, E.cx, []byte{c}, true)
	E.cy, E.cx = er, ec
	sync_want()
}

newline_indent :: proc() {
	delete_selection()
	if E.num_rows == 0 || E.cy >= E.num_rows {
		er, ec := editor_insert_text(E.cy, E.cx, []byte{'\n'}, true)
		E.cy, E.cx = er, ec
		sync_want()
		return
	}
	row := E.row[E.cy].chars[:]
	n := 0
	for n < len(row) && (row[n] == ' ' || row[n] == '\t') do n += 1
	text := make([]byte, 1 + n)
	text[0] = '\n'
	copy(text[1:], row[:n])
	er, ec := editor_insert_text(E.cy, E.cx, text, true)
	delete(text)
	E.cy, E.cx = er, ec
	sync_want()
}

backspace :: proc() {
	if delete_selection() do return
	if E.num_rows == 0 do return
	if E.cy >= E.num_rows {
		E.cy = E.num_rows - 1
		E.cx = E.row[E.cy].size
	}
	if E.cx > 0 {
		prev := prev_rune_start(E.row[E.cy].chars[:], E.cx)
		editor_delete_range(E.cy, prev, E.cy, E.cx, true)
		return
	}
	if E.cy == 0 do return
	editor_delete_range(E.cy - 1, E.row[E.cy - 1].size, E.cy, 0, true)
}

delete_forward :: proc() {
	if delete_selection() do return
	if E.cy >= E.num_rows do return
	line := E.row[E.cy].chars[:]
	if E.cx < len(line) {
		nxt := next_rune_start(line, E.cx)
		editor_delete_range(E.cy, E.cx, E.cy, nxt, true)
		return
	}
	if E.cy + 1 < E.num_rows {
		editor_delete_range(E.cy, E.cx, E.cy + 1, 0, true)
	}
}

duplicate_line :: proc() {
	if E.cy >= E.num_rows do return
	col := E.cx
	line := E.row[E.cy].chars[:]
	text := make([]byte, len(line) + 1)
	text[0] = '\n'
	copy(text[1:], line)
	er, _ := editor_insert_text(E.cy, E.row[E.cy].size, text, true)
	delete(text)
	E.cy = er
	E.cx = col
	if E.cx > E.row[E.cy].size do E.cx = E.row[E.cy].size
	sync_want()
}

/* --------------------------------------------------------------- find */

ascii_fold :: proc(c: byte) -> byte {
	if c >= 'A' && c <= 'Z' do return c + 32
	return c
}

find_in :: proc(hay, needle: []byte, from: int) -> int {
	if len(needle) == 0 do return -1
	start := from
	if start < 0 do start = 0
	if start > len(hay) do return -1
	if search_case {
		idx := strings.index(string(hay[start:]), string(needle))
		if idx < 0 do return -1
		return start + idx
	}
	if len(needle) > len(hay) - start do return -1
	for i in start ..= len(hay) - len(needle) {
		match := true
		for j in 0 ..< len(needle) {
			if ascii_fold(hay[i + j]) != ascii_fold(needle[j]) {
				match = false
				break
			}
		}
		if match do return i
	}
	return -1
}

chars_to_render_index :: proc(row: ^E_Row, cx: int) -> int {
	ri := 0
	j := 0
	limit := cx
	if limit > row.size do limit = row.size
	if limit < 0 do limit = 0
	for j < limit {
		if row.chars[j] == '\t' {
			ri += 1
			for ri % Tab_Stop != 0 do ri += 1
			j += 1
			continue
		}
		_, n := utf8.decode_rune(row.chars[j:])
		if n <= 0 do n = 1
		if j + n > limit {
			ri += limit - j
			break
		}
		ri += n
		j += n
	}
	return ri
}

saved_hl_line := -1
saved_hl: [dynamic]Highlight

clear_find_hl :: proc() {
	if len(saved_hl) == 0 do return
	if saved_hl_line >= 0 && saved_hl_line < E.num_rows && len(E.row[saved_hl_line].hl) == len(saved_hl) {
		copy(E.row[saved_hl_line].hl[:], saved_hl[:])
	}
	clear(&saved_hl)
	saved_hl_line = -1
}

mark_match :: proc(row, byte_at, n: int) {
	clear_find_hl()
	if row < 0 || row >= E.num_rows do return
	r := &E.row[row]
	r0 := chars_to_render_index(r, byte_at)
	r1 := chars_to_render_index(r, byte_at + n)
	if r0 < 0 do r0 = 0
	if r1 > len(r.hl) do r1 = len(r.hl)
	saved_hl_line = row
	resize(&saved_hl, r.rsize)
	if r.rsize > 0 do copy(saved_hl[:], r.hl[:])
	for j in r0 ..< r1 {
		if j >= 0 && j < len(r.hl) do r.hl[j] = .Hl_Match
	}
	E.cy = row
	E.cx = byte_at
	E.rowoff = E.num_rows
	sync_want()
}

// dir > 0 searches forward from just after the cursor, wrapping once.
find_move :: proc(dir: int) {
	if search_query == "" {
		editor_find()
		return
	}
	needle := str_bytes(search_query)
	if E.num_rows == 0 {
		set_status_message("No matches")
		return
	}
	origin := E.cy
	if origin < 0 || origin >= E.num_rows do origin = 0
	origin_col := E.cx
	row := origin
	for n in 0 ..< E.num_rows {
		line := E.row[row].chars[:]
		idx := -1
		if dir > 0 {
			from := 0
			if n == 0 do from = origin_col + 1
			if from < 0 do from = 0
			idx = find_in(line, needle, from)
		} else {
			// Last match that starts strictly before the cursor on the
			// origin line, or anywhere on the lines we walk backward.
			limit := len(line)
			if n == 0 do limit = origin_col
			prev := -1
			from := 0
			for from < len(line) {
				at := find_in(line, needle, from)
				if at < 0 || at >= limit do break
				prev = at
				from = at + 1
			}
			idx = prev
		}
		if idx >= 0 {
			mark_match(row, idx, len(needle))
			return
		}
		if dir > 0 {
			row += 1
			if row >= E.num_rows do row = 0
		} else {
			row -= 1
			if row < 0 do row = E.num_rows - 1
		}
	}
	set_status_message("No matches for \"%s\"", search_query)
}

find_callback :: proc(query: []byte, key: Key) {
	clear_find_hl()
	if len(query) == 0 do return
	dir := 1
	#partial switch v in key {
	case byte:
		if v == '\r' || v == '\x1b' do return
	case Arrow:
		if v == .Arrow_Right || v == .Arrow_Down do dir = 1
		else if v == .Arrow_Left || v == .Arrow_Up do dir = -1
	}

	if E.num_rows == 0 do return
	needle := query
	start := E.cy
	for n in 0 ..< E.num_rows {
		row := start + dir * (n + 1)
		for row < 0 do row += E.num_rows
		for row >= E.num_rows do row -= E.num_rows
		idx := find_in(E.row[row].chars[:], needle, 0)
		if idx >= 0 {
			mark_match(row, idx, len(needle))
			return
		}
	}
}

editor_find :: proc() {
	saved_cx, saved_cy := E.cx, E.cy
	saved_coloff, saved_rowoff := E.coloff, E.rowoff
	query, ok := editor_prompt("Search: %s  (Esc cancel, arrows jump)", find_callback, search_query, false)
	defer delete(query)
	if !ok {
		clear_find_hl()
		E.cx, E.cy = saved_cx, saved_cy
		E.coloff, E.rowoff = saved_coloff, saved_rowoff
		return
	}
	if search_query != "" do delete(search_query)
	search_query = strings.clone(query)
	set_status_message("Searching for \"%s\" (%s)", search_query, search_case ? "case-sensitive" : "case-insensitive")
}

editor_replace :: proc() {
	needle := search_query
	owned_needle := false
	if needle == "" {
		n, ok := editor_prompt("Replace find: %s", nil, "", false)
		if !ok {
			delete(n)
			return
		}
		needle = n
		owned_needle = true
	}
	defer if owned_needle do delete(needle)

	repl, ok := editor_prompt("Replace with: %s  (empty deletes)", nil, "", true)
	if !ok {
		delete(repl)
		return
	}
	defer delete(repl)
	replace_all(needle, repl)
	kept := strings.clone(needle)
	if search_query != "" do delete(search_query)
	search_query = kept
}

replace_all :: proc(needle, repl: string) {
	if needle == "" do return
	nb := str_bytes(needle)
	rb := str_bytes(repl)
	src := buffer_snapshot()
	out := make([dynamic]byte, 0, len(src))
	defer delete(out)
	count := 0
	i := 0
	for i <= len(src) {
		line_end := i
		for line_end < len(src) && src[line_end] != '\n' do line_end += 1
		line := src[i:line_end]
		p := 0
		for {
			idx := find_in(line, nb, p)
			if idx < 0 {
				append(&out, ..line[p:])
				break
			}
			append(&out, ..line[p:idx])
			append(&out, ..rb)
			count += 1
			p = idx + len(nb)
		}
		if line_end < len(src) && src[line_end] == '\n' do append(&out, '\n')
		if line_end >= len(src) do break
		i = line_end + 1
	}
	if count == 0 {
		delete(src)
		set_status_message("No matches for \"%s\"", needle)
		return
	}
	cx, cy := E.cx, E.cy
	clear_sel()
	clear_find_hl()
	restore_snapshot(out[:])
	E.cx, E.cy = cx, cy
	clamp_cursor()
	sync_want()
	push_undo(Edit {
		kind = .Snap,
		text = src,
		cx0 = cx, cy0 = cy,
	})
	set_status_message("Replaced %d occurrence%s", count, count == 1 ? "" : "s")
}
