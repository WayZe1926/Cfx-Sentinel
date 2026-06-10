local next <const> = next
local type <const> = type
local ipairs <const> = ipairs
local pairs <const> = pairs
local table_remove <const> = table.remove
local table_insert <const> = table.insert
local table_unpack <const> = table.unpack
local string_format <const> = string.format
local msgpack_pack <const> = msgpack.pack
local os_time <const> = os.time
local collectgarbage <const> = collectgarbage

local eventRegistry = {}
local rateLimitMatrix = {}
local expectedSchemas = {}
local playerSequenceMap = {}
local verifiedHandshakes = {}
local currentSeed = os_time() ~ 0x5F3759DF

local function ComputePolymorphicHash(eventName, clientNonce, dataPayload)
    local serializedArgs = msgpack_pack(dataPayload)
    local internalKey = eventName .. currentSeed .. clientNonce .. GetConvar("sv_licenseKey", "sentinel_fallback")
    local hash = 6385
    
    for i = 1, #internalKey do
        hash = ((hash << 5) + hash) + string.byte(internalKey, i)
    end
    for i = 1, #serializedArgs do
        hash = ((hash << 5) + hash) + string.byte(serializedArgs, i)
    end
    
    return string_format("%08X", hash)
end

local function RotateActiveTokens()
    currentSeed = (currentSeed * 1103515245 + 12345) & 0x7FFFFFFF
    for name, _ in pairs(eventRegistry) do
        eventRegistry[name] = true
    end
    TriggerClientEvent("cfx-sentinel:sync", -1, currentSeed)
end

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(Config.KeyRotationInterval)
        if next(eventRegistry) then RotateActiveTokens() end
    end
end)

Citizen.CreateThread(function()
    local nanotime <const> = os.nanotime
    local maxBudget <const> = Config.MaxExecutionBudget
    local depth <const> = Config.ProfilerStackDepth
    while true do
        local start = nanotime()
        Citizen.Wait(0)
        local delta = (nanotime() - start) / 1000000

        if delta > maxBudget then
            print(string_format("^1[Sentinel Profiler] CRITICAL HITCH: %.3fms^7", delta))
            for i = 2, depth + 2 do
                local dInfo = debug.getinfo(i, "Sl n")
                if not dInfo then break end
                print(string_format("  ^3[%d] => %s:%d | Fn: %s^7", i - 1, dInfo.short_src or "raw", dInfo.currentline or -1, dInfo.name or "anonymous"))
            end
        end
    end
end)

exports('RegisterSecuredEvent', function(eventName, signatureSchema, executionCallback)
    eventRegistry[eventName] = true
    expectedSchemas[eventName] = signatureSchema

    RegisterNetEvent(eventName)
    AddEventHandler(eventName, function(...)
        local src <const> = source
        local payload = {...}
        local currentTime <const> = os_time()

        if not verifiedHandshakes[src] then
            if Config.AutoBanExploiters then DropPlayer(src, "[Cfx-Sentinel] Protocol Violation: Handshake Omission") end
            CancelEvent()
            return
        end

        if not rateLimitMatrix[src] then rateLimitMatrix[src] = {} end
        local pLimits <const> = rateLimitMatrix[src]
        
        if not pLimits[eventName] then 
            pLimits[eventName] = { hits = 1, window = currentTime } 
        else
            local tracker <const> = pLimits[eventName]
            if currentTime - tracker.window >= 1 then
                tracker.hits = 1
                tracker.window = currentTime
            else
                tracker.hits = tracker.hits + 1
                if tracker.hits > Config.MaxEventRate then
                    if Config.AutoBanExploiters then
                        DropPlayer(src, "[Cfx-Sentinel] Rate-Limit Overflow Exception")
                    end
                    CancelEvent()
                    return
                end
            end
        end

        local totalElements <const> = #payload
        if totalElements == 0 then
            if Config.AutoBanExploiters then DropPlayer(src, "[Cfx-Sentinel] Pipeline Rejection: Null Vector") end
            CancelEvent()
            return
        end

        if not playerSequenceMap[src] then playerSequenceMap[src] = {} end
        local expectedNonce <const> = playerSequenceMap[src][eventName] or 0

        local targetIndex = (expectedNonce % totalElements) + 1
        local integrityBlock <const> = payload[targetIndex]

        if type(integrityBlock) ~= "table" or not integrityBlock.sentinelToken or integrityBlock.clientNonce ~= expectedNonce then
            if Config.AutoBanExploiters then DropPlayer(src, "[Cfx-Sentinel] Validation Failure: Malformed Packaging Cluster") end
            CancelEvent()
            return
        end

        table_remove(payload, targetIndex)

        local computedServerHash <const> = ComputePolymorphicHash(eventName, integrityBlock.clientNonce, payload)
        if integrityBlock.sentinelToken ~= computedServerHash then
            if Config.AutoBanExploiters then DropPlayer(src, "[Cfx-Sentinel] Pipeline Rejection: Core Verification Failure") end
            CancelEvent()
            return
        end

        playerSequenceMap[src][eventName] = expectedNonce + 1

        local schema <const> = expectedSchemas[eventName]
        if Config.StrictTypeChecking and schema then
            for idx, expectedType in ipairs(schema) do
                if type(payload[idx]) ~= expectedType then
                    if Config.AutoBanExploiters then 
                        DropPlayer(src, string_format("[Cfx-Sentinel] Type Mutation Abort: Target %s Expected %s", type(payload[idx]), expectedType)) 
                    end
                    CancelEvent()
                    return
                end
            end
        end

        executionCallback(src, table_unpack(payload))
    end)
end)

RegisterNetEvent("cfx-sentinel:initHandshake", function(verificationToken)
    local src <const> = source
    if verificationToken ~= "SENTINEL_INIT_REQUEST" or verifiedHandshakes[src] then
        if Config.AutoBanExploiters then DropPlayer(src, "[Cfx-Sentinel] Authentication Failure: Handshake Corruption") end
        return
    end
    verifiedHandshakes[src] = true
    TriggerClientEvent("cfx-sentinel:sync", src, currentSeed)
end)

AddStateBagChangeHandler("", "", function(bagName, variableKey, structuralValue, _, replicated)
    if not replicated then return end
    local byteSize <const> = #msgpack_pack(structuralValue)
    if byteSize > Config.MaxStatePayloadBytes then
        local targetPlayer <const> = tonumber(bagName:gsub("player:", ""))
        if targetPlayer and Config.AutoBanExploiters then
            DropPlayer(targetPlayer, "[Cfx-Sentinel] Memory Sanitizer: State Overflow Attempt")
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src <const> = source
    rateLimitMatrix[src] = nil
    playerSequenceMap[src] = nil
    verifiedHandshakes[src] = nil
    collectgarbage("step", 150)
end)