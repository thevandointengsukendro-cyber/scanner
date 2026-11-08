--!nocheck
-- ============================================================================
-- PROJECT: GAMESCANNER DELTA V3.2.3 — DELTA COMPATIBILITY & SYNTAX PATCH
-- Reference Architecture: RuntimeInspector-DeepScan-v2
-- File: GameScanner-Delta-V3.2.3.lua (Standalone Complete Build)
-- ============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local LogService = game:GetService("LogService")
local CoreGui = game:GetService("CoreGui")

-- ============================================================================
-- [1] COMPATIBILITY ADAPTER & SAFE HELPERS
-- ============================================================================
local CompatAdapter = {}

function CompatAdapter.getEnv()
	return {
		getgenv = (typeof(getgenv) == "function" and getgenv) or function() return _G end,
		getrenv = (typeof(getrenv) == "function" and getrenv) or function() return _G end,
		getgc = typeof(getgc) == "function" and getgc or nil,
		getinstances = typeof(getinstances) == "function" and getinstances or nil,
		getnilinstances = typeof(getnilinstances) == "function" and getnilinstances or nil,
		getloadedmodules = typeof(getloadedmodules) == "function" and getloadedmodules or nil,
		getsenv = typeof(getsenv) == "function" and getsenv or nil,
		getupvalues = (typeof(debug) == "table" and debug.getupvalues) or (typeof(getupvalues) == "function" and getupvalues) or nil,
		getconstants = (typeof(debug) == "table" and debug.getconstants) or (typeof(getconstants) == "function" and getconstants) or nil,
		getinfo = (typeof(debug) == "table" and debug.info) or (typeof(getinfo) == "function" and getinfo) or nil,
		hookmetamethod = typeof(hookmetamethod) == "function" and hookmetamethod or nil,
		getnamecallmethod = typeof(getnamecallmethod) == "function" and getnamecallmethod or nil,
		checkcaller = typeof(checkcaller) == "function" and checkcaller or function() return false end,
		writefile = typeof(writefile) == "function" and writefile or nil,
		appendfile = typeof(appendfile) == "function" and appendfile or nil,
		readfile = typeof(readfile) == "function" and readfile or nil,
		setclipboard = typeof(setclipboard) == "function" and setclipboard or nil,
		gethui = typeof(gethui) == "function" and gethui or nil,
	}
end

local Env = CompatAdapter.getEnv()

function CompatAdapter.getCapabilities()
	return {
		IsStudio = RunService:IsStudio(),
		IsClient = RunService:IsClient(),
		IsServer = RunService:IsServer(),
		IsTouch = UserInputService.TouchEnabled,
		HasGetGC = Env.getgc ~= nil,
		HasGetNil = Env.getnilinstances ~= nil,
		HasLoadedModules = Env.getloadedmodules ~= nil,
		HasGetsenv = Env.getsenv ~= nil,
		HasUpvalues = Env.getupvalues ~= nil,
		HasConstants = Env.getconstants ~= nil,
		HasHookMeta = (Env.hookmetamethod ~= nil and Env.getnamecallmethod ~= nil),
		HasWriteFile = Env.writefile ~= nil,
		HasClipboard = Env.setclipboard ~= nil,
		HasGetHui = Env.gethui ~= nil,
	}
end

local function canParentTo(container: Instance?): boolean
	if not container or typeof(container) ~= "Instance" then
		return false
	end
	local ok = pcall(function()
		local probe = Instance.new("Folder")
		probe.Name = "_GSProbe"
		probe.Parent = container
		probe:Destroy()
	end)
	return ok
end

function CompatAdapter.getGuiParent(): Instance?
	-- Prefer PlayerGui: this is the standard client UI container and was
	-- confirmed to work in the user's Delta UI smoke test.
	local lp = Players.LocalPlayer
	if lp then
		local pg = lp:FindFirstChildOfClass("PlayerGui")
		if not pg then
			local ok, result = pcall(function()
				return lp:WaitForChild("PlayerGui", 5)
			end)
			if ok then pg = result end
		end
		if canParentTo(pg) then return pg end
	end

	-- Executor GUI containers are fallbacks with write-access verification.
	if Env.gethui then
		local ok, hui = pcall(Env.gethui)
		if ok and canParentTo(hui) then return hui end
	end
	local okCore, core = pcall(function() return CoreGui end)
	if okCore and canParentTo(core) then return core end
	return nil
end

local function safePath(inst: Instance?): string
	if not inst then return "nil" end
	local ok, p = pcall(inst.GetFullName, inst)
	return ok and p or tostring(inst)
end

local function safeSerialize(val: any, depth: number?, seen: { [any]: boolean }?): any
	local d = depth or 0
	local visited = seen or {}
	local t = typeof(val)
	if t == "nil" or t == "boolean" or t == "number" then
		return val
	elseif t == "string" then
		return #val > 240 and (string.sub(val, 1, 240) .. "...[trunc]") or val
	elseif t == "Instance" then
		return string.format("<%s> %s", val.ClassName, safePath(inst))
	elseif t == "Vector3" then
		return string.format("Vector3(%.2f, %.2f, %.2f)", val.X, val.Y, val.Z)
	elseif t == "CFrame" then
		local p = val.Position
		return string.format("CFramePos(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z)
	elseif t == "Color3" then
		return string.format("RGB(%d,%d,%d)", math.floor(val.R * 255), math.floor(val.G * 255), math.floor(val.B * 255))
	elseif t == "table" then
		if visited[val] then return "<cycle>" end
		if d >= 3 then return "<table:max_depth>" end
		visited[val] = true
		local out = {}
		local count = 0
		for k, v in pairs(val) do
			count += 1
			if count > 35 then
				out["__more"] = "truncated"
				break
			end
			out[tostring(k)] = safeSerialize(v, d + 1, visited)
		end
		return out
	end
	return tostring(val)
end

-- ============================================================================
-- [2] INCREMENTAL SCHEDULER & LIFECYCLE MANAGER (NO LEAKS / NO DUPLICATES)
-- ============================================================================
local Scheduler = {
	BatchSize = 65,
	YieldInterval = 0.016,
	Status = "IDLE", -- IDLE, RUNNING, PAUSED, STOPPED
	Connections = {},
	NamedConnections = {},
	Threads = {},
	RateBuckets = {},
	CleanupCallbacks = {},
	Progress = { Current = 0, Total = 0, Label = "Ready", Percent = 0 },
	OnProgress = nil,
	OnStatusChange = nil,
}

function Scheduler:setStatus(newStatus: string)
	if self.Status == newStatus then return end
	self.Status = newStatus
	if self.OnStatusChange then
		task.spawn(self.OnStatusChange, newStatus)
	end
end

function Scheduler:registerCleanup(key: string, fn: () -> ())
	self.CleanupCallbacks[key] = fn
end

function Scheduler:bindConnection(key: string?, conn: RBXScriptConnection?): RBXScriptConnection?
	if not conn then return nil end
	if key then
		local prev = self.NamedConnections[key]
		if prev then
			pcall(function()
				if prev.Connected then prev:Disconnect() end
			end)
		end
		self.NamedConnections[key] = conn
	else
		table.insert(self.Connections, conn)
	end
	return conn
end

function Scheduler:unbindConnection(key: string)
	local prev = self.NamedConnections[key]
	if prev then
		pcall(function()
			if prev.Connected then prev:Disconnect() end
		end)
		self.NamedConnections[key] = nil
	end
end

function Scheduler:allowRate(key: string, maxPerSec: number): boolean
	local now = os.clock()
	local b = self.RateBuckets[key]
	if not b or (now - b.Window) >= 1.0 then
		self.RateBuckets[key] = { Window = now, Count = 1 }
		return true
	end
	if b.Count >= maxPerSec then return false end
	b.Count += 1
	return true
end

function Scheduler:runBatch(label: string, items: { any }, worker: (any, number) -> (), onComplete: (() -> ())?)
	if self.Status == "IDLE" or self.Status == "STOPPED" then
		self:setStatus("RUNNING")
	end
	local total = #items
	self.Progress = { Current = 0, Total = total, Label = label, Percent = total == 0 and 100 or 0 }
	if self.OnProgress then pcall(self.OnProgress, self.Progress) end

	local th = task.spawn(function()
		for i = 1, total do
			while self.Status == "PAUSED" do
				task.wait(0.08)
			end
			if self.Status == "STOPPED" then
				self.Progress = {
					Current = i,
					Total = total,
					Label = label .. " [Stopped]",
					Percent = math.floor((i / math.max(1, total)) * 100),
				}
				if self.OnProgress then pcall(self.OnProgress, self.Progress) end
				return
			end
			pcall(worker, items[i], i)
			if i % self.BatchSize == 0 or i == total then
				self.Progress = {
					Current = i,
					Total = total,
					Label = label,
					Percent = math.floor((i / math.max(1, total)) * 100),
				}
				if self.OnProgress then pcall(self.OnProgress, self.Progress) end
				task.wait(self.YieldInterval)
			end
		end
		if onComplete then pcall(onComplete) end
	end)
	table.insert(self.Threads, th)
	return th
end

function Scheduler:pause()
	if self.Status == "RUNNING" then self:setStatus("PAUSED") end
end

function Scheduler:resume()
	if self.Status == "PAUSED" then self:setStatus("RUNNING") end
end

function Scheduler:stopAndCleanup()
	self:setStatus("STOPPED")
	for _, c in ipairs(self.Connections) do
		pcall(function() if c.Connected then c:Disconnect() end end)
	end
	table.clear(self.Connections)

	for k, c in pairs(self.NamedConnections) do
		pcall(function() if c.Connected then c:Disconnect() end end)
		self.NamedConnections[k] = nil
	end

	for _, th in ipairs(self.Threads) do
		if th ~= coroutine.running() then
			pcall(task.cancel, th)
		end
	end
	table.clear(self.Threads)
	table.clear(self.RateBuckets)

	for key, fn in pairs(self.CleanupCallbacks) do
		pcall(fn)
		self.CleanupCallbacks[key] = nil
	end
end

-- ============================================================================
-- [3] TIMELINE & EVENT CORRELATION ENGINE
-- ============================================================================
local Timeline = {
	MaxEvents = 500,
	CorrelationWindow = 0.35,
	Events = {},
	Seq = 0,
	OnNewEvent = nil,
}

function Timeline:record(category: string, source: string, summary: string, details: { [string]: any }?)
	local now = os.clock()
	local correlated = {}
	for i = #self.Events, math.max(1, #self.Events - 6), -1 do
		local prev = self.Events[i]
		if prev and (now - prev.Clock) <= self.CorrelationWindow and prev.Category ~= category then
			table.insert(correlated, prev.Id)
		else
			break
		end
	end

	self.Seq += 1
	local ev = {
		Id = self.Seq,
		Clock = math.floor(now * 1000) / 1000,
		Time = os.date("!%H:%M:%S"),
		Category = category,
		Source = source,
		Summary = summary,
		Details = details and safeSerialize(details) or {},
		Correlated = correlated,
	}
	table.insert(self.Events, ev)
	if #self.Events > self.MaxEvents then
		table.remove(self.Events, 1)
	end
	if self.OnNewEvent then
		task.spawn(self.OnNewEvent, ev)
	end
	return ev
end

function Timeline:query(searchText: string?, category: string?): { any }
	local out = {}
	local q = searchText and string.lower(searchText) or ""
	for i = #self.Events, 1, -1 do
		local e = self.Events[i]
		local catMatch = (not category or category == "ALL" or e.Category == category)
		local txtMatch = (q == "")
			or string.find(string.lower(e.Summary), q, 1, true) ~= nil
			or string.find(string.lower(e.Source), q, 1, true) ~= nil
			or string.find(string.lower(e.Category), q, 1, true) ~= nil
		if catMatch and txtMatch then
			table.insert(out, e)
		end
	end
	return out
end

function Timeline:clear()
	table.clear(self.Events)
	self.Seq = 0
end

-- ============================================================================
-- [4] FINDINGS & ANOMALY DEDUPLICATION STORE
-- ============================================================================
local Findings = {
	MaxFindings = 300,
	Items = {},
	Dedup = {},
	Seq = 0,
	OnFinding = nil,
}

function Findings:add(severity: string, category: string, title: string, source: string, details: { [string]: any }?)
	local key = string.format("%s|%s|%s", category, title, source)
	if self.Dedup[key] then
		local item = self.Dedup[key]
		item.Count += 1
		item.LastSeen = os.date("!%H:%M:%S")
		return item
	end
	self.Seq += 1
	local entry = {
		Id = self.Seq,
		Severity = severity, -- INFO, LOW, MEDIUM, HIGH
		Category = category,
		Title = title,
		Source = source,
		FirstSeen = os.date("!%H:%M:%S"),
		LastSeen = os.date("!%H:%M:%S"),
		Count = 1,
		Details = details and safeSerialize(details) or {},
	}
	table.insert(self.Items, entry)
	self.Dedup[key] = entry
	if #self.Items > self.MaxFindings then
		local removed = table.remove(self.Items, 1)
		if removed then
			local oldKey = string.format("%s|%s|%s", removed.Category, removed.Title, removed.Source)
			self.Dedup[oldKey] = nil
		end
	end
	if self.OnFinding then
		task.spawn(self.OnFinding, entry)
	end
	return entry
end

function Findings:query(searchText: string?, filterCat: string?): { any }
	local out = {}
	local q = searchText and string.lower(searchText) or ""
	for i = #self.Items, 1, -1 do
		local f = self.Items[i]
		local catOk = (not filterCat or filterCat == "ALL" or f.Category == filterCat or f.Severity == filterCat)
		local txtOk = (q == "")
			or string.find(string.lower(f.Title), q, 1, true) ~= nil
			or string.find(string.lower(f.Source), q, 1, true) ~= nil
			or string.find(string.lower(f.Category), q, 1, true) ~= nil
		if catOk and txtOk then
			table.insert(out, f)
		end
	end
	return out
end

function Findings:clear()
	table.clear(self.Items)
	table.clear(self.Dedup)
	self.Seq = 0
end

-- ============================================================================
-- [5] DATAMODEL EXPLORER, DEEPSCAN & SNAPSHOT DELTA ENGINE
-- ============================================================================
local DataModelExplorer = {
	Nodes = {},
	NilInstances = {},
	Snapshots = {},
	SnapshotOrder = {},
	MaxSnapshots = 8,
	LastDiff = nil,
	IgnoreServices = { CoreGui = true, CorePackages = true },
}

local SAFE_PROPS = {
	BasePart = { "Position", "Size", "Transparency", "Anchored", "CanCollide", "Material" },
	Humanoid = { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight" },
	Sound = { "SoundId", "Volume", "PlaybackSpeed", "Playing", "Looped" },
	Animation = { "AnimationId" },
	MeshPart = { "MeshId", "TextureID", "Size", "Anchored" },
	SpecialMesh = { "MeshId", "TextureId", "MeshType" },
	Decal = { "Texture", "Transparency", "Face" },
	Texture = { "Texture", "Transparency" },
	ImageLabel = { "Image", "Visible" },
	ImageButton = { "Image", "Visible" },
	TextLabel = { "Text", "Visible" },
	TextButton = { "Text", "Visible" },
	ProximityPrompt = { "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "Enabled" },
	ClickDetector = { "MaxActivationDistance" },
	Tool = { "ToolTip", "RequiresHandle", "Enabled" },
	ValueBase = { "Value" },
}

function DataModelExplorer:readSignatureProps(inst: Instance): { [string]: string }
	local props = {
		Name = inst.Name,
		ClassName = inst.ClassName,
		Parent = inst.Parent and inst.Parent.Name or "nil",
	}
	for cls, propList in pairs(SAFE_PROPS) do
		local okIsa, match = pcall(inst.IsA, inst, cls)
		if okIsa and match then
			for _, pName in ipairs(propList) do
				local okP, val = pcall(function() return (inst :: any)[pName] end)
				if okP and val ~= nil then
					props[pName] = tostring(safeSerialize(val))
				end
			end
		end
	end
	return props
end

function DataModelExplorer:inspectInstance(inst: Instance, depth: number?): { [string]: any }
	local props = self:readSignatureProps(inst)
	local attrs = {}
	local okA, rawAttrs = pcall(inst.GetAttributes, inst)
	if okA and rawAttrs then
		for k, v in pairs(rawAttrs) do
			attrs[tostring(k)] = tostring(v)
		end
	end

	local tags = {}
	local okT, rawTags = pcall(CollectionService.GetTags, CollectionService, inst)
	if okT and rawTags then tags = rawTags end

	local okCh, chList = pcall(inst.GetChildren, inst)
	return {
		Name = inst.Name,
		ClassName = inst.ClassName,
		Path = safePath(inst),
		Depth = depth or 0,
		ChildCount = (okCh and chList) and #chList or 0,
		Properties = props,
		Attributes = attrs,
		Tags = tags,
	}
end

function DataModelExplorer:runDeepScan(root: Instance?, maxDepth: number?, onDone: (() -> ())?)
	local target = root or game
	local limit = math.max(0, maxDepth or 5)
	local queue = { { Inst = target, Depth = 0 } }
	local head, tail = 1, 1
	local generation = (self.ScanGeneration or 0) + 1
	self.ScanGeneration = generation
	table.clear(self.Nodes)
	if Scheduler.Status == "IDLE" or Scheduler.Status == "STOPPED" then
		Scheduler:setStatus("RUNNING")
	end

	-- Iterative breadth-first traversal: avoids recursive stack growth and
	-- yields while discovering children instead of prebuilding all descendants.
	local th = task.spawn(function()
		local processed = 0
		while head <= tail do
			if self.ScanGeneration ~= generation or Scheduler.Status == "STOPPED" then return end
			while Scheduler.Status == "PAUSED" do
				task.wait(0.08)
				if self.ScanGeneration ~= generation or Scheduler.Status == "STOPPED" then return end
			end

			local entry = queue[head]
			queue[head] = nil
			head += 1
			if entry and entry.Depth <= limit then
				local inst = entry.Inst
				if inst and (inst.Parent ~= nil or inst == target) then
					table.insert(self.Nodes, self:inspectInstance(inst, entry.Depth))
					if entry.Depth < limit then
						local okChildren, children = pcall(inst.GetChildren, inst)
						if okChildren and children then
							for _, child in ipairs(children) do
								if not (entry.Depth == 0 and self.IgnoreServices[child.Name]) then
									tail += 1
									queue[tail] = { Inst = child, Depth = entry.Depth + 1 }
								end
							end
						end
					end
				end
			end

			processed += 1
			if processed % Scheduler.BatchSize == 0 then
				Scheduler.Progress = { Current = processed, Total = 0, Label = "DeepScan Hierarchy", Percent = 0 }
				if Scheduler.OnProgress then pcall(Scheduler.OnProgress, Scheduler.Progress) end
				task.wait(Scheduler.YieldInterval)
			end
		end

		if self.ScanGeneration ~= generation or Scheduler.Status == "STOPPED" then return end
		table.clear(self.NilInstances)
		if Env.getnilinstances then
			local okN, nilList = pcall(Env.getnilinstances)
			if okN and type(nilList) == "table" then
				for i = 1, math.min(#nilList, 120) do
					local ni = nilList[i]
					if typeof(ni) == "Instance" then
						table.insert(self.NilInstances, { Name = ni.Name, ClassName = ni.ClassName })
					end
				end
			end
		end
		Scheduler.Progress = { Current = processed, Total = processed, Label = "DeepScan Complete", Percent = 100 }
		if Scheduler.OnProgress then pcall(Scheduler.OnProgress, Scheduler.Progress) end
		Timeline:record("DEEPSCAN_DONE", safePath(target), string.format("Scanned %d nodes (Nil=%d)", #self.Nodes, #self.NilInstances))
		if onDone then pcall(onDone) end
	end)
	table.insert(Scheduler.Threads, th)
	return th
end

function DataModelExplorer:takeSnapshot(customLabel: string?): string
	local id = customLabel or string.format("Snap_%d_%s", #self.SnapshotOrder + 1, os.date("!%H%M%S"))
	local map = {}
	local count = 0
	local targetServices = {
		game:GetService("Workspace"),
		game:GetService("ReplicatedStorage"),
		game:GetService("ReplicatedFirst"),
		game:GetService("StarterGui"),
		game:GetService("StarterPack"),
		game:GetService("Lighting"),
		game:GetService("Players"),
	}
	for _, svc in ipairs(targetServices) do
		local okD, desc = pcall(svc.GetDescendants, svc)
		if okD and desc then
			for _, inst in ipairs(desc) do
				local path = safePath(inst)
				local okA, attrs = pcall(inst.GetAttributes, inst)
				local attrParts = {}
				if okA and attrs then
					for k, v in pairs(attrs) do
						table.insert(attrParts, tostring(k) .. "=" .. tostring(v))
					end
					table.sort(attrParts)
				end
				local okT, tags = pcall(CollectionService.GetTags, CollectionService, inst)
				local tagSig = (okT and tags and #tags > 0) and table.concat(tags, ",") or ""
				local valSig = ""
				local okIsa, isVal = pcall(inst.IsA, inst, "ValueBase")
				if okIsa and isVal then
					local okV, v = pcall(function() return (inst :: any).Value end)
					if okV then valSig = tostring(v) end
				end
				map[path] = {
					Class = inst.ClassName,
					Parent = inst.Parent and inst.Parent.Name or "nil",
					AttrSig = table.concat(attrParts, ";"),
					TagSig = tagSig,
					ValSig = valSig,
				}
				count += 1
			end
		end
	end

	self.Snapshots[id] = { Id = id, Time = os.date("!%H:%M:%S"), Count = count, Map = map }
	table.insert(self.SnapshotOrder, id)
	while #self.SnapshotOrder > self.MaxSnapshots do
		local oldest = table.remove(self.SnapshotOrder, 1)
		if oldest then self.Snapshots[oldest] = nil end
	end

	Timeline:record("SNAPSHOT", id, string.format("Saved snapshot %s (%d instances)", id, count))
	return id
end

function DataModelExplorer:compareSnapshots(id1: string?, id2: string?): { [string]: any }?
	if not id1 or not id2 then
		if #self.SnapshotOrder < 2 then
			self:takeSnapshot()
			if #self.SnapshotOrder < 2 then return nil end
		end
		id1 = self.SnapshotOrder[#self.SnapshotOrder - 1]
		id2 = self.SnapshotOrder[#self.SnapshotOrder]
	end
	local s1 = self.Snapshots[id1 :: string]
	local s2 = self.Snapshots[id2 :: string]
	if not s1 or not s2 then return nil end

	local added, removed, modified = {}, {}, {}
	for path, m2 in pairs(s2.Map) do
		local m1 = s1.Map[path]
		if not m1 then
			table.insert(added, string.format("+ [%s] %s", m2.Class, path))
		else
			local changes = {}
			if m1.Parent ~= m2.Parent then
				table.insert(changes, string.format("Parent:%s->%s", m1.Parent, m2.Parent))
			end
			if m1.AttrSig ~= m2.AttrSig then
				table.insert(changes, "AttrsChanged")
			end
			if m1.TagSig ~= m2.TagSig then
				table.insert(changes, string.format("Tags:%s->%s", m1.TagSig, m2.TagSig))
			end
			if m1.ValSig ~= m2.ValSig then
				table.insert(changes, string.format("Value:%s->%s", m1.ValSig, m2.ValSig))
			end
			if #changes > 0 then
				table.insert(modified, string.format("~ [%s] %s (%s)", m2.Class, path, table.concat(changes, ", ")))
			end
		end
	end
	for path, m1 in pairs(s1.Map) do
		if not s2.Map[path] then
			table.insert(removed, string.format("- [%s] %s", m1.Class, path))
		end
	end

	self.LastDiff = {
		From = id1,
		To = id2,
		AddedCount = #added,
		RemovedCount = #removed,
		ModifiedCount = #modified,
		Added = added,
		Removed = removed,
		Modified = modified,
	}
	Timeline:record("SNAPSHOT_DIFF", tostring(id1) .. "->" .. tostring(id2), string.format("+%d Added | -%d Removed | ~%d Modified", #added, #removed, #modified), self.LastDiff)
	Findings:add("INFO", "SnapshotDelta", string.format("Diff %s -> %s (+%d / -%d / ~%d)", tostring(id1), tostring(id2), #added, #removed, #modified), tostring(id2), self.LastDiff)
	return self.LastDiff
end

-- ============================================================================
-- [6] NON-INTRUSIVE SCRIPT & MODULE INSPECTOR (NO AUTO-REQUIRE)
-- ============================================================================
local ScriptInspector = {
	Items = {},
}

function ScriptInspector:scanScripts(onDone: (() -> ())?)
	local loadedMap = {}
	if Env.getloadedmodules then
		local okL, list = pcall(Env.getloadedmodules)
		if okL and type(list) == "table" then
			for _, m in ipairs(list) do loadedMap[m] = true end
		end
	end

	local scripts = {}
	local okDesc, descList = pcall(game.GetDescendants, game)
	if okDesc and descList then
		for _, inst in ipairs(descList) do
			local okS, isScr = pcall(function()
				return inst:IsA("LocalScript") or inst:IsA("ModuleScript") or inst:IsA("Script")
			end)
			if okS and isScr then
				table.insert(scripts, inst)
			end
		end
	end

	table.clear(self.Items)
	Scheduler:runBatch("Inspect Scripts (Safe)", scripts, function(scr: Instance)
		local path = safePath(scr)
		local enabled = true
		local runCtx = "Standard"
		if scr:IsA("BaseScript") then
			pcall(function() enabled = scr.Enabled end)
			pcall(function() runCtx = scr.RunContext.Name end)
		end

		local senvFuncs = {}
		local upvalueSummary = {}
		if Env.getsenv and scr:IsA("LocalScript") and enabled then
			local okE, envTbl = pcall(Env.getsenv, scr)
			if okE and type(envTbl) == "table" then
				local count = 0
				for k, v in pairs(envTbl) do
					if type(v) == "function" and count < 20 then
						count += 1
						local fnInfo = tostring(k)
						if Env.getinfo then
							local okI, _, _, line, arity = pcall(Env.getinfo, v, "nsla")
							if okI then
								fnInfo = string.format("%s (line:%s, args:%s)", tostring(k), tostring(line or "?"), tostring(arity or 0))
							end
						end
						table.insert(senvFuncs, fnInfo)
						if Env.getupvalues and #upvalueSummary < 10 then
							local okU, ups = pcall(Env.getupvalues, v)
							if okU and type(ups) == "table" and next(ups) ~= nil then
								upvalueSummary[tostring(k)] = safeSerialize(ups, 1)
							end
						end
					end
				end
			end
		end

		local okA, attrs = pcall(scr.GetAttributes, scr)
		local okT, tags = pcall(CollectionService.GetTags, CollectionService, scr)
		table.insert(self.Items, {
			Name = scr.Name,
			ClassName = scr.ClassName,
			Path = path,
			Enabled = enabled,
			RunContext = runCtx,
			IsLoadedModule = loadedMap[scr] == true,
			SenvFunctions = senvFuncs,
			UpvaluePreview = upvalueSummary,
			Attributes = (okA and attrs) or {},
			Tags = (okT and tags) or {},
			Mode = "Passive Metadata Only (require() not executed)",
		})
	end, function()
		Timeline:record("SCRIPT_AUDIT", "DataModel", string.format("Indexed %d scripts/modules safely", #self.Items))
		if onDone then onDone() end
	end)
end

-- ============================================================================
-- [7] ASSET AUDITOR (DISCOVERY & GROUPING)
-- ============================================================================
local AssetAuditor = {
	Items = {},
	CountsByCategory = {},
}

local ASSET_RULES = {
	MeshPart = { { P = "MeshId", C = "Mesh" }, { P = "TextureID", C = "Texture" } },
	SpecialMesh = { { P = "MeshId", C = "Mesh" }, { P = "TextureId", C = "Texture" } },
	Sound = { { P = "SoundId", C = "Audio" } },
	Animation = { { P = "AnimationId", C = "Animation" } },
	Decal = { { P = "Texture", C = "Texture" } },
	Texture = { { P = "Texture", C = "Texture" } },
	ImageLabel = { { P = "Image", C = "UIImage" } },
	ImageButton = { { P = "Image", C = "UIImage" } },
	Shirt = { { P = "ShirtTemplate", C = "Clothing" } },
	Pants = { { P = "PantsTemplate", C = "Clothing" } },
}

function AssetAuditor:scanAssets(onDone: (() -> ())?)
	local okDesc, all = pcall(game.GetDescendants, game)
	if not okDesc or type(all) ~= "table" then
		all = {}
	end
	table.clear(self.Items)
	table.clear(self.CountsByCategory)

	Scheduler:runBatch("Audit Assets", all, function(inst: Instance)
		local rules = ASSET_RULES[inst.ClassName]
		if not rules then return end
		local path = safePath(inst)
		for _, r in ipairs(rules) do
			local okP, val = pcall(function() return (inst :: any)[r.P] end)
			if okP and type(val) == "string" and val ~= "" then
				table.insert(self.Items, {
					Category = r.C,
					Property = r.P,
					AssetId = val,
					Name = inst.Name,
					ClassName = inst.ClassName,
					Path = path,
				})
				self.CountsByCategory[r.C] = (self.CountsByCategory[r.C] or 0) + 1
			end
		end
	end, function()
		Timeline:record("ASSET_AUDIT", "DataModel", string.format("Cataloged %d assets across categories", #self.Items), self.CountsByCategory)
		if onDone then onDone() end
	end)
end

-- ============================================================================
-- [8] NETWORK & REMOTE TELEMETRY MONITOR (WITH HOOK RESTORATION ON STOP)
-- ============================================================================
local NetworkMonitor = {
	Remotes = {},
	Traffic = {},
	Counts = {},
	NamecallHooked = false,
	OriginalNamecall = nil,
}

function NetworkMonitor:scanRemotes()
	table.clear(self.Remotes)
	local okDesc, descList = pcall(game.GetDescendants, game)
	if okDesc and descList then
		for _, inst in ipairs(descList) do
			local okN, isNet = pcall(function()
				return inst:IsA("RemoteEvent")
					or inst:IsA("UnreliableRemoteEvent")
					or inst:IsA("RemoteFunction")
					or inst:IsA("BindableEvent")
					or inst:IsA("BindableFunction")
			end)
			if okN and isNet then
				local path = safePath(inst)
				table.insert(self.Remotes, {
					Name = inst.Name,
					ClassName = inst.ClassName,
					Path = path,
					Calls = self.Counts[path] or 0,
				})
			end
		end
	end
	Timeline:record("NET_INVENTORY", "DataModel", string.format("Found %d Remote/Bindable objects", #self.Remotes))
end

function NetworkMonitor:logPacket(dir: string, inst: Instance, method: string, args: { any })
	local path = safePath(inst)
	if not Scheduler:allowRate("net_" .. path, 20) then return end
	self.Counts[path] = (self.Counts[path] or 0) + 1

	local preview = {}
	for i = 1, math.min(#args, 5) do
		table.insert(preview, string.format("%s:%s", typeof(args[i]), string.sub(tostring(safeSerialize(args[i], 1)), 1, 45)))
	end
	local argStr = table.concat(preview, ", ")

	local pkt = {
		Time = os.date("!%H:%M:%S"),
		Direction = dir,
		Name = inst.Name,
		ClassName = inst.ClassName,
		Path = path,
		Method = method,
		Count = self.Counts[path],
		Args = argStr,
	}
	table.insert(self.Traffic, pkt)
	if #self.Traffic > 300 then
		table.remove(self.Traffic, 1)
	end

	Timeline:record("NET_" .. dir, path, string.format("%s.%s(%s)", inst.Name, method, argStr), pkt)
	if self.Counts[path] == 75 then
		Findings:add("MEDIUM", "HighFrequencyRemote", string.format("Remote %s triggered 75+ times", inst.Name), path, pkt)
	end
end

function NetworkMonitor:restoreHooks()
	if self.NamecallHooked and self.OriginalNamecall and Env.hookmetamethod then
		pcall(function()
			Env.hookmetamethod(game, "__namecall", self.OriginalNamecall)
		end)
	end
	self.NamecallHooked = false
	self.OriginalNamecall = nil
end

function NetworkMonitor:attachListeners()
	local function bindOne(inst: Instance)
		local path = safePath(inst)
		if inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent") then
			Scheduler:bindConnection("net_ev_" .. path, inst.OnClientEvent:Connect(function(...)
				if Scheduler.Status ~= "RUNNING" then return end
				self:logPacket("IN", inst, "OnClientEvent", { ... })
			end))
		elseif inst:IsA("BindableEvent") then
			Scheduler:bindConnection("net_bind_" .. path, inst.Event:Connect(function(...)
				if Scheduler.Status ~= "RUNNING" then return end
				self:logPacket("BIND", inst, "Event", { ... })
			end))
		end
	end

	local okDesc, descList = pcall(game.GetDescendants, game)
	if okDesc and descList then
		for _, inst in ipairs(descList) do
			pcall(bindOne, inst)
		end
	end
	Scheduler:bindConnection("net_desc_add", game.DescendantAdded:Connect(function(inst)
		if Scheduler.Status == "RUNNING" then pcall(bindOne, inst) end
	end))

	if Env.hookmetamethod and Env.getnamecallmethod and not self.NamecallHooked then
		local okHook = pcall(function()
			local oldNamecall
			oldNamecall = Env.hookmetamethod(game, "__namecall", function(selfInst, ...)
				if not self.NamecallHooked or Scheduler.Status ~= "RUNNING" then
					return oldNamecall(selfInst, ...)
				end
				local method = Env.getnamecallmethod()
				if typeof(selfInst) == "Instance" and (method == "FireServer" or method == "InvokeServer") then
					local args = { ... }
					task.spawn(function()
						self:logPacket("OUT", selfInst, method, args)
					end)
				end
				return oldNamecall(selfInst, ...)
			end)
			self.OriginalNamecall = oldNamecall
			self.NamecallHooked = true
		end)
		if okHook then
			Scheduler:registerCleanup("NetworkNamecallRestore", function()
				self:restoreHooks()
			end)
		end
	end
end

-- ============================================================================
-- [9] RUNTIME MONITOR, CHARACTER/ANIMATION TRACKER & ANOMALY DETECTOR
-- ============================================================================
local RuntimeMonitor = {
	SpeedLimit = 75,
	Stats = {
		InstancesAdded = 0,
		InstancesRemoved = 0,
		CharacterEvents = 0,
		AnimationsTracked = 0,
		ErrorsCaptured = 0,
	},
}

function RuntimeMonitor:bindPlayerCharacter(plr: Player, char: Model)
	local hum = char:WaitForChild("Humanoid", 5) :: Humanoid?
	local root = char:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	if not hum then return end

	Timeline:record("CHAR_SPAWN", plr.Name, string.format("WalkSpeed=%.1f, Health=%.1f", hum.WalkSpeed, hum.Health))

	for _, prop in ipairs({ "WalkSpeed", "JumpPower", "Health" }) do
		local okS, sig = pcall(hum.GetPropertyChangedSignal, hum, prop)
		if okS and sig then
			Scheduler:bindConnection("hum_" .. plr.Name .. "_" .. prop, sig:Connect(function()
				if Scheduler.Status ~= "RUNNING" then return end
				if not Scheduler:allowRate("hum_" .. plr.Name .. prop, 6) then return end
				local val = (hum :: any)[prop]
				self.Stats.CharacterEvents += 1
				Timeline:record("PROP_CHANGE", plr.Name, string.format("Humanoid.%s = %s", prop, tostring(val)))
				if prop == "WalkSpeed" and type(val) == "number" and val > 32 then
					Findings:add("MEDIUM", "WalkSpeedModified", string.format("%s WalkSpeed=%d", plr.Name, val), plr.Name, { WalkSpeed = val })
				end
			end))
		end
	end

	Scheduler:bindConnection("state_" .. plr.Name, hum.StateChanged:Connect(function(oldSt, newSt)
		if Scheduler.Status ~= "RUNNING" or oldSt == newSt then return end
		if Scheduler:allowRate("st_" .. plr.Name, 8) then
			self.Stats.CharacterEvents += 1
			Timeline:record("HUM_STATE", plr.Name, oldSt.Name .. " -> " .. newSt.Name)
		end
	end))

	local animator = hum:WaitForChild("Animator", 4) :: Animator?
	if animator then
		Scheduler:bindConnection("anim_" .. plr.Name, animator.AnimationPlayed:Connect(function(track)
			if Scheduler.Status ~= "RUNNING" then return end
			if Scheduler:allowRate("anim_" .. plr.Name, 6) then
				local id = (track.Animation and track.Animation.AnimationId) or "unknown"
				self.Stats.AnimationsTracked += 1
				self.Stats.CharacterEvents += 1
				Timeline:record("ANIMATION", plr.Name, string.format("%s (spd=%.1f)", id, track.Speed))
			end
		end))
	end

	Scheduler:bindConnection("tool_" .. plr.Name, char.ChildAdded:Connect(function(child)
		if Scheduler.Status ~= "RUNNING" then return end
		if child:IsA("Tool") then
			self.Stats.CharacterEvents += 1
			Timeline:record("TOOL_EQUIP", plr.Name, "Equipped Tool: " .. child.Name)
		end
	end))

	if root then
		local lastPos = root.Position
		local lastTime = os.clock()
		Scheduler:bindConnection("spd_" .. plr.Name, RunService.Heartbeat:Connect(function()
			if Scheduler.Status ~= "RUNNING" or not root.Parent then return end
			local now = os.clock()
			local dt = now - lastTime
			if dt >= 0.6 then
				local dist = (root.Position - lastPos).Magnitude
				local velocity = dist / dt
				if velocity > self.SpeedLimit then
					Findings:add("HIGH", "MovementAnomaly", string.format("%s velocity %.1f studs/s", plr.Name, velocity), plr.Name, {
						Velocity = velocity,
						From = tostring(lastPos),
						To = tostring(root.Position),
					})
					Timeline:record("ANOMALY", plr.Name, string.format("Velocity spike: %.1f studs/s", velocity))
				end
				lastPos = root.Position
				lastTime = now
			end
		end))
	end
end

function RuntimeMonitor:start()
	Scheduler:setStatus("RUNNING")

	for _, svcName in ipairs({ "Workspace", "ReplicatedStorage" }) do
		local svc = game:GetService(svcName)
		Scheduler:bindConnection("inst_add_" .. svcName, svc.DescendantAdded:Connect(function(inst)
			if Scheduler.Status ~= "RUNNING" then return end
			self.Stats.InstancesAdded += 1
			if Scheduler:allowRate("add_" .. svcName, 12) then
				Timeline:record("INST_ADDED", svcName, string.format("[%s] %s", inst.ClassName, safePath(inst)))
			end
		end))
		Scheduler:bindConnection("inst_rem_" .. svcName, svc.DescendantRemoving:Connect(function(inst)
			if Scheduler.Status ~= "RUNNING" then return end
			self.Stats.InstancesRemoved += 1
			if Scheduler:allowRate("rem_" .. svcName, 12) then
				Timeline:record("INST_REMOVED", svcName, string.format("[%s] %s", inst.ClassName, safePath(inst)))
			end
		end))
	end

	Scheduler:bindConnection("log_err", LogService.MessageOut:Connect(function(msg, msgType)
		if Scheduler.Status ~= "RUNNING" then return end
		if msgType == Enum.MessageType.MessageError or msgType == Enum.MessageType.MessageWarning then
			self.Stats.ErrorsCaptured += 1
			if Scheduler:allowRate("err_log", 8) then
				local sev = (msgType == Enum.MessageType.MessageError) and "HIGH" or "LOW"
				Findings:add(sev, "RuntimeError", string.sub(msg, 1, 120), "LogService", { FullMessage = msg, Type = msgType.Name })
				Timeline:record("LOG_" .. sev, "LogService", string.sub(msg, 1, 100))
			end
		end
	end))

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			task.spawn(function() self:bindPlayerCharacter(plr, plr.Character) end)
		end
		Scheduler:bindConnection("pchar_" .. plr.Name, plr.CharacterAdded:Connect(function(c)
			self:bindPlayerCharacter(plr, c)
		end))
	end
	Scheduler:bindConnection("padd", Players.PlayerAdded:Connect(function(plr)
		Scheduler:bindConnection("pchar_" .. plr.Name, plr.CharacterAdded:Connect(function(c)
			self:bindPlayerCharacter(plr, c)
		end))
	end))
	Scheduler:bindConnection("prem", Players.PlayerRemoving:Connect(function(plr)
		for _, suffix in ipairs({ "pchar_", "hum_", "state_", "anim_", "tool_", "spd_" }) do
			Scheduler:unbindConnection(suffix .. plr.Name)
		end
		Scheduler:unbindConnection("hum_" .. plr.Name .. "_WalkSpeed")
		Scheduler:unbindConnection("hum_" .. plr.Name .. "_JumpPower")
		Scheduler:unbindConnection("hum_" .. plr.Name .. "_Health")
	end))

	NetworkMonitor:attachListeners()
	Timeline:record("RUNTIME_START", "Lifecycle", "Runtime monitoring started/resumed")
end

-- ============================================================================
-- [10] EXPORT CENTER (JSON / TXT / CLIPBOARD / FILE)
-- ============================================================================
local ExportCenter = {}

function ExportCenter:toJSON(): string
	local data = {
		Version = "3.2.3-DeltaPatch",
		Timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		PlaceId = game.PlaceId,
		JobId = game.JobId,
		Capabilities = CompatAdapter.getCapabilities(),
		RuntimeStats = RuntimeMonitor.Stats,
		Counts = {
			Nodes = #DataModelExplorer.Nodes,
			NilInstances = #DataModelExplorer.NilInstances,
			Scripts = #ScriptInspector.Items,
			Assets = #AssetAuditor.Items,
			Remotes = #NetworkMonitor.Remotes,
			Findings = #Findings.Items,
			Timeline = #Timeline.Events,
		},
		LastSnapshotDiff = DataModelExplorer.LastDiff,
		Findings = Findings.Items,
		Timeline = Timeline.Events,
		Remotes = NetworkMonitor.Remotes,
		RecentTraffic = NetworkMonitor.Traffic,
		AssetSummary = AssetAuditor.CountsByCategory,
	}
	local ok, res = pcall(HttpService.JSONEncode, HttpService, data)
	return ok and res or "{}"
end

function ExportCenter:toTXT(): string
	local out = {
		"==========================================================",
		" GAMESCANNER DELTA V3.2.3 — DEEP INSPECTION REPORT",
		string.format(" PlaceId: %d | UTC: %s", game.PlaceId, os.date("!%Y-%m-%d %H:%M:%S")),
		"==========================================================",
		string.format("Nodes: %d | Scripts: %d | Assets: %d | Remotes: %d | Findings: %d | Timeline: %d",
			#DataModelExplorer.Nodes, #ScriptInspector.Items, #AssetAuditor.Items,
			#NetworkMonitor.Remotes, #Findings.Items, #Timeline.Events),
		"",
		"--- [FINDINGS] ---",
	}
	for _, f in ipairs(Findings.Items) do
		table.insert(out, string.format("[%s] (%s) %s | Src: %s | Count: %d | Last: %s",
			f.Severity, f.Category, f.Title, f.Source, f.Count, f.LastSeen))
	end
	table.insert(out, "")
	table.insert(out, "--- [TIMELINE (LATEST 50)] ---")
	for i = math.max(1, #Timeline.Events - 50), #Timeline.Events do
		local e = Timeline.Events[i]
		if e then
			table.insert(out, string.format("[%s] [%s] %s: %s (Corr:%d)",
				e.Time, e.Category, e.Source, e.Summary, #e.Correlated))
		end
	end
	return table.concat(out, "\n")
end

function ExportCenter:exportToFile(fmt: string): (boolean, string)
	if not Env.writefile then
		return false, "writefile unavailable in this environment"
	end
	local isTxt = string.upper(fmt) == "TXT"
	local ext = isTxt and "txt" or "json"
	local payload = isTxt and self:toTXT() or self:toJSON()
	local fname = string.format("GameScannerV3_2_3_%d.%s", game.PlaceId, ext)
	local ok, err = pcall(Env.writefile, fname, payload)
	if ok then
		Timeline:record("EXPORT_FILE", fname, string.format("Saved %d bytes", #payload))
		return true, "Saved to " .. fname
	end
	return false, tostring(err)
end

function ExportCenter:exportToClipboard(fmt: string): (boolean, string)
	if not Env.setclipboard then
		return false, "setclipboard unavailable in this environment"
	end
	local isTxt = string.upper(fmt) == "TXT"
	local payload = isTxt and self:toTXT() or self:toJSON()
	local ok, err = pcall(Env.setclipboard, payload)
	if ok then
		Timeline:record("EXPORT_CLIP", fmt, string.format("Copied %d bytes to clipboard", #payload))
		return true, "Copied " .. fmt .. " to clipboard"
	end
	return false, tostring(err)
end

-- ============================================================================
-- [11] ANDROID-OPTIMIZED FLOATING UI WITH PAGINATION & CLEANUP
-- ============================================================================
local UI = {
	ScreenGui = nil,
	DetailLabel = nil,
	ProgressLabel = nil,
	RefreshActiveTab = nil,
	ActiveTab = "Overview",
	SearchQuery = "",
	CurrentPage = 1,
	PageSize = 45,
	TotalPages = 1,
	EventSeq = 0,
}

local function bindUIEvent(signal: RBXScriptSignal, callback: (...any) -> ())
	UI.EventSeq += 1
	return Scheduler:bindConnection("ui_event_" .. tostring(UI.EventSeq), signal:Connect(callback))
end

local function makeCorner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function makeDraggable(keyPrefix: string, dragHandle: GuiObject, targetFrame: GuiObject)
	local dragging = false
	local dragStart, startPos

	Scheduler:bindConnection(keyPrefix .. "_began", dragHandle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = targetFrame.Position
		end
	end))

	Scheduler:bindConnection(keyPrefix .. "_ended", UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))

	Scheduler:bindConnection(keyPrefix .. "_changed", UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			targetFrame.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end))
end

function UI:reportInitError(subsystem: string, errMsg: any)
	local cleanErr = tostring(errMsg)
	warn(string.format("[GameScanner][%s] %s", subsystem, cleanErr))
	Findings:add("HIGH", "InitError", subsystem .. " failed", subsystem, { Error = cleanErr })
	Timeline:record("INIT_ERROR", subsystem, cleanErr)
	if self.ProgressLabel then
		self.ProgressLabel.Text = "Err: " .. string.sub(subsystem, 1, 8)
		self.ProgressLabel.TextColor3 = Color3.fromRGB(248, 113, 113)
	end
	if self.DetailLabel then
		self.DetailLabel.Text = string.format("[INIT ERROR: %s]\n%s", subsystem, cleanErr)
	end
	if self.RefreshActiveTab then
		pcall(self.RefreshActiveTab)
	end
end

function UI:mount()
	if RunService:IsServer() and not RunService:IsClient() then return end
	local parent = CompatAdapter.getGuiParent()
	if not parent then return end

	for _, guiName in ipairs({ "GameScannerDeltaV3_2_1", "GameScannerDeltaV3_2_2", "GameScannerDeltaV3_2_3" }) do
		local old = parent:FindFirstChild(guiName)
		if old then pcall(old.Destroy, old) end
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "GameScannerDeltaV3_2_3"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent
	self.ScreenGui = gui

	-- Floating Minimized Pill Icon
	local floatBtn = Instance.new("TextButton")
	floatBtn.Name = "FloatingOrb"
	floatBtn.Size = UDim2.fromOffset(62, 32)
	floatBtn.Position = UDim2.new(0.02, 0, 0.18, 0)
	floatBtn.BackgroundColor3 = Color3.fromRGB(16, 185, 129)
	floatBtn.Font = Enum.Font.GothamBold
	floatBtn.TextSize = 11
	floatBtn.TextColor3 = Color3.fromRGB(10, 15, 20)
	floatBtn.Text = "GS-3.2"
	floatBtn.Visible = false
	floatBtn.Parent = gui
	makeCorner(floatBtn, 16)

	-- Main Compact Panel (475x305 for Android Landscape)
	local panel = Instance.new("Frame")
	panel.Name = "MainPanel"
	panel.Size = UDim2.fromOffset(475, 305)
	panel.Position = UDim2.new(0.5, -237, 0.5, -152)
	panel.BackgroundColor3 = Color3.fromRGB(18, 20, 27)
	panel.BorderSizePixel = 0
	panel.Parent = gui
	makeCorner(panel, 8)

	makeDraggable("ui_orb", floatBtn, floatBtn)

	-- Top Header Bar
	local topBar = Instance.new("Frame")
	topBar.Size = UDim2.new(1, 0, 0, 26)
	topBar.BackgroundColor3 = Color3.fromRGB(26, 29, 39)
	topBar.BorderSizePixel = 0
	topBar.Parent = panel
	makeCorner(topBar, 8)
	makeDraggable("ui_panel", topBar, panel)

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Size = UDim2.new(1, -100, 1, 0)
	titleLbl.Position = UDim2.fromOffset(8, 0)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.Code
	titleLbl.TextSize = 11
	titleLbl.TextColor3 = Color3.fromRGB(110, 231, 183)
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = "GameScanner Delta V3.2.3 [RUNNING]"
	titleLbl.Parent = topBar

	local minBtn = Instance.new("TextButton")
	minBtn.Size = UDim2.fromOffset(40, 18)
	minBtn.Position = UDim2.new(1, -88, 0, 4)
	minBtn.BackgroundColor3 = Color3.fromRGB(55, 65, 81)
	minBtn.Font = Enum.Font.Code
	minBtn.TextSize = 10
	minBtn.TextColor3 = Color3.fromRGB(240, 240, 245)
	minBtn.Text = "Min"
	minBtn.Parent = topBar
	makeCorner(minBtn, 4)

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.fromOffset(40, 18)
	closeBtn.Position = UDim2.new(1, -44, 0, 4)
	closeBtn.BackgroundColor3 = Color3.fromRGB(185, 28, 28)
	closeBtn.Font = Enum.Font.Code
	closeBtn.TextSize = 10
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.Text = "Stop"
	closeBtn.Parent = topBar
	makeCorner(closeBtn, 4)

	bindUIEvent(minBtn.MouseButton1Click, function()
		panel.Visible = false
		floatBtn.Visible = true
	end)
	bindUIEvent(floatBtn.MouseButton1Click, function()
		floatBtn.Visible = false
		panel.Visible = true
	end)

	-- Control & Pagination Bar
	local ctrlBar = Instance.new("Frame")
	ctrlBar.Size = UDim2.new(1, -12, 0, 22)
	ctrlBar.Position = UDim2.fromOffset(6, 29)
	ctrlBar.BackgroundTransparency = 1
	ctrlBar.Parent = panel

	local ctrlLayout = Instance.new("UIListLayout")
	ctrlLayout.FillDirection = Enum.FillDirection.Horizontal
	ctrlLayout.Padding = UDim.new(0, 3)
	ctrlLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	ctrlLayout.Parent = ctrlBar

	local function createCtrlBtn(txt: string, w: number, bg: Color3, fn: () -> ())
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(w, 19)
		b.BackgroundColor3 = bg
		b.Font = Enum.Font.Code
		b.TextSize = 10
		b.TextColor3 = Color3.fromRGB(245, 245, 250)
		b.Text = txt
		b.Parent = ctrlBar
		makeCorner(b, 4)
		bindUIEvent(b.MouseButton1Click, fn)
		return b
	end

	local searchBox = Instance.new("TextBox")
	searchBox.Size = UDim2.fromOffset(96, 19)
	searchBox.BackgroundColor3 = Color3.fromRGB(30, 34, 45)
	searchBox.Font = Enum.Font.Code
	searchBox.TextSize = 10
	searchBox.TextColor3 = Color3.fromRGB(230, 235, 245)
	searchBox.PlaceholderText = "Filter..."
	searchBox.Text = ""
	searchBox.ClearTextOnFocus = false
	searchBox.Parent = ctrlBar
	makeCorner(searchBox, 4)

	local pageLbl = Instance.new("TextLabel")
	pageLbl.Size = UDim2.fromOffset(48, 19)
	pageLbl.BackgroundTransparency = 1
	pageLbl.Font = Enum.Font.Code
	pageLbl.TextSize = 10
	pageLbl.TextColor3 = Color3.fromRGB(209, 213, 219)
	pageLbl.Text = "1/1"
	pageLbl.Parent = ctrlBar

	local progLbl = Instance.new("TextLabel")
	progLbl.Size = UDim2.fromOffset(82, 19)
	progLbl.BackgroundTransparency = 1
	progLbl.Font = Enum.Font.Code
	progLbl.TextSize = 9
	progLbl.TextColor3 = Color3.fromRGB(156, 163, 175)
	progLbl.TextXAlignment = Enum.TextXAlignment.Left
	progLbl.Text = "Ready"
	progLbl.Parent = ctrlBar
	self.ProgressLabel = progLbl

	-- Tab Strip (10 Tabs)
	local tabScroll = Instance.new("ScrollingFrame")
	tabScroll.Size = UDim2.new(1, -12, 0, 22)
	tabScroll.Position = UDim2.fromOffset(6, 53)
	tabScroll.BackgroundColor3 = Color3.fromRGB(24, 27, 36)
	tabScroll.BorderSizePixel = 0
	tabScroll.ScrollBarThickness = 2
	tabScroll.ScrollingDirection = Enum.ScrollingDirection.X
	tabScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
	tabScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	tabScroll.Parent = panel
	makeCorner(tabScroll, 4)

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 3)
	tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	tabLayout.Parent = tabScroll

	-- Content Split: Left List (60%) + Right Detail Inspector (40%)
	local listScroll = Instance.new("ScrollingFrame")
	listScroll.Size = UDim2.new(0.60, -8, 1, -82)
	listScroll.Position = UDim2.fromOffset(6, 78)
	listScroll.BackgroundColor3 = Color3.fromRGB(13, 15, 21)
	listScroll.BorderSizePixel = 0
	listScroll.ScrollBarThickness = 4
	listScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	listScroll.Parent = panel
	makeCorner(listScroll, 6)

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 2)
	listLayout.Parent = listScroll

	local detailFrame = Instance.new("ScrollingFrame")
	detailFrame.Size = UDim2.new(0.40, -8, 1, -82)
	detailFrame.Position = UDim2.new(0.60, 2, 0, 78)
	detailFrame.BackgroundColor3 = Color3.fromRGB(15, 17, 24)
	detailFrame.BorderSizePixel = 0
	detailFrame.ScrollBarThickness = 4
	detailFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	detailFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	detailFrame.Parent = panel
	makeCorner(detailFrame, 6)

	local detailText = Instance.new("TextLabel")
	detailText.Size = UDim2.new(1, -10, 0, 0)
	detailText.Position = UDim2.fromOffset(5, 5)
	detailText.AutomaticSize = Enum.AutomaticSize.Y
	detailText.BackgroundTransparency = 1
	detailText.Font = Enum.Font.Code
	detailText.TextSize = 10
	detailText.TextColor3 = Color3.fromRGB(209, 213, 219)
	detailText.TextXAlignment = Enum.TextXAlignment.Left
	detailText.TextYAlignment = Enum.TextYAlignment.Top
	detailText.TextWrapped = true
	detailText.Text = "Select an item on the left to inspect full details."
	detailText.Parent = detailFrame
	self.DetailLabel = detailText

	local function showDetails(title: string, tbl: any)
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, safeSerialize(tbl))
		if ok and type(encoded) == "string" then
			local formatted = string.gsub(encoded, ',"', ',\n  "')
			detailText.Text = "[" .. tostring(title) .. "]\n" .. formatted
		else
			detailText.Text = "[" .. tostring(title) .. "]\n" .. tostring(tbl)
		end
	end

	local function clearList()
		for _, ch in ipairs(listScroll:GetChildren()) do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
	end

	local function addRow(label: string, color: Color3?, onSelect: (() -> ())?)
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, -6, 0, 19)
		row.BackgroundColor3 = Color3.fromRGB(22, 25, 34)
		row.Font = Enum.Font.Code
		row.TextSize = 10
		row.TextColor3 = color or Color3.fromRGB(229, 231, 235)
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.Text = " " .. string.sub(label, 1, 65)
		row.Parent = listScroll
		makeCorner(row, 3)
		if onSelect then
			bindUIEvent(row.MouseButton1Click, onSelect)
		end
		return row
	end

	local function renderPaginated(entries: { { Text: string, Color: Color3?, Callback: (() -> ())? } })
		local total = #entries
		self.TotalPages = math.max(1, math.ceil(total / self.PageSize))
		self.CurrentPage = math.clamp(self.CurrentPage, 1, self.TotalPages)
		pageLbl.Text = string.format("%d/%d", self.CurrentPage, self.TotalPages)

		local startIdx = (self.CurrentPage - 1) * self.PageSize + 1
		local endIdx = math.min(total, startIdx + self.PageSize - 1)
		for i = startIdx, endIdx do
			local item = entries[i]
			if item then
				addRow(item.Text, item.Color, item.Callback)
			end
		end
	end

	local function renderActiveTab()
		clearList()
		local q = string.lower(self.SearchQuery)
		local tab = self.ActiveTab
		local rows = {}

		if tab == "Overview" then
			local caps = CompatAdapter.getCapabilities()
			table.insert(rows, {
				Text = "=== ENVIRONMENT CAPABILITIES ===",
				Color = Color3.fromRGB(110, 231, 183),
				Callback = function() showDetails("Capabilities", caps) end,
			})
			table.insert(rows, { Text = string.format("Lifecycle Status: %s | Hook Active: %s", Scheduler.Status, tostring(NetworkMonitor.NamecallHooked)) })
			table.insert(rows, { Text = string.format("DataModel Nodes: %d | Nil: %d", #DataModelExplorer.Nodes, #DataModelExplorer.NilInstances) })
			table.insert(rows, { Text = string.format("Scripts Indexed: %d (Passive Mode)", #ScriptInspector.Items) })
			table.insert(rows, { Text = string.format("Assets Cataloged: %d", #AssetAuditor.Items) })
			table.insert(rows, { Text = string.format("Remotes Inventory: %d | Packets: %d", #NetworkMonitor.Remotes, #NetworkMonitor.Traffic) })
			table.insert(rows, { Text = string.format("Timeline Events: %d | Findings: %d", #Timeline.Events, #Findings.Items) })
			table.insert(rows, {
				Text = "Inspect RuntimeMonitor Live Stats",
				Color = Color3.fromRGB(147, 197, 253),
				Callback = function() showDetails("RuntimeMonitor Stats", RuntimeMonitor.Stats) end,
			})
			renderPaginated(rows)

		elseif tab == "Explorer" then
			if #DataModelExplorer.Nodes == 0 then
				table.insert(rows, {
					Text = "[ACTION] Run DeepScan Hierarchy Now",
					Color = Color3.fromRGB(252, 211, 77),
					Callback = function() DataModelExplorer:runDeepScan(game, 4, function() renderActiveTab() end) end,
				})
			end
			for _, node in ipairs(DataModelExplorer.Nodes) do
				if q == "" or string.find(string.lower(node.Path), q, 1, true) or string.find(string.lower(node.ClassName), q, 1, true) then
					local indent = string.rep("  ", math.min(node.Depth, 4))
					local nRef = node
					table.insert(rows, {
						Text = string.format("%s[%s] %s (%d)", indent, nRef.ClassName, nRef.Name, nRef.ChildCount),
						Callback = function() showDetails(nRef.Path, nRef) end,
					})
				end
			end
			renderPaginated(rows)

		elseif tab == "DeepScan" then
			table.insert(rows, {
				Text = "[ACTION] Run Full DeepScan (Hierarchy + Scripts + Assets + Remotes)",
				Color = Color3.fromRGB(110, 231, 183),
				Callback = function()
					DataModelExplorer:runDeepScan(game, 5, function()
						ScriptInspector:scanScripts(function()
							AssetAuditor:scanAssets(function()
								NetworkMonitor:scanRemotes()
								renderActiveTab()
							end)
						end)
					end)
				end,
			})
			table.insert(rows, {
				Text = "[ACTION] Take DataModel Snapshot Now",
				Color = Color3.fromRGB(147, 197, 253),
				Callback = function()
					local snapId = DataModelExplorer:takeSnapshot()
					showDetails("Snapshot Saved: " .. snapId, {
						Id = snapId,
						Count = DataModelExplorer.Snapshots[snapId].Count,
						Time = DataModelExplorer.Snapshots[snapId].Time,
					})
					renderActiveTab()
				end,
			})
			table.insert(rows, {
				Text = "[ACTION] Compare Latest 2 Snapshots (Delta Diff)",
				Color = Color3.fromRGB(252, 211, 77),
				Callback = function()
					local diff = DataModelExplorer:compareSnapshots()
					if diff then showDetails("Snapshot Delta Diff", diff) end
					renderActiveTab()
				end,
			})
			table.insert(rows, { Text = string.format("Snapshots Stored: %d (Max %d)", #DataModelExplorer.SnapshotOrder, DataModelExplorer.MaxSnapshots) })
			if DataModelExplorer.LastDiff then
				local d = DataModelExplorer.LastDiff
				table.insert(rows, {
					Text = string.format("Last Diff (%s->%s): +%d / -%d / ~%d", tostring(d.From), tostring(d.To), d.AddedCount, d.RemovedCount, d.ModifiedCount),
					Callback = function() showDetails("Last Snapshot Diff", d) end,
				})
			end
			renderPaginated(rows)

		elseif tab == "Runtime" then
			table.insert(rows, { Text = string.format("Instances Added: %d | Removed: %d", RuntimeMonitor.Stats.InstancesAdded, RuntimeMonitor.Stats.InstancesRemoved) })
			table.insert(rows, { Text = string.format("Char Events: %d | Anims: %d | Errors: %d", RuntimeMonitor.Stats.CharacterEvents, RuntimeMonitor.Stats.AnimationsTracked, RuntimeMonitor.Stats.ErrorsCaptured) })
			for _, plr in ipairs(Players:GetPlayers()) do
				local pRef = plr
				table.insert(rows, {
					Text = "Player: " .. pRef.Name,
					Color = Color3.fromRGB(147, 197, 253),
					Callback = function()
						local char = pRef.Character
						local hum = char and char:FindFirstChildOfClass("Humanoid")
						showDetails(pRef.Name, {
							UserId = pRef.UserId,
							WalkSpeed = hum and hum.WalkSpeed or "N/A",
							Health = hum and hum.Health or "N/A",
							Position = (char and char.PrimaryPart) and tostring(char.PrimaryPart.Position) or "N/A",
						})
					end,
				})
			end
			renderPaginated(rows)

		elseif tab == "Scripts" then
			table.insert(rows, {
				Text = "[ACTION] Scan Scripts & ModuleScripts (Passive Metadata)",
				Color = Color3.fromRGB(110, 231, 183),
				Callback = function() ScriptInspector:scanScripts(function() renderActiveTab() end) end,
			})
			for _, scr in ipairs(ScriptInspector.Items) do
				if q == "" or string.find(string.lower(scr.Path), q, 1, true) or string.find(string.lower(scr.ClassName), q, 1, true) then
					local sRef = scr
					local tag = sRef.IsLoadedModule and "[LOADED]" or ""
					table.insert(rows, {
						Text = string.format("[%s]%s %s", sRef.ClassName, tag, sRef.Name),
						Callback = function() showDetails(sRef.Path, sRef) end,
					})
				end
			end
			renderPaginated(rows)

		elseif tab == "Network" then
			table.insert(rows, {
				Text = "[ACTION] Refresh Remote Inventory (" .. #NetworkMonitor.Remotes .. ")",
				Color = Color3.fromRGB(110, 231, 183),
				Callback = function()
					NetworkMonitor:scanRemotes()
					renderActiveTab()
				end,
			})
			for i = #NetworkMonitor.Traffic, 1, -1 do
				local pkt = NetworkMonitor.Traffic[i]
				if q == "" or string.find(string.lower(pkt.Path), q, 1, true) or string.find(string.lower(pkt.Args), q, 1, true) then
					local pRef = pkt
					table.insert(rows, {
						Text = string.format("[%s] %s (%dx) %s", pRef.Direction, pRef.Name, pRef.Count, pRef.Args),
						Color = Color3.fromRGB(196, 181, 253),
						Callback = function() showDetails("Packet " .. pRef.Name, pRef) end,
					})
				end
			end
			for _, rem in ipairs(NetworkMonitor.Remotes) do
				if q == "" or string.find(string.lower(rem.Path), q, 1, true) then
					local rRef = rem
					table.insert(rows, {
						Text = string.format("[INV:%s] %s (Calls:%d)", rRef.ClassName, rRef.Name, rRef.Calls),
						Callback = function() showDetails(rRef.Path, rRef) end,
					})
				end
			end
			renderPaginated(rows)

		elseif tab == "Assets" then
			table.insert(rows, {
				Text = "[ACTION] Scan Asset IDs",
				Color = Color3.fromRGB(110, 231, 183),
				Callback = function() AssetAuditor:scanAssets(function() renderActiveTab() end) end,
			})
			for cat, total in pairs(AssetAuditor.CountsByCategory) do
				table.insert(rows, {
					Text = string.format("Category [%s]: %d assets", cat, total),
					Color = Color3.fromRGB(147, 197, 253),
				})
			end
			for _, a in ipairs(AssetAuditor.Items) do
				if q == "" or string.find(string.lower(a.Category), q, 1, true) or string.find(string.lower(a.Name), q, 1, true) or string.find(string.lower(a.AssetId), q, 1, true) then
					local aRef = a
					table.insert(rows, {
						Text = string.format("[%s] %s -> %s", aRef.Category, aRef.Name, aRef.AssetId),
						Callback = function() showDetails(aRef.Path, aRef) end,
					})
				end
			end
			renderPaginated(rows)

		elseif tab == "Timeline" then
			local list = Timeline:query(self.SearchQuery, "ALL")
			for _, ev in ipairs(list) do
				local eRef = ev
				table.insert(rows, {
					Text = string.format("[%s] [%s] %s", eRef.Time, eRef.Category, eRef.Summary),
					Callback = function() showDetails("Timeline #" .. eRef.Id, eRef) end,
				})
			end
			renderPaginated(rows)

		elseif tab == "Findings" then
			local list = Findings:query(self.SearchQuery, "ALL")
			if #list == 0 then
				table.insert(rows, { Text = "No findings or anomalies recorded yet.", Color = Color3.fromRGB(156, 163, 175) })
			end
			for _, f in ipairs(list) do
				local fRef = f
				local col = (fRef.Severity == "HIGH" and Color3.fromRGB(248, 113, 113))
					or (fRef.Severity == "MEDIUM" and Color3.fromRGB(251, 191, 36))
					or Color3.fromRGB(147, 197, 253)
				table.insert(rows, {
					Text = string.format("[%s] %s (%dx)", fRef.Severity, fRef.Title, fRef.Count),
					Color = col,
					Callback = function() showDetails("Finding #" .. fRef.Id, fRef) end,
				})
			end
			renderPaginated(rows)

		elseif tab == "Export" then
			table.insert(rows, {
				Text = "[EXPORT] Copy JSON Report to Clipboard",
				Color = Color3.fromRGB(110, 231, 183),
				Callback = function()
					local _, msg = ExportCenter:exportToClipboard("JSON")
					detailText.Text = msg
				end,
			})
			table.insert(rows, {
				Text = "[EXPORT] Copy TXT Report to Clipboard",
				Color = Color3.fromRGB(147, 197, 253),
				Callback = function()
					local _, msg = ExportCenter:exportToClipboard("TXT")
					detailText.Text = msg
				end,
			})
			table.insert(rows, {
				Text = "[EXPORT] Save JSON File (writefile)",
				Color = Color3.fromRGB(252, 211, 77),
				Callback = function()
					local _, msg = ExportCenter:exportToFile("JSON")
					detailText.Text = msg
				end,
			})
			table.insert(rows, {
				Text = "[EXPORT] Save TXT File (writefile)",
				Color = Color3.fromRGB(252, 211, 77),
				Callback = function()
					local _, msg = ExportCenter:exportToFile("TXT")
					detailText.Text = msg
				end,
			})
			table.insert(rows, {
				Text = "[PREVIEW] Show TXT Summary in Right Panel",
				Callback = function() detailText.Text = ExportCenter:toTXT() end,
			})
			renderPaginated(rows)
		end
	end
	self.RefreshActiveTab = renderActiveTab

	-- Create 10 Tabs
	local TABS = { "Overview", "Explorer", "DeepScan", "Runtime", "Scripts", "Network", "Assets", "Timeline", "Findings", "Export" }
	local tabButtons = {}
	for _, tabName in ipairs(TABS) do
		local tb = Instance.new("TextButton")
		tb.Size = UDim2.fromOffset(62, 18)
		tb.BackgroundColor3 = (tabName == self.ActiveTab) and Color3.fromRGB(16, 185, 129) or Color3.fromRGB(38, 43, 56)
		tb.Font = Enum.Font.Code
		tb.TextSize = 10
		tb.TextColor3 = (tabName == self.ActiveTab) and Color3.fromRGB(10, 15, 20) or Color3.fromRGB(220, 225, 235)
		tb.Text = tabName
		tb.Parent = tabScroll
		makeCorner(tb, 4)
		tabButtons[tabName] = tb

		bindUIEvent(tb.MouseButton1Click, function()
			self.ActiveTab = tabName
			self.CurrentPage = 1
			for name, btn in pairs(tabButtons) do
				btn.BackgroundColor3 = (name == tabName) and Color3.fromRGB(16, 185, 129) or Color3.fromRGB(38, 43, 56)
				btn.TextColor3 = (name == tabName) and Color3.fromRGB(10, 15, 20) or Color3.fromRGB(220, 225, 235)
			end
			renderActiveTab()
		end)
	end

	-- Control & Pagination Buttons
	createCtrlBtn("Start", 42, Color3.fromRGB(16, 185, 129), function()
		RuntimeMonitor:start()
		renderActiveTab()
	end)
	createCtrlBtn("Pause", 42, Color3.fromRGB(217, 119, 6), function()
		Scheduler:pause()
		renderActiveTab()
	end)
	createCtrlBtn("Resume", 46, Color3.fromRGB(37, 99, 235), function()
		Scheduler:resume()
		renderActiveTab()
	end)
	createCtrlBtn("<", 22, Color3.fromRGB(55, 65, 81), function()
		if self.CurrentPage > 1 then
			self.CurrentPage -= 1
			renderActiveTab()
		end
	end)
	createCtrlBtn(">", 22, Color3.fromRGB(55, 65, 81), function()
		if self.CurrentPage < self.TotalPages then
			self.CurrentPage += 1
			renderActiveTab()
		end
	end)
	createCtrlBtn("Ref", 34, Color3.fromRGB(75, 85, 99), function()
		renderActiveTab()
	end)

	bindUIEvent(closeBtn.MouseButton1Click, function()
		Scheduler:stopAndCleanup()
		gui:Destroy()
		self.ScreenGui = nil
	end)

	bindUIEvent(searchBox:GetPropertyChangedSignal("Text"), function()
		self.SearchQuery = searchBox.Text
		self.CurrentPage = 1
		renderActiveTab()
	end)

	Scheduler.OnProgress = function(p)
		progLbl.TextColor3 = Color3.fromRGB(156, 163, 175)
		progLbl.Text = string.format("%s %d%%", string.sub(p.Label, 1, 8), p.Percent)
	end
	Scheduler.OnStatusChange = function(st)
		titleLbl.Text = string.format("GameScanner Delta V3.2.3 [%s]", st)
	end

	renderActiveTab()
end

-- ============================================================================
-- [12] BOOTSTRAP & PUBLIC LIFECYCLE API
-- ============================================================================
local GameScannerV3_2 = {
	Version = "3.2.3-DeltaPatch",
	CompatAdapter = CompatAdapter,
	Scheduler = Scheduler,
	Timeline = Timeline,
	Findings = Findings,
	DataModelExplorer = DataModelExplorer,
	ScriptInspector = ScriptInspector,
	AssetAuditor = AssetAuditor,
	NetworkMonitor = NetworkMonitor,
	RuntimeMonitor = RuntimeMonitor,
	ExportCenter = ExportCenter,
	UI = UI,
}

function GameScannerV3_2.start()
	-- 1. Mount UI first before any scanning or hooking begins.
	local uiOk, uiErr = pcall(function()
		UI:mount()
	end)
	if not uiOk then
		warn("[GameScanner] UI mount failed: " .. tostring(uiErr))
		return GameScannerV3_2
	end
	if not UI.ScreenGui then
		warn("[GameScanner] UI was not mounted: no writable GUI parent found.")
		return GameScannerV3_2
	end

	-- 2. Run initial scan modules safely in isolated pcall blocks and surface
	-- any initialization failure directly in the UI.
	local snapshotOk, snapshotErr = pcall(function()
		DataModelExplorer:takeSnapshot("Initial")
	end)
	if not snapshotOk then
		UI:reportInitError("InitialSnapshot", snapshotErr)
	end

	local inventoryOk, inventoryErr = pcall(function()
		NetworkMonitor:scanRemotes()
	end)
	if not inventoryOk then
		UI:reportInitError("RemoteInventory", inventoryErr)
	end

	local monitorOk, monitorErr = pcall(function()
		RuntimeMonitor:start()
	end)
	if not monitorOk then
		UI:reportInitError("RuntimeMonitor", monitorErr)
	end

	if UI.RefreshActiveTab then
		pcall(UI.RefreshActiveTab)
	end

	return GameScannerV3_2
end

function GameScannerV3_2.stop()
	Scheduler:stopAndCleanup()
	if UI.ScreenGui then
		UI.ScreenGui:Destroy()
		UI.ScreenGui = nil
	end
end

-- Static Self-Checks
assert(type(CompatAdapter.getCapabilities()) == "table", "CompatAdapter check failed")
assert(type(ExportCenter:toJSON()) == "string", "ExportCenter JSON check failed")
assert(type(ExportCenter:toTXT()) == "string", "ExportCenter TXT check failed")

return GameScannerV3_2.start()
