" Run: YOSEGAKI_URL=ws://127.0.0.1:PORT/ws vim -Nu NONE -es -S test/test_session.vim </dev/null
let &rtp = expand('<sfile>:p:h:h') . ',' . &rtp
runtime plugin/yosegaki.vim
set hidden
let s:log = []

function! s:wait(cond) abort
  for _ in range(200)
    if eval(a:cond)
      return
    endif
    sleep 10m
  endfor
  throw 'timeout: ' . a:cond
endfunction

function! s:check(name, a, b) abort
  if a:a !=# a:b
    call add(s:log, 'FAIL ' . a:name . ': ' . string(a:a) . ' != ' . string(a:b))
  endif
endfunction

function! s:flush_all() abort
  call listener_flush(s:a)
  call listener_flush(s:b)
endfunction

function! s:idle() abort
  " Wait until both sides have no outstanding edits and agree.
  call s:flush_all()
  call s:wait('yosegaki#_session(s:a).state ==# "sync" && yosegaki#_session(s:b).state ==# "sync" && yosegaki#_session(s:a).rev == yosegaki#_session(s:b).rev')
endfunction

function! s:run() abort
  " Host shares a buffer publicly.
  enew
  let s:a = bufnr('%')
  call setline(1, ['hello', 'world', 'あいう'])
  let g:yosegaki_name = 'host'
  " No configuration: the server is given on the command line, without /ws.
  execute 'YosegakiShare public' substitute($YOSEGAKI_URL, '/ws$', '', '')
  call s:wait('getbufvar(s:a, "yosegaki_session") !=# ""')
  let id = yosegaki#_session(s:a).server . '/' . getbufvar(s:a, 'yosegaki_session')

  " Guest joins as a viewer.
  let g:yosegaki_name = 'guest'
  execute 'YosegakiJoin' id
  let s:b = bufnr('%')
  call s:wait('getbufvar(s:b, "yosegaki_session") !=# ""')
  call s:check('initial', getbufline(s:b, 1, '$'), ['hello', 'world', 'あいう'])
  call s:check('viewer role', yosegaki#_session(s:b).role, 'viewer')
  call s:check('viewer nomodifiable', getbufvar(s:b, '&modifiable'), 0)

  " Host edits, viewer follows.
  call setbufline(s:a, 2, 'world!')
  call s:flush_all()
  call s:wait('getbufline(s:b, 2) ==# ["world!"]')

  " Guest asks for edit permission and the host approves.
  call yosegaki#request_edit()
  call s:wait('!empty(yosegaki#_session(s:a).requests)')
  execute 'buffer' s:a
  execute 'YosegakiAllow' yosegaki#_session(s:a).requests[0].client
  call s:wait('yosegaki#_session(s:b).role ==# "editor"')
  call s:check('editor modifiable', getbufvar(s:b, '&modifiable'), 1)

  " Concurrent random edits must converge.
  let seed = srand(str2nr($SEED))
  let words = ['x', 'yy', 'あ', '😀', "\n", 'zz', '']
  for round in range(60)
    for _ in range(1 + rand(seed) % 4)
      for buf in [s:a, s:b]
        let lines = getbufline(buf, 1, '$')
        let l = rand(seed) % len(lines)
        let line = lines[l]
        let c = rand(seed) % (strchars(line) + 1)
        let k = rand(seed) % 3
        if k == 0 && len(lines) > 1
          call deletebufline(buf, l + 1)
        elseif k == 1
          let w = words[rand(seed) % len(words)]
          let new = split(strcharpart(line, 0, c) . w . strcharpart(line, c), "\n", 1)
          call setbufline(buf, l + 1, new[0])
          if len(new) > 1
            call appendbufline(buf, l + 1, new[1:])
          endif
        else
          call setbufline(buf, l + 1, strcharpart(line, 0, c) . strcharpart(line, c + 2))
        endif
        " Sometimes flush right away, sometimes let edits pile up.
        if rand(seed) % 2
          call listener_flush(buf)
        endif
      endfor
    endfor
    if round % 3 == 0
      sleep 5m
    endif
  endfor
  call s:idle()
  call s:check('converged', getbufline(s:a, 1, '$'), getbufline(s:b, 1, '$'))

  " A third, private session: guests wait for approval. Server from $YOSEGAKI_SERVER.
  let $YOSEGAKI_SERVER = $YOSEGAKI_URL
  enew
  let s:c = bufnr('%')
  call setline(1, 'secret')
  let g:yosegaki_name = 'host2'
  YosegakiShare private
  call s:wait('getbufvar(s:c, "yosegaki_session") !=# ""')
  let id2 = getbufvar(s:c, 'yosegaki_session')
  let g:yosegaki_name = 'guest2'
  execute 'YosegakiJoin' id2
  let s:d = bufnr('%')
  call s:wait('!empty(yosegaki#_session(s:c).requests)')
  call s:check('pending has no text', getbufline(s:d, 1, '$'), [''])
  execute 'buffer' s:c
  execute 'YosegakiAllow' yosegaki#_session(s:c).requests[0].client 'view'
  call s:wait('getbufvar(s:d, "yosegaki_session") !=# ""')
  call s:check('private viewer', getbufline(s:d, 1, '$'), ['secret'])
  call s:check('private role', yosegaki#_session(s:d).role, 'viewer')

  " Host leaving closes the session for guests.
  execute 'buffer' s:c
  YosegakiLeave
  call s:wait('empty(yosegaki#_session(s:d))')

  " Sessions are independent: the first one still works.
  call setbufline(s:b, 1, 'still here')
  call s:idle()
  call s:check('first session alive', getbufline(s:a, 1), ['still here'])
endfunction

try
  call s:run()
catch
  call add(s:log, 'ERROR ' . v:exception . ' ' . v:throwpoint)
  call extend(s:log, split(execute('messages'), "\n"))
endtry
call writefile(empty(s:log) ? ['OK'] : s:log, '/dev/stdout')
qa!
