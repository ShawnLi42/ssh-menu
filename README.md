# ssh_menu

A single-file, dependency-light **quick-pick SSH menu** for the terminal. It
remembers what you connect to, floats your favorites and recent hosts to the
top, and (on WSL) opens each connection in its own colored Windows Terminal
tab. No daemon, no config language — just one bash script and a flat text file.

![ssh_menu demo](demo/demo.gif)

### Features at a glance

| Feature | |
|---|---|
| **Fuzzy menu** — favorites (`*`), recently used (`~`), colored env tags, "time ago", and a live preview pane for the highlighted host. | ![fuzzy menu](demo/01-fuzzy-menu.png) |
| **Type to filter** — the list narrows instantly and the preview follows the highlight. | ![filter + preview](demo/02-filter-preview.png) |
| **No-`fzf` fallback** — a clean numbered menu grouped by site, no extra tools required. | ![numeric menu](demo/03-numeric-menu.png) |
| **Production guard** — any `PROD` host makes you type `YES` before it connects. | ![prod guard](demo/04-prod-guard.png) |

> **Want it to look exactly like the GIF and screenshots above?** They were
> produced with **`fzf` installed** and the bundled, fully-fake
> [`ssh_menu.conf.example`](ssh_menu.conf.example). To reproduce:
> 1. Install **`fzf`** — that's what gives you the fuzzy UI in the GIF and
>    shots 1–2. Without it you get the numbered menu in shot 3.
> 2. Run `./install.sh` (it seeds `~/.ssh_menu.conf` from the example), then
>    `ssh_menu`.
>
> See [Requirements](#requirements) for the one-line install per platform.

---

## Why

`~/.ssh/config` is great for *defining* hosts but does nothing for *picking*
one fast when you have dozens. `ssh_menu` is the picker:

- **Fuzzy search** every host with [`fzf`](https://github.com/junegunn/fzf) —
  type a few letters, hit Enter, you're connected.
- **Recency-aware** — the 5 hosts you used most recently sort to the top,
  each annotated with `3m ago` / `2h ago` / `4d ago`.
- **Favorites** — star the hosts you hit daily; toggle a star live with `f`.
- **Live preview pane** — highlight a host to see its user/port, dashboard
  URL, favorite status, last-used time, and total connect count.
- **Colored terminal tabs** — on WSL, each environment opens in a Windows
  Terminal tab tinted by site (dev green, qa amber, staging blue, prod red).
- **Open a dashboard** for the highlighted host with `Ctrl-O`.
- **Production guard** — any `PROD` host makes you type `YES` before it
  connects.
- **Graceful fallback** — no `fzf`? You get a clean numbered menu grouped by
  site instead. Nothing else is required.

---

## Requirements

| Tool | Purpose | Required? |
|------|---------|-----------|
| `bash`, `ssh`, coreutils (`sed`, `sort`, `cut`, `mktemp`, `date`) | core | **Required** (present on virtually every system) |
| [`fzf`](https://github.com/junegunn/fzf) | the fuzzy UI + preview pane | **Optional but recommended** — falls back to a numeric menu without it |
| `wt.exe` (Windows Terminal) | colored connection tabs on WSL | Optional (WSL only) |
| `wslview` / `explorer.exe` / `xdg-open` | the `Ctrl-O` "open dashboard" action | Optional |

Install `fzf`:

```bash
sudo apt-get install fzf     # Debian / Ubuntu
sudo dnf install fzf         # Fedora / RHEL
brew install fzf             # macOS
sudo pacman -S fzf           # Arch
```

---

## Install

```bash
git clone https://github.com/ShawnLi42/ssh-menu.git
cd ssh-menu
./install.sh
```

`install.sh` will:

1. Symlink `ssh_menu.sh` to `~/.local/bin/ssh_menu` (override with `BIN_DIR=`).
2. Seed `~/.ssh_menu.conf` from the example **only if you don't already have one**.
3. Check dependencies and offer to install `fzf` if it's missing (it asks
   before running anything with `sudo`).

Then run:

```bash
ssh_menu
```

Prefer no installer? Just `chmod +x ssh_menu.sh`, drop it on your `PATH`, and
copy `ssh_menu.conf.example` to `~/.ssh_menu.conf`.

---

## Configuration

One connection per line in `~/.ssh_menu.conf`:

```
[* ]Name:user@host:port
```

- The **first word of `Name`** is the *site* (e.g. `DEV`, `QA`, `STG`, `PROD`)
  and drives the colored tag, group color, tab color, and dashboard URL.
- A leading **`* `** marks the entry a **favorite**.
- Lines starting with `#` and blank lines are ignored.

```ini
* DEV web1:deploy@web1.dev.example.com:22
DEV db:deploy@db.dev.example.com:22
QA api:qa@api.qa.example.com:22
* PROD gateway:ops@gateway.prod.example.com:2222
```

### Adapting it to your environments

The site names, colors, dashboard URLs, and which sites get a colored tab are
plain `case` statements near the top of `ssh_menu.sh`:

| Function | Controls |
|----------|----------|
| `get_env_tag` | the `[dev]` / `[qa]` / `[staging]` / `[PROD]` tag + color |
| `site_color_for` | the group header color in the numeric menu |
| `tab_color_for` | the Windows Terminal tab color (and whether a tab opens at all) |
| `navigator_url_for` | the dashboard URL opened with `Ctrl-O` |

Edit those to match your own naming. The `PROD` confirmation guard is in the
main loop (`case "$name" in "PROD"*) ...`).

### Environment overrides

| Variable | Default | Meaning |
|----------|---------|---------|
| `SSH_MENU_CONF` | `~/.ssh_menu.conf` | config file path |
| `SSH_MENU_HISTORY` | `~/.ssh_menu.history` | connect-history path |
| `WT_PROFILE_ID` | *(unset)* | Windows Terminal profile to open tabs with |

---

## Keys (fzf mode)

| Key | Action |
|-----|--------|
| type | fuzzy-filter the list |
| `↑` / `↓` | move |
| `Enter` | connect |
| `f` | toggle favorite (rewrites the config and reloads) |
| `Ctrl-O` | open the highlighted host's dashboard URL |
| `Esc` | exit the menu |

Markers in the list: `*` (yellow) favorite · `~` (cyan) recently used · blank
otherwise. The menu loops after each connection so you can fan out several
sessions back-to-back; `Esc` leaves.

---

## How it works

- **Connections** live in `~/.ssh_menu.conf`; **history** is appended to
  `~/.ssh_menu.history` as `<unix_ts>|<name>` lines, one per connect. Recency
  and "times used" are derived from that file.
- In fzf mode the script **dispatches back into itself** via hidden flags
  (`--gen-lines`, `--preview-line`, `--toggle-fav`, `--open-nav`) so fzf's
  key-binds and preview window can call the same code that renders the menu.
- Neither file is committed — both are in `.gitignore` — so your real hosts
  never end up in version control.

---

## License

[MIT](LICENSE) © 2026 Shawn Li
