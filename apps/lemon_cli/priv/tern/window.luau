local tern = require("tern")
local config = tern.json.decode(tern.fs.read("launcher.json"))

-- Launcher paths are JSON data, never Luau source. The installer quotes the
-- complete executable as one POSIX shell word; cwd is a layout field, not code.
local function can_launch(cx)
	return tern.runtime.os ~= "windows" and cx.hosts:current().kind == "local"
end

local function is_lemon(pane)
	-- A custom card-form session title need not contain the Lemon brand.
	-- Program identity also handles renamed installed launchers.
	if (pane.kind ~= "terminal" and pane.kind ~= "agent") or pane.exited ~= nil then
		return false
	end
	local program = pane.program or ""
	local basename = string.match(program, "([^/]+)$") or program
	return basename == "lemon"
		or basename == "lemon-tui"
		or program == config.launcher
		or string.sub(pane.title, 1, #"🍋 LEMON: ") == "🍋 LEMON: "
		or string.sub(pane.title, 1, #"Lemon · ") == "Lemon · "
end

tern.command({
	id = "new-session-split",
	title = "Lemon: New session in split",
	available = can_launch,
	run = function(cx)
		if not can_launch(cx) then
			cx:toast("error", "Lemon must be launched on this local POSIX host")
			return
		end

		local focused = cx.session:focused()
		local source = focused and cx.session:pane(focused)
		local launch = { command = config.command }
		if source and source.cwd and source.cwd ~= "" then
			launch.cwd = source.cwd
		elseif source then
			cx:toast("error", "The focused pane has no working directory", "Focus a shell or Lemon pane first.")
			return
		end

		local pane
		if focused then
			pane = cx.layout:split(focused, "right", launch)
		else
			pane = cx.layout:new_tab(launch)
		end
		if not pane then
			cx:toast("error", "Could not open a Lemon pane")
		end
	end,
})

tern.command({
	id = "focus-session",
	title = "Lemon: Focus existing session",
	run = function(cx)
		local items = {}
		for _, pane in ipairs(cx.session:panes()) do
			if is_lemon(pane) then
				table.insert(items, {
					label = pane.title,
					detail = (pane.cwd or "") .. " · pane " .. tostring(pane.pane)
						.. (pane.parked and " · parked" or ""),
					current = pane.focused,
					pane = pane.pane,
				})
			end
		end

		if #items == 0 then
			cx:toast("info", "No open Lemon TUI sessions", "Choose Lemon: New session in split to open one. ACP sessions are separate.")
			return
		end

		cx:pick({ items = items, placeholder = "Focus a Lemon session", action = "focus" }):next(function(item, err, fresh)
			if not fresh then
				return
			end
			if err then
				fresh:toast("error", "Could not select a Lemon session", err)
				return
			end
			if not item then
				return
			end
			local pane = fresh.session:pane(item.pane)
			if not pane or not is_lemon(pane) then
				fresh:toast("info", "That Lemon session is no longer open")
				return
			end
			if pane.parked then
				local ok, problem = fresh.layout:unpark(pane.pane)
				if not ok then
					fresh:toast("error", "Could not reveal the Lemon session", problem)
					return
				end
			end
			fresh.layout:focus(pane.pane)
		end)
	end,
})
