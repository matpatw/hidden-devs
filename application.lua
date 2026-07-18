-- Roblox: MatPatW, discord: matpatw
-- "find the" game server script

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- modules
local Modules = ReplicatedStorage:WaitForChild("Modules")
local ChasesModule = require(Modules:WaitForChild("Chases"))
local DifficultiesModule = require(Modules:WaitForChild("Difficulties"))
local RealmsModule = require(Modules:WaitForChild("Realms"))
local ChaseAwarder = require(ServerScriptService:WaitForChild("ChaseAwarder"))

local CURRENT_REALM = "MainRealm"


-- config
local DATA_VERSION = "v3"
local chaseStore = DataStoreService:GetDataStore("ChaseData_" .. DATA_VERSION)
local AUTOSAVE_INTERVAL = 60
local SAVE_RETRY_ATTEMPTS = 5
local SAVE_RETRY_DELAY = 2
local CHASES_FOLDER_NAME = "Chases"
local LOAD_TIMEOUT = 15

-- remotes setup
local Remotes = ReplicatedStorage:FindFirstChild("ChaseRemotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "ChaseRemotes"
	Remotes.Parent = ReplicatedStorage
end

local function ensureRemote(className, name)
	local r = Remotes:FindFirstChild(name)
	if not r then
		r = Instance.new(className)
		r.Name = name
		r.Parent = Remotes
	end
	return r
end

local ChaseFoundEvent = ensureRemote("RemoteEvent", "ChaseFound")
local AlreadyFoundEvent = ensureRemote("RemoteEvent", "AlreadyFoundEvent")
local GetDataFunction = ensureRemote("RemoteFunction", "GetChaseData")
local ClaimGuiChaseEvent = ensureRemote("RemoteEvent", "ClaimGuiChase")

-- listen for clients claiming the GuiChase secret
ClaimGuiChaseEvent.OnServerEvent:Connect(function(player)
	ChaseAwarder.Award(player, "GuiChase")
end)

-- shared state
-- these tables are shared with ChaseAwarder via Init below

local sessionData = {}
local debounce = {}
local loadingSignals = {}

-- leaderstats

local function setupLeaderstats(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	local chases = leaderstats:FindFirstChild("Chases")
	if not chases then
		chases = Instance.new("IntValue")
		chases.Name = "Chases"
		chases.Value = 0
		chases.Parent = leaderstats
	end
	return chases
end

local function updateLeaderstats(player)
	local sd = sessionData[player.UserId]
	if not sd or not sd.loaded then return end

	local stat = setupLeaderstats(player)
	local count = 0
	for _ in pairs(sd.found) do
		count += 1
	end
	stat.Value = count
end

-- helpers

local function safeCall(fn, ...)
	local attempts = 0
	local args = table.pack(...)
	while attempts < SAVE_RETRY_ATTEMPTS do
		attempts += 1
		local ok, result = pcall(fn, table.unpack(args, 1, args.n))
		if ok then return true, result end
		warn(("[ChaseService] DataStore call failed (attempt %d): %s"):format(attempts, tostring(result)))
		task.wait(SAVE_RETRY_DELAY)
	end
	return false
end

local function buildDefaultData()
	return { found = {}, lastUpdated = os.time() }
end

local function loadPlayer(player)
	local userId = player.UserId
	local key = "User_" .. userId

	local signal = Instance.new("BindableEvent")
	loadingSignals[userId] = signal

	local ok, data = safeCall(function()
		return chaseStore:GetAsync(key)
	end)

	if not ok then
		sessionData[userId] = { found = {}, dirty = false, loaded = false, locked = true }
		warn("[ChaseService] Could not load data for", player.Name, "- saves disabled this session.")
	else
		data = data or buildDefaultData()
		data.found = data.found or {}

		sessionData[userId] = {
			found  = data.found,
			dirty  = false,
			loaded = true,
			locked = false,
		}
		debounce[userId] = {}
		print("[ChaseService] Loaded data for", player.Name)
	end

	-- refresh leaderstats with the loaded count
	updateLeaderstats(player)

	signal:Fire()
	task.delay(2, function()
		if loadingSignals[userId] == signal then
			loadingSignals[userId] = nil
		end
		signal:Destroy()
	end)
end

local function waitForLoad(player)
	local userId = player.UserId
	local sd = sessionData[userId]
	if sd then return sd end

	local signal = loadingSignals[userId]
	if signal then
		local thread = coroutine.running()
		local resumed = false
		local conn
		conn = signal.Event:Connect(function()
			if not resumed then
				resumed = true
				conn:Disconnect()
				task.spawn(thread)
			end
		end)
		task.delay(LOAD_TIMEOUT, function()
			if not resumed then
				resumed = true
				if conn then conn:Disconnect() end
				task.spawn(thread)
			end
		end)
		coroutine.yield()
	end

	return sessionData[userId]
end

local function savePlayer(player, removeAfter)
	local userId = player.UserId
	local sd = sessionData[userId]

	if not sd or not sd.loaded or sd.locked then
		if removeAfter then
			sessionData[userId] = nil
			debounce[userId] = nil
		end
		return
	end
	if not sd.dirty then
		if removeAfter then
			sessionData[userId] = nil
			debounce[userId] = nil
		end
		return
	end

	local key = "User_" .. userId
	local snapshot = {}
	for chaseId in pairs(sd.found) do
		snapshot[chaseId] = true
	end

	local ok = safeCall(function()
		chaseStore:UpdateAsync(key, function(old)
			local merged = {}
			if old and old.found then
				for chaseId in pairs(old.found) do
					merged[chaseId] = true
				end
			end
			for chaseId in pairs(snapshot) do
				merged[chaseId] = true
			end
			return { found = merged, lastUpdated = os.time() }
		end)
	end)

	if ok then
		sd.dirty = false
		print("[ChaseService] Save successful for", player.Name)
	else
		warn("[ChaseService] Failed to save data for", player.Name)
	end

	if removeAfter then
		sessionData[userId] = nil
		debounce[userId] = nil
	end
end

-- studio: immediate save callback (passed to the awarder)
local function studioImmediateSave(player)
	if RunService:IsStudio() then
		savePlayer(player, false)
	end
end

-- wire up the awarder with shared state and remotes
ChaseAwarder.Init({
	sessionData = sessionData,
	debounce = debounce,
	remotes = {
		ChaseFoundEvent = ChaseFoundEvent,
		AlreadyFoundEvent = AlreadyFoundEvent,
	},
	studioImmediateSave = studioImmediateSave,
	onAward = updateLeaderstats,
})

-- touch hook setup

local function setupChaseModels()
	local folder = workspace:WaitForChild(CHASES_FOLDER_NAME, 10)
	if not folder then
		warn("[ChaseService] No '" .. CHASES_FOLDER_NAME .. "' folder in workspace.")
		return
	end

	local registered = {}

	local function tryRegister(child)
		if not child:IsA("Model") and not child:IsA("BasePart") then return end
		local chaseId = child.Name
		if not ChasesModule[chaseId] then
			warn(("[ChaseService] '%s' has no matching entry in Chases module."):format(chaseId))
			return
		end
		registered[chaseId] = true
		ChaseAwarder.HookTouch(child, chaseId, { requireAlive = true })
	end

	for _, child in ipairs(folder:GetChildren()) do tryRegister(child) end
	folder.ChildAdded:Connect(tryRegister)

	-- log chases defined in the module but missing from workspace
	task.delay(5, function()
		for chaseId in pairs(ChasesModule) do
			if not registered[chaseId] then
				print(("[ChaseService] '%s' is defined but has no model in workspace; it will still display in the Dex."):format(chaseId))
			end
		end
	end)
end

-- remote: client requests its data + the static chase definitions
GetDataFunction.OnServerInvoke = function(player)
	local sd = waitForLoad(player)
	local found = (sd and sd.loaded) and sd.found or {}

	local chases = {}
	for id, info in pairs(ChasesModule) do
		local diff = DifficultiesModule[info.Difficulty]
		local realm = info.Realm and RealmsModule[info.Realm]
		chases[id] = {
			Name = info.Name,
			Difficulty = info.Difficulty,
			DifficultyColor = diff and diff.Color or Color3.new(1, 1, 1),
			Realm = info.Realm,
			RealmName = realm and realm.Name or info.Realm,
			RealmIcon = realm and realm.Icon or "",
			Description = info.Description,
			Hint = info.Hint,
			Icon = info.Icon,
			Found = found[id] == true,
		}
	end
	return {
		Chases = chases,
		CurrentRealm = CURRENT_REALM,
	}
end

-- lifecycle

Players.PlayerAdded:Connect(loadPlayer)
for _, p in ipairs(Players:GetPlayers()) do task.spawn(loadPlayer, p) end

Players.PlayerRemoving:Connect(function(player)
	savePlayer(player, true)
end)

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(savePlayer, player, false)
		end
	end
end)

game:BindToClose(function()
	local players = Players:GetPlayers()
	if #players == 0 then return end

	local remaining = #players
	for _, player in ipairs(players) do
		task.spawn(function()
			savePlayer(player, true)
			remaining -= 1
		end)
	end

	local startTime = os.clock()
	while remaining > 0 and os.clock() - startTime < 25 do
		task.wait(0.1)
	end
end)

setupChaseModels()
