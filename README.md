# ASCII Wallpaper

Animated ASCII art as your Mac desktop background, on every screen, behind your icons. 634 pieces from [ascii-magic-art](https://www.npmjs.com/package/ascii-magic-art).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Arz-Gev/visual/main/install.sh | bash
```

It builds the app on your Mac (needs Apple's command line tools: `xcode-select --install`), puts it in `~/Applications`, starts it, and starts it at login.

Use the ✨ menu bar icon to pick a piece, change the look (dots, binary, blocks...), speed and fit, shuffle on a timer, pause, or quit.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Arz-Gev/visual/main/uninstall.sh | bash
```

## Files

- `app/main.swift`: the app (a desktop-level window per screen with a web view, plus the menu)
- `wallpaper.html`: the page the app shows, scaled to fill the screen
- `ascii-magic-art/`: the npm package (MIT), pieces and runtime
- `demo.html`: the `<ascii-art>` web component on a plain page
