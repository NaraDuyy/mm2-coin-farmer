--!nocheck
-- MM2 Coin Farmer — auto-tweens to coins, GUI dashboard, server-hop on low pop.
-- Designed to run from Volt's autoexec folder (fires on every game join).

if not game:IsLoaded() then game.Loaded:Wait() end

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local Workspace        = game:GetService("Workspace")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TeleportService  = game:GetService("TeleportService")
local HttpService      = game:GetService("HttpService")
local CoreGui          = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
	LocalPlayer = Players.LocalPlayer
end

-- =========================
-- MM2 sanity check
-- =========================
-- Autoexec runs on every game. Bail out quietly if this isn't MM2 so the
-- script doesn't spam the console or build a GUI in unrelated games.
local function isLikelyMM2()
	local rs = game:GetService("ReplicatedStorage")
	local remotes = rs:FindFirstChild("Remotes")
	if not remotes then return false end
	if remotes:FindFirstChild("Inventory") and remotes:FindFirstChild("Gameplay") then
		return true
	end
	local extras = remotes:FindFirstChild("Extras")
	if extras and extras:FindFirstChild("SetMurderer") then return true end
	return false
end
if not isLikelyMM2() then return end

-- =========================
-- Device auto-detection (silent, no prompt)
-- =========================
-- Some UI paths differ between desktop and small-screen layouts (e.g.
-- the account-coin label sits under CrossPlatform.Shop.Medium on PC vs
-- CrossPlatform.Shop.Small on phone). Detect silently from
-- UserInputService — no prompt, no saved file.
local DEVICE = "pc"
do
	local UIS = game:GetService("UserInputService")
	if UIS.TouchEnabled and not UIS.MouseEnabled then
		local cam = workspace.CurrentCamera
		local aspect = cam and (cam.ViewportSize.X / cam.ViewportSize.Y) or 1.78
		DEVICE = (aspect < 1.5) and "ipad" or "mobile"
	end
end
local IS_MOBILE = (DEVICE == "mobile" or DEVICE == "ipad")
print(("[CoinTween] Device: %s"):format(DEVICE))

-- =========================
-- Config
-- =========================
local FALLBACK_WALKSPEED = 25    -- slower = more physics ticks of coin
                                  -- overlap = more reliable Touched events
local SPEED_MULTIPLIER   = 1.0
local COIN_OFFSET        = Vector3.new(0, -2.5, 0)   -- HRP center 3 studs above
                                                    -- coin = character standing
                                                    -- ON the coin. NEGATIVE Y
                                                    -- offsets put the HRP below
                                                    -- floor level → MM2 kicks
                                                    -- for "invalid position"
local SCAN_INTERVAL      = 0.1
local RADIUS             = 150
local MIN_TWEEN_TIME     = 0.25  -- enforces ≥ 2.5 physics ticks per tween
                                  -- at FPS_CAP=10, so even short hops have
                                  -- enough overlap windows for the engine
                                  -- to detect the coin Touched event
local MAX_TWEEN_TIME     = 8.0
local POST_TWEEN_DWELL   = 0.5   -- pause after each tween. Safe at this
                                  -- length now that we're in anchored mode
                                  -- (no float drift to worry about).
local MAX_BAG            = 40
local ENABLE_NOCLIP      = true   -- character ignores collision (passes through walls)
local RESET_DELAY        = 0.4
local STOP_KEY           = Enum.KeyCode.X
local TOGGLE_GUI_KEY     = Enum.KeyCode.H

-- Server hop
local MIN_PLAYERS         = 5     -- hop if server population drops below this
local SERVER_CHECK_PERIOD = 15    -- seconds between population checks
local HOP_GRACE_PERIOD    = 30    -- seconds after join before the first hop check
                                  -- (so we don't hop the moment we land before others load in)

-- Low-rate hop: if our coins/hour falls below LOW_RATE_THRESHOLD after
-- LOW_RATE_GRACE seconds in this server, hop to a fresh one. Catches dead
-- rounds, slow servers, and rare situations where coins aren't spawning.
local LOW_RATE_THRESHOLD     = 500    -- coins/hour
local LOW_RATE_GRACE         = 600    -- seconds (10 min) before the check kicks in
local LOW_RATE_CHECK_PERIOD  = 60     -- seconds between low-rate checks

-- Permanent-anchor: HRP.Anchored = true at all times. Server treats the
-- CFrame as authoritative for anchored parts (no physics validation =
-- no invalid-position kick). The downside is that Touched events on
-- coins don't fire from CFrame writes alone, so we ALSO call
-- firetouchinterest() after each tween to manually fire the touch ->
-- server's coin pickup handler runs and awards the coin.
local PERMANENT_ANCHOR    = true
local SPAWN_LIFT_Y        = 500   -- (unused — kept for legacy compat)
local USE_FIRETOUCH       = true  -- manually fire Touched events on coins
                                   -- after each tween (works around the
                                   -- anchored-CFrame-no-Touched issue)

-- Hitbox extension: scale the HumanoidRootPart by HITBOX_MULTIPLIER. With
-- the float setup (HRP unanchored, gravity cancelled, Touched events fire
-- normally), a larger HRP means coin Touched events trigger from a wider
-- radius. Default HRP is ~2x2x1, so 1.5x → 3x3x1.5.
-- DISABLED — combining Massless=true on a resized HRP throws off the
-- assembly mass calc, which makes BodyForce gravity-cancel under-correct
-- and the character doesn't follow the tween cleanly.
local EXPAND_HITBOX       = false
local HITBOX_MULTIPLIER   = 1.5

-- Performance
local FPS_CAP             = 10    -- lock framerate (0 = no cap)
local OPTIMIZE_GRAPHICS   = true  -- lower quality, kill shadows/lighting/particles
local AGGRESSIVE_OPTIMIZE = false  -- camera-underground trick, mute audio, hide all geometry
local BLACK_BACKGROUND    = true  -- solid black overlay covering the game render
local GUI_UPDATE_INTERVAL = 1.0   -- seconds between GUI text refreshes

-- =========================
-- Performance optimizations
-- =========================
-- Lock the framerate via the executor's setfpscap. Different executors
-- expose it in different namespaces — try each known location until one
-- accepts the call.
if FPS_CAP and FPS_CAP > 0 then
	local methods = {
		{ "global setfpscap",       function() return setfpscap(FPS_CAP) end },
		{ "getgenv().setfpscap",    function() return getgenv().setfpscap(FPS_CAP) end },
		{ "_G.setfpscap",           function() return _G.setfpscap(FPS_CAP) end },
		{ "getrenv().setfpscap",    function() return getrenv().setfpscap(FPS_CAP) end },
		{ "setframerate",           function() return setframerate(FPS_CAP) end },
		{ "set_fps_cap",            function() return set_fps_cap(FPS_CAP) end },
	}
	local applied
	for _, entry in ipairs(methods) do
		local ok = pcall(entry[2])
		if ok then applied = entry[1]; break end
	end
	if applied then
		print(("[CoinTween] FPS capped at %d via %s"):format(FPS_CAP, applied))
	else
		warn("[CoinTween] Could not set FPS cap — executor exposes none of the known APIs.")
	end
end

-- Strip expensive rendering features. Coin pickup is purely physics-based,
-- so we don't need shadows, particles, lighting effects, or terrain detail.
if OPTIMIZE_GRAPHICS then
	pcall(function()
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
	end)

	local Lighting = game:GetService("Lighting")
	pcall(function()
		Lighting.GlobalShadows  = false
		Lighting.FogEnd         = 1e9
		Lighting.Brightness     = 1
		Lighting.EnvironmentDiffuseScale  = 0
		Lighting.EnvironmentSpecularScale = 0
	end)

	-- Disable post-processing, atmosphere, sky.
	for _, c in ipairs(Lighting:GetChildren()) do
		if c:IsA("PostEffect") or c:IsA("Clouds") then
			pcall(function() c.Enabled = false end)
		elseif c:IsA("Atmosphere") or c:IsA("Sky") then
			-- These have no Enabled property — destroy them outright.
			pcall(function() c:Destroy() end)
		end
	end

	local Workspace = game:GetService("Workspace")
	-- One-time pass over existing instances.
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam")
		or d:IsA("Smoke") or d:IsA("Fire") or d:IsA("Sparkles")
		or d:IsA("PointLight") or d:IsA("SurfaceLight") or d:IsA("SpotLight") then
			pcall(function() d.Enabled = false end)
		end
	end
	-- Catch newly added effects (server-spawned coins/effects).
	Workspace.DescendantAdded:Connect(function(d)
		if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam")
		or d:IsA("Smoke") or d:IsA("Fire") or d:IsA("Sparkles")
		or d:IsA("PointLight") or d:IsA("SurfaceLight") or d:IsA("SpotLight") then
			pcall(function() d.Enabled = false end)
		end
	end)

	-- Make terrain cheap (water reflections + decorations are expensive).
	pcall(function()
		Workspace.Terrain.WaterWaveSize  = 0
		Workspace.Terrain.WaterWaveSpeed = 0
		Workspace.Terrain.WaterReflectance = 0
		Workspace.Terrain.WaterTransparency = 1
		Workspace.Terrain.Decoration = false
	end)
end

-- ============================================================
-- AGGRESSIVE optimizations: hide everything, mute all audio,
-- park the camera underground so the renderer has nothing to draw.
-- These are the heavy hitters for GPU/RAM. Combined with FPS_CAP,
-- the client should idle at single-digit-percent GPU.
-- ============================================================
if AGGRESSIVE_OPTIMIZE then
	local Workspace      = game:GetService("Workspace")
	local SoundService   = game:GetService("SoundService")
	local Lighting       = game:GetService("Lighting")
	local RunService     = game:GetService("RunService")

	-- 1) Park the camera ~50,000 studs underground with a 1-degree FOV.
	-- Almost nothing falls inside the view frustum → renderer has near-zero
	-- work. We re-pin every 0.5s in case the game tries to grab control.
	local hideCF = CFrame.new(0, -50000, 0)
	local function pinCamera()
		local cam = Workspace.CurrentCamera
		if not cam then return end
		pcall(function()
			cam.CameraType   = Enum.CameraType.Scriptable
			cam.CFrame       = hideCF
			cam.Focus        = hideCF
			cam.FieldOfView  = 1
		end)
	end
	pinCamera()
	task.spawn(function()
		while true do
			pinCamera()
			task.wait(0.5)
		end
	end)
	-- Re-pin on character respawn (the game often resets camera then).
	if LocalPlayer then
		LocalPlayer.CharacterAdded:Connect(function()
			task.wait(0.2)
			pinCamera()
		end)
	end

	-- 2) Make every visual surface fully transparent. Transparency is purely
	-- cosmetic — Touched events, CanCollide, and CanTouch are unaffected,
	-- so coin pickup still works perfectly.
	local function hideRender(d)
		if d:IsA("BasePart") then
			pcall(function()
				d.Transparency  = 1
				d.CastShadow    = false
				d.Material      = Enum.Material.SmoothPlastic
				d.Reflectance   = 0
			end)
		elseif d:IsA("Decal") or d:IsA("Texture") then
			pcall(function() d.Transparency = 1 end)
		elseif d:IsA("SpecialMesh") or d:IsA("MeshPart") then
			pcall(function() d.TextureId = "" end)
		end
	end

	for _, d in ipairs(Workspace:GetDescendants()) do
		hideRender(d)
	end
	Workspace.DescendantAdded:Connect(hideRender)

	-- 3) Mute everything. Sound is purely additional CPU/IO; we don't need
	-- it for farming and it can be quite expensive on map-heavy games.
	pcall(function()
		SoundService.AmbientReverb        = Enum.ReverbType.NoReverb
		SoundService.DistanceFactor       = 1
		SoundService.DopplerScale         = 0
		SoundService.RolloffScale         = 0
	end)
	local function muteSound(d)
		if d:IsA("Sound") then
			pcall(function()
				d.Volume   = 0
				d.Playing  = false
				d:Stop()
			end)
		end
	end
	for _, d in ipairs(game:GetDescendants()) do muteSound(d) end
	game.DescendantAdded:Connect(muteSound)

	-- 4) Cull additional lighting properties.
	pcall(function()
		Lighting.ShadowSoftness        = 0
		Lighting.GlobalShadows         = false
		Lighting.ColorShift_Bottom     = Color3.new(0, 0, 0)
		Lighting.ColorShift_Top        = Color3.new(0, 0, 0)
		Lighting.ExposureCompensation  = 0
	end)

	print("[CoinTween] Aggressive graphics/audio optimization applied.")
end

-- =========================
-- Anti-AFK
-- =========================
-- Roblox kicks idle players after ~20 minutes. `LocalPlayer.Idled` fires
-- when the engine detects no input. We respond with a synthetic mouse
-- click via the VirtualUser service, which resets the idle timer. This
-- is the well-known anti-AFK pattern and works from any LocalScript /
-- executor environment.
do
	local VirtualUser = game:GetService("VirtualUser")
	LocalPlayer.Idled:Connect(function()
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
		print("[CoinTween] Anti-AFK click fired (idle timer reset).")
	end)
end

-- =========================
-- Helpers
-- =========================
local function getRoot()
	-- Non-blocking: if the character has been destroyed (round death, anti-
	-- cheat reset), return nil instead of hanging on CharacterAdded:Wait().
	-- The main loop checks for nil and yields one frame, then retries —
	-- so we resume the moment the character respawns instead of stalling
	-- the whole coroutine for 5+ seconds.
	local char = LocalPlayer.Character
	if not char then return nil, nil, nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum  = char:FindFirstChildOfClass("Humanoid")
	return root, hum, char
end

local function collectCoins()
	local coins = {}
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d.Name == "Coin_Server" and d:IsA("BasePart") and d.Parent then
			table.insert(coins, d)
		end
	end
	return coins
end

local function isFiniteVec(v)
	return v
		and v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and math.abs(v.X) ~= math.huge
		and math.abs(v.Y) ~= math.huge
		and math.abs(v.Z) ~= math.huge
end

local function getEffectiveSpeed(hum)
	-- Always use the explicit fallback. MM2's WalkSpeed default is 16,
	-- which would make tweens painfully slow. We override.
	return FALLBACK_WALKSPEED * SPEED_MULTIPLIER
end

local function tweenTo(root, hum, targetPos, distance)
	if not isFiniteVec(targetPos) or not isFiniteVec(root.Position) then
		return nil, "non-finite position", 0
	end

	-- In anchored mode, also rotate the HRP 90° around X so the rig is
	-- pinned in a lay-flat pose. Anchored parts don't run physics, so
	-- Humanoid state alone can't pose them — the rotation has to come
	-- from the CFrame we're writing. Server trusts anchored CFrames so
	-- the rotation doesn't trigger anti-cheat.
	local goalCF
	if PERMANENT_ANCHOR then
		goalCF = CFrame.new(targetPos) * CFrame.Angles(math.rad(90), 0, 0)
	else
		goalCF = CFrame.new(targetPos)
	end

	local speed    = getEffectiveSpeed(hum)
	local duration = math.max(MIN_TWEEN_TIME, distance / speed)

	local info = TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	local ok, tween = pcall(TweenService.Create, TweenService, root, info, { CFrame = goalCF })
	if not ok then return nil, tween, duration end
	local ok2, err = pcall(function() tween:Play() end)
	if not ok2 then return nil, err, duration end
	return tween, nil, duration
end

-- =========================
-- Stats: derived from the in-game coin label
-- =========================
-- Both "Total this session" and "Coins / hour" come from watching the
-- account coin balance change in PlayerGui (the same TextLabel the dashboard
-- displays). The local tween-pickup count is no longer used for stats —
-- it only drives the bag-full reset.

-- Forward declarations for the account-coin label state. The "Account
-- coin balance" section later in the file populates these — declared up
-- here so the stat helpers below close over the right upvalues.
local accountCoinsText = "?"
local accountCoinsNum  = 0
local coinTextLabel    = nil


local ROLLING_WINDOW    = 3600   -- seconds (1 hour)
local sessionStart      = os.clock()
local sessionStartCoins = nil    -- account balance when the session began
local lastKnownCoins    = nil    -- last-seen account balance (delta basis)
local coinGains         = {}     -- {{ time = clock, amount = +delta }, ...}
local bagCount          = 0      -- still tracked for the auto-reset trigger

-- Called whenever the account coin label changes. Only positive deltas
-- count as "earned this session" — purchases (negative deltas) reset the
-- baseline so they don't artificially inflate later gains.
local function onCoinBalanceChanged(newVal)
	if not newVal then return end
	if not sessionStartCoins then
		sessionStartCoins = newVal
		lastKnownCoins    = newVal
		return
	end
	local delta = newVal - (lastKnownCoins or newVal)
	if delta > 0 then
		local now = os.clock()
		table.insert(coinGains, { time = now, amount = delta })
		-- Trim entries older than the rolling window.
		local cutoff = now - ROLLING_WINDOW
		while #coinGains > 0 and coinGains[1].time < cutoff do
			table.remove(coinGains, 1)
		end
	elseif delta < 0 then
		-- Spent some coins (shop, etc). Re-anchor the session baseline so
		-- future gains aren't measured against a balance we no longer have.
		sessionStartCoins = math.max(0, (sessionStartCoins or 0) + delta)
	end
	lastKnownCoins = newVal
end

local function getSessionTotal()
	if not sessionStartCoins or not accountCoinsNum then return 0 end
	return math.max(0, accountCoinsNum - sessionStartCoins)
end

local function coinsLastHour()
	local cutoff = os.clock() - ROLLING_WINDOW
	while #coinGains > 0 and coinGains[1].time < cutoff do
		table.remove(coinGains, 1)
	end
	local total = 0
	for _, e in ipairs(coinGains) do total += e.amount end
	return total
end

-- Local pickup detection still drives the bag-full auto-reset; the rate
-- stats no longer depend on it.
local function recordPickup()
	bagCount += 1
end

-- =========================
-- GUI
-- =========================
-- Cleanup any previous GUI from a prior script run (autoexec re-runs on
-- teleport, so we always rebuild from a clean slate).
pcall(function()
	for _, g in ipairs(CoreGui:GetChildren()) do
		if g.Name == "MM2CoinFarmerGui" then g:Destroy() end
	end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "MM2CoinFarmerGui"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent = CoreGui end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

-- Full-screen frame. When BLACK_BACKGROUND is on this is a solid black
-- wall covering the game render — combined with the FPS cap and graphics
-- downgrades, it lets the GPU coast on a near-empty frame.
local fullscreen = Instance.new("Frame")
fullscreen.Name = "Fullscreen"
fullscreen.Size = UDim2.fromScale(1, 1)
fullscreen.BackgroundColor3       = Color3.new(0, 0, 0)
fullscreen.BackgroundTransparency = BLACK_BACKGROUND and 0 or 1
fullscreen.BorderSizePixel        = 0
fullscreen.Active                 = BLACK_BACKGROUND   -- absorb clicks if opaque
fullscreen.Parent                 = gui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Position = UDim2.new(0.5, 0, 0, 12)
panel.Size = UDim2.fromOffset(440, 260)
panel.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
panel.BackgroundTransparency = 0.25
panel.BorderSizePixel = 0
panel.Parent = fullscreen

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = panel

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 200, 50)
stroke.Thickness = 2
stroke.Transparency = 0.3
stroke.Parent = panel

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, 0, 0, 34)
title.Position = UDim2.new(0, 0, 0, 6)
title.BackgroundTransparency = 1
title.Text = "MM2 COIN FARMER"
title.TextColor3 = Color3.fromRGB(255, 215, 75)
title.Font = Enum.Font.GothamBlack
title.TextScaled = true
title.TextXAlignment = Enum.TextXAlignment.Center
title.Parent = panel

local function makeRow(name, y)
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.Size = UDim2.new(1, -24, 0, 24)
	lbl.Position = UDim2.new(0, 12, 0, y)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = Color3.fromRGB(240, 240, 240)
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 18
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = ""
	lbl.Parent = panel
	return lbl
end

local rowRate     = makeRow("Rate",     44)   -- coins per hour
local rowTotal    = makeRow("Total",    72)   -- session total
local rowCoins    = makeRow("Coins",   100)   -- player's account coin balance
local rowBag      = makeRow("Bag",     128)   -- bag fill
local rowPlayers  = makeRow("Players", 156)   -- player count
local rowLocation = makeRow("Location", 184)  -- lobby vs map + round phase
local rowStatus   = makeRow("Status",  212)   -- current state

-- Big rate display behind/under the title for "fullscreen" emphasis: a huge
-- translucent number floating in the upper area.
local bigRate = Instance.new("TextLabel")
bigRate.Name = "BigRate"
bigRate.AnchorPoint = Vector2.new(0.5, 0)
bigRate.Position = UDim2.new(0.5, 0, 0, 230)
bigRate.Size = UDim2.fromOffset(700, 160)
bigRate.BackgroundTransparency = 1
bigRate.Text = "0"
bigRate.TextColor3 = Color3.fromRGB(255, 215, 75)
bigRate.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
bigRate.TextStrokeTransparency = 0.5
bigRate.TextTransparency = 0.25
bigRate.Font = Enum.Font.GothamBlack
bigRate.TextScaled = true
bigRate.Parent = fullscreen

local bigLabel = Instance.new("TextLabel")
bigLabel.AnchorPoint = Vector2.new(0.5, 0)
bigLabel.Position = UDim2.new(0.5, 0, 0, 380)
bigLabel.Size = UDim2.fromOffset(500, 30)
bigLabel.BackgroundTransparency = 1
bigLabel.Text = "coins / hour"
bigLabel.TextColor3 = Color3.fromRGB(255, 215, 75)
bigLabel.TextStrokeTransparency = 0.6
bigLabel.TextTransparency = 0.35
bigLabel.Font = Enum.Font.GothamMedium
bigLabel.TextScaled = true
bigLabel.Parent = fullscreen

-- =========================
-- State + GUI updater
-- =========================
local stopped     = false
local statusText  = "Starting..."
local hopLockout  = os.clock() + HOP_GRACE_PERIOD
local hopping     = false

local function setStatus(s)
	statusText = s
end

-- =========================
-- Location + round-phase detection
-- =========================
-- "Where am I" comes from inspecting Workspace children. The active map is
-- a Model child that contains a CoinContainer (during coin phase) or a
-- known map name pattern. The lobby is a Model named "Lobby".
local locationStr = "Detecting..."
local roundPhase  = "Idle"

local function refreshLocation()
	-- Strongest signal: any Model with a CoinContainer = current map.
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") and child:FindFirstChild("CoinContainer") then
			locationStr = "Map: " .. child.Name
			return
		end
	end

	-- Otherwise look for a Lobby model.
	local lobby = Workspace:FindFirstChild("Lobby")
	if lobby and lobby:IsA("Model") then
		locationStr = "Lobby"
		return
	end

	-- Fallback: assume any non-default workspace Model is a map between rounds.
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model")
		   and child.Name ~= "Lobby"
		   and not child:IsA("Camera")
		   and child:FindFirstChildWhichIsA("BasePart") then
			-- Skip player characters.
			if not Players:GetPlayerFromCharacter(child) then
				locationStr = "Map: " .. child.Name
				return
			end
		end
	end
	locationStr = "Unknown"
end

-- =========================
-- Account coin balance (live)
-- =========================
-- MM2 doesn't expose coins as a leaderstat — it lives in the in-game UI:
--   PlayerGui.CrossPlatform.Shop.Medium.Title.Coins.Container.Amount.Text
-- We bind to that TextLabel's Text property and listen for changes so the
-- dashboard mirrors whatever the game shows.
-- Account-coin label paths differ between desktop and mobile/ipad.
-- We try the device-preferred path first, then fall back to the others.
local COIN_LABEL_PATH_PC = {
	"CrossPlatform", "Shop", "Medium", "Title", "Coins", "Container", "Amount",
}
local COIN_LABEL_PATH_MOBILE = {
	"CrossPlatform", "Shop", "Small", "Container", "Title", "Container", "Coins", "Container", "Amount",
}
local COIN_LABEL_PATHS = IS_MOBILE
	and { COIN_LABEL_PATH_MOBILE, COIN_LABEL_PATH_PC }
	or  { COIN_LABEL_PATH_PC, COIN_LABEL_PATH_MOBILE }
-- accountCoinsText / accountCoinsNum / coinTextLabel are forward-declared
-- in the Stats section above so closures there capture the correct upvalues.

local function parseCoinsNumber(text)
	if not text then return nil end
	-- Strip whitespace and commas.
	local cleaned = text:gsub("%s+", ""):gsub(",", "")

	-- Try suffix-style first ("12K", "1.5M", "1234", etc.).
	local num, suffix = cleaned:match("^([%d%.]+)([KkMmBb]?)$")
	if num then
		local n = tonumber(num)
		if n then
			if suffix == "K" or suffix == "k" then n = n * 1e3
			elseif suffix == "M" or suffix == "m" then n = n * 1e6
			elseif suffix == "B" or suffix == "b" then n = n * 1e9 end
			return math.floor(n)
		end
	end

	-- Fallback: extract the first run of digits/decimal — handles
	-- "40/40", "40 of 40", "Coins: 40", "40 / 40", etc. The bag label
	-- in MM2 specifically uses "current/max" form, which the strict
	-- match above rejects.
	local firstNum = cleaned:match("([%d%.]+)")
	if firstNum then return tonumber(firstNum) end

	return tonumber(cleaned)
end

local function findCoinLabel()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	if not pg then return nil end
	-- Try every device's path in priority order; first hit wins.
	for _, path in ipairs(COIN_LABEL_PATHS) do
		local node = pg
		local ok = true
		for _, name in ipairs(path) do
			node = node:FindFirstChild(name)
			if not node then ok = false; break end
		end
		if ok and node and (node:IsA("TextLabel") or node:IsA("TextBox") or node:IsA("TextButton")) then
			return node
		end
	end
	return nil
end

local function readCoinLabel()
	if not coinTextLabel or not coinTextLabel.Parent then return end
	accountCoinsText = coinTextLabel.Text
	accountCoinsNum  = parseCoinsNumber(accountCoinsText) or accountCoinsNum
	-- Feed the rate-tracker so "Total this session" and "Coins / hour"
	-- update from the authoritative account balance.
	onCoinBalanceChanged(accountCoinsNum)
end

local function bindCoinLabel()
	local lbl = findCoinLabel()
	if not lbl or lbl == coinTextLabel then return end
	coinTextLabel = lbl
	readCoinLabel()
	lbl:GetPropertyChangedSignal("Text"):Connect(readCoinLabel)
end

bindCoinLabel()

-- The Shop GUI may not exist immediately on join — watch for it to spawn.
local pg = LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5)
if pg then
	pg.DescendantAdded:Connect(function(d)
		if d.Name == "Amount" and (not coinTextLabel or not coinTextLabel.Parent) then
			task.wait(0.1)
			bindCoinLabel()
		end
	end)
end

-- Slow safety poll: re-read in case the property change signal doesn't
-- fire (the game might rewrite the whole label rather than just .Text),
-- and re-bind if the label was replaced.
task.spawn(function()
	while true do
		task.wait(3)
		if coinTextLabel and coinTextLabel.Parent then
			readCoinLabel()
		else
			coinTextLabel = nil
			bindCoinLabel()
		end
	end
end)

-- =========================
-- Bag-per-round counter (live)
-- =========================
-- MM2 also exposes the in-round coin-bag fill at:
--   PlayerGui.MainGUI.Game.CoinBags.Container.Coin.CurrencyFrame.Icon.Coins
-- Same binding pattern as the account label — read .Text, parse to a
-- number, and listen for property changes. This is the authoritative
-- source for the bag-fill display and the auto-reset trigger; the local
-- bagCount falls back if the label isn't found (lobby state, etc.).
-- Bag label sits at the same MainGUI tree on both desktop and mobile,
-- but the dump shows two possible parents — `Container` (runtime alias
-- created by CoinBagContainerScript) or `CoinBagContainerScript` (the
-- raw script instance). Try both.
local BAG_LABEL_PATHS = {
	{ "MainGUI", "Game", "CoinBags", "Container",                "Coin", "CurrencyFrame", "Icon", "Coins" },
	{ "MainGUI", "Game", "CoinBags", "CoinBagContainerScript",   "Coin", "CurrencyFrame", "Icon", "Coins" },
}
local bagLabel    = nil
local bagFromUI   = nil   -- nil if not yet bound; number once we have a reading

local function findBagLabel()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	if not pg then return nil end
	for _, path in ipairs(BAG_LABEL_PATHS) do
		local node = pg
		local ok = true
		for _, name in ipairs(path) do
			node = node:FindFirstChild(name)
			if not node then ok = false; break end
		end
		if ok and node and (node:IsA("TextLabel") or node:IsA("TextBox") or node:IsA("TextButton")) then
			return node
		end
	end
	return nil
end

-- The original single-path findBagLabel definition that follows is dead
-- code now (the if/return block below); leaving the structure intact so
-- we don't break the surrounding control flow.
local function _findBagLabel_legacy_unused()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	if not pg then return nil end
	local node = pg
	for _, name in ipairs(BAG_LABEL_PATHS[1]) do
		node = node:FindFirstChild(name)
		if not node then return nil end
	end
	if node:IsA("TextLabel") or node:IsA("TextBox") or node:IsA("TextButton") then
		return node
	end
	return nil
end

local function readBagLabel()
	if not bagLabel or not bagLabel.Parent then return end
	local raw    = bagLabel.Text
	local parsed = parseCoinsNumber(raw)
	if parsed then
		-- Only log when the value crosses or hits the reset threshold so
		-- we don't spam the console on every increment.
		if parsed >= MAX_BAG and (not bagFromUI or bagFromUI < MAX_BAG) then
			print(("[CoinTween] Bag label = %q → parsed %d (>= %d, reset will fire)")
				:format(raw, parsed, MAX_BAG))
		end
		bagFromUI = parsed
	end
end

local function bindBagLabel()
	local lbl = findBagLabel()
	if not lbl or lbl == bagLabel then return end
	bagLabel = lbl
	readBagLabel()
	lbl:GetPropertyChangedSignal("Text"):Connect(readBagLabel)
end

bindBagLabel()

-- The MainGUI is built late on the first round transition; watch for it.
do
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	if pg then
		pg.DescendantAdded:Connect(function(d)
			if d.Name == "Coins" and (not bagLabel or not bagLabel.Parent) then
				task.wait(0.1)
				bindBagLabel()
			end
		end)
	end
end

-- Safety poll for the bag label too.
task.spawn(function()
	while true do
		task.wait(3)
		if bagLabel and bagLabel.Parent then
			readBagLabel()
		else
			bagLabel = nil
			bindBagLabel()
		end
	end
end)

-- Returns the authoritative bag value: UI label if available, else local.
local function getBagValue()
	if bagFromUI then return bagFromUI end
	return bagCount
end

-- Hook MM2's round remotes for live phase tracking.
do
	local rs = game:GetService("ReplicatedStorage")
	local remotes = rs:FindFirstChild("Remotes")
	local gameplay = remotes and remotes:FindFirstChild("Gameplay")
	if gameplay then
		local function hookEv(name, phase)
			local r = gameplay:FindFirstChild(name)
			if r and r:IsA("RemoteEvent") then
				r.OnClientEvent:Connect(function() roundPhase = phase end)
			end
		end
		hookEv("CoinsStarted", "Coins active")
		hookEv("RoundStart",   "Round in progress")
		hookEv("ShowRoleSelect","Role select")
		hookEv("GameOver",     "Round over")
		hookEv("LoadingMap",   "Map loading")
	end
end

task.spawn(function()
	while not stopped do
		local rolling      = coinsLastHour()
		local elapsed      = math.max(1, os.clock() - sessionStart)
		local sessionTotal = getSessionTotal()  -- (account_now - account_at_session_start)
		local sessionRate  = math.floor((sessionTotal / elapsed) * 3600 + 0.5) -- extrapolated coins/hour
		-- Use the actual rolling count once a full hour has passed; before
		-- that, extrapolate from session rate so the GUI shows real numbers
		-- from minute 1.
		local displayRate = (elapsed >= ROLLING_WINDOW) and rolling or sessionRate

		bigRate.Text = tostring(displayRate)
		rowRate.Text    = ("Coins / hour: %d  (rolling %d, extrapolated %d)"):format(displayRate, rolling, sessionRate)
		rowTotal.Text   = ("Total this session: %d   (%.1f min)"):format(sessionTotal, elapsed / 60)
		rowCoins.Text    = ("Coins: %s"):format(coinTextLabel and accountCoinsText or "?")
		rowBag.Text      = ("Bag: %d / %d"):format(getBagValue(), MAX_BAG)
		rowPlayers.Text  = ("Players: %d / %d"):format(#Players:GetPlayers(), Players.MaxPlayers)
		refreshLocation()
		rowLocation.Text = ("Location: %s   |   Phase: %s"):format(locationStr, roundPhase)
		rowStatus.Text   = ("Status: %s    [X] stop  [H] hide"):format(statusText)
		task.wait(GUI_UPDATE_INTERVAL)
	end
end)

-- Toggle GUI visibility
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == TOGGLE_GUI_KEY then
		gui.Enabled = not gui.Enabled
	elseif input.KeyCode == STOP_KEY then
		stopped = true
		setStatus("Stopped")
		warn("[CoinTween] Stopped by user.")
	end
end)

-- =========================
-- Server hop
-- =========================
-- Pull a list of public servers, pick one with healthy population, teleport.
-- `game:HttpGet` is provided by the executor; HttpService:GetAsync would be
-- blocked from a LocalScript context.
local function fetchServerList()
	local placeId = game.PlaceId
	local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100"):format(placeId)
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if not ok then return nil end
	local ok2, data = pcall(function() return HttpService:JSONDecode(body) end)
	if not ok2 then return nil end
	return data and data.data
end

-- Hopping involves an HTTP server-list fetch + a teleport handshake. That
-- can take 1–4 seconds, during which the script's tween loop is paused —
-- if the character is left untouched, gravity drags it through the floor
-- (some MM2 maps have OOB voids that kill or get-stuck the player). We
-- anchor HumanoidRootPart for the duration of the hop so it stays put,
-- and re-apply every 0.2s in case anything resets it.
-- =========================
-- Total-character freeze
-- =========================
-- Lock down every BasePart in the character, not just the HumanoidRootPart.
-- Anchoring only the HRP leaves the limbs free to swing on their Motor6D
-- joints, which is the source of the "fling" behaviour the user reported.
-- We also watch each part's Anchored property so anything that tries to
-- clear the flag (game scripts, anti-cheat reset, character loader) gets
-- immediately corrected.
local isFrozen        = false       -- read by the main loop to skip tweens
local frozenConns     = {}          -- [BasePart] = RBXScriptConnection
local frozenHumState  = nil         -- snapshot of WalkSpeed/JumpPower for unfreeze

local function disconnectFrozenConns()
	for part, conn in pairs(frozenConns) do
		pcall(function() conn:Disconnect() end)
	end
	frozenConns = {}
end

local function freezeCharacterForHop()
	local char = LocalPlayer.Character
	if not char then return end

	-- Snapshot humanoid for restoration. Done once per freeze cycle so a
	-- mid-cycle re-call doesn't blow away the original values.
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and not frozenHumState then
		frozenHumState = {
			WalkSpeed   = hum.WalkSpeed,
			JumpPower   = hum.JumpPower,
			JumpHeight  = hum.JumpHeight,
			AutoRotate  = hum.AutoRotate,
		}
	end

	disconnectFrozenConns()

	-- Anchor every BasePart and zero its assembly velocities. Re-bind a
	-- property listener that snaps Anchored back to true if anything
	-- clears it.
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			pcall(function()
				d.AssemblyLinearVelocity  = Vector3.zero
				d.AssemblyAngularVelocity = Vector3.zero
				d.Anchored                = true
			end)
			frozenConns[d] = d:GetPropertyChangedSignal("Anchored"):Connect(function()
				if isFrozen and not d.Anchored then
					pcall(function() d.Anchored = true end)
				end
			end)
		end
	end

	-- Cripple the humanoid so input/walk/jump/AutoRotate can't push the
	-- assembly. PlatformStand stops ragdoll-like physics responses too.
	if hum then
		pcall(function()
			hum.WalkSpeed     = 0
			hum.JumpPower     = 0
			hum.JumpHeight    = 0
			hum.AutoRotate    = false
			hum.PlatformStand = true
		end)
	end

	isFrozen = true
end

local function unfreezeCharacter()
	isFrozen = false
	disconnectFrozenConns()

	local char = LocalPlayer.Character
	if not char then return end

	-- Float mode: unanchor every part. The HRP is held in place by the
	-- BodyForce + velocity-zero loop, not by anchoring — so we want it
	-- unanchored after a hop unfreeze so Touched events fire normally.
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			pcall(function() d.Anchored = false end)
		end
	end

	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(function()
			-- Anchor mode keeps PlatformStand=true (lay-down pose).
			-- Without anchor mode, restore PlatformStand=false and the
			-- pre-freeze snapshot.
			if PERMANENT_ANCHOR then
				hum.PlatformStand = true
			else
				hum.PlatformStand = false
				if frozenHumState then
					hum.WalkSpeed  = frozenHumState.WalkSpeed
					hum.JumpPower  = frozenHumState.JumpPower
					hum.JumpHeight = frozenHumState.JumpHeight
					hum.AutoRotate = frozenHumState.AutoRotate
				end
			end
		end)
	end
	frozenHumState = nil
end

local function hopServer()
	if hopping then return end
	hopping = true
	setStatus("Hopping server (low pop)")

	-- Pin the character now and keep re-pinning until the hop resolves.
	freezeCharacterForHop()
	task.spawn(function()
		while hopping do
			freezeCharacterForHop()
			task.wait(0.2)
		end
	end)

	local placeId = game.PlaceId
	local currentJobId = game.JobId

	local servers = fetchServerList()
	if servers then
		-- Prefer a server with the most players that still has space.
		table.sort(servers, function(a, b) return (a.playing or 0) > (b.playing or 0) end)
		for _, server in ipairs(servers) do
			if server.id
			   and server.id ~= currentJobId
			   and (server.playing or 0) >= MIN_PLAYERS
			   and (server.playing or 0) < (server.maxPlayers or 0) then
				local ok = pcall(function()
					TeleportService:TeleportToPlaceInstance(placeId, server.id, LocalPlayer)
				end)
				-- On a successful teleport the character is destroyed by
				-- the engine, so we don't need to unfreeze.
				if ok then return end
			end
		end
	end

	-- Fallback: vanilla matchmake.
	pcall(function() TeleportService:Teleport(placeId, LocalPlayer) end)
	-- If teleport silently failed, release the freeze so the loop can
	-- resume normally on this server.
	task.wait(8)
	hopping = false
	unfreezeCharacter()
end

-- =========================
-- Emergency hop on kick / disconnect / error
-- =========================
-- Roblox shows a "you were kicked" / "lost connection" UI any time
-- the client gets booted (anti-cheat reset, server crash, network
-- loss, "Disconnected: invalid position", etc.). The error text
-- surfaces through GuiService — we listen for it and immediately
-- TeleportService:Teleport into a fresh server. NetworkClient
-- removal also catches socket-level disconnects.
do
	local GuiService    = game:GetService("GuiService")
	local CoreGui       = game:GetService("CoreGui")
	local hopAttempted  = false

	local function emergencyHop(reason)
		if hopAttempted then return end
		hopAttempted = true
		warn(("[CoinTween] Emergency hop: %s"):format(tostring(reason)))
		pcall(setStatus, "Emergency hop: " .. tostring(reason))

		task.spawn(function()
			local placeId = game.PlaceId
			-- Try a populated server first, fall back to matchmaker.
			local triedSpecific = false
			pcall(function()
				local servers = fetchServerList and fetchServerList()
				if servers then
					table.sort(servers, function(a, b)
						return (a.playing or 0) > (b.playing or 0)
					end)
					for _, s in ipairs(servers) do
						if s.id and s.id ~= game.JobId
						   and (s.playing or 0) >= MIN_PLAYERS
						   and (s.playing or 0) < (s.maxPlayers or 0) then
							TeleportService:TeleportToPlaceInstance(placeId, s.id, LocalPlayer)
							triedSpecific = true
							return
						end
					end
				end
			end)
			if not triedSpecific then
				pcall(function() TeleportService:Teleport(placeId, LocalPlayer) end)
			end
		end)
	end

	-- 1) GuiService error message changes — covers "kicked", "lost
	-- connection", "invalid position", "place is full", etc.
	GuiService.ErrorMessageChanged:Connect(function()
		local ok, msg = pcall(function() return GuiService:GetErrorMessage() end)
		if ok and msg and msg ~= "" then
			emergencyHop("error: " .. msg)
		end
	end)

	-- 2) Network-level disconnect: NetworkClient's child object
	-- disappears when the client's socket drops.
	local nc = game:FindFirstChildOfClass("NetworkClient")
	if nc then
		nc.ChildRemoved:Connect(function()
			emergencyHop("NetworkClient child removed")
		end)
	end

	-- 3) Roblox's kick/disconnect prompt has a predictable name in
	-- CoreGui. If it appears, hop immediately instead of waiting on
	-- the user to click Leave/Reconnect.
	local function watchPrompt(d)
		if d and d.Name == "ErrorPrompt" then
			emergencyHop("ErrorPrompt UI shown")
		end
	end
	for _, d in ipairs(CoreGui:GetDescendants()) do watchPrompt(d) end
	CoreGui.DescendantAdded:Connect(watchPrompt)

	-- 4) TeleportService failures — sometimes the hop itself fails
	-- (e.g., target server is full). Try a vanilla teleport as fallback.
	TeleportService.TeleportInitFailed:Connect(function(_, _, errorMsg)
		warn(("[CoinTween] TeleportInitFailed: %s — retrying vanilla."):format(tostring(errorMsg)))
		hopAttempted = false   -- allow another attempt
		emergencyHop("teleport init failed: " .. tostring(errorMsg))
	end)
end

-- Periodic population check
task.spawn(function()
	while not stopped do
		if os.clock() >= hopLockout and #Players:GetPlayers() < MIN_PLAYERS then
			hopServer()
		end
		task.wait(SERVER_CHECK_PERIOD)
	end
end)

-- Periodic low-rate check (sliding window).
-- The previous behavior hopped after 10 min if session-average rate was
-- below threshold — but a slow start could trigger the hop even if we
-- were currently farming fast. New behavior: track the recent (5-min)
-- rate. If it stays below threshold for LOW_RATE_GRACE consecutive
-- seconds, hop. Any minute where rate ≥ threshold resets the counter.
local RECENT_WINDOW = 300  -- seconds — rate is measured over the last 5 min

local function recentRatePerHour()
	local now    = os.clock()
	local cutoff = now - RECENT_WINDOW
	local total  = 0
	for _, e in ipairs(coinGains) do
		if e.time >= cutoff then total += e.amount end
	end
	-- Extrapolate the recent total to a per-hour figure.
	return math.floor(total * (3600 / RECENT_WINDOW) + 0.5)
end

local lowRateStreakStart = nil   -- os.clock() when rate first dropped below threshold

task.spawn(function()
	while not stopped do
		task.wait(LOW_RATE_CHECK_PERIOD)
		if hopping then continue end

		local elapsed = os.clock() - sessionStart
		-- Don't even start measuring until the recent-window has had
		-- time to fill — before that, the rate is meaningless.
		if elapsed < RECENT_WINDOW then continue end

		local rate = recentRatePerHour()

		if rate >= LOW_RATE_THRESHOLD then
			-- Performance is fine — reset the streak so the player gets
			-- a fresh 10-min window if they slow down later.
			if lowRateStreakStart then
				print(("[CoinTween] Rate recovered to %d/hr — resetting low-rate timer.")
					:format(rate))
				lowRateStreakStart = nil
			end
		else
			-- Performance is below threshold.
			if not lowRateStreakStart then
				lowRateStreakStart = os.clock()
				print(("[CoinTween] Rate dropped to %d/hr (< %d) — starting %ds low-rate timer.")
					:format(rate, LOW_RATE_THRESHOLD, LOW_RATE_GRACE))
			else
				local streak = os.clock() - lowRateStreakStart
				if streak >= LOW_RATE_GRACE then
					print(("[CoinTween] Rate %d/hr stayed below %d for %.1f min — hopping.")
						:format(rate, LOW_RATE_THRESHOLD, streak / 60))
					setStatus(("Hopping (rate %d/hr below %d for too long)"):format(rate, LOW_RATE_THRESHOLD))
					lowRateStreakStart = nil   -- reset for the new server
					hopServer()
				end
			end
		end
	end
end)

-- =========================
-- Bag tracking + reset
-- (bagCount lives in the stats section so recordPickup() can mutate it.)
-- =========================
-- ============================================================
-- Fling murderer out of the map
-- ============================================================
-- When the bag is full, instead of self-resetting, we attempt to fling
-- the player who's currently holding the Knife to a position far below
-- the map. The technique:
--   1) Find the murderer via their Backpack/Character.Knife
--   2) Briefly unanchor our HRP and set huge velocity
--   3) Repeatedly snap our HRP onto their HRP and write their CFrame
--      to (0, -10000, 0) — the rapid collision tries to transfer
--      network ownership of their HRP to us, letting our CFrame writes
--      stick before the server reverts
--   4) After ~0.5s, re-anchor and restore lay-down pose
local FLING_FAR_POSITION = Vector3.new(0, -10000, 0)
local FLING_DURATION     = 0.5
local FLING_TICK         = 0.03   -- 33Hz repeated writes during the fling

local function findKnifeHolder()
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer then
			local backpack = p:FindFirstChild("Backpack")
			if backpack and backpack:FindFirstChild("Knife") then return p end
			local char = p.Character
			if char and char:FindFirstChild("Knife") then return p end
		end
	end
	return nil
end

local function flingMurdererOutOfMap()
	local m = findKnifeHolder()
	if not m then
		warn("[CoinTween] Bag full but no murderer detected — skipping fling.")
		return
	end
	local mChar = m.Character
	local mHRP  = mChar and mChar:FindFirstChild("HumanoidRootPart")
	if not mHRP then
		warn(("[CoinTween] Murderer %s has no HRP — skipping fling."):format(m.Name))
		return
	end

	local char = LocalPlayer.Character
	local hrp  = char and char:FindFirstChild("HumanoidRootPart")
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if not hrp then return end

	print(("[CoinTween] FLING: targeting %s"):format(m.Name))
	setStatus("Flinging " .. m.Name)

	-- Save state so we can restore.
	local wasAnchored     = hrp.Anchored
	local wasPlatformStand = hum and hum.PlatformStand or false

	pcall(function()
		hrp.Anchored      = false
		if hum then hum.PlatformStand = false end
	end)

	-- Save our own pre-fling position. If anything goes wrong (the
	-- murderer's CFrame ends up cached as garbage, our HRP somehow
	-- drifts to the void), we have a known-good in-map fallback.
	local preFlingPosition = hrp.CFrame

	-- Cache the murderer's position from BEFORE we touch their CFrame.
	-- Validate it: if it's already in the void (another exploiter
	-- flung them, or MM2 just respawned them mid-air), use OUR
	-- pre-fling position instead so we don't end up there ourselves.
	local pinPosition = mHRP.CFrame
	if pinPosition.Position.Y < -1000 or pinPosition.Position.Y > 10000 then
		pinPosition = preFlingPosition
	end

	local started = tick()
	while tick() - started < FLING_DURATION do
		-- Bail out if the murderer disconnected or dropped the knife.
		if not mHRP.Parent then break end

		pcall(function()
			-- Anchor ourselves to the cached in-map position (we never
			-- read mHRP.CFrame again, so we can't drift).
			hrp.CFrame                  = pinPosition
			hrp.AssemblyLinearVelocity  = Vector3.new(0, 99999, 0)

			-- Write the murderer to far-below-map. If we have ownership
			-- for a tick (collision transfer) the write replicates;
			-- otherwise the server reverts harmlessly.
			mHRP.CFrame                 = CFrame.new(FLING_FAR_POSITION)
			mHRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		end)

		task.wait(FLING_TICK)
	end

	-- Restore. Final out-of-bounds check: if our HRP somehow ended up
	-- in the void (server lag accepted one of our void-writes for our
	-- character, or pinPosition was invalid), snap to preFlingPosition.
	pcall(function()
		local restoreCF = pinPosition
		if hrp.Position.Y < -1000 or hrp.Position.Y > 10000 then
			print("[CoinTween] Post-fling: HRP ended up in void, restoring to pre-fling position.")
			restoreCF = preFlingPosition
		end
		hrp.CFrame   = restoreCF
		hrp.Anchored = wasAnchored
		if hum then hum.PlatformStand = wasPlatformStand end
	end)

	setStatus("Fling done")
end

-- Legacy alias so callers that say resetCharacter() still get the new
-- fling behavior.
local resetCharacter = flingMurdererOutOfMap

LocalPlayer.CharacterAdded:Connect(function()
	bagCount = 0
end)

local root, hum = getRoot()

local function refreshRoot()
	root, hum = getRoot()
end
LocalPlayer.CharacterAdded:Connect(refreshRoot)

-- =========================
-- Float mode (unanchored — Touched events fire reliably)
-- =========================
-- Anchored mode looked clean to anti-cheat but Roblox's Touched events
-- often don't fire when an anchored part's CFrame changes via property
-- write — MM2's coin pickup hook wasn't seeing our overlaps.
--
-- Float mode keeps the HRP UNANCHORED, so the engine treats CFrame
-- writes as physics-relevant (Touched fires) — but holds the character
-- still with two physics tools that don't trigger anti-cheat:
--   1) BodyForce that exactly cancels gravity.
--   2) RunService.Stepped loop that zeroes residual velocities.
--
-- Critically, we DO NOT touch the Humanoid this time: WalkSpeed stays
-- at the default 16, JumpPower at default. That way the server-side
-- anti-cheat doesn't see "WalkSpeed=0 but moving fast" — which is what
-- triggered the invalid-position kick last time.
local floatVelocityConn
local function anchorPermanently(char)
	if not PERMANENT_ANCHOR or not char then return end
	local r = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 3)
	if not r then return end

	pcall(function()
		r.Anchored = false
		r.AssemblyLinearVelocity  = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
	end)

	-- Self-heal: outside the hop freeze, never let anything anchor us.
	r:GetPropertyChangedSignal("Anchored"):Connect(function()
		if r.Anchored and not isFrozen then
			pcall(function() r.Anchored = false end)
		end
	end)

	-- Gravity-canceling BodyForce.
	local bf = r:FindFirstChild("FloatGravityCancel")
	if not bf then
		bf = Instance.new("BodyForce")
		bf.Name = "FloatGravityCancel"
		bf.Parent = r
	end
	pcall(function()
		bf.Force = Vector3.new(0, workspace.Gravity * r.AssemblyMass, 0)
	end)

	-- Velocity-zeroing loop.
	if floatVelocityConn then
		pcall(function() floatVelocityConn:Disconnect() end)
	end
	floatVelocityConn = RunService.Stepped:Connect(function()
		if not r or not r.Parent or isFrozen then return end
		r.AssemblyLinearVelocity  = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
		if bf and bf.Parent then
			bf.Force = Vector3.new(0, workspace.Gravity * r.AssemblyMass, 0)
		end
	end)

	-- =====================================================
	-- Humanoid setup: lay-down pose + GODMODE
	-- =====================================================
	-- Godmode = stack every classic Roblox death-prevention trick on
	-- top of each other. Each one blocks a different death path; if any
	-- single layer fails (game patches, anti-cheat overrides), the
	-- remaining layers still keep us alive.
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(function()
			-- Lay-down pose (visual only).
			hum.PlatformStand = true

			-- Layer 1: infinite health.
			hum.MaxHealth     = math.huge
			hum.Health        = math.huge

			-- Layer 2: don't break joints when health hits 0.
			hum.BreakJointsOnDeath = false

			-- Layer 3: don't auto-die from a missing/broken neck joint.
			-- Most games kill the character via head-removal; this
			-- nullifies that path.
			hum.RequiresNeck = false

			-- Layer 4: hide the health bar so we don't broadcast damage
			-- visually (some servers / players spot exploiters by the
			-- damage flash on a "tanky" player).
			hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		end)

		-- Layer 5: disable the Dead state. Even if Health=0 reaches the
		-- humanoid, ChangeState(Dead) becomes a no-op so the death
		-- pipeline (Died event, character destroy) never fires.
		pcall(function()
			hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		end)

		-- Layer 6: ForceField blocks all standard damage at the engine
		-- level. Visible=false so it doesn't show the shimmering shield.
		local ff = char:FindFirstChild("GodmodeShield")
		if not ff then
			ff = Instance.new("ForceField")
			ff.Name    = "GodmodeShield"
			ff.Visible = false
			ff.Parent  = char
		end

		-- Layer 7: regen-on-damage. Catches anything that bypasses the
		-- ForceField (direct Health writes from server scripts).
		hum.HealthChanged:Connect(function(newHealth)
			if newHealth < hum.MaxHealth then
				pcall(function() hum.Health = hum.MaxHealth end)
			end
		end)

		-- Self-heal watchers: re-assert every layer if anything (game
		-- script, anti-cheat, MM2's character setup) tries to clear it.
		hum:GetPropertyChangedSignal("PlatformStand"):Connect(function()
			if not hum.PlatformStand then
				pcall(function() hum.PlatformStand = true end)
			end
		end)
		hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
			if hum.MaxHealth ~= math.huge then
				pcall(function() hum.MaxHealth = math.huge end)
			end
		end)
		hum:GetPropertyChangedSignal("BreakJointsOnDeath"):Connect(function()
			if hum.BreakJointsOnDeath then
				pcall(function() hum.BreakJointsOnDeath = false end)
			end
		end)
		hum:GetPropertyChangedSignal("RequiresNeck"):Connect(function()
			if hum.RequiresNeck then
				pcall(function() hum.RequiresNeck = false end)
			end
		end)

		-- Layer 8: if the ForceField gets removed, recreate it.
		ff.AncestryChanged:Connect(function(_, newParent)
			if newParent == nil and char and char.Parent then
				task.wait()
				if not char:FindFirstChild("GodmodeShield") then
					local newFf    = Instance.new("ForceField")
					newFf.Name     = "GodmodeShield"
					newFf.Visible  = false
					newFf.Parent   = char
				end
			end
		end)
	end

	-- Hitbox extension: scale the HRP up by HITBOX_MULTIPLIER. Since the
	-- HRP is unanchored (float mode), Touched events fire on its full
	-- bounding box — a 50% larger box gives coins a wider trigger zone.
	-- We hold a reference size and re-assert it via property listener
	-- because the avatar loader can reset HRP.Size after streaming.
	if EXPAND_HITBOX and HITBOX_MULTIPLIER and HITBOX_MULTIPLIER ~= 1 then
		local targetSize = Vector3.new(2, 2, 1) * HITBOX_MULTIPLIER
		pcall(function()
			r.Size         = targetSize
			r.Massless     = true
			r.CanTouch     = true
		end)
		r:GetPropertyChangedSignal("Size"):Connect(function()
			if r.Size ~= targetSize then
				pcall(function() r.Size = targetSize end)
			end
		end)
	else
		-- Make sure we don't carry over inflated size from a previous run.
		pcall(function() r.Size = Vector3.new(2, 2, 1) end)
	end

	local leftover = char:FindFirstChild("CoinHitboxExtender")
	if leftover then leftover:Destroy() end
end

LocalPlayer.CharacterAdded:Connect(anchorPermanently)
if LocalPlayer.Character then anchorPermanently(LocalPlayer.Character) end

-- =========================
-- Noclip
-- =========================
-- Continuously force every BasePart in the character to CanCollide = false.
-- The engine resets this each step (and the game's character loader sets
-- some parts back to colliding on respawn), so we re-apply on Stepped —
-- which runs *before* the physics tick, meaning physics uses the
-- non-colliding value for that frame. Result: the character passes through
-- walls and never gets stuck on geometry.
--
-- We deliberately leave anchored parts alone — the freeze/anchor system
-- already takes care of those, and toggling CanCollide on an anchored
-- part is a no-op for physics.
if ENABLE_NOCLIP then
	RunService.Stepped:Connect(function()
		local char = LocalPlayer.Character
		if not char or isFrozen then return end
		for _, d in ipairs(char:GetDescendants()) do
			if d:IsA("BasePart") and d.CanCollide then
				d.CanCollide = false
			end
		end
	end)
end

-- =========================
-- Coin cache + nearest-coin queries
-- =========================
-- Per-iteration GetDescendants() over Workspace was the heaviest CPU cost
-- in the loop (workspaces have tens of thousands of descendants in MM2 maps).
-- We maintain a Set of live Coin_Server parts via DescendantAdded/Removing
-- so the hot path only iterates the few dozen actual coins.
local coinSet = {} -- [BasePart] = true

local function isCoin(d)
	return d.Name == "Coin_Server" and d:IsA("BasePart")
end

for _, d in ipairs(Workspace:GetDescendants()) do
	if isCoin(d) then coinSet[d] = true end
end
Workspace.DescendantAdded:Connect(function(d)
	if isCoin(d) then coinSet[d] = true end
end)
Workspace.DescendantRemoving:Connect(function(d)
	coinSet[d] = nil
end)

-- Per-coin cooldown. When we tween onto a coin and it doesn't get
-- collected (server didn't accept the touch — could be anti-cheat
-- throttle, mid-flight race, or geometry issue), we mark the coin as
-- skipped for COIN_SKIP_DURATION seconds. findNearestCoin then ignores
-- it and picks the next-nearest coin instead — so the loop never gets
-- stuck spinning on a single un-collectable coin.
local coinSkipUntil      = {}    -- [coin BasePart] = os.clock() expire
local COIN_SKIP_DURATION = 3     -- seconds

-- Pick the single nearest in-range coin from the player's *current*
-- position. Re-evaluated every loop iteration so movement, new spawns,
-- and other players' pickups are all reflected immediately.
local function findNearestCoin(originPos)
	local nearest, nearestDist = nil, math.huge
	local now = os.clock()
	for c in pairs(coinSet) do
		if not c.Parent then
			coinSet[c] = nil
			coinSkipUntil[c] = nil
			continue
		end
		local skip = coinSkipUntil[c]
		if skip then
			if skip <= now then
				coinSkipUntil[c] = nil   -- cooldown expired, eligible again
			else
				continue                  -- still on cooldown
			end
		end
		local dist = (c.Position - originPos).Magnitude
		if dist <= RADIUS and dist < nearestDist then
			nearest, nearestDist = c, dist
		end
	end
	return nearest, nearestDist
end

local function countInRange(originPos)
	local n = 0
	for c in pairs(coinSet) do
		if c.Parent and (c.Position - originPos).Magnitude <= RADIUS then
			n += 1
		end
	end
	return n
end

-- =========================
-- Auto-buy (emotes / gears / perks / pets / knives / guns)
-- =========================
-- Periodically sweep the runtime item catalogs in ReplicatedStorage
-- and call BuyItemNew on each item we haven't tried yet. Best-effort:
-- without exact source for MM2's shop modules, we discover items by
-- require()ing the loaded modules and iterating their tables. The
-- buy remote is fired in pcall so failures don't crash the loop.
local AUTO_BUY               = true
local AUTO_BUY_INTERVAL      = 90    -- seconds between full catalog sweeps
local AUTO_BUY_RATE          = 0.3   -- delay between individual buy attempts (anti-spam)
local AUTO_BUY_CATEGORIES    = {     -- ModuleScript names under Database.Sync
	"Emotes", "Effects", "Toys", "Pets", "Knives", "Guns", "Shop", "Item",
}

task.spawn(function()
	if not AUTO_BUY then return end

	-- Resolve the buy remote. BuyItemNew is preferred (modern MM2);
	-- BuyItem is the legacy version. Both are RemoteFunctions.
	local rs       = game:GetService("ReplicatedStorage")
	local remotes  = rs:FindFirstChild("Remotes")
	local shop     = remotes and remotes:FindFirstChild("Shop")
	local buyNew   = shop and shop:FindFirstChild("BuyItemNew")
	local buyOld   = shop and shop:FindFirstChild("BuyItem")
	if not (buyNew or buyOld) then
		warn("[CoinTween] AutoBuy: no BuyItemNew or BuyItem remote — disabled.")
		return
	end

	-- Resolve the item catalog. Database.Sync.<Category> are
	-- ModuleScripts that return a table of items when require()d.
	local db    = rs:FindFirstChild("Database")
	local sync  = db and db:FindFirstChild("Sync")
	if not sync then
		warn("[CoinTween] AutoBuy: ReplicatedStorage.Database.Sync not found — disabled.")
		return
	end

	local tried = {}   -- [itemName] = true (one attempt per item per session)

	local function tryBuy(itemName)
		if tried[itemName] then return end
		tried[itemName] = true
		-- Try BuyItemNew first, then fall back to BuyItem. Both with
		-- (itemName) as the only arg — that's the most common signature
		-- across MM2 versions. If neither works the function fails
		-- silently and we move on.
		if buyNew then
			local ok, result = pcall(function()
				return buyNew:InvokeServer(itemName)
			end)
			if ok and result then
				print(("[CoinTween] Bought: %s (BuyItemNew → %s)"):format(itemName, tostring(result)))
				return
			end
		end
		if buyOld then
			pcall(function() buyOld:InvokeServer(itemName) end)
		end
	end

	-- Recursively iterate a table to find string keys that look like
	-- item identifiers. Many MM2 modules nest items under sub-categories.
	local function collectItems(t, out, depth)
		if type(t) ~= "table" or depth > 3 then return end
		for k, v in pairs(t) do
			if type(k) == "string" and k:len() > 1 and k:len() < 64 then
				-- Heuristic: looks like an item name (alphanumeric + spaces)
				if k:match("^[%w%s%-_'.]+$") then
					out[#out + 1] = k
				end
			end
			if type(v) == "table" then collectItems(v, out, depth + 1) end
		end
	end

	while not stopped do
		local totalTried = 0
		for _, cat in ipairs(AUTO_BUY_CATEGORIES) do
			local module = sync:FindFirstChild(cat)
			if module then
				local ok, contents = pcall(require, module)
				if ok and type(contents) == "table" then
					local items = {}
					collectItems(contents, items, 1)
					for _, itemName in ipairs(items) do
						if stopped then break end
						tryBuy(itemName)
						totalTried = totalTried + 1
						task.wait(AUTO_BUY_RATE)
					end
				end
			end
			if stopped then break end
		end
		print(("[CoinTween] AutoBuy sweep done — %d items attempted (cumulative)."):format(totalTried))
		task.wait(AUTO_BUY_INTERVAL)
	end
end)

print(("[CoinTween] Started. Device=%s Radius=%d MaxBag=%d MinPlayers=%d Stop=%s ToggleGUI=%s")
	:format(DEVICE, RADIUS, MAX_BAG, MIN_PLAYERS, STOP_KEY.Name, TOGGLE_GUI_KEY.Name))
setStatus("Running")

while not stopped do
	-- Bag full? Fling murderer and skip the rest of the iteration.
	-- This check has to be FIRST in the loop so it fires regardless of
	-- whether the previous tween's local "did we collect" detection
	-- agreed with the in-game UI. The in-game UI is the only source of
	-- truth — if it shows 40/40, we should fling, period.
	if bagFromUI and bagFromUI >= MAX_BAG then
		setStatus("Bag full — flinging murderer")
		print(("[CoinTween] Bag full (%d/%d) — attempting murderer fling."):format(bagFromUI, MAX_BAG))
		flingMurdererOutOfMap()
		task.wait(0.3)
		continue
	end

	refreshRoot()
	if not root or not root.Parent then task.wait(0.1); continue end
	if not isFiniteVec(root.Position) then task.wait(0.1); continue end

	-- Skip the tween cycle while the character is fully anchored. Tweening
	-- CFrame on an anchored part with anchored limbs would either snap the
	-- rig or fight our own anchor watchers.
	if isFrozen then
		setStatus("Frozen — waiting for map to load")
		task.wait(0.3)
		continue
	end

	local coin, distance = findNearestCoin(root.Position)
	rowBag.Text = ("Bag: %d / %d"):format(getBagValue(), MAX_BAG)

	if not coin then
		setStatus("Waiting for coins...")
		task.wait(SCAN_INTERVAL)
		continue
	end

	local inRange = countInRange(root.Position)
	setStatus(("Farming (%d in range)"):format(inRange))

	if not isFiniteVec(coin.Position) then continue end

	local target = coin.Position + COIN_OFFSET
	-- Recompute after applying offset (Y-shift changes the magnitude slightly).
	distance = (target - root.Position).Magnitude
	if distance < 0.05 then
		-- We're already on it but it hasn't been collected. Server didn't
		-- accept the touch yet (anti-cheat throttle, replication delay).
		-- Cool down this coin so the loop moves on instead of looping
		-- on it forever.
		coinSkipUntil[coin] = os.clock() + COIN_SKIP_DURATION
		continue
	end

	local speed     = getEffectiveSpeed(hum)
	local projected = distance / speed
	if projected > MAX_TWEEN_TIME then
		print(("[CoinTween] skip far coin  dist=%.1f (would take %.1fs at %.1f studs/s)")
			:format(distance, projected, speed))
		task.wait()
		continue
	end

	print(("[CoinTween] bag=%d/%d  inRange=%d -> %s  dist=%.1f  speed=%.1f")
		:format(bagCount, MAX_BAG, inRange, coin.Name, distance, speed))

	-- Final liveness check right before committing the tween. A coin can
	-- be picked up by another player between findNearestCoin and now —
	-- if so, skip without spending any time.
	if not coin.Parent then continue end

	local tween, err, duration = tweenTo(root, hum, target, distance)
	if not tween then
		warn(("[CoinTween] tween skipped (%s)"):format(tostring(err)))
		task.wait()
		continue
	end

	-- Wait for the tween to finish. Tween.Completed fires for natural
	-- completion AND for tween:Cancel() — so we cancel from inside the
	-- ancestry listener (coin collected by another player) and from a
	-- delayed safety timeout. Whichever fires first triggers Completed
	-- and unblocks us.
	--
	-- Direct :Wait() on the signal returns the moment Completed fires —
	-- no polling, no frame yields. The previous polling loop with
	-- task.wait() was adding ~100ms-1s of latency per coin under
	-- FPS_CAP=10 because each `task.wait()` resumes on the next render
	-- frame, which at 10 FPS is 100ms.
	local coinGone     = false
	local ancestryConn = coin.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then
			coinGone = true
			pcall(function() tween:Cancel() end)
		end
	end)
	task.delay(duration + 1.0, function()
		if tween.PlaybackState == Enum.PlaybackState.Playing then
			pcall(function() tween:Cancel() end)
		end
	end)

	tween.Completed:Wait()
	ancestryConn:Disconnect()

	if coinGone then
		continue   -- another player got it; no pickup record
	end

	-- Manually fire Touched between HRP and coin. Anchored parts don't
	-- naturally fire Touched events from tween-driven CFrame writes, so
	-- the server's pickup hook never triggers. firetouchinterest fires
	-- the signal directly — server's Touched listener runs, validates
	-- the touch, and awards the coin.
	if USE_FIRETOUCH and coin.Parent and root then
		local fti = (rawget(getfenv(), "firetouchinterest"))
			or (rawget(_G, "firetouchinterest"))
			or (getgenv and getgenv().firetouchinterest)
		if fti then
			pcall(fti, root, coin, 0)   -- enter touch
			pcall(fti, root, coin, 1)   -- end touch
		end
	end

	-- Tween done. If the coin is still parented (server didn't accept
	-- the touch), cool it down so the next iteration picks a different
	-- coin instead of looping back to this one forever.
	if coin.Parent then
		coinSkipUntil[coin] = os.clock() + COIN_SKIP_DURATION
		continue
	end

	-- Coin actually got collected — count it.
	recordPickup()
	rowBag.Text = ("Bag: %d / %d"):format(getBagValue(), MAX_BAG)

	-- (Bag-full check moved to the top of the loop so it fires even when
	-- the per-coin detection path doesn't reach this point.)

	-- Tiny dwell after each pickup so the server-side Touched hook has
	-- time to fire before we tween away. Without this, very fast tweens
	-- can sweep past coins faster than the physics tick can register
	-- the overlap.
	if POST_TWEEN_DWELL and POST_TWEEN_DWELL > 0 then
		task.wait(POST_TWEEN_DWELL)
	end
end

setStatus("Stopped")
print("[CoinTween] Stopped.")
