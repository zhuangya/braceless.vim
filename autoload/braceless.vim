" I had it in my head that blocks needed to stop when they hit another pattern
" match. They just need to stop at lower-indented lines.  I could hard-code
" the stop pattern, but I don't want to break the magic spell that's making
" this work.
let s:pattern_python = '\%(if\|def\|for\|try\|elif\|else\|with\|class\|while\|except\|finally\)\_.\{-}:'

let s:pattern_coffee = '\%('
                      \.'\%(\zs\%(do\|if\|for\|try\|else\|when\|with\|catch\|class\|while\|switch\|finally\).*\)\|'
                      \.'\S\&.\+\%(\zs='
                      \.'\|\zs\%((.*)\)\{,1}\s*[-=]>'
                      \.'\)\)\s*\_$'

" Gets the byte index of a buffer position
function! s:pos2byte(pos)
  let p = getpos(a:pos)
  return line2byte(p[1]) + p[2]
endfunction


" Similar to prevnonblank() but tests non-empty whitespace lines
function! s:prevnonempty(line)
  let c_line = a:line
  while c_line > 0
    if getline(c_line) !~ '^\s*$'
      return c_line
    endif
    let c_line -= 1
  endwhile
  return 0
endfunction


" Similar to nextnonblank() but tests non-empty whitespace lines
function! s:nextnonempty(line)
  let c_line = a:line
  let end = line('$')
  while c_line <= end
    if getline(c_line) !~ '^\s*$'
      return c_line
    endif
    let c_line += 1
  endwhile
  return 0
endfunction


" Tests if there is selected text
function! s:is_selected()
  let pos = s:pos2byte('.')
  let m_start = s:pos2byte("'<")
  let m_end = s:pos2byte("'>")

  echomsg 'Current Position:' pos 'Mark Start:' m_start 'Mark End:' m_end
  return m_start != -1 && m_end != -1 && pos == m_start && pos != m_end
endfunction


" Gets the indent level of a line and modifies it with a indent level delta.
function! s:get_indent(expr, delta)
  let i_c = ' '
  let i_n = indent(a:expr)
  if !&expandtab
    let i_c = '\t'
    let i_n = (i_n / &ts) + a:delta
  else
    let i_n += &sw * a:delta
  endif
  return [i_c, max([0, i_n])]
endfunction


" Get the indented block by finding the first line that matches a pattern that
" looks for a lower indent level.
function! s:get_block_end(start, pattern)
  let end = line('$')
  let start = min([end, a:start])
  let lastline = end

  while start > 0 && start <= end
    if getline(start) =~ a:pattern
      let lastline = s:prevnonempty(start - 1)
      break
    endif
    let start = s:nextnonempty(start + 1)
  endwhile

  return lastline
endfunction


" Build a pattern that is suitable for the current line and indent level
function! s:build_pattern(line, base, motion, selected)
  let pat = '^\s*'.a:base
  let flag = 'bc'
  let text = getline(a:line)

  if a:selected
    let i_d = 0
    let line = a:line
    if a:motion ==# 'i'
      " Moving inward, include current line
      let flag = 'c'
      let i_d = 1
    else
      " Moving outward, don't include current line
      let flag = 'b'
    endif
    let [i_c, i_n] = s:get_indent(line, i_d - 1)
    let pat = '^'.i_c.'\{,'.i_n.'}'
  elseif text =~ '^\s*$' || text !~ pat
    let [i_c, i_n] = s:get_indent(a:line, -1)
    let pat = '^'.i_c.'\{-,'.i_n.'}'
  else
    " Reset
    echomsg "Reset"
    let [i_c, i_n] = s:get_indent(a:line, 0)
    let pat = '^'.i_c.'\{-,'.i_n.'}'
  endif

  if a:base !~ '\\zs'
    let pat .= '\zs'
  endif
  let pat .= a:base

  return [pat, flag]
endfunction


" Get the line with the nicest looking indent level
function! s:best_indent(line)
  let p_line = s:prevnonempty(a:line)
  let n_line = s:nextnonempty(a:line)

  " Make sure there's at least something to find
  if p_line == 0
    return 0
  endif

  let p_indent = indent(p_line)
  let n_indent = indent(n_line)

  " If the current line is all whitespace, use one of the surrounding
  " non-empty line's indent level that you may expect to be the selected
  " block.
  if getline(a:line) =~ '^\s*$'
    if p_indent > n_indent
      return n_line
    endif

    return p_line
  endif

  return a:line
endfunction


" Select an indent block using ~magic~
function! braceless#select_block(pattern, stop_pattern, motion, keymode, vmode, op, select)
  let has_selection = 0
  if a:op == ''
    let has_selection = s:is_selected()
  endif

  let saved_view = winsaveview()
  let c_line = s:best_indent(line('.'))
  if c_line == 0
    return 0
  endif
  echomsg 'Start line:' c_line

  echomsg 'Has Selection:' has_selection
  let [pat, flag] = s:build_pattern(c_line, a:pattern, a:motion, has_selection)
  echomsg 'Search Pattern:' pat
  echomsg 'Search Flags:' flag

  let head = searchpos(pat, flag.'W')
  let tail = searchpos(pat, 'nceW')

  let tbyte = line2byte(tail[0]) + tail[1]
  let hbyte = line2byte(head[0]) + head[1]
  echomsg 'Head Byte:' hbyte 'Tail Byte:' tbyte

  if (hbyte == 0 && tbyte == 0) || hbyte == -1 || tbyte == -1
    if a:keymode ==# 'v'
      normal! gV
    else
      call winrestview(saved_view)
    endif
    return [c_line, c_line]
  endif

  " Finally begin the block search
  let head = searchpos(pat, 'cbW')
  echomsg 'Matched Line:' getline(head[0])

  let [i_c, i_n] = s:get_indent(head[0], 0)
  let pat = '^'.i_c.'\{,'.i_n.'}'.a:stop_pattern
  echomsg 'Stop Pattern:' pat

  let startline = s:nextnonempty(tail[0] + 1)
  let lastline = s:get_block_end(startline, pat)

  if a:motion ==# 'i'
    if lastline < startline
      call cursor(tail[0], 0)
    else
      let [i_c, i_n] = s:get_indent(head[0], 1)
      call cursor(tail[0] + 1, i_n + 1)
    endif
  endif

  if a:select == 1 && (a:keymode == 'v' || a:op != '')
    exec 'normal!' a:vmode
  endif

  if lastline < startline
    if a:select == 1
      call cursor(tail[0], tail[1])
    else
      call winrestview(saved_view)
    endif
    return [lastline, lastline]
  endif

  let end = col([lastline, '$'])
  echomsg 'Last Line' lastline

  if a:select == 1
    call cursor(lastline, end - 1)
  else
    call winrestview(saved_view)
  endif

  if a:motion ==# 'a'
    let startline = head[0]
  endif

  return [startline, lastline]
endfunction


" Gets a pattern.  If g:braceless#start#<filetype> does not exist, fallback to
" a built in one, and if that doesn't exist, return an empty string.
function! s:get_pattern()
  let pattern = get(g:, 'braceless#start#'.&ft, get(s:, 'pattern_'.&ft, '\S.*'))
  let stop_pattern = get(g:, 'braceless#stop#'.&ft, get(s:, 'pattern_stop_'.&ft, '\S'))
  return [pattern, stop_pattern]
endfunction


" Highlight indent block
function! braceless#highlight(ignore_prev)
  let l = line('.')
  let last_line = get(b:, 'braceless_last_line', 0)

  if !a:ignore_prev && last_line == l
    echomsg 'No indent change'
    return
  endif

  let b:braceless_last_line = l

  let [pattern, stop_pattern] = s:get_pattern()
  if empty(pattern)
    return
  endif

  let il = braceless#select_block(pattern, stop_pattern, 'a', 'n', '', '', 0)
  if type(il) != 3
    return
  endif

  let pl = s:prevnonempty(il[0])
  let nl = s:nextnonempty(il[0])
  if indent(nl) < indent(pl)
    let il[0] = pl
  else
    let il[0] = nl
  endif

  if !a:ignore_prev
    let last_range = get(b:, 'braceless_range', [0, 0])
    if il[0] == last_range[0] && il[1] == last_range[1]
      return
    endif
  endif

  let b:braceless_range = il

  let [i_c, i_n] = s:get_indent(il[0], 0)
  silent! syntax clear BracelessIndent
  " Note, 2 is the right side of the column.  So +2 to the indent.
  let match_id = get(b:, 'braceless_match', -1)
  if match_id != -1
    call matchdelete(match_id)
  endif
  let matchpattern = '\%>'.(il[0]-1).'l'.i_c.'\%'.(i_n + 2).'v\%<'.(il[1]+1).'l'
  let b:braceless_match = matchadd('BracelessIndent', matchpattern, 99)
endfunction


" Kinda like black ops, but more exciting.
function! braceless#block_op(motion, keymode, vmode, op)
  let [pattern, stop_pattern] = s:get_pattern()
  if empty(pattern)
    return
  endif
  call braceless#select_block(pattern, stop_pattern, a:motion, a:keymode, a:vmode, a:op, 1)
endfunction


" Jump to an *actual* meaningful block in Python!
function! braceless#block_jump(direction, vmode, count)
  let [pattern, stop_pattern] = s:get_pattern()
  if empty(pattern)
    return
  endif

  if a:vmode != 'n'
    normal! gv
  endif

  let flags = ''
  if a:direction == -1
    let flags = 'b'
  endif

  let pat = '^\s*'
  if pattern !~ '\\zs'
    let pat .= '\zs'
  endif
  let pat .= pattern

  let i = a:count
  while i > 0
    call searchpos(pat, flags.'e')
    let i -= 1
  endwhile
endfunction
