if exists('g:loaded_yosegaki') || !has('channel') || !has('textprop') || !has('popupwin')
  finish
endif
let g:loaded_yosegaki = 1

command! -nargs=* -complete=customlist,s:visibility YosegakiShare call yosegaki#cmd('share', <f-args>)
command! -nargs=1 YosegakiJoin call yosegaki#cmd('join', <q-args>)
command! -nargs=? YosegakiList call yosegaki#cmd('list', <f-args>)
command! -nargs=0 YosegakiLeave call yosegaki#cmd('leave')
command! -nargs=0 YosegakiStatus call yosegaki#cmd('status')
command! -nargs=0 YosegakiRequestEdit call yosegaki#cmd('request_edit')
command! -nargs=+ -complete=customlist,yosegaki#complete YosegakiAllow call yosegaki#cmd('set_role', 'editor', <f-args>)
command! -nargs=1 -complete=customlist,yosegaki#complete YosegakiDeny call yosegaki#cmd('set_role', 'deny', <f-args>)
command! -nargs=1 -complete=customlist,yosegaki#complete YosegakiRevoke call yosegaki#cmd('set_role', 'viewer', <f-args>)

function! s:visibility(...) abort
  return ['private', 'public']
endfunction

augroup yosegaki
  autocmd!
  autocmd ColorScheme * if exists('*yosegaki#highlight') | call yosegaki#cmd('highlight') | endif
augroup END
