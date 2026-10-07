" Run: vim -Nu NONE -es -S test/test_ot.vim </dev/null
let &rtp = expand('<sfile>:p:h:h') . ',' . &rtp
let s:chars = ['a', 'b', "\n", 'あ', '😀', "é"]
let s:seed = srand(42)

function! s:rand(n) abort
  return rand(s:seed) % a:n
endfunction

function! s:rand_str(n) abort
  return join(map(range(a:n), 's:chars[s:rand(len(s:chars))]'), '')
endfunction

function! s:rand_op(doc) abort
  let ops = []
  let left = strchars(a:doc)
  while left > 0
    let n = 1 + s:rand(left)
    let k = s:rand(3)
    if k == 0
      call yosegaki#ot#retain(ops, n)
      let left -= n
    elseif k == 1
      call yosegaki#ot#delete(ops, n)
      let left -= n
    else
      call yosegaki#ot#insert(ops, s:rand_str(1 + s:rand(3)))
    endif
  endwhile
  if s:rand(2) == 0
    call yosegaki#ot#insert(ops, s:rand_str(2))
  endif
  return ops
endfunction

function! s:run() abort
  let errors = []
  for _ in range(1000)
    let doc = s:rand_str(s:rand(15))
    let a = s:rand_op(doc)
    let b = s:rand_op(doc)
    let [a1, b1] = yosegaki#ot#transform(a, b)
    if yosegaki#ot#apply(b1, yosegaki#ot#apply(a, doc)) !=# yosegaki#ot#apply(a1, yosegaki#ot#apply(b, doc))
      call add(errors, 'transform: ' . string([doc, a, b]))
    endif
    let mid = yosegaki#ot#apply(a, doc)
    let c = s:rand_op(mid)
    if yosegaki#ot#apply(yosegaki#ot#compose(a, c), doc) !=# yosegaki#ot#apply(c, mid)
      call add(errors, 'compose: ' . string([doc, a, c]))
    endif
    let d = yosegaki#ot#diff(split(doc, "\n", 1), split(mid, "\n", 1), strchars(doc))
    if empty(d) ? doc !=# mid : yosegaki#ot#apply(d, doc) !=# mid
      call add(errors, 'diff: ' . string([doc, mid, d]))
    endif
  endfor
  return errors
endfunction

try
  let s:errors = s:run()
catch
  let s:errors = [v:exception . ' ' . v:throwpoint]
endtry
call writefile(empty(s:errors) ? ['OK'] : s:errors[: 10], '/dev/stdout')
qa!
