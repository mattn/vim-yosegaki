# vim-yosegaki

Collaborative editing for Vim. Several people edit the same buffer at the same time through a [yosegaki](https://github.com/mattn/yosegaki) server.

## Installation

Every user needs the `yosegaki` command. Get a binary from [Releases](https://github.com/mattn/yosegaki/releases), or

```
go install github.com/mattn/yosegaki@latest
```

```vim
Plug 'mattn/vim-yosegaki'
```

## Usage

Use a public server such as `yosegaki.compile-error.net`, or run one (`yosegaki serve`, or `docker run -p 8080:8080 ghcr.io/mattn/yosegaki`). A buffer remembers its server in `b:yosegaki_server` once connected; without one, `ws://localhost:8080` is used.

Host:

```vim
:YosegakiShare private   " or public; add a server like localhost:8080 to pick one
```

A link such as `ws://localhost:8080/ws/abcdefghijklmnop` is shown. Give it to your guests.

Guest:

```vim
:YosegakiJoin <link>
:YosegakiJoin <server>   " pick one of its public sessions, same as :YosegakiList <server>
:YosegakiRequestEdit     " ask the host for edit permission
```

In a public session guests can view right away and edit once the host allows it. In a private session guests wait for the host to let them in. Requests pop up on the host side.

See `:help yosegaki` for details.

## Testing

```
yosegaki serve -addr 127.0.0.1:8080 &
vim -Nu NONE -es -S test/test_ot.vim </dev/null
YOSEGAKI_URL=ws://127.0.0.1:8080/ws vim -Nu NONE -es -S test/test_session.vim </dev/null
```

## License

MIT

## Author

Yasuhiro Matsumoto (a.k.a. mattn)
