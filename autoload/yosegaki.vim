" Collaborative editing client for the yosegaki server.

let s:sessions = {}
let s:colors = [
\ [1, '#e06c75'], [2, '#98c379'], [3, '#e5c07b'], [4, '#61afef'],
\ [5, '#c678dd'], [6, '#56b6c2'], [9, '#ff875f'], [10, '#87d787'],
\]

function! s:server() abort
  let server = get(g:, 'yosegaki_server', $YOSEGAKI_SERVER)
  return s:normalize(empty(server) ? 'ws://localhost:8080' : server)
endfunction

" Accepts ws://host:port, http://host:port/ws and so on; returns .../ws.
function! s:normalize(url) abort
  let url = substitute(a:url, '/\+$', '', '')
  let url = substitute(url, '^http\(s\?\)://', 'ws\1://', '')
  if url =~# '^\a\+://' && url !~# '^wss\?://'
    throw 'yosegaki: unsupported server: ' . a:url
  endif
  if url !~# '^wss\?://'
    " A bare host is a public server behind TLS, unless it is this machine.
    let local = url =~# '^\%(localhost\|127\.\|\[::1\]\)'
    let url = (local ? 'ws://' : 'wss://') . url
  endif
  return url =~# '/ws$' ? url : url . '/ws'
endfunction

function! s:link(st) abort
  return a:st.server . '/' . a:st.session
endfunction

function! s:command() abort
  return get(g:, 'yosegaki_command', 'yosegaki')
endfunction

function! s:name() abort
  return get(g:, 'yosegaki_name', empty($USER) ? 'anonymous' : $USER)
endfunction

function! s:echo(msg) abort
  echomsg 'yosegaki: ' . a:msg
endfunction

function! s:error(msg) abort
  echohl ErrorMsg
  echomsg 'yosegaki: ' . a:msg
  echohl None
endfunction

" Runs a command and shows errors as one line instead of a stack trace.
function! yosegaki#cmd(name, ...) abort
  try
    call call('yosegaki#' . a:name, a:000)
  catch
    call s:error(substitute(v:exception, '^\%(yosegaki: \|Vim\%((\a\+)\)\=:\)', '', ''))
  endtry
endfunction

function! yosegaki#highlight() abort
  for i in range(len(s:colors))
    let [cterm, gui] = s:colors[i]
    execute printf('highlight default YosegakiCursor%d ctermfg=0 ctermbg=%d guifg=#000000 guibg=%s', i, cterm, gui)
    execute printf('highlight default YosegakiLabel%d ctermfg=%d guifg=%s cterm=italic gui=italic', i, cterm, gui)
    if empty(prop_type_get('yosegaki_cursor' . i))
      call prop_type_add('yosegaki_cursor' . i, {'highlight': 'YosegakiCursor' . i, 'priority': 100})
      call prop_type_add('yosegaki_label' . i, {'highlight': 'YosegakiLabel' . i})
    endif
  endfor
endfunction

function! s:can_edit(st) abort
  return a:st.role ==# 'host' || a:st.role ==# 'editor'
endfunction

function! s:send(st, msg) abort
  if job_status(a:st.job) ==# 'run'
    call ch_sendraw(job_getchannel(a:st.job), json_encode(a:msg) . "\n")
  endif
endfunction

function! s:text_len(lines) abort
  let n = len(a:lines) - 1
  for l in a:lines
    let n += strchars(l)
  endfor
  return n
endfunction

function! s:starts(lines) abort
  let starts = []
  let n = 0
  for l in a:lines
    call add(starts, n)
    let n += strchars(l) + 1
  endfor
  return starts
endfunction

" Returns [line index, character column] of offset pos.
function! s:locate(starts, pos) abort
  let [lo, hi] = [0, len(a:starts) - 1]
  while lo < hi
    let mid = (lo + hi + 1) / 2
    if a:starts[mid] <= a:pos
      let lo = mid
    else
      let hi = mid - 1
    endif
  endwhile
  return [lo, a:pos - a:starts[lo]]
endfunction

function! s:offset(lines, lnum, col) abort
  let n = 0
  for i in range(min([a:lnum, len(a:lines)]) - 1)
    let n += strchars(a:lines[i]) + 1
  endfor
  return n + min([a:col - 1, strchars(get(a:lines, a:lnum - 1, ''))])
endfunction

function! s:current(...) abort
  let bufnr = a:0 ? a:1 : bufnr('%')
  if has_key(s:sessions, bufnr)
    return s:sessions[bufnr]
  endif
  if !a:0 && len(s:sessions) == 1
    return values(s:sessions)[0]
  endif
  throw 'yosegaki: this buffer is not in a session'
endfunction

" Local edits ------------------------------------------------------------

function! s:flush(st) abort
  if !a:st.ready || a:st.applying || !s:can_edit(a:st) || !bufloaded(a:st.bufnr)
    return
  endif
  let lines = getbufline(a:st.bufnr, 1, '$')
  let op = yosegaki#ot#diff(a:st.shadow, lines, a:st.len)
  if empty(op)
    return
  endif
  let a:st.shadow = lines
  let a:st.len = yosegaki#ot#target_len(op)
  for p in values(a:st.peers)
    let p.pos = yosegaki#ot#transform_index(op, p.pos)
  endfor
  if a:st.state ==# 'sync'
    call s:send(a:st, {'type': 'op', 'rev': a:st.rev, 'op': op})
    let a:st.outstanding = op
    let a:st.state = 'await'
  elseif a:st.state ==# 'await'
    let a:st.buffer = op
    let a:st.state = 'buffer'
  else
    let a:st.buffer = yosegaki#ot#compose(a:st.buffer, op)
  endif
endfunction

function! s:on_change(bufnr, start, end, added, changes) abort
  if has_key(s:sessions, a:bufnr)
    call s:flush(s:sessions[a:bufnr])
  endif
endfunction

" Remote edits -----------------------------------------------------------

function! s:apply(st, op) abort
  let bufnr = a:st.bufnr
  let lines = copy(a:st.shadow)
  let starts = s:starts(lines)

  let cursors = []
  for winid in win_findbuf(bufnr)
    let p = getcursorcharpos(winid)
    call add(cursors, [winid, s:offset(lines, p[1], p[2])])
  endfor

  let edits = []
  let pos = 0
  for c in a:op
    if type(c) == v:t_string
      call add(edits, [pos, 0, c])
    elseif c > 0
      let pos += c
    else
      if !empty(edits) && edits[-1][0] == pos && edits[-1][1] == 0
        let edits[-1][1] = -c
      else
        call add(edits, [pos, -c, ''])
      endif
      let pos -= c
    endif
  endfor

  let modifiable = getbufvar(bufnr, '&modifiable')
  call setbufvar(bufnr, '&modifiable', 1)
  " Vim may run listeners in the middle; ignore our own half-applied state.
  let a:st.applying = 1
  try
    " From the end, so earlier offsets stay valid.
    for [p, d, ins] in reverse(edits)
      let [sl, sc] = s:locate(starts, p)
      let [el, ec] = s:locate(starts, p + d)
      let new = split(strcharpart(lines[sl], 0, sc) . ins . strcharpart(lines[el], ec), "\n", 1)
      let old = el - sl + 1
      let n = len(new)
      call setbufline(bufnr, sl + 1, new[: min([n, old]) - 1])
      if n > old
        call appendbufline(bufnr, sl + old, new[old :])
      elseif n < old
        silent call deletebufline(bufnr, sl + n + 1, el + 1)
      endif
      call remove(lines, sl, el)
      call extend(lines, new, sl)
    endfor
  finally
    call setbufvar(bufnr, '&modifiable', modifiable)
    let a:st.applying = 0
  endtry
  let a:st.shadow = lines
  let a:st.len = yosegaki#ot#target_len(a:op)

  let starts = s:starts(lines)
  for [winid, off] in cursors
    let [l, c] = s:locate(starts, yosegaki#ot#transform_index(a:op, off))
    let p = getcursorcharpos(winid)
    if p[1] != l + 1 || p[2] != c + 1
      call win_execute(winid, printf('call setcursorcharpos(%d, %d)', l + 1, c + 1))
    endif
  endfor
  for p in values(a:st.peers)
    let p.pos = yosegaki#ot#transform_index(a:op, p.pos)
  endfor
  call s:render(a:st)
endfunction

function! s:server_op(st, op) abort
  if a:st.state ==# 'sync'
    call s:apply(a:st, a:op)
  elseif a:st.state ==# 'await'
    let [a:st.outstanding, op] = yosegaki#ot#transform(a:st.outstanding, a:op)
    call s:apply(a:st, op)
  else
    let [a:st.outstanding, op1] = yosegaki#ot#transform(a:st.outstanding, a:op)
    let [a:st.buffer, op2] = yosegaki#ot#transform(a:st.buffer, op1)
    call s:apply(a:st, op2)
  endif
endfunction

function! s:server_ack(st) abort
  if a:st.state ==# 'await'
    let a:st.state = 'sync'
  elseif a:st.state ==# 'buffer'
    call s:send(a:st, {'type': 'op', 'rev': a:st.rev, 'op': a:st.buffer})
    let a:st.outstanding = a:st.buffer
    let a:st.state = 'await'
  endif
endfunction

" Peers ------------------------------------------------------------------

function! s:render(st) abort
  let bufnr = a:st.bufnr
  if !bufloaded(bufnr)
    return
  endif
  for i in range(len(s:colors))
    call prop_remove({'type': 'yosegaki_cursor' . i, 'bufnr': bufnr, 'all': 1})
    call prop_remove({'type': 'yosegaki_label' . i, 'bufnr': bufnr, 'all': 1})
  endfor
  let lines = a:st.shadow
  let starts = s:starts(lines)
  for p in values(a:st.peers)
    if p.id == a:st.id
      continue
    endif
    let color = p.id % len(s:colors)
    let [l, c] = s:locate(starts, max([0, min([p.pos, a:st.len])]))
    let line = lines[l]
    if c < strchars(line)
      let b = byteidxcomp(line, c)
      call prop_add(l + 1, b + 1, {'type': 'yosegaki_cursor' . color, 'bufnr': bufnr,
      \ 'length': byteidxcomp(line, c + 1) - b})
    else
      call prop_add(l + 1, len(line) + 1, {'type': 'yosegaki_cursor' . color, 'bufnr': bufnr, 'text': ' '})
    endif
    call prop_add(l + 1, 0, {'type': 'yosegaki_label' . color, 'bufnr': bufnr,
    \ 'text': printf('%s #%d%s', p.name, p.id, p.role ==# 'viewer' ? ' (view)' : ''), 'text_align': 'after', 'text_padding_left': 2})
  endfor
endfunction

function! s:cursor_moved(bufnr) abort
  let st = get(s:sessions, a:bufnr, {})
  if empty(st) || !st.ready
    return
  endif
  call timer_stop(st.cursor_timer)
  let st.cursor_timer = timer_start(80, {-> s:send_cursor(a:bufnr)})
endfunction

function! s:send_cursor(bufnr) abort
  let st = get(s:sessions, a:bufnr, {})
  if empty(st) || bufnr('%') != a:bufnr
    return
  endif
  call s:flush(st)
  let p = getcursorcharpos()
  let pos = s:offset(st.shadow, p[1], p[2])
  if pos != st.last_cursor
    let st.last_cursor = pos
    call s:send(st, {'type': 'cursor', 'pos': pos})
  endif
endfunction

" Host requests ----------------------------------------------------------

function! s:show_request(st) abort
  if (a:st.popup && !empty(popup_getpos(a:st.popup))) || empty(a:st.requests)
    return
  endif
  let r = a:st.requests[0]
  if r.want ==# 'join'
    let text = [printf('%s (ID %d) wants to join.', r.name, r.client), '', '[e]dit  [v]iew only  [n]o  (Esc: later)']
  else
    let text = [printf('%s (ID %d) wants to edit.', r.name, r.client), '', '[y]es  [n]o  (Esc: later)']
  endif
  let a:st.popup = popup_create(text, {
  \ 'title': ' yosegaki ',
  \ 'border': [],
  \ 'padding': [0, 1, 0, 1],
  \ 'zindex': 300,
  \ 'mapping': 0,
  \ 'filter': function('s:request_filter', [a:st.bufnr]),
  \ })
endfunction

function! s:request_filter(bufnr, winid, key) abort
  let st = get(s:sessions, a:bufnr, {})
  if empty(st) || empty(st.requests)
    call popup_close(a:winid)
    return 1
  endif
  let r = st.requests[0]
  if r.want ==# 'join'
    let role = get({'e': 'editor', 'v': 'viewer', 'n': 'deny'}, a:key, '')
  else
    let role = get({'y': 'editor', 'n': 'deny'}, a:key, '')
  endif
  if a:key ==# "\<Esc>"
    call popup_close(a:winid)
    let st.popup = 0
    call s:echo(printf('%s is waiting; answer with :YosegakiAllow %d or :YosegakiDeny %d', r.name, r.client, r.client))
  elseif role !=# ''
    call popup_close(a:winid)
    let st.popup = 0
    call s:answer(st, r.client, role)
  endif
  return 1
endfunction

function! s:answer(st, client, role) abort
  call filter(a:st.requests, {_, v -> v.client != a:client})
  call s:send(a:st, {'type': 'set_role', 'client': a:client, 'role': a:role})
  call s:show_request(a:st)
endfunction

" Messages from the server -----------------------------------------------

function! s:on_message(bufnr, ch, line) abort
  let st = get(s:sessions, a:bufnr, {})
  if empty(st) || a:line ==# ''
    return
  endif
  try
    let msg = json_decode(a:line)
    call s:handle(st, msg)
  catch
    call s:error(v:exception)
    call yosegaki#leave(a:bufnr)
  endtry
endfunction

function! s:handle(st, msg) abort
  let st = a:st
  let t = a:msg.type
  if t ==# 'op'
    call s:flush(st)
    let st.rev = a:msg.rev
    call s:server_op(st, a:msg.op)
  elseif t ==# 'ack'
    call s:flush(st)
    let st.rev = a:msg.rev
    call s:server_ack(st)
  elseif t ==# 'cursor'
    if has_key(st.peers, a:msg.client)
      let st.peers[a:msg.client].pos = a:msg.pos
      call s:render(st)
    endif
  elseif t ==# 'init'
    call s:on_init(st, a:msg)
  elseif t ==# 'pending'
    call s:echo('waiting for the host to let you in...')
  elseif t ==# 'join'
    let st.peers[a:msg.client] = {'id': a:msg.client, 'name': a:msg.name, 'role': a:msg.role, 'pos': 0}
    call s:echo(printf('%s (ID %d) joined as %s', a:msg.name, a:msg.client, a:msg.role))
    call s:render(st)
  elseif t ==# 'leave'
    if has_key(st.peers, a:msg.client)
      call remove(st.peers, a:msg.client)
    endif
    call s:echo(printf('%s (ID %d) left', a:msg.name, a:msg.client))
    call s:render(st)
  elseif t ==# 'request'
    call add(st.requests, {'client': a:msg.client, 'name': a:msg.name, 'want': a:msg.want})
    call s:show_request(st)
  elseif t ==# 'cancel'
    call filter(st.requests, {_, v -> v.client != a:msg.client})
    if st.popup
      call popup_close(st.popup)
      let st.popup = 0
    endif
    call s:show_request(st)
  elseif t ==# 'role'
    if a:msg.client == st.id
      call s:flush(st)
      let st.role = a:msg.role
      call setbufvar(st.bufnr, '&modifiable', s:can_edit(st))
      call s:echo(s:can_edit(st) ? 'you can edit now' : 'you are now read-only')
    elseif has_key(st.peers, a:msg.client)
      let st.peers[a:msg.client].role = a:msg.role
      call s:echo(printf('%s (ID %d) is now %s', a:msg.name, a:msg.client, a:msg.role))
      call s:render(st)
    endif
  elseif t ==# 'denied'
    call s:echo('the host declined your request')
  elseif t ==# 'closed'
    call s:echo('session closed: ' . a:msg.reason)
  elseif t ==# 'error'
    call s:error(a:msg.error)
  endif
endfunction

function! s:on_init(st, msg) abort
  let st = a:st
  let bufnr = st.bufnr
  let st.session = a:msg.session
  let st.id = a:msg.id
  let st.role = a:msg.role
  let st.rev = a:msg.rev
  let st.public = a:msg.public
  let st.title = a:msg.title
  let st.peers = {}
  for p in a:msg.peers
    let st.peers[p.id] = p
  endfor
  if st.role !=# 'host'
    let lines = split(a:msg.text, "\n", 1)
    let undolevels = getbufvar(bufnr, '&undolevels')
    call setbufvar(bufnr, '&undolevels', -1)
    call setbufvar(bufnr, '&modifiable', 1)
    silent call deletebufline(bufnr, 1, '$')
    call setbufline(bufnr, 1, lines)
    call setbufvar(bufnr, '&undolevels', undolevels)
    call setbufvar(bufnr, '&modified', 0)
    if a:msg.filetype !=# ''
      call setbufvar(bufnr, '&filetype', a:msg.filetype)
    endif
    let st.shadow = lines
    let st.len = strchars(a:msg.text)
  endif
  call setbufvar(bufnr, '&modifiable', s:can_edit(st))
  call setbufvar(bufnr, 'yosegaki_session', st.session)
  let st.ready = 1
  let st.listener = listener_add(function('s:on_change'), bufnr)
  execute printf('augroup yosegaki_%d', bufnr)
    autocmd!
    execute printf('autocmd CursorMoved,CursorMovedI <buffer=%d> call s:cursor_moved(%d)', bufnr, bufnr)
    execute printf('autocmd BufWipeout <buffer=%d> call yosegaki#leave(%d)', bufnr, bufnr)
  augroup END
  if st.role ==# 'host'
    call s:echo(printf('shared (%s). Guests join with :YosegakiJoin %s',
    \ st.public ? 'public' : 'private', s:link(st)))
  else
    call s:echo(printf('joined %s as %s', st.session, st.role))
  endif
  " The host may have typed while waiting for the server.
  call s:flush(st)
  call s:render(st)
  call s:send_cursor(bufnr)
endfunction

function! s:on_stderr(bufnr, ch, line) abort
  if a:line !=# ''
    call s:error(a:line)
  endif
endfunction

function! s:on_exit(bufnr, job, status) abort
  let st = get(s:sessions, a:bufnr, {})
  if empty(st)
    return
  endif
  call s:cleanup(a:bufnr)
  if st.ready
    call s:echo('disconnected')
  elseif st.guest && bufexists(a:bufnr)
    " Joining failed; do not leave an empty buffer behind.
    execute 'silent! bwipeout!' a:bufnr
  endif
endfunction

function! s:cleanup(bufnr) abort
  let st = get(s:sessions, a:bufnr, {})
  if empty(st)
    return
  endif
  call remove(s:sessions, a:bufnr)
  call timer_stop(st.cursor_timer)
  if st.listener
    call listener_remove(st.listener)
  endif
  if st.popup
    call popup_close(st.popup)
  endif
  execute printf('augroup yosegaki_%d', a:bufnr)
    autocmd!
  augroup END
  execute printf('augroup! yosegaki_%d', a:bufnr)
  if bufloaded(a:bufnr)
    let st.peers = {}
    call s:render(st)
    call setbufvar(a:bufnr, '&modifiable', 1)
    call setbufvar(a:bufnr, 'yosegaki_session', '')
  endif
  redrawstatus!
endfunction

" Commands ---------------------------------------------------------------

function! s:start(bufnr, server, hello, shadow) abort
  call yosegaki#highlight()
  let st = {
  \ 'server': a:server, 'bufnr': a:bufnr, 'guest': has_key(a:hello, 'session'), 'ready': 0, 'applying': 0, 'session': '', 'id': 0, 'role': '', 'rev': 0,
  \ 'public': 0, 'title': '', 'shadow': a:shadow, 'len': s:text_len(a:shadow),
  \ 'state': 'sync', 'outstanding': [], 'buffer': [], 'peers': {},
  \ 'requests': [], 'popup': 0, 'listener': 0, 'cursor_timer': -1, 'last_cursor': -1,
  \ }
  let s:sessions[a:bufnr] = st
  let st.job = job_start([s:command(), 'connect', a:server], {
  \ 'mode': 'nl',
  \ 'noblock': 1,
  \ 'out_cb': function('s:on_message', [a:bufnr]),
  \ 'err_cb': function('s:on_stderr', [a:bufnr]),
  \ 'exit_cb': function('s:on_exit', [a:bufnr]),
  \ })
  if job_status(st.job) !=# 'run'
    call remove(s:sessions, a:bufnr)
    throw printf('yosegaki: cannot run %s; get it from https://github.com/mattn/yosegaki/releases', s:command())
  endif
  call s:send(st, a:hello)
endfunction

function! yosegaki#share(...) abort
  let visibility = 'private'
  let server = s:server()
  for arg in a:000
    if arg =~# '^\%(public\|private\)$'
      let visibility = arg
    elseif arg =~# '[:./]' || arg ==# 'localhost'
      let server = s:normalize(arg)
    else
      throw 'yosegaki: unknown argument: ' . arg . ' (public, private or a server like localhost:8080)'
    endif
  endfor
  let bufnr = bufnr('%')
  if has_key(s:sessions, bufnr)
    throw 'yosegaki: this buffer is already in a session'
  endif
  let lines = getline(1, '$')
  call s:start(bufnr, server, {
  \ 'type': 'hello',
  \ 'create': v:true,
  \ 'public': visibility ==# 'public' ? v:true : v:false,
  \ 'title': expand('%:t') ==# '' ? '[No Name]' : expand('%:t'),
  \ 'name': s:name(),
  \ 'filetype': &filetype,
  \ 'text': join(lines, "\n"),
  \ }, lines)
endfunction

" Takes the link shown by :YosegakiShare, or a bare id for the default server.
function! yosegaki#join(target) abort
  let target = trim(a:target)
  let m = matchlist(target, '^\(.\+\)/\([a-z2-7]\{16}\)$')
  if !empty(m)
    let [server, session] = [s:normalize(m[1]), m[2]]
  elseif target =~# '^[a-z2-7]\{16}$'
    let [server, session] = [s:server(), target]
  else
    throw 'yosegaki: give the link shown by :YosegakiShare'
  endif
  enew
  setlocal buftype=nofile bufhidden=hide noswapfile nomodifiable
  execute 'silent file' fnameescape('yosegaki://' . session)
  call s:start(bufnr('%'), server, {'type': 'hello', 'session': session, 'name': s:name()}, [''])
endfunction

function! yosegaki#leave(...) abort
  let st = a:0 ? s:current(a:1) : s:current()
  " Closing stdin makes the bridge say goodbye to the server; kill it only if
  " it hangs.
  if job_status(st.job) ==# 'run'
    call ch_close_in(job_getchannel(st.job))
    let job = st.job
    call timer_start(3000, {-> job_status(job) ==# 'run' ? job_stop(job) : 0})
  endif
  call s:cleanup(st.bufnr)
endfunction

function! yosegaki#request_edit() abort
  let st = s:current()
  if st.role !=# 'viewer'
    throw 'yosegaki: you are not a viewer'
  endif
  call s:send(st, {'type': 'request_edit'})
  call s:echo('asked the host for edit permission')
endfunction

function! s:guest_id(st, key) abort
  let id = a:key =~# '^\d\+$' ? str2nr(a:key) : -1
  if id != a:st.id && (has_key(a:st.peers, id) || !empty(filter(copy(a:st.requests), 'v:val.client == id')))
    return id
  endif
  throw 'yosegaki: no such guest ID: ' . a:key . ' (see :YosegakiStatus)'
endfunction

function! yosegaki#set_role(role, who, ...) abort
  let st = s:current()
  if st.role !=# 'host'
    throw 'yosegaki: only the host can do this'
  endif
  let role = a:role
  if role ==# 'editor' && a:0 && a:1 =~# '^v'
    let role = 'viewer'
  endif
  call s:answer(st, s:guest_id(st, a:who), role)
endfunction

function! yosegaki#status() abort
  let st = s:current()
  let lines = [printf('%s (%s) %s', s:link(st), st.public ? 'public' : 'private', st.title),
  \ printf('  %4s  %-20s %s', 'ID', 'NAME', 'ROLE')]
  for p in sort(values(st.peers), {a, b -> a.id - b.id})
    call add(lines, printf('  %4d  %-20s %s%s', p.id, p.name, p.role, p.id == st.id ? ' (you)' : ''))
  endfor
  for r in st.requests
    call add(lines, printf('  %4d  %-20s pending: wants to %s', r.client, r.name, r.want))
  endfor
  echo join(lines, "\n")
endfunction

function! yosegaki#list(...) abort
  let server = a:0 ? s:normalize(a:1) : s:server()
  let out = system(join(map([s:command(), 'list', server], 'shellescape(v:val)')))
  if v:shell_error
    throw 'yosegaki: ' . trim(out)
  endif
  let list = json_decode(out)
  if empty(list)
    call s:echo('no public sessions')
    return
  endif
  let items = map(copy(list), {_, v -> printf('%s  (%s, %d people)', v.title, v.host, v.people)})
  call popup_menu(items, {
  \ 'title': ' yosegaki: public sessions ',
  \ 'callback': {id, result -> result > 0 ? yosegaki#cmd('join', server . '/' . list[result - 1].id) : 0},
  \ })
endfunction

" For 'statusline': %{yosegaki#statusline()}
function! yosegaki#statusline() abort
  let st = get(s:sessions, bufnr('%'), {})
  if empty(st) || !st.ready
    return ''
  endif
  return printf('[yosegaki %s %d]', st.role, len(st.peers))
endfunction

function! yosegaki#complete(arglead, cmdline, pos) abort
  try
    let st = s:current()
  catch
    return []
  endtry
  let ids = map(copy(st.requests), 'string(v:val.client)')
  call extend(ids, map(filter(values(st.peers), 'v:val.id != st.id'), 'string(v:val.id)'))
  return filter(uniq(sort(ids, 'N')), 'stridx(v:val, a:arglead) == 0')
endfunction

" For tests.
function! yosegaki#_session(bufnr) abort
  return get(s:sessions, a:bufnr, {})
endfunction

function! yosegaki#_normalize(url) abort
  return s:normalize(a:url)
endfunction
