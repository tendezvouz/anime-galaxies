-- language: Luau, file: test.lua, target: Real / Anime Galaxies
local CONFIG = {
    UniverseId = 10770748262, LobbyPlaceId = 83869074416117,
    LibraryUrl = "https://sirius.menu/gen2",
    ToggleKey = Enum.KeyCode.LeftControl, PollSeconds = 0.5,
    SettingsFile = "AG_AutoQueue/settings.json",
    JoinRetry = 8, StartRetry = 25, ReturnRetry = 15,
    MaxStartAttempts = 3, MaxReturnAttempts = 4,
}
if not game:IsLoaded() then game.Loaded:Wait() end
if game.GameId ~= CONFIG.UniverseId then return end
-- Allow the destination place UI to finish loading before initialization.
local entryChallengeRound = math.floor(workspace:GetServerTimeNow() / 900)
task.wait(15)
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Http = game:GetService("HttpService")
local player = Players.LocalPlayer
while not player do task.wait(); player = Players.LocalPlayer end
local env = getgenv()
local previous = env.__AGChallenge
local defaults = {challenges=false, raids=false, story=false, storyMap="", storyAct=1,
    storyNightmare=false, raidMap="", raidNightmare=false, webhookEnabled=false, webhookUrl=""}
local options = table.clone(defaults)
pcall(function()
    if isfile(CONFIG.SettingsFile) then
        local saved = Http:JSONDecode(readfile(CONFIG.SettingsFile))
        for k, default in pairs(defaults) do
            if type(saved[k]) == type(default) then options[k] = saved[k] end
        end
    elseif previous then
        options.challenges = previous.toggle and previous.toggle.value == true or false
    end
end)
if previous and previous.options then
    for k, default in pairs(defaults) do
        if type(previous.options[k]) == type(default) then options[k] = previous.options[k] end
    end
end
local inheritedRound = previous and previous.jobId == game.JobId and previous.matchRound
local inheritedMode = previous and previous.mode
local inheritedHost = previous and previous.host
local inheritedManaged = previous and previous.managedRoom
if previous and previous.cleanup then pcall(previous.cleanup) end
local S = {alive=true, options=options, connections={}, mode=inheritedMode, host=inheritedHost,
    jobId=game.JobId, matchRound=inheritedRound or entryChallengeRound,
    managedRoom=inheritedManaged, selectedKey=nil, lastJoin=-math.huge,
    lastSelect=-math.huge, lastStart=-math.huge, startAttempts=0,
    lastLeave=-math.huge, lastReturn=-math.huge, returnAttempts=0, holdStart=false}
env.__AGChallenge = S
local function connect(signal, fn)
    local c = signal:Connect(fn); table.insert(S.connections,c); return c
end
function S.cleanup()
    if not S.alive then return end
    S.alive=false
    for _,c in ipairs(S.connections) do c:Disconnect() end
    if S.window and not S.window.unloaded then pcall(function() S.window:Unload() end) end
end
if type(STATE)=="table" and STATE.onCleanup then STATE.onCleanup(S.cleanup) end
local information = RS:WaitForChild("Master",30)
if not information then return end
information = information:WaitForChild("Information",30)
if not information then return end
local WorldsModule = information:WaitForChild("Worlds",120)
if not WorldsModule or not WorldsModule:IsA("ModuleScript") then
    S.startupError = "Missing Information.Worlds in this place"
    warn("[AG Queue] " .. S.startupError)
    return
end
local Worlds = require(WorldsModule)
local RaidsModule = information:WaitForChild("Raids",120)
if not RaidsModule or not RaidsModule:IsA("ModuleScript") then
    S.startupError = "Missing Information.Raids in this place"
    warn("[AG Queue] " .. S.startupError)
    return
end
local Raids = require(RaidsModule)
-- ChallengeRotation exists in lobby but is not shipped in the match place.
-- Both places share the same 900-second UTC rotation; no lobby-only dependency is required.
local Rotation = {Period = 900}
function Rotation.id(now) return math.floor(now / Rotation.Period) end
function Rotation.endsAt(id) return (id + 1) * Rotation.Period end
local rotationModule = information:FindFirstChild("ChallengeRotation")
if rotationModule and rotationModule:IsA("ModuleScript") then
    local ok, module = pcall(require, rotationModule)
    if ok and type(module) == "table" and type(module.id) == "function"
        and type(module.endsAt) == "function" then Rotation = module end
end
local worldNames, raidNames, worldsByName, raidsByName = {}, {}, {}, {}
for _,w in ipairs(Worlds) do
    if not w.Exclusive then table.insert(worldNames,w.Name); worldsByName[w.Name]=w end
end
for _,r in ipairs(Raids) do table.insert(raidNames,r.Name); raidsByName[r.Name]=r end
if not worldsByName[options.storyMap] then options.storyMap=worldNames[1] or "" end
if not raidsByName[options.raidMap] then options.raidMap=raidNames[1] or "" end
local function actsFor(name)
    local values={}
    local world=worldsByName[name]
    for i,title in ipairs(world and world.Stages or {}) do
        table.insert(values,string.format("%d - %s",i,tostring(title)))
    end
    return values
end
local function clampAct()
    local n=#actsFor(options.storyMap)
    options.storyAct=math.clamp(math.floor(options.storyAct),1,math.max(1,n))
end
clampAct()
local status
local function setStatus(value)
    if value~=S.status then S.status=value; if status then status:Set(value) end end
end
local function save()
    local ok,err=pcall(function() writefile(CONFIG.SettingsFile,Http:JSONEncode(options)) end)
    if not ok then warn("[AG Queue] Could not save: "..tostring(err)) end
end
local webhookStatus
local queueWebhook
local initializing=true
local function changed(key,value)
    options[key]=value
    S.selectedKey=nil; S.startAttempts=0; S.lastStart=-math.huge
    S.returnAttempts=0; S.returnReason=nil; S.lastReturn=-math.huge
    if not initializing then save() end
end
local Rayfield=loadstring(game:HttpGet(CONFIG.LibraryUrl))()
if not S.alive then return end
local window=Rayfield:CreateWindow({name="Anime Galaxies",subtitle="Auto Queue",sidebarLayout=false})
S.window=window
window.settings.toggleKeybind=CONFIG.ToggleKey
local main=window:CreateTab({name="Auto Queue"})
main:CreateText({text="Priority: Challenges > Raids > Story\nLeft Ctrl: show / hide"})
S.toggle=main:CreateToggle({name="Auto Challenges",value=options.challenges,forgetState=true,
    description="New round: return from match. After Challenge: return to lobby.",
    callback=function(v) changed("challenges",v) end})
S.raidToggle=main:CreateToggle({name="Auto Raids",value=options.raids,forgetState=true,
    description="Repeat selected Raid when no Challenge is available.",
    callback=function(v) changed("raids",v) end})
S.storyToggle=main:CreateToggle({name="Auto Story",value=options.story,forgetState=true,
    description="Join selected Story; use game Auto Replay until a new Challenge round.",
    callback=function(v) changed("story",v) end})
status=main:CreateText({name="Status",text="Ready"})
local timer=main:CreateText({name="Challenge reset",text="--:--"})
local raidTab=window:CreateTab({name="Raid"})
S.raidMap=raidTab:CreateDropdown({name="Raid",options=raidNames,value=options.raidMap,forgetState=true,
    callback=function(v) if raidsByName[v] then changed("raidMap",v) end end})
raidTab:CreateText({name="Act",text="This Raid has one stage; no separate Act selection."})
S.raidNightmare=raidTab:CreateToggle({name="Nightmare",value=options.raidNightmare,forgetState=true,
    description="Off = Normal. On = Nightmare.",
    callback=function(v) changed("raidNightmare",v) end})
local storyTab=window:CreateTab({name="Story"})
local actDropdown
S.storyMap=storyTab:CreateDropdown({name="World",options=worldNames,value=options.storyMap,forgetState=true,
    callback=function(v)
        if not worldsByName[v] then return end
        if options.storyMap~=v then options.storyAct=1 end
        options.storyMap=v; clampAct()
        if actDropdown then
            local choices=actsFor(v)
            actDropdown:Refresh(choices)
            actDropdown:Set(choices[options.storyAct],true)
        end
        changed("storyMap",v)
    end})
local choices=actsFor(options.storyMap)
actDropdown=storyTab:CreateDropdown({name="Act",options=choices,value=choices[options.storyAct],forgetState=true,
    callback=function(v)
        local n=type(v)=="string" and tonumber(v:match("^(%d+)"))
        if n then changed("storyAct",n) end
    end})
S.storyAct=actDropdown
S.storyNightmare=storyTab:CreateToggle({name="Nightmare",value=options.storyNightmare,forgetState=true,
    description="Off = Normal. On = Nightmare.",
    callback=function(v) changed("storyNightmare",v) end})
local webhookTab=window:CreateTab({name="Webhook"})
S.webhookInput=webhookTab:CreateInput({
    name="Discord Webhook URL",value=options.webhookUrl,forgetState=true,
    placeholder="https://discord.com/api/webhooks/...",
    callback=function(value) changed("webhookUrl",tostring(value):match("^%s*(.-)%s*$")) end,
})
S.webhookToggle=webhookTab:CreateToggle({
    name="Enable Webhook",value=options.webhookEnabled,forgetState=true,
    description="Send Victory / Defeat and inventory totals after every round.",
    callback=function(value) changed("webhookEnabled",value) end,
})
webhookStatus=webhookTab:CreateText({name="Webhook status",text="Disabled"})
webhookTab:CreateText({text="Includes Trait Crystal (Trait Reroll), Rainbow Stars and inventory totals. Works with game Auto Replay."})
webhookTab:CreateButton({name="Send test message",callback=function()
    if queueWebhook then queueWebhook({Status="Test"},true) end
end})
initializing=false
save()
local function inLobby() return game.PlaceId==CONFIG.LobbyPlaceId end
local function challengeState()
    local now=workspace:GetServerTimeNow()
    local id=Rotation.id(now)
    local endsAt=Rotation.endsAt(id)
    local raw=RS:FindFirstChild("RawInformation")
    local current=raw and raw:FindFirstChild("CurrentChallenge")
    local serverId=current and current:GetAttribute("Id")
    local data=player:FindFirstChild("Data")
    local cleared=data and data:FindFirstChild("ChallengeCleared")
    -- In lobby, wait for replicated rotation to catch up to the clock at the boundary.
    return {id=id,endsAt=endsAt,now=now,ready=not inLobby() or serverId==id,
        known=cleared~=nil,cleared=cleared and cleared.Value==id}
end
local function chooseTarget(c)
    if options.challenges and c.known and not c.cleared then
        return {mode="Challenge",round=c.id}
    end
    if options.raids and raidsByName[options.raidMap] then
        return {mode="Raid",map=options.raidMap,nightmare=options.raidNightmare}
    end
    if options.story and worldsByName[options.storyMap] then
        return {mode="Story",map=options.storyMap,act=options.storyAct,nightmare=options.storyNightmare}
    end
    if options.challenges and c.known then return {mode="Challenge",round=c.id,wait=true} end
end
S.chooseTarget=chooseTarget
local function targetKey(t)
    return table.concat({t.mode,t.map or "",tostring(t.act or ""),tostring(t.round or ""),tostring(t.nightmare==true)},"|")
end
local function payload(t)
    if t.mode=="Challenge" then return {Action="SelectMap",ChallengeTier="Rotating",FriendsOnly=false} end
    local p={Action="SelectMap",MapName=t.map,FriendsOnly=false,Nightmare=t.nightmare==true}
    if t.mode=="Story" then p.Stage=t.act end
    return p
end
S.payload=payload
local lobbyNetwork
local function wireLobby()
    if lobbyNetwork then return true end
    local modules=RS.Master:FindFirstChild("Modules")
    if not modules or not modules:FindFirstChild("Network_Client") then return false end
    lobbyNetwork=require(modules.Network_Client)
    if not lobbyNetwork.Topics or not lobbyNetwork.Topics.Room then lobbyNetwork=nil; return false end
    connect(lobbyNetwork.Topics.Room,function(message)
        if type(message)~="table" then return end
        if message.Action=="ShowUi" or message.Action=="ShowLeaveUi" then
            S.mode=message.Mode or "Story"; S.host=message.Action=="ShowUi"
            S.managedRoom=S.pendingMode==S.mode
            S.selectedKey=nil; S.startAttempts=0; S.lastSelect=-math.huge
        elseif message.Action=="Kick" then
            S.mode=nil; S.host=false; S.managedRoom=false; S.pendingMode=nil
            S.selectedKey=nil; S.lastJoin=os.clock()
        end
    end)
    return true
end
local function freeDoor(mode)
    local root=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    local rooms=workspace:FindFirstChild("Rooms")
    if not root or not rooms then return end
    local best, distance=nil,math.huge
    for _,room in ipairs(rooms:GetChildren()) do
        if room.Name:sub(1,#mode)==mode then
            local door=room:FindFirstChild("Door")
            local details=room:FindFirstChild("DetailsUI",true)
            local count=details and details:FindFirstChild("Count")
            if door and door:IsA("BasePart") and door:GetAttribute("Ready")~=true
                and (not count or count.Value==0)
                and (mode~="Challenge" or (door:GetAttribute("ChallengeTier") or "Rotating")=="Rotating") then
                local d=(door.Position-root.Position).Magnitude
                if d<distance then best=door; distance=d end
            end
        end
    end
    return best,root
end
local function resultVisible()
    local gui=player:FindFirstChild("PlayerGui")
    if not gui then return false end
    local fusion=gui:FindFirstChild("FusionMatchHUD")
    local host=fusion and fusion:FindFirstChild("ResultHost")
    local result=host and host:FindFirstChild("RoundResult")
    if not result then
        local legacy=gui:FindFirstChild("ScreenGui"); result=legacy and legacy:FindFirstChild("RoundResult")
    end
    if not result or not result:IsA("GuiObject") or not result.Visible then return false end
    local ancestor=result.Parent
    while ancestor and ancestor~=gui do
        if ancestor:IsA("GuiObject") and not ancestor.Visible then return false end
        if ancestor:IsA("ScreenGui") and not ancestor.Enabled then return false end
        ancestor=ancestor.Parent
    end
    return true
end
S.resultVisible=resultVisible
local function matchInfo()
    local g=workspace:FindFirstChild("Game")
    local join={}
    if g then
        local raw=g:GetAttribute("JoinData")
        if type(raw)=="string" then
            local ok,v=pcall(Http.JSONDecode,Http,raw)
            if ok and type(v)=="table" then join=v end
        end
    end
    local mode=join.Mode or workspace:GetAttribute("Mode")
    if mode=="Normal" or mode=="Nightmare" then mode="Story" end
    return mode,join
end
-- Persist the outbox before HTTP so a return/Auto Replay can finish delivery in the next place.
local WEBHOOK_FILE="AG_AutoQueue/webhook_outbox.json"
local webhookData={pending={},seen={}}
pcall(function()
    if isfile(WEBHOOK_FILE) then
        local loaded=Http:JSONDecode(readfile(WEBHOOK_FILE))
        if type(loaded)=="table" and type(loaded.pending)=="table" and type(loaded.seen)=="table" then
            webhookData=loaded
        end
    end
end)
S.webhookData=webhookData
S.webhookMessage="Disabled"
local function webhookMessage(text)
    S.webhookMessage=text
    if webhookStatus then webhookStatus:Set(text) end
end
local function saveOutbox()
    local ok=pcall(function() writefile(WEBHOOK_FILE,Http:JSONEncode(webhookData)) end)
    if not ok then webhookMessage("Could not save pending report") end
end
local function webhookURL(value)
    if type(value)~="string" then return end
    local host,path=value:match("^https://([^/]+)(/[^#]+)$")
    if host~="discord.com" and host~="discordapp.com" and host~="canary.discord.com" and host~="ptb.discord.com" then return end
    local base,tail=path:match("^(/api/webhooks/%d+/[%w_%-]+)(.*)$")
    if not base then base,tail=path:match("^(/api/v%d+/webhooks/%d+/[%w_%-]+)(.*)$") end
    if not base or (tail~="" and tail:sub(1,1)~="?") then return end
    if value:find("[?&]wait=") then return (value:gsub("([?&]wait=)[^&]*","%1true")) end
    return value..(value:find("?",1,true) and "&" or "?").."wait=true"
end
local function numericValue(folder,name)
    if not folder then return nil end
    local value=folder:FindFirstChild(name)
    if value and value:IsA("ValueBase") then return tonumber(value.Value) end
    return 0
end
local function inventorySnapshot()
    local data=player:FindFirstChild("Data")
    local inventory=data and data:FindFirstChild("Inventory")
    local items=inventory and inventory:FindFirstChild("Items")
    local currencies=data and data:FindFirstChild("Currencies")
    local itemLines,currencyLines={},{}
    for _,pair in ipairs({{items,itemLines},{currencies,currencyLines}}) do
        if pair[1] then
            for _,v in ipairs(pair[1]:GetChildren()) do
                if v:IsA("NumberValue") or v:IsA("IntValue") then
                    table.insert(pair[2],v.Name..": "..tostring(v.Value))
                end
            end
            table.sort(pair[2])
        end
    end
    return {trait=numericValue(items,"Trait Crystal"),stars=numericValue(currencies,"EventTokens"),
        items=itemLines,currencies=currencyLines}
end
local function makeWebhookBody(message,isTest)
    local mode,join=matchInfo()
    local g=workspace:FindFirstChild("Game")
    local map=g and g:FindFirstChild("Map")
    local stage=g and g:FindFirstChild("Stage")
    local duration=g and g:FindFirstChild("TotalDuration")
    local inventory=inventorySnapshot()
    local result=isTest and "Test" or message.Status
    local fields={
        {name="Player",value=player.Name,inline=true},
        {name="Mode",value=tostring(mode or "Lobby"),inline=true},
        {name="Map / Act",value=tostring(map and map.Value or join.Map or "-").." / "..tostring(stage and stage.Value or join.Stage or "-"),inline=true},
        {name="Difficulty",value=(join.Nightmare==true and "Nightmare" or "Normal"),inline=true},
        {name="Trait Reroll (Trait Crystal)",value=inventory.trait~=nil and tostring(inventory.trait) or "Data not loaded",inline=true},
        {name="Rainbow Stars",value=inventory.stars~=nil and tostring(inventory.stars) or "Data not loaded",inline=true},
    }
    if duration then table.insert(fields,{name="Duration",value=tostring(math.floor(duration.Value)).." seconds",inline=true}) end
    local function addList(title,lines)
        local chunk=""
        local index=1
        for _,line in ipairs(lines) do
            if #chunk+#line+1>950 then
                table.insert(fields,{name=title.." "..index,value=chunk,inline=false})
                index+=1;chunk=""
            end
            chunk=chunk..(chunk=="" and "" or "\n")..line
        end
        if chunk~="" then table.insert(fields,{name=title.." "..index,value=chunk,inline=false}) end
    end
    addList("Inventory",inventory.items)
    addList("Currencies",inventory.currencies)
    return {username="Anime Galaxies Report",
        embeds={{title=isTest and "Webhook test" or ("Round result: "..tostring(result)),
            color=result=="Victory" and 5763719 or result=="Defeat" and 15548997 or 5793266,
            fields=fields,footer={text="Inventory totals after the round"}}}}
end
S.inventorySnapshot=inventorySnapshot
S.makeWebhookBody=makeWebhookBody
S.webhookURL=webhookURL
queueWebhook=function(message,isTest)
    if not options.webhookEnabled then
        if isTest then webhookMessage("Enable Webhook first") end
        return false
    end
    if not webhookURL(options.webhookUrl) then webhookMessage("Enter a valid Discord Webhook URL");return false end
    if type(message)~="table" or (not isTest and message.Status~="Victory" and message.Status~="Defeat") then return false end
    local g=workspace:FindFirstChild("Game")
    local duration=g and g:FindFirstChild("TotalDuration")
    local key=isTest and ("test:"..Http:GenerateGUID(false))
        or (game.JobId..":"..tostring(message.Status)..":"..tostring(duration and duration.Value or 0))
    for _,seen in ipairs(webhookData.seen) do if seen==key then return false end end
    table.insert(webhookData.seen,key)
    while #webhookData.seen>100 do table.remove(webhookData.seen,1) end
    -- Give replicated inventory changes a short moment, without delaying the game's Auto Replay.
    task.spawn(function()
        if not isTest then task.wait(0.4) end
        local body=makeWebhookBody(message,isTest)
        table.insert(webhookData.pending,{id=key,body=Http:JSONEncode(body),attempts=0,nextAt=0})
        saveOutbox()
        webhookMessage("Report queued ("..#webhookData.pending..")")
    end)
    return true
end
S.queueWebhook=queueWebhook
local webhookWired=false
local function tickWebhook()
    if not options.webhookEnabled then webhookMessage("Disabled");return end
    if not webhookURL(options.webhookUrl) then webhookMessage("Enter a valid Discord Webhook URL");return end
    if not inLobby() and not webhookWired then
        local service=require(RS.RemoteService)
        local remote=service.Remotes and service.Remotes.EndGame
        if remote then
            connect(remote,function(message) queueWebhook(message,false) end)
            webhookWired=true
            S.webhookWired=true
            webhookMessage("Listening for round results")
        end
    end
end
local function processWebhook()
    if not options.webhookEnabled then return end
    local url=webhookURL(options.webhookUrl)
    if not url then return end
    local item=webhookData.pending[1]
    if not item or workspace:GetServerTimeNow()<(item.nextAt or 0) then return end
    local sender=request or http_request
    if type(sender)~="function" then webhookMessage("Executor HTTP request unavailable");return end
    local ok,response=pcall(sender,{Url=url,Method="POST",Headers={["Content-Type"]="application/json"},Body=item.body})
    if not S.alive then return end
    local statusCode=ok and type(response)=="table" and tonumber(response.StatusCode) or 0
    if statusCode and statusCode>=200 and statusCode<300 then
        table.remove(webhookData.pending,1);saveOutbox()
        webhookMessage("Sent successfully ("..tostring(statusCode)..")")
        return
    end
    item.attempts=(item.attempts or 0)+1
    local delay=math.min(60,2^item.attempts)
    if statusCode==429 then
        local parsedOk,parsed=pcall(Http.JSONDecode,Http,response.Body or "")
        local headers=response.Headers or {}
        delay=tonumber(headers["Retry-After"] or headers["retry-after"])
            or (parsedOk and type(parsed)=="table" and tonumber(parsed.retry_after)) or delay
        delay=math.max(0.5,delay)
    elseif statusCode==400 or statusCode==401 or statusCode==403 or statusCode==404 then
        -- Stop retrying this webhook until its URL is changed.
        S.webhookBlockedUrl=options.webhookUrl
        webhookMessage("Discord HTTP "..statusCode..": check Webhook URL / permissions")
        saveOutbox();return
    end
    item.nextAt=workspace:GetServerTimeNow()+delay
    if item.attempts>=6 then
        table.remove(webhookData.pending,1)
        webhookMessage("Report failed after 6 attempts (HTTP "..tostring(statusCode)..")")
    else webhookMessage("Retry scheduled (HTTP "..tostring(statusCode)..")") end
    saveOutbox()
end
task.spawn(function()
    while S.alive do
        if S.webhookBlockedUrl~=options.webhookUrl then
            local ok=pcall(processWebhook)
            if not ok then webhookMessage("HTTP delivery failed; pending report retained") end
        end
        task.wait(0.5)
    end
end)
local returnNetwork
local function returnToLobby(reason)
    if S.returnReason~=reason then
        S.returnReason=reason; S.returnAttempts=0; S.lastReturn=-math.huge
        local record={reason=reason,time=workspace:GetServerTimeNow(),place=game.PlaceId,
            jobId=game.JobId,matchRound=S.matchRound,
            currentRound=Rotation.id(workspace:GetServerTimeNow()),
            mode=workspace:GetAttribute("Mode")}
        S.lastReturnRecord=record
        pcall(function() writefile("AG_AutoQueue/last_return.json",Http:JSONEncode(record)) end)
        print("[AG Queue] Return: "..reason.." (match round "..tostring(S.matchRound)..")")
    end
    local modules=RS.Master:FindFirstChild("Modules")
    if not modules then setStatus("Waiting for return controls"); return end
    local interface=modules:FindFirstChild("Interface_Client")
    local gameEnd=interface and interface:FindFirstChild("GameEndUi")
    if gameEnd then pcall(function() require(gameEnd):CancelAutoReplay() end) end
    if S.returnAttempts>=CONFIG.MaxReturnAttempts then
        setStatus("Return not confirmed: toggle the active mode off/on to retry"); return
    end
    if os.clock()-S.lastReturn>=CONFIG.ReturnRetry then
        returnNetwork=returnNetwork or require(modules.Network_Client)
        -- The same request as the game's Return to Lobby button, including mid-match.
        returnNetwork:Publish("EndGame","Return")
        S.returnAttempts+=1; S.lastReturn=os.clock()
    end
    setStatus(reason.." - returning to lobby")
end
local function preemptForChallenge(c,mode,join)
    if not options.challenges or not c.known or c.cleared then return false end
    if mode~="Story" and mode~="Raid" and mode~="Challenge" then return false end
    if mode=="Challenge" then
        -- Keep playing the current rotating challenge; leave only when its round expires.
        if join.ChallengeTier and join.ChallengeTier~="Rotating" then return c.id > S.matchRound end
        local activeId=tonumber(join.ChallengeId)
        if not activeId then return false end
        return activeId<c.id
    end
    -- An uncleared round alone is not evidence of a reset during this match.
    return c.id > S.matchRound
end
S.preemptForChallenge=preemptForChallenge
local function tickMatch(c)
    local mode,join=matchInfo()
    if preemptForChallenge(c,mode,join) then
        returnToLobby("Challenge round "..c.id.." available"); return
    end
    -- Story completion belongs to the game's Auto Replay.
    -- Only a new Challenge round may interrupt Story above.
    if mode=="Story" then
        S.resultSince=nil; S.returnReason=nil
        setStatus("Story: using game Auto Replay; waiting for Challenge reset")
        return
    end
    local managed=(mode=="Challenge" and options.challenges)
        or (mode=="Raid" and options.raids) or (mode=="Story" and options.story)
    if not managed then
        S.resultSince=nil; S.returnReason=nil
        setStatus("Auto queue paused for this match"); return
    end
    if not resultVisible() then
        S.resultSince=nil; S.returnReason=nil
        setStatus(tostring(mode)..": waiting for match to finish"); return
    end
    S.resultSince=S.resultSince or os.clock()
    if os.clock()-S.resultSince<1.5 then
        local interface=RS.Master.Modules:FindFirstChild("Interface_Client")
        local gameEnd=interface and interface:FindFirstChild("GameEndUi")
        if gameEnd then pcall(function() require(gameEnd):CancelAutoReplay() end) end
        setStatus("Match complete: preparing to return"); return
    end
    returnToLobby(tostring(mode).." finished")
end
local function tickLobby(c)
    S.returnReason=nil; S.resultSince=nil
    if not c.ready then setStatus("Waiting for server Challenge reset"); return end
    if options.challenges and not c.known then setStatus("Waiting for Challenge clear data"); return end
    local target=chooseTarget(c)
    if not target then setStatus("Disabled"); return end
    if not wireLobby() then setStatus("Waiting for lobby network"); return end
    local character=player.Character
    local root=character and character:FindFirstChild("HumanoidRootPart")
    local humanoid=character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health<=0 then setStatus("Waiting for character"); return end
    local clock=os.clock()
    if not character:GetAttribute("InRoom") then
        S.mode=nil; S.host=false; S.managedRoom=false; S.selectedKey=nil
        if clock-S.lastStart<CONFIG.StartRetry then setStatus("Waiting for teleport"); return end
        if clock-S.lastJoin>=CONFIG.JoinRetry then
            local door=freeDoor(target.mode)
            if not door then setStatus("Waiting for empty "..target.mode.." room"); return end
            S.pendingMode=target.mode; S.lastJoin=clock
            root.CFrame=door.CFrame
        end
        setStatus("Entering "..target.mode.." room"); return
    end
    if S.mode~=target.mode then
        if S.managedRoom then
            if clock-S.lastLeave>=4 then
                lobbyNetwork:Publish("Room",{Action="Leave"}); S.lastLeave=clock
            end
            setStatus("Switching to "..target.mode)
        else setStatus("Leave your current room to auto queue") end
        return
    end
    if not S.host then setStatus("Waiting for room host"); return end
    -- A room the user entered manually is left under their control.
    if not S.managedRoom then setStatus("Manual room: leave it to auto queue"); return end
    local key=targetKey(target)
    if key~=S.selectedKey then
        if clock-S.lastSelect>=2 then
            lobbyNetwork:Publish("Room",payload(target))
            S.selectedKey=key; S.lastSelect=clock; S.startAttempts=0; S.lastStart=-math.huge
        end
        setStatus("Selecting "..target.mode); return
    end
    if target.wait then setStatus("Challenge cleared: waiting in room for reset"); return end
    if clock-S.lastSelect<2 then setStatus("Waiting for selection"); return end
    if S.holdStart then setStatus("Validation: "..target.mode.." room ready (start held)"); return end
    if S.startAttempts>=CONFIG.MaxStartAttempts then
        setStatus("Start not confirmed: check unlocks or toggle active mode off/on"); return
    end
    if clock-S.lastStart>=CONFIG.StartRetry then
        lobbyNetwork:Publish("Room",{Action="Start"})
        S.startAttempts+=1; S.lastStart=clock
    end
    setStatus("Starting "..target.mode.." / waiting for teleport")
end
local function tickQueue()
    if window.unloaded then S.cleanup(); return end
    tickWebhook()
    local c=challengeState()
    local seconds=math.max(0,math.ceil(c.endsAt-c.now))
    timer:Set(string.format("%02d:%02d",math.floor(seconds/60),seconds%60))
    if inLobby() then tickLobby(c) else tickMatch(c) end
end
S.tick=tickQueue
S.save=save
task.spawn(function()
    while S.alive do
        local ok,err=pcall(tickQueue)
        if not ok then setStatus("Waiting / error: "..tostring(err):sub(1,150)); warn("[AG Queue] "..tostring(err)); task.wait(3) end
        task.wait(CONFIG.PollSeconds)
    end
end)
print("[AG Queue] Ready. Challenges > Raids > Story; Left Ctrl toggles UI.")
