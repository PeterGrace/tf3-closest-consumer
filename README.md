# Closest Consumer (Transport Fever 3 mod)

Adds a **Nearest consumers** card to the industry and warehouse info windows.
For each cargo the building sends out, it lists the three closest industries or
towns that consume that cargo, with straight-line distances. Each row has the
game's Locate button, and the consumer's name opens its window.

Each row also has a **flow arrow toggle**. It shows a single cargo-flow arrow on
the map, from the building to that consumer, and frames the camera on both ends.
The arrow is animated if cargo already flows there; otherwise it's faint and
static. Only one arrow shows at a time. Toggling it off, or closing the window,
gives the map back to the window's normal overlay.

- Mod ID: `pgrace_closest_consumer`
- Cosmetic: yes. It doesn't affect the simulation, so achievements stay enabled.
- Design: [docs/superpowers/specs/2026-10-08-closest-consumer-design.md](docs/superpowers/specs/2026-10-08-closest-consumer-design.md)

## Layout

```
mod/pgrace_closest_consumer/          # the mod folder TF3 loads
├── mod.json, _metadata/modinfo.json
├── tealdef/                          # Teal type definitions (canonical)
└── content/gui/closest_consumer/
    ├── industry_plugin.res.lua       # registers the card in the industry window
    ├── warehouse_plugin.res.lua      # registers the card in the warehouse window
    ├── closest_consumer.script.tl    # UI
    ├── nearest.tl                    # reads game state: cargo, candidates, positions
    └── rank.tl                       # pure ranking + distance formatting
tools/                                # dev tooling (type check, tests, install)
tests/                                # unit tests for rank.tl
```

## Dev loop

The tools need `lua` (5.4 or later) and `python3`.

```bash
tools/fetch-tl.sh      # once: downloads Teal 0.24.8 into .tools/
tools/check.sh         # type-check all .tl against the game's API definitions
lua tools/test.lua     # unit tests (plain Lua, no game needed)
tools/install.sh       # symlink the mod into TF3's staging_area
tools/install.sh --copy  # copy instead, if the game doesn't follow symlinks
```

`tools/build.py` runs automatically from `check.sh` and `install.sh`. It mirrors
`tealdef/*.d.tl` into `content/` and regenerates `_content.json`.

You can override these defaults:

- `TF3_DIR`: game install, used for API definitions. Default:
  `/run/host/var/Fun/SteamLibrary/steamapps/common/Transport Fever 3`
- `TF3_STAGING`: staging area. Default: the first
  `~/.local/share/Steam/userdata/*/3493540/local/staging_area`

After changing code, restart the game. With the symlink install there's no need
to re-run `install.sh`, unless you added or removed files: then run
`tools/install.sh` (or `python3 tools/build.py`) to refresh `_content.json`.

## In-game test

1. Start TF3. In the mod selection for a new game or for loading a save, enable
   **Closest Consumer**. It should be listed from the staging area.
2. Check the log for the load message:
   ```bash
   grep -h closest_consumer ~/.local/share/Steam/userdata/*/3493540/local/crash_dump/*.txt | tail
   ```
   Expect `[closest_consumer] script loaded`. Errors from our code are prefixed
   `[closest_consumer] error`.
3. Checklist:
   - [ ] A producer (e.g. a coal mine) shows the **Nearest consumers** card, with up to 3 consumers per cargo and distances.
   - [ ] A town that demands the cargo appears with "(town)".
   - [ ] The Locate button moves the camera to the consumer.
   - [ ] Clicking a consumer's name opens its window.
   - [ ] A warehouse with assigned cargo lists consumers for that cargo.
   - [ ] A warehouse with nothing assigned shows "No cargo assigned".
   - [ ] A pure consumer (e.g. a power plant) shows no card.
   - [ ] The arrow toggle shows exactly one flow arrow and frames both ends; switching rows moves it.
   - [ ] The arrow is animated for a consumer already being supplied, and faint and static otherwise.
   - [ ] Map clicks still select or open things while an arrow is shown.
   - [ ] Toggling off restores the normal overlay (the catchment circle, and the all-consumer arrows if Output is expanded).
   - [ ] Closing the window with an arrow showing leaves the map normal.
   - [ ] The game's own Stocks and Consumers sections still work as before.

## Releasing

1. Put screenshots in `mod/pgrace_closest_consumer/_metadata/`: `0.png` is
   the cover, and `1.png`, `2.png`, ... are the gallery. Each must be 1920x1080
   and at most 8 MB, with no added text, logos or overlays.
2. For an update, bump `revision` in `mod.json`.
3. Run `tools/check.sh && lua tools/test.lua && python3 tools/release_check.py`.
4. In TF3, open **Mod Hub > My Mods** (the mod is listed from the staging
   area). Check the description and images, write a changelog message, and
   click **Upload**. The game validates the mod before upload.
5. After the first upload, keep the `_metadata/mod.io_fileid.txt` the game
   creates. It links later uploads to the same mod.io entry, so commit it.

The formatted description is in `_metadata/description.html`, which overrides
the plain-text `description` in `modinfo.json`. Edits made directly on mod.io
are overwritten on the next upload, so keep both files current.

## Known limitations

- If you pin the window while an arrow is showing and then open another
  window, our arrow keeps the map. The new window's overlay is hidden until
  you toggle the arrow off or close the pinned window.

## Troubleshooting

- **Mod not listed in-game.** Try `tools/install.sh --copy`, in case symlinks
  aren't followed.
- **Mod listed, but no card and no "script loaded" in the log.** The plugin
  resource wasn't picked up. Check the log for `react-plugin` or
  `pgrace_closest_consumer` errors.
- **Card shows "error (see log)".** Grep the log for `[closest_consumer] error`.
