local localSeed = 0
local sequenceTracker = {}
local nuiThrottleMap = {}
local GetGameTimer <const> = GetGameTimer
local debug_getinfo <const> = debug.getinfo
local string_find <const> = string.find
local debug_traceback <const> = debug.traceback
local string_format <const> = string.format
local msgpack_pack <const> = msgpack.pack
local table_insert <const> = table.insert

local rawTriggerServerEvent <const> = TriggerServerEvent
local rawRegisterNUICallback <const> = RegisterNUICallback

Citizen.CreateThread(function()
    while not NetworkIsSessionActive() do Citizen.Wait(0) end
    rawTriggerServerEvent("cfx-sentinel:initHandshake", "SENTINEL_INIT_REQUEST")
end)

RegisterNetEvent("cfx-sentinel:sync", function(synchronizedSeed)
    localSeed = synchronizedSeed
end)

exports('TriggerSecuredServerEvent', function(eventName, ...)
    local payload = {...}
    if not sequenceTracker[eventName] then sequenceTracker[eventName] = 0 end
    local activeNonce <const> = sequenceTracker[eventName]
    
    local dynamicToken <const> = string_format("%08X", (function()
        local serializedArgs = msgpack_pack(payload)
        local internalKey = eventName .. localSeed .. activeNonce .. "sentinel_fallback"
        local hash = 6385
        
        for i = 1, #internalKey do
            hash = ((hash << 5) + hash) + string.byte(internalKey, i)
        end
        for i = 1, #serializedArgs do
            hash = ((hash << 5) + hash) + string.byte(serializedArgs, i)
        end
        return hash
    end)())

    local packagingCluster = { 
        sentinelToken = dynamicToken,
        clientNonce = activeNonce
    }
    
    local totalElements = #payload
    local targetIndex = (activeNonce % (totalElements + 1)) + 1
    table_insert(payload, targetIndex, packagingCluster)
    
    sequenceTracker[eventName] = activeNonce + 1
    rawTriggerServerEvent(eventName, table_unpack(payload))
end)

TriggerServerEvent = function(eventName, ...)
    if eventName ~= "cfx-sentinel:initHandshake" and not string_find(eventName, "sentinel") then
        local trace <const> = debug_traceback()
        if not string_find(trace, "client/engine.lua") and not string_find(trace, "exports") then
            return
        end
    end
    rawTriggerServerEvent(eventName, ...)
end

RegisterNUICallback = function(callbackName, executionHandler)
    rawRegisterNUICallback(callbackName, function(payloadData, resolveCallback)
        local timeNow <const> = GetGameTimer()
        if not nuiThrottleMap[callbackName] then 
            nuiThrottleMap[callbackName] = { counter = 1, timeline = timeNow } 
        else
            local tracker <const> = nuiThrottleMap[callbackName]
            if timeNow - tracker.timeline < 1000 then
                tracker.counter = tracker.counter + 1
                if tracker.counter > Config.MaxNuiCallbackRate then
                    resolveCallback({ status = "rejected", message = "Telemetry flood control active" })
                    return
                end
            else
                tracker.counter = 1
                tracker.timeline = timeNow
            end
        end
        executionHandler(payloadData, resolveCallback)
    end)
end

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(2500)
        
        local validationStatus, runtimeOutput = pcall(function()
            return debug_getinfo(TriggerServerEvent)
        end)
        
        if not validationStatus or (runtimeOutput and runtimeOutput.what ~= "C") then
            rawTriggerServerEvent("cfx-sentinel:tamperTelemetry", "TriggerServerEvent_Detour")
            ForceCrashPool()
        end
        
        local signatureStatus, signatureOutput = pcall(function()
            return debug_getinfo(rawTriggerServerEvent)
        end)
        
        if not signatureStatus or (signatureOutput and signatureOutput.what ~= "C") then
            rawTriggerServerEvent("cfx-sentinel:tamperTelemetry", "RawTriggerServerEvent_Detour")
            ForceCrashPool()
        end
        
        if type(_G.pcall) ~= "function" or type(_G.debug.getinfo) ~= "function" then
            ForceCrashPool()
        end
    end
end)

function ForceCrashPool()
    local crash <const> = nil
    local execution = crash.trigger
end