# Closest Consumer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Nearest consumers" card to TF3's industry and warehouse info windows. For each cargo the building sends out, it lists the 3 nearest industries or towns that consume that cargo, with straight-line distances.

**Architecture:** A TF3 mod that hooks into the game's React extension points
(`IndustryEowExtensionPoint`, `WarehouseEowExtensionPoint`) through
`react-plugin` resource files. The code is split three ways:

- `rank.tl`: pure ranking and formatting, unit-tested in plain Lua.
- `nearest.tl`: reads game data.
- `closest_consumer.script.tl`: UI only.

Teal type definitions (`*.d.tl`) follow the base game's pattern, so `tl check`
validates our code against the game's real API.

**Tech Stack:**

- Teal 0.24.8 (`tl.lua`, used as a library)
- Lua 5.5 (brew) for tooling and tests
- Python 3 for generating `_content.json`
- TF3 build 40408 (Linux)

**Spec:** `docs/superpowers/specs/2026-10-08-closest-consumer-design.md`

**Key paths:**

- Game: `/run/host/var/Fun/SteamLibrary/steamapps/common/Transport Fever 3` (override with `TF3_DIR`)
- Staging: `~/.local/share/Steam/userdata/*/3493540/local/staging_area/` (override with `TF3_STAGING`)
- Game logs: `~/.local/share/Steam/userdata/*/3493540/local/crash_dump/*.txt`

---

## File Structure

| Path | Responsibility |
|---|---|
| `.gitignore` | ignore `.tools/` |
| `tools/fetch-tl.sh` | download `tl.lua` into `.tools/` |
| `tools/check_def.d.tl` | predefined module: game API defs + our defs |
| `tools/check.lua` | type-check `.tl` files against game defs |
| `tools/check.sh` | run check.lua over all mod `.tl` files |
| `tools/test.lua` | minimal test runner; loads `.tl` modules as Lua |
| `tools/gen_content_json.py` | write `mod/.../_content.json` index |
| `tools/install.sh` | symlink (or copy) mod into staging area |
| `tests/rank_test.lua` | unit tests for rank.tl |
| `mod/pgrace_closest_consumer/mod.json` | mod definition |
| `mod/pgrace_closest_consumer/_metadata/modinfo.json` | mod browser info |
| `mod/.../content/gui/closest_consumer/rank.d.tl` / `rank.tl` | pure ranking + distance formatting |
| `mod/.../content/gui/closest_consumer/nearest.d.tl` / `nearest.tl` | gather source cargo, candidates, positions, names |
| `mod/.../content/gui/closest_consumer/closest_consumer.script.tl` | plugin recipes + condition |
| `mod/.../content/gui/closest_consumer/industry_plugin.res.lua` | registers industry plugin |
| `mod/.../content/gui/closest_consumer/warehouse_plugin.res.lua` | registers warehouse plugin |
| `README.md` | install, dev loop, in-game checklist |

---

### Task 1: Tooling (Teal fetch, type checker, test runner)

**Files:**
- Create: `.gitignore`, `tools/fetch-tl.sh`, `tools/check_def.d.tl`, `tools/check.lua`, `tools/check.sh`, `tools/test.lua`

- [ ] **Step 1: Create `.gitignore`**

```
.tools/
```

- [ ] **Step 2: Create `tools/fetch-tl.sh`**

```bash
#!/usr/bin/env bash
# Downloads the Teal compiler (a single Lua file) used by the check and test tools.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tools
curl -fsSL https://raw.githubusercontent.com/teal-language/tl/v0.24.8/tl.lua -o .tools/tl.lua
lua -e 'package.path = ".tools/?.lua;" .. package.path; print("tl " .. require("tl").version())'
```

- [ ] **Step 3: Create `tools/check_def.d.tl`** (the game's `all_def` plus our module definitions)

```lua
require "api_def"
require "content_def"
require "gui.closest_consumer.rank"
require "gui.closest_consumer.nearest"
```

- [ ] **Step 4: Create `tools/check.lua`**

```lua
-- Type-checks Teal files against the game's API definitions.
-- usage: lua tools/check.lua <tf3_dir> <file.tl>...
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local game = arg[1]
package.path = root .. "/.tools/?.lua;" .. package.path
local tl = require("tl")
package.path = table.concat({
	root .. "/tools/?.d.tl",
	root .. "/mod/pgrace_closest_consumer/content/?.d.tl",
	game .. "/api/tealdef/?.d.tl",
	game .. "/base/tealdef/?.d.tl",
}, ";") .. ";" .. package.path

local total = 0
for i = 2, #arg do
	local env = tl.new_env({ predefined_modules = { "check_def" }, defaults = { gen_target = "5.1" } })
	local result, err = tl.check_file(arg[i], env)
	if not result then
		print(arg[i] .. ": " .. tostring(err))
		total = total + 1
	else
		for _, list in ipairs({ result.syntax_errors or {}, result.type_errors or {} }) do
			for _, e in ipairs(list) do
				print(("%s:%d:%d: %s"):format(e.filename, e.y, e.x, e.msg))
				total = total + 1
			end
		end
	end
end
print(total .. " error(s)")
os.exit(total == 0 and 0 or 1)
```

- [ ] **Step 5: Create `tools/check.sh`**

```bash
#!/usr/bin/env bash
# Type-checks every .tl file in the mod against the TF3 API definitions.
set -euo pipefail
cd "$(dirname "$0")/.."
TF3_DIR="${TF3_DIR:-/run/host/var/Fun/SteamLibrary/steamapps/common/Transport Fever 3}"
[ -f .tools/tl.lua ] || tools/fetch-tl.sh
mapfile -t files < <(find mod -name '*.tl' ! -name '*.d.tl' | sort)
lua tools/check.lua "$TF3_DIR" "${files[@]}"
```

- [ ] **Step 6: Create `tools/test.lua`**

```lua
-- Minimal test runner: loads Teal modules as plain Lua and runs tests/*_test.lua.
-- usage: lua tools/test.lua
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
package.path = root .. "/.tools/?.lua;" .. package.path
local tl = require("tl")

local t = { passed = 0, failed = 0 }

function t.requireTl(relPath)
	local path = root .. "/mod/pgrace_closest_consumer/content/" .. relPath
	local f = assert(io.open(path, "r"))
	local src = f:read("a")
	f:close()
	local code, result = tl.gen(src, tl.new_env({ defaults = { gen_target = "5.1" } }))
	if not code then
		error("failed to compile " .. path .. ": " .. tostring(result and result.syntax_errors and result.syntax_errors[1] and result.syntax_errors[1].msg))
	end
	return assert(load(code, "@" .. path))()
end

function t.eq(actual, expected, label)
	if actual ~= expected then
		error(("%s: expected %s, got %s"):format(label or "eq", tostring(expected), tostring(actual)), 2)
	end
end

function t.test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		t.passed = t.passed + 1
		print("PASS " .. name)
	else
		t.failed = t.failed + 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end

local p = io.popen('ls "' .. root .. '/tests/"*_test.lua 2>/dev/null')
for file in p:lines() do
	assert(loadfile(file))(t)
end
p:close()
print(("%d passed, %d failed"):format(t.passed, t.failed))
os.exit(t.failed == 0 and t.passed > 0 and 0 or 1)
```

- [ ] **Step 7: Make scripts executable, fetch tl, verify**

Run: `chmod +x tools/*.sh && tools/fetch-tl.sh`
Expected: `tl 0.24.8`

- [ ] **Step 8: Commit**

```bash
git add .gitignore tools/
git commit -m "build: add Teal type-check and test tooling"
```

---

### Task 2: Mod skeleton + hello-world plugin + install script

Proves the plumbing: the mod loads, the `react-plugin` resource is picked up, and
our script runs. **Checkpoint for the user**: verify the text appears in-game.

**Files:**
- Create: `mod/pgrace_closest_consumer/mod.json`, `mod/pgrace_closest_consumer/_metadata/modinfo.json`, `mod/pgrace_closest_consumer/content/gui/closest_consumer/closest_consumer.script.tl`, `.../industry_plugin.res.lua`, `.../warehouse_plugin.res.lua`, `tools/gen_content_json.py`, `tools/install.sh`
- Temporary stubs (replaced in Tasks 3 and 4): `rank.d.tl`, `nearest.d.tl`, so that `check_def` resolves

- [ ] **Step 1: `mod/pgrace_closest_consumer/mod.json`**

```json
{
    "modId": "pgrace_closest_consumer",
    "revision": 1,
    "severityAdd": "None",
    "severityRemove": "None",
    "cosmetic": true,
    "dependencies": null,
    "incompatibilities": null,
    "params": null
}
```

- [ ] **Step 2: `mod/pgrace_closest_consumer/_metadata/modinfo.json`**

```json
{
    "authors": [
        {
            "name": "Peter Grace",
            "role": "CREATOR"
        }
    ],
    "name": "Closest Consumer",
    "summary": "Shows the nearest consumers for each cargo in industry and warehouse windows.",
    "description": "Adds a 'Nearest consumers' card to industry and warehouse windows. For each cargo the building sends out, it lists the three closest industries or towns that use it, with straight-line distance.",
    "tags": [
        "Script Mod"
    ],
    "url": ""
}
```

- [ ] **Step 3: `industry_plugin.res.lua`** (in `mod/pgrace_closest_consumer/content/gui/closest_consumer/`)

```lua
function data()
	return {
		type = "react-plugin ::IndustryEowExtensionPoint",
		data = {
			filePath = "pgrace_closest_consumer::/gui/closest_consumer/closest_consumer.script@IndustryPlugin",
			order = 35,
		}
	}
end
```

- [ ] **Step 4: `warehouse_plugin.res.lua`**

```lua
function data()
	return {
		type = "react-plugin ::WarehouseEowExtensionPoint",
		data = {
			filePath = "pgrace_closest_consumer::/gui/closest_consumer/closest_consumer.script@WarehousePlugin",
			order = 25,
		}
	}
end
```

- [ ] **Step 5: Hello-world `closest_consumer.script.tl`**

```lua
local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local industry_eow = ug_require "::/gui/entity_window/industry/industry_eow.script.tl" as IndustryEow
local warehouse_eow = ug_require "::/gui/entity_window/warehouse/warehouse_eow.script.tl" as WarehouseEow

debugPrint("[closest_consumer] script loaded")

local plugins = {}

plugins.IndustryPlugin = react.RegisterPluginRecipe(industry_eow.IndustryEowExtensionPoint, "ClosestConsumerIndustryPlugin", function(params : IndustryEow.IndustryWidgetPluginParams) : TreeNodeId
	return builtin.TextView{ text = "Closest consumer: hello (industry " .. tostring(params.entityId) .. ")" }
end)

plugins.WarehousePlugin = react.RegisterPluginRecipe(warehouse_eow.WarehouseEowExtensionPoint, "ClosestConsumerWarehousePlugin", function(params : WarehouseEow.WarehouseWidgetPluginParams) : TreeNodeId
	return builtin.TextView{ text = "Closest consumer: hello (warehouse " .. tostring(params.entityId) .. ")" }
end)

return plugins
```

- [ ] **Step 6: Temporary definition stubs** so `check_def` resolves (replaced in Tasks 3 and 4)

`rank.d.tl`:
```lua
global record ClosestConsumerRank
end
```
`nearest.d.tl`:
```lua
global record ClosestConsumerNearest
end
```

- [ ] **Step 7: `tools/gen_content_json.py`**

```python
#!/usr/bin/env python3
"""Writes the mod's _content.json, the file index that TF3 mods ship with."""
import json
import pathlib

mod = pathlib.Path(__file__).resolve().parent.parent / "mod" / "pgrace_closest_consumer"
content = mod / "content"
files = sorted(p.relative_to(content).as_posix() for p in content.rglob("*") if p.is_file())
(mod / "_content.json").write_text(json.dumps({"archives": None, "files": files}, indent=4) + "\n")
print(f"_content.json: {len(files)} files")
```

- [ ] **Step 8: `tools/install.sh`**

```bash
#!/usr/bin/env bash
# Installs the mod into TF3's staging area. Symlinks by default; pass --copy to copy instead.
set -euo pipefail
cd "$(dirname "$0")/.."
MOD_ID=pgrace_closest_consumer
STAGING="${TF3_STAGING:-$(ls -d "$HOME"/.local/share/Steam/userdata/*/3493540/local/staging_area 2>/dev/null | head -n1)}"
[ -d "$STAGING" ] || { echo "staging_area not found; set TF3_STAGING" >&2; exit 1; }
python3 tools/gen_content_json.py
rm -rf "${STAGING:?}/$MOD_ID"
if [ "${1:-}" = "--copy" ]; then
	cp -r "mod/$MOD_ID" "$STAGING/$MOD_ID"
	echo "copied to $STAGING/$MOD_ID"
else
	ln -s "$PWD/mod/$MOD_ID" "$STAGING/$MOD_ID"
	echo "symlinked $STAGING/$MOD_ID -> $PWD/mod/$MOD_ID"
fi
```

- [ ] **Step 9: Type-check**

Run: `chmod +x tools/*.sh tools/*.py && tools/check.sh`
Expected: `0 error(s)`

- [ ] **Step 10: Generate `_content.json`, install, commit**

Run: `tools/install.sh`
Expected: `_content.json: 6 files`, then `symlinked ...`

```bash
git add mod tools
git commit -m "feat: mod skeleton with hello-world entity window plugins"
```

---

### Task 3: Pure ranking module (TDD)

**Files:**
- Modify: `mod/.../gui/closest_consumer/rank.d.tl`
- Create: `mod/.../gui/closest_consumer/rank.tl`, `tests/rank_test.lua`

- [ ] **Step 1: Write the definitions in `rank.d.tl`**

```lua
global record ClosestConsumerRank
	record Candidate
		entity : Engine.Entity
		name : string
		isTown : boolean
		x : number
		y : number
	end

	record Ranked
		entity : Engine.Entity
		name : string
		isTown : boolean
		distance : number
	end

	-- Sorts candidates by straight-line (x, y) distance to the source; returns at most `limit`.
	nearest : function(sourceX : number, sourceY : number, candidates : {Candidate}, limit : integer) : {Ranked}
	-- "850 m" below one kilometre, otherwise "4.2 km".
	formatDistance : function(metres : number) : string
end
```

- [ ] **Step 2: Write the failing tests in `tests/rank_test.lua`**

```lua
local t = ...
local rank = t.requireTl("gui/closest_consumer/rank.tl")

local function c(entity, name, x, y, isTown)
	return { entity = entity, name = name, x = x, y = y, isTown = isTown or false }
end

t.test("formatDistance: metres below 1 km", function()
	t.eq(rank.formatDistance(0), "0 m")
	t.eq(rank.formatDistance(850.4), "850 m")
	t.eq(rank.formatDistance(999.4), "999 m")
end)

t.test("formatDistance: kilometres with one decimal", function()
	t.eq(rank.formatDistance(999.6), "1.0 km")
	t.eq(rank.formatDistance(4210), "4.2 km")
	t.eq(rank.formatDistance(11349), "11.3 km")
end)

t.test("nearest: sorts ascending by planar distance", function()
	local r = rank.nearest(0, 0, { c(1, "far", 300, 400), c(2, "near", 3, 4), c(3, "mid", 30, 40) }, 3)
	t.eq(#r, 3)
	t.eq(r[1].entity, 2)
	t.eq(r[1].distance, 5)
	t.eq(r[2].entity, 3)
	t.eq(r[3].entity, 1)
	t.eq(r[3].distance, 500)
end)

t.test("nearest: measures from the source position", function()
	local r = rank.nearest(100, 100, { c(1, "a", 0, 0), c(2, "b", 103, 104) }, 3)
	t.eq(r[1].entity, 2)
	t.eq(r[1].distance, 5)
end)

t.test("nearest: limits the result count", function()
	local r = rank.nearest(0, 0, { c(1, "a", 1, 0), c(2, "b", 2, 0), c(3, "c", 3, 0), c(4, "d", 4, 0) }, 3)
	t.eq(#r, 3)
	t.eq(r[3].entity, 3)
end)

t.test("nearest: fewer candidates than limit returns all", function()
	t.eq(#rank.nearest(0, 0, { c(1, "a", 1, 0) }, 3), 1)
	t.eq(#rank.nearest(0, 0, {}, 3), 0)
end)

t.test("nearest: ties broken by name", function()
	local r = rank.nearest(0, 0, { c(1, "Zeta", 0, 10), c(2, "Alpha", 10, 0) }, 3)
	t.eq(r[1].name, "Alpha")
	t.eq(r[2].name, "Zeta")
end)

t.test("nearest: carries town flag and name through", function()
	local r = rank.nearest(0, 0, { c(7, "Esslingen", 1, 0, true) }, 3)
	t.eq(r[1].isTown, true)
	t.eq(r[1].name, "Esslingen")
	t.eq(r[1].entity, 7)
end)
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `lua tools/test.lua`
Expected: FAIL (`rank.tl` does not exist yet)

- [ ] **Step 4: Implement `rank.tl`**

```lua
local rank : ClosestConsumerRank = {}

function rank.nearest(sourceX : number, sourceY : number, candidates : {ClosestConsumerRank.Candidate}, limit : integer) : {ClosestConsumerRank.Ranked}
	local all : {ClosestConsumerRank.Ranked} = {}
	for _, candidate in ipairs(candidates) do
		local dx = candidate.x - sourceX
		local dy = candidate.y - sourceY
		all[#all + 1] = {
			entity = candidate.entity,
			name = candidate.name,
			isTown = candidate.isTown,
			distance = math.sqrt(dx * dx + dy * dy),
		}
	end
	table.sort(all, function(a : ClosestConsumerRank.Ranked, b : ClosestConsumerRank.Ranked) : boolean
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.name < b.name
	end)
	local result : {ClosestConsumerRank.Ranked} = {}
	for i = 1, math.min(limit, #all) do
		result[i] = all[i]
	end
	return result
end

function rank.formatDistance(metres : number) : string
	local rounded = math.floor(metres + 0.5)
	if rounded < 1000 then
		return string.format("%d m", rounded)
	end
	return string.format("%.1f km", metres / 1000)
end

return rank
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `lua tools/test.lua`
Expected: `8 passed, 0 failed`

- [ ] **Step 6: Type-check**

Run: `tools/check.sh`
Expected: `0 error(s)`

- [ ] **Step 7: Commit**

```bash
git add mod tests
git commit -m "feat: add pure distance ranking and formatting"
```

---

### Task 4: Game-data gathering (`nearest.tl`)

This code needs the game API, so it can't be unit-tested here. Correctness comes
from `tl check` against the game's definitions and from the in-game checklist.

**Files:**
- Modify: `mod/.../gui/closest_consumer/nearest.d.tl`
- Create: `mod/.../gui/closest_consumer/nearest.tl`

- [ ] **Step 1: Write the definitions in `nearest.d.tl`**

```lua
global record ClosestConsumerNearest
	record CargoResult
		cargoType : CargoTypeId
		consumers : {ClosestConsumerRank.Ranked}
	end

	-- Cargo types the entity sends out: industry rule outputs, or a warehouse's assigned stock cargo types.
	getSourceCargoTypes : function(entity : Engine.Entity) : {CargoTypeId}
	-- For each source cargo type (sorted by id), the nearest `limit` consumers. Warehouses and the source are never consumers.
	findNearestConsumers : function(entity : Engine.Entity, limit : integer) : {CargoResult}
end
```

- [ ] **Step 2: Implement `nearest.tl`**

```lua
local rank = ug_require "pgrace_closest_consumer::/gui/closest_consumer/rank.tl" as ClosestConsumerRank

local nearest : ClosestConsumerNearest = {}

local function getWarehouse(entity : Engine.Entity) : Engine.Component.Warehouse
	return api.engine.getComponent(entity, api.type.ComponentType.WAREHOUSE)
end

local function getStockList(entity : Engine.Entity) : Engine.Component.StockList
	local stockList : Engine.Component.StockList = api.engine.getComponent(entity, api.type.ComponentType.STOCK_LIST)
	if stockList ~= nil then
		return stockList
	end
	local warehouse = getWarehouse(entity)
	if warehouse ~= nil then
		return api.engine.getComponent(warehouse.stockList, api.type.ComponentType.STOCK_LIST)
	end
	return nil
end

-- Centre of the bounding volume on the map plane, as the base industry window computes it.
local function getPosition(entity : Engine.Entity) : number, number
	local bv : Engine.Component.BoundingVolume = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME)
	if bv == nil then
		local warehouse = getWarehouse(entity)
		if warehouse ~= nil then
			bv = api.engine.getComponent(warehouse.construction, api.type.ComponentType.BOUNDING_VOLUME)
		end
	end
	if bv == nil then
		return nil, nil
	end
	return 0.5 * (bv.bbox.min.x + bv.bbox.max.x), 0.5 * (bv.bbox.min.y + bv.bbox.max.y)
end

local function getName(entity : Engine.Entity) : string
	local name = api.engine.util.getEntityName(entity)
	if name == nil or name == "" then
		return _("Unnamed")
	end
	return name
end

function nearest.getSourceCargoTypes(entity : Engine.Entity) : {CargoTypeId}
	local stockList = getStockList(entity)
	if stockList == nil then
		return {}
	end
	local seen : {CargoTypeId : boolean} = {}
	local result : {CargoTypeId} = {}
	local function add(cargoType : CargoTypeId)
		if cargoType >= 0 and not seen[cargoType] then
			seen[cargoType] = true
			result[#result + 1] = cargoType
		end
	end
	if getWarehouse(entity) ~= nil then
		for _, stock in ipairs(stockList.stocks) do
			add(stock.cargoType)
		end
	else
		for _, rule in ipairs(stockList.rules) do
			for cargoType, _ in pairs(rule.output) do
				add(cargoType)
			end
		end
	end
	table.sort(result)
	return result
end

local function collectCandidates(sourceEntity : Engine.Entity, cargoTypes : {CargoTypeId}) : {CargoTypeId : {ClosestConsumerRank.Candidate}}
	local byCargo : {CargoTypeId : {ClosestConsumerRank.Candidate}} = {}
	for _, cargoType in ipairs(cargoTypes) do
		byCargo[cargoType] = {}
	end

	local function add(entity : Engine.Entity, cargoType : CargoTypeId, isTown : boolean)
		local x, y = getPosition(entity)
		if x == nil then
			return
		end
		local list = byCargo[cargoType]
		list[#list + 1] = { entity = entity, name = getName(entity), isTown = isTown, x = x, y = y }
	end

	local inputStock = api.type["enum"].StockListType.InputStock
	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		if entity == sourceEntity or getWarehouse(entity) ~= nil then
			return
		end
		local stockList : Engine.Component.StockList = api.engine.getComponent(entity, api.type.ComponentType.STOCK_LIST)
		if stockList == nil then
			return
		end
		local added : {CargoTypeId : boolean} = {}
		for _, stock in ipairs(stockList.stocks) do
			local cargoType = stock.cargoType
			if byCargo[cargoType] ~= nil and not added[cargoType] and stock.type == inputStock then
				added[cargoType] = true
				add(entity, cargoType, false)
			end
		end
	end, api.type.ComponentType.INDUSTRY)

	api.engine.forEachEntityWithComponent(function(townEntity : Engine.Entity)
		local town : Engine.Component.Town = api.engine.getComponent(townEntity, api.type.ComponentType.TOWN)
		if town == nil then
			return
		end
		local added : {CargoTypeId : boolean} = {}
		for _, needs in ipairs(town.cargoNeeds) do
			for _, cargoAndLevel in ipairs(needs) do
				local cargoType = cargoAndLevel[1]
				if byCargo[cargoType] ~= nil and not added[cargoType] then
					added[cargoType] = true
					add(townEntity, cargoType, true)
				end
			end
		end
	end, api.type.ComponentType.TOWN)

	return byCargo
end

function nearest.findNearestConsumers(entity : Engine.Entity, limit : integer) : {ClosestConsumerNearest.CargoResult}
	local cargoTypes = nearest.getSourceCargoTypes(entity)
	if #cargoTypes == 0 then
		return {}
	end
	local sourceX, sourceY = getPosition(entity)
	if sourceX == nil then
		error("no position for entity " .. tostring(entity))
	end
	local byCargo = collectCandidates(entity, cargoTypes)
	local results : {ClosestConsumerNearest.CargoResult} = {}
	for _, cargoType in ipairs(cargoTypes) do
		results[#results + 1] = {
			cargoType = cargoType,
			consumers = rank.nearest(sourceX, sourceY, byCargo[cargoType], limit),
		}
	end
	return results
end

return nearest
```

- [ ] **Step 3: Type-check and fix any API mismatches it reports**

Run: `tools/check.sh`
Expected: `0 error(s)`. If a component record name differs (for example
`Engine.Component.BoundingVolume`), look it up in the game's
`api/tealdef/api/engine.d.tl` and fix it. Do not cast to `any` to silence the
checker.

- [ ] **Step 4: Run the unit tests (no regressions)**

Run: `lua tools/test.lua`
Expected: `8 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add mod
git commit -m "feat: gather source cargo and candidate consumers from game state"
```

---

### Task 5: UI plugins (replace hello world)

**Files:**
- Modify: `mod/.../gui/closest_consumer/closest_consumer.script.tl` (full rewrite)
- Modify: `mod/.../gui/closest_consumer/industry_plugin.res.lua` (add `condition`)

- [ ] **Step 1: Rewrite `closest_consumer.script.tl`**

```lua
local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local cargo_react_util = ug_require "::/gui/main/cargo_react_util.tl" as CargoReactUtil
local cargo_util = ug_require "::/gui/main/cargo_util.tl" as CargoUtil
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local industry_eow = ug_require "::/gui/entity_window/industry/industry_eow.script.tl" as IndustryEow
local warehouse_eow = ug_require "::/gui/entity_window/warehouse/warehouse_eow.script.tl" as WarehouseEow
local nearest = ug_require "pgrace_closest_consumer::/gui/closest_consumer/nearest.tl" as ClosestConsumerNearest
local rank = ug_require "pgrace_closest_consumer::/gui/closest_consumer/rank.tl" as ClosestConsumerRank

debugPrint("[closest_consumer] script loaded")

local RESULT_LIMIT = 3

local record ListParams
	entityId : Engine.Entity
	isWarehouse : boolean
end

local record ListState
	results : {ClosestConsumerNearest.CargoResult}
	failed : boolean
end

local function computeState(entity : Engine.Entity) : ListState
	local ok, resultsOrError = pcall(nearest.findNearestConsumers, entity, RESULT_LIMIT)
	if ok then
		return { results = resultsOrError as {ClosestConsumerNearest.CargoResult}, failed = false }
	end
	debugPrint("[closest_consumer] error for entity " .. tostring(entity) .. ": " .. tostring(resultsOrError))
	return { results = {}, failed = true }
end

local function makeHint(text : string) : TreeNodeId
	return builtin.TextView{ meta = { class = "font-scale-annotation" }, text = text }
end

local function makeConsumerRow(consumer : ClosestConsumerRank.Ranked) : TreeNodeId
	local label = consumer.name
	if consumer.isTown then
		label = label .. " " .. _("(town)")
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			line_react_util.LocateButton{ entity = consumer.entity },
			line_react_util.makeEntityWindowButton(label, consumer.entity),
			builtin.TextView{ text = rank.formatDistance(consumer.distance) },
		},
	}
end

local function makeCargoSection(result : ClosestConsumerNearest.CargoResult) : TreeNodeId
	local children : {TreeNodeId} = {
		builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				cargo_react_util.makeCargoIcon(result.cargoType),
				builtin.TextView{ text = cargo_util.getCargoNameById(result.cargoType) },
			},
		},
	}
	if #result.consumers == 0 then
		children[#children + 1] = makeHint(_("No consumers on this map"))
	else
		for _, consumer in ipairs(result.consumers) do
			children[#children + 1] = makeConsumerRow(consumer)
		end
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end

local NearestConsumersList = react.RegisterRecipe("ClosestConsumerList", function(params : ListParams) : TreeNodeId
	local state = react.useStateLazy(function() : ListState
		return computeState(params.entityId)
	end)
	local current = state:old()

	local children : {TreeNodeId} = {}
	if current.failed then
		children[1] = makeHint(_("Closest consumer: error (see log)"))
	elseif #current.results == 0 then
		children[1] = makeHint(params.isWarehouse and _("No cargo assigned") or _("No outputs"))
	else
		for _, result in ipairs(current.results) do
			children[#children + 1] = makeCargoSection(result)
		end
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end)

local function makeCard(entityId : Engine.Entity, isWarehouse : boolean, gameCtx : GameContext, showOnRightSide : boolean) : TreeNodeId
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Nearest consumers"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(NearestConsumersList, {
				entityId = entityId,
				isWarehouse = isWarehouse,
			} as ListParams),
			gameCtx = gameCtx,
			showOnRightSide = showOnRightSide,
		},
	}
end

local plugins = {}

plugins.IndustryPlugin = react.RegisterPluginRecipe(industry_eow.IndustryEowExtensionPoint, "ClosestConsumerIndustryPlugin", function(params : IndustryEow.IndustryWidgetPluginParams) : TreeNodeId
	return makeCard(params.entityId, false, params.gameCtx, params.showCalloutOnRightSide)
end)

plugins.WarehousePlugin = react.RegisterPluginRecipe(warehouse_eow.WarehouseEowExtensionPoint, "ClosestConsumerWarehousePlugin", function(params : WarehouseEow.WarehouseWidgetPluginParams) : TreeNodeId
	return makeCard(params.entityId, true, params.gameCtx, params.showCalloutOnRightSide)
end)

-- Hides the card for industries that produce nothing (e.g. pure consumers).
-- On error it returns true, so that the card can show the error hint.
function plugins.hasOutputs(params : IndustryEow.IndustryWidgetPluginParams) : boolean
	local ok, cargoTypes = pcall(nearest.getSourceCargoTypes, params.entityId)
	return not ok or #(cargoTypes as {CargoTypeId}) > 0
end

return plugins
```

- [ ] **Step 2: Add the condition to `industry_plugin.res.lua`**

```lua
function data()
	return {
		type = "react-plugin ::IndustryEowExtensionPoint",
		data = {
			filePath = "pgrace_closest_consumer::/gui/closest_consumer/closest_consumer.script@IndustryPlugin",
			condition = "pgrace_closest_consumer::/gui/closest_consumer/closest_consumer.script@hasOutputs",
			order = 35,
		}
	}
end
```

- [ ] **Step 3: Type-check and fix any errors**

Run: `tools/check.sh`
Expected: `0 error(s)`

- [ ] **Step 4: Run the tests, regenerate `_content.json`, commit**

Run: `lua tools/test.lua && python3 tools/gen_content_json.py`
Expected: `8 passed, 0 failed`, `_content.json: 8 files`

```bash
git add mod
git commit -m "feat: nearest consumers card in industry and warehouse windows"
```

---

### Task 6: README with dev loop and in-game checklist

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`** covering:
  - What the mod does.
  - Repo layout.
  - `tools/fetch-tl.sh`, `tools/check.sh`, `lua tools/test.lua`.
  - `tools/install.sh` (symlink, `--copy` fallback, `TF3_STAGING` / `TF3_DIR` overrides).
  - How to enable the mod in-game.
  - Where the logs are (`crash_dump/*.txt`, grep `closest_consumer`).
  - The in-game checklist from the spec.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with dev loop and in-game checklist"
```

---

## Self-Review Notes

- **Spec coverage:**
  - Matching rules: Task 4.
  - Straight-line distance and top 3: Task 3, plus `RESULT_LIMIT` in Task 5.
  - Warehouses excluded as consumers: Task 4.
  - Warehouse source cargo: Task 4.
  - UI card, locate/name buttons, "(town)", empty states, no card for no outputs: Task 5.
  - `pcall` error hint: Task 5.
  - `tl check` and unit tests: Tasks 1 and 3.
  - Hello-world plumbing: Task 2.
  - Install: Task 2.
  - `_content.json` risk: Task 2.
- **Deviation from spec:** the spec put `rank` inside `nearest.tl`. The plan splits it into `rank.tl` so the tests can load it without the game API. Same responsibilities, cleaner boundary.
- **Unknowns only resolvable in-game:**
  - Is `_content.json` needed or regenerated?
  - Is a symlinked mod folder followed?
  - Does the `pgrace_closest_consumer::/` require path resolve?
  - Is `useStateLazy` evaluated once per window open?

  The script prints `[closest_consumer] script loaded` to the log to help diagnose these.
