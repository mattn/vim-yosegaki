" Plain text operational transformation, compatible with the server side.
" An operation is a list whose items are a positive number (retain), a
" negative number (delete) or a string (insert). Lengths count characters.

function! s:is_insert(c) abort
  return type(a:c) == v:t_string
endfunction

function! s:is_retain(c) abort
  return type(a:c) == v:t_number && a:c > 0
endfunction

function! s:is_delete(c) abort
  return type(a:c) == v:t_number && a:c < 0
endfunction

function! s:is_none(c) abort
  return type(a:c) == v:t_number && a:c == 0
endfunction

function! s:get(ops, i) abort
  return a:i < len(a:ops) ? a:ops[a:i] : 0
endfunction

function! yosegaki#ot#retain(ops, n) abort
  if a:n <= 0
    return a:ops
  endif
  if !empty(a:ops) && s:is_retain(a:ops[-1])
    let a:ops[-1] += a:n
  else
    call add(a:ops, a:n)
  endif
  return a:ops
endfunction

function! yosegaki#ot#insert(ops, s) abort
  if a:s ==# ''
    return a:ops
  endif
  if !empty(a:ops) && s:is_insert(a:ops[-1])
    let a:ops[-1] .= a:s
  elseif !empty(a:ops) && s:is_delete(a:ops[-1])
    " Keep inserts before deletes so equal operations look the same.
    if len(a:ops) > 1 && s:is_insert(a:ops[-2])
      let a:ops[-2] .= a:s
    else
      call insert(a:ops, a:s, len(a:ops) - 1)
    endif
  else
    call add(a:ops, a:s)
  endif
  return a:ops
endfunction

function! yosegaki#ot#delete(ops, n) abort
  if a:n <= 0
    return a:ops
  endif
  if !empty(a:ops) && s:is_delete(a:ops[-1])
    let a:ops[-1] -= a:n
  else
    call add(a:ops, -a:n)
  endif
  return a:ops
endfunction

function! yosegaki#ot#base_len(ops) abort
  let n = 0
  for c in a:ops
    if !s:is_insert(c)
      let n += abs(c)
    endif
  endfor
  return n
endfunction

function! yosegaki#ot#target_len(ops) abort
  let n = 0
  for c in a:ops
    if s:is_insert(c)
      let n += strchars(c)
    elseif c > 0
      let n += c
    endif
  endfor
  return n
endfunction

function! yosegaki#ot#transform_index(ops, idx) abort
  let pos = 0
  let shift = 0
  for c in a:ops
    if pos > a:idx
      break
    endif
    if s:is_insert(c)
      let shift += strchars(c)
    elseif c > 0
      let pos += c
    else
      let d = -c
      let shift -= a:idx >= pos + d ? d : a:idx - pos
      let pos += d
    endif
  endfor
  return a:idx + shift
endfunction

" Returns [a', b'] such that apply(apply(S, a), b') == apply(apply(S, b), a').
" Inserts of a win ties, same as the server.
function! yosegaki#ot#transform(a, b) abort
  if yosegaki#ot#base_len(a:a) != yosegaki#ot#base_len(a:b)
    throw 'yosegaki: transform: length mismatch'
  endif
  let [a1, b1] = [[], []]
  let [i1, i2] = [0, 0]
  let op1 = s:get(a:a, i1)
  let op2 = s:get(a:b, i2)
  while !s:is_none(op1) || !s:is_none(op2)
    if s:is_insert(op1)
      call yosegaki#ot#insert(a1, op1)
      call yosegaki#ot#retain(b1, strchars(op1))
      let i1 += 1
      let op1 = s:get(a:a, i1)
      continue
    endif
    if s:is_insert(op2)
      call yosegaki#ot#retain(a1, strchars(op2))
      call yosegaki#ot#insert(b1, op2)
      let i2 += 1
      let op2 = s:get(a:b, i2)
      continue
    endif
    if s:is_none(op1) || s:is_none(op2)
      throw 'yosegaki: transform: operation too short'
    endif
    " Both are numbers from here: retain (> 0) or delete (< 0).
    let l1 = abs(op1)
    let l2 = abs(op2)
    let m = min([l1, l2])
    if op1 > 0 && op2 > 0
      call yosegaki#ot#retain(a1, m)
      call yosegaki#ot#retain(b1, m)
    elseif op1 < 0 && op2 > 0
      call yosegaki#ot#delete(a1, m)
    elseif op1 > 0 && op2 < 0
      call yosegaki#ot#delete(b1, m)
    endif
    if l1 == m
      let i1 += 1
      let op1 = s:get(a:a, i1)
    else
      let op1 = op1 > 0 ? op1 - m : op1 + m
    endif
    if l2 == m
      let i2 += 1
      let op2 = s:get(a:b, i2)
    else
      let op2 = op2 > 0 ? op2 - m : op2 + m
    endif
  endwhile
  return [a1, b1]
endfunction

" Returns an operation equivalent to applying a then b.
function! yosegaki#ot#compose(a, b) abort
  if yosegaki#ot#target_len(a:a) != yosegaki#ot#base_len(a:b)
    throw 'yosegaki: compose: length mismatch'
  endif
  let c = []
  let [i1, i2] = [0, 0]
  let op1 = s:get(a:a, i1)
  let op2 = s:get(a:b, i2)
  while !s:is_none(op1) || !s:is_none(op2)
    if s:is_delete(op1)
      call yosegaki#ot#delete(c, -op1)
      let i1 += 1
      let op1 = s:get(a:a, i1)
      continue
    endif
    if s:is_insert(op2)
      call yosegaki#ot#insert(c, op2)
      let i2 += 1
      let op2 = s:get(a:b, i2)
      continue
    endif
    if s:is_none(op1) || s:is_none(op2)
      throw 'yosegaki: compose: operation too short'
    endif
    " op1 is a retain or an insert, op2 is a retain or a delete.
    let l1 = s:is_insert(op1) ? strchars(op1) : op1
    let l2 = abs(op2)
    let m = min([l1, l2])
    if op2 > 0
      if s:is_insert(op1)
        call yosegaki#ot#insert(c, strcharpart(op1, 0, m))
      else
        call yosegaki#ot#retain(c, m)
      endif
    elseif !s:is_insert(op1)
      call yosegaki#ot#delete(c, m)
    endif
    if l1 == m
      let i1 += 1
      let op1 = s:get(a:a, i1)
    else
      let op1 = s:is_insert(op1) ? strcharpart(op1, m) : op1 - m
    endif
    if l2 == m
      let i2 += 1
      let op2 = s:get(a:b, i2)
    else
      let op2 = op2 > 0 ? op2 - m : op2 + m
    endif
  endwhile
  return c
endfunction

function! yosegaki#ot#apply(ops, s) abort
  if yosegaki#ot#base_len(a:ops) != strchars(a:s)
    throw 'yosegaki: apply: length mismatch'
  endif
  let out = ''
  let i = 0
  for c in a:ops
    if s:is_insert(c)
      let out .= c
    elseif c > 0
      let out .= strcharpart(a:s, i, c)
      let i += c
    else
      let i -= c
    endif
  endfor
  return out
endfunction

" Builds an operation that turns the lines old into new. oldlen is the
" character count of join(old, "\n").
function! yosegaki#ot#diff(old, new, oldlen) abort
  let no = len(a:old)
  let nn = len(a:new)
  let s = 0
  while s < no && s < nn && a:old[s] ==# a:new[s]
    let s += 1
  endwhile
  if s == no && s == nn
    return []
  endif
  let e = 0
  while e < no - s && e < nn - s && a:old[no - 1 - e] ==# a:new[nn - 1 - e]
    let e += 1
  endwhile
  " Make both middles non-empty so the newline separators around them are
  " the same in old and new.
  if no - s - e == 0 || nn - s - e == 0
    if e > 0
      let e -= 1
    else
      let s -= 1
    endif
  endif
  let pre = s
  for i in range(s)
    let pre += strchars(a:old[i])
  endfor
  let om = str2list(join(a:old[s : no - e - 1], "\n"))
  let nm = str2list(join(a:new[s : nn - e - 1], "\n"))
  let lo = len(om)
  let ln = len(nm)
  let cp = 0
  while cp < lo && cp < ln && om[cp] == nm[cp]
    let cp += 1
  endwhile
  let cs = 0
  while cs < lo - cp && cs < ln - cp && om[lo - 1 - cs] == nm[ln - 1 - cs]
    let cs += 1
  endwhile
  let ops = []
  call yosegaki#ot#retain(ops, pre + cp)
  call yosegaki#ot#insert(ops, ln - cp - cs > 0 ? list2str(nm[cp : ln - cs - 1]) : '')
  call yosegaki#ot#delete(ops, lo - cp - cs)
  call yosegaki#ot#retain(ops, a:oldlen - pre - lo + cs)
  return ops
endfunction
