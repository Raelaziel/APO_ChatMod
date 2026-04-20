local MOD_NAME = "WindroseChat"
local VERSION = "0.3.10-side-single-stable"

local CLIENT_COMMANDS = { "wrchat", "chat" }
local SERVER_COMMAND = "wrchat_send"
local MAX_MESSAGE_BYTES = 180
local MESSAGE_LIFETIME_SECONDS = 10.0
local DEDUPE_SECONDS = 1.0
local UI_MESSAGE_PREFIX = "[Chat]"
local ENABLE_CLIENT_OVERLAY = true
local MAX_OVERLAY_LINES = 80
local NATIVE_MULTILINE_VISIBLE_LINES = 1
local NATIVE_MULTILINE_REFRESH_DELAY_MS = 75
local NATIVE_OVERLAY_VISIBLE_SECONDS = 10
local NATIVE_LINE_SEPARATOR = " "

local okUEHelpers, UEHelpers = pcall(require, "UEHelpers")
if not okUEHelpers then
    UEHelpers = nil
end

local knownControllers = {}
local recentMessages = {}
local cachedNotificationManager = nil
local cachedSpawnNotificationManager = nil
local cachedMainNotificationManager = nil
local cachedMainNotificationWidgetClass = nil
local cachedKismetSystemLibrary = nil
local cachedClientRuntime = nil
local lastOverlayWarningAt = -1000.0
local clientMessageHookDebugCount = 0
local loggedOverlayBackend = nil
local nativeOverlayRefreshPending = false
local pendingNativeOverlayText = nil
local pendingNativeOverlayContext = nil
local getLocalPlayerController
local sendChatFromClient
local overlayLines = {}
local overlayFileWriteFailed = false
local serverLogWriteFailed = false

local function detectModRoot()
    local okInfo, info = pcall(function()
        return debug.getinfo(1, "S")
    end)
    if not okInfo or info == nil or type(info.source) ~= "string" then
        return nil
    end

    local source = info.source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end

    source = source:gsub("/", "\\")

    local scriptDirectory = source:match("^(.*)\\[^\\]+$")
    if scriptDirectory == nil then
        return nil
    end

    local modRoot = scriptDirectory:match("^(.*)\\Scripts$")
    if modRoot ~= nil and modRoot ~= "" then
        return modRoot
    end

    return scriptDirectory
end

local MOD_ROOT = detectModRoot()
local CHAT_OVERLAY_FILE = MOD_ROOT ~= nil
    and (MOD_ROOT .. "\\chat_overlay.txt")
    or "ue4ss/Mods/WindroseChat/chat_overlay.txt"
local CHAT_SERVER_LOG_FILE = MOD_ROOT ~= nil
    and (MOD_ROOT .. "\\chat_server.log")
    or "ue4ss/Mods/WindroseChat/chat_server.log"

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function unwrap(value)
    if value == nil then
        return nil
    end

    if type(value) == "userdata" or type(value) == "table" then
        local okLower, lowerValue = pcall(function()
            return value:get()
        end)
        if okLower and lowerValue ~= nil then
            return lowerValue
        end

        local okUpper, upperValue = pcall(function()
            return value:Get()
        end)
        if okUpper and upperValue ~= nil then
            return upperValue
        end
    end

    return value
end

local function isValid(object)
    if object == nil then
        return false
    end

    local ok, result = pcall(function()
        return object:IsValid()
    end)

    return ok and result == true
end

local function toText(value)
    value = unwrap(value)
    if value == nil then
        return ""
    end

    if type(value) == "string" then
        return value
    end

    local okToString, asString = pcall(function()
        return value:ToString()
    end)
    if okToString and asString ~= nil then
        return tostring(asString)
    end

    return tostring(value)
end

local function objectKey(object)
    if not isValid(object) then
        return "nil"
    end

    local okAddress, address = pcall(function()
        return object:GetAddress()
    end)
    if okAddress and address ~= nil then
        return tostring(address)
    end

    local okName, name = pcall(function()
        return object:GetFullName()
    end)
    if okName and name ~= nil then
        return tostring(name)
    end

    return tostring(object)
end

local function objectName(object)
    if not isValid(object) then
        return ""
    end

    local okName, name = pcall(function()
        return object:GetName()
    end)
    if okName and name ~= nil then
        return tostring(name)
    end

    local okFullName, fullName = pcall(function()
        return object:GetFullName()
    end)
    if okFullName and fullName ~= nil then
        return tostring(fullName)
    end

    return tostring(object)
end

local function isRuntimeObject(object)
    local name = objectName(object)
    if name == "" then
        return false
    end

    return not name:find("Default__", 1, true)
end

local function isLocalPlayerController(controller)
    if not isValid(controller) then
        return false
    end

    local ok, result = pcall(function()
        return controller:IsLocalPlayerController()
    end)

    return ok and result == true
end

local function trim(text)
    text = tostring(text or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function cleanMessage(text)
    text = trim(text)
    text = text:gsub("[\r\n\t]", " ")
    text = text:gsub("%s%s+", " ")

    if #text > MAX_MESSAGE_BYTES then
        text = text:sub(1, MAX_MESSAGE_BYTES)
    end

    return trim(text)
end

local function commandHead(text)
    local head = trim(text):match("^(%S+)")
    if head == nil then
        return ""
    end
    return string.lower(head)
end

local function stripCommand(text)
    local _, finish = trim(text):find("^%S+")
    if finish == nil then
        return ""
    end
    return cleanMessage(trim(text):sub(finish + 1))
end

local function getChatType()
    if UEHelpers ~= nil and type(UEHelpers.FindOrAddFName) == "function" then
        local ok, name = pcall(function()
            return UEHelpers.FindOrAddFName("Chat")
        end)
        if ok and name ~= nil then
            return name
        end
    end

    return "Chat"
end

local function findFirstValid(classNames)
    for _, className in ipairs(classNames) do
        local okAll, objects = pcall(FindAllOf, className)
        if okAll and objects ~= nil then
            for _, object in ipairs(objects) do
                if isValid(object) and isRuntimeObject(object) then
                    return object
                end
            end
        end

        local ok, object = pcall(FindFirstOf, className)
        if ok and isValid(object) and isRuntimeObject(object) then
            return object
        end
    end

    return nil
end

local function safeStaticFind(path)
    if type(StaticFindObject) ~= "function" then
        return nil
    end

    local ok, object = pcall(StaticFindObject, path)
    if ok and isValid(object) then
        return object
    end

    return nil
end

local function getKismetSystemLibrary()
    if isValid(cachedKismetSystemLibrary) then
        return cachedKismetSystemLibrary
    end

    if UEHelpers ~= nil and type(UEHelpers.GetKismetSystemLibrary) == "function" then
        local ok, object = pcall(function()
            return UEHelpers.GetKismetSystemLibrary()
        end)
        if ok and isValid(object) then
            cachedKismetSystemLibrary = object
            return cachedKismetSystemLibrary
        end
    end

    cachedKismetSystemLibrary = safeStaticFind("/Script/Engine.Default__KismetSystemLibrary")
    return cachedKismetSystemLibrary
end

local function isClientRuntime()
    if cachedClientRuntime == true then
        return true
    end

    if UEHelpers ~= nil and type(UEHelpers.GetGameViewportClient) == "function" then
        local okViewport, viewport = pcall(function()
            return UEHelpers.GetGameViewportClient()
        end)
        if okViewport and isValid(viewport) then
            cachedClientRuntime = true
            return true
        end
    end

    local okFind, viewport = pcall(FindFirstOf, "GameViewportClient")
    if okFind and isValid(viewport) then
        cachedClientRuntime = true
        return true
    end

    return false
end

local function enableScreenDebugMessages()
    local ok, engine = pcall(FindFirstOf, "Engine")
    if not ok or not isValid(engine) then
        return
    end

    pcall(function()
        engine.bEnableOnScreenDebugMessages = true
    end)
    pcall(function()
        engine.bEnableOnScreenDebugMessagesDisplay = true
    end)
end

local function printOnScreen(text, worldContext, keyName, lifetimeSeconds)
    local kismet = getKismetSystemLibrary()
    if not isValid(kismet) then
        return false
    end

    worldContext = unwrap(worldContext)
    if not isValid(worldContext) then
        worldContext = getLocalPlayerController()
    end
    if not isValid(worldContext) then
        return false
    end

    enableScreenDebugMessages()

    local key = keyName or "WindroseChat"
    if UEHelpers ~= nil and type(UEHelpers.FindOrAddFName) == "function" then
        local okName, name = pcall(function()
            return UEHelpers.FindOrAddFName(keyName or "WindroseChat")
        end)
        if okName and name ~= nil then
            key = name
        end
    end

    lifetimeSeconds = lifetimeSeconds or MESSAGE_LIFETIME_SECONDS

    local ok = pcall(function()
        return kismet:PrintString(worldContext, text, true, false, FLinearColor(0.35, 0.85, 1.0, 1.0), lifetimeSeconds, key)
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        return kismet:PrintString(worldContext, text, true, false, { R = 0.35, G = 0.85, B = 1.0, A = 1.0 }, lifetimeSeconds, key)
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        return kismet:PrintString(worldContext, text, true, false, nil, lifetimeSeconds, key)
    end)

    return ok
end

local function getPlayerConnectedNotificationManager()
    if isValid(cachedNotificationManager) then
        return cachedNotificationManager
    end

    cachedNotificationManager = findFirstValid({
        "BP_PlayerConnectedNotification_Manager_SC_C",
        "BP_PlayerConnectedNotification_Manager_SC",
    })

    return cachedNotificationManager
end

local function getSpawnNotificationManager()
    if isValid(cachedSpawnNotificationManager) then
        return cachedSpawnNotificationManager
    end

    cachedSpawnNotificationManager = findFirstValid({
        "BP_SpawnPointNotificationManager_C",
        "BP_SpawnPointNotificationManager",
    })

    return cachedSpawnNotificationManager
end

local function getMainNotificationManager()
    if isValid(cachedMainNotificationManager) then
        return cachedMainNotificationManager
    end

    cachedMainNotificationManager = findFirstValid({
        "BP_MainNotifications_Manager_SC_C",
        "BP_MainNotifications_Manager_SC",
    })

    return cachedMainNotificationManager
end

local function tryLoadObject(path)
    local object = safeStaticFind(path)
    if isValid(object) then
        return object
    end

    if type(LoadAsset) == "function" then
        local okLoad, loadedObject = pcall(LoadAsset, path)
        if okLoad and isValid(loadedObject) then
            return loadedObject
        end
    end

    return nil
end

local function getMainNotificationWidgetClass()
    if isValid(cachedMainNotificationWidgetClass) then
        return cachedMainNotificationWidgetClass
    end

    cachedMainNotificationWidgetClass = tryLoadObject("/Game/UI/HUD/Notifications/WBP_MainNotification_CustomText.WBP_MainNotification_CustomText_C")
        or tryLoadObject("WidgetBlueprintGeneratedClass'/Game/UI/HUD/Notifications/WBP_MainNotification_CustomText.WBP_MainNotification_CustomText_C'")
        or tryLoadObject("/Game/UI/HUD/Notifications/WBP_MainNotification_CustomText")

    return cachedMainNotificationWidgetClass
end

local function shouldShowChatOverlay(text)
    text = trim(toText(text))
    return text:sub(1, #UI_MESSAGE_PREFIX) == UI_MESSAGE_PREFIX
end

local function appendServerChatLog(text)
    if isClientRuntime() then
        return false
    end

    local file = io.open(CHAT_SERVER_LOG_FILE, "a")
    if file == nil then
        if not serverLogWriteFailed then
            serverLogWriteFailed = true
            log("server chat log write failed: " .. tostring(CHAT_SERVER_LOG_FILE))
        end
        return false
    end

    serverLogWriteFailed = false
    file:write(os.date("%Y-%m-%d %H:%M:%S"), "\t", tostring(text), "\n")
    file:close()
    return true
end

local function writeOverlayFile()
    local file = io.open(CHAT_OVERLAY_FILE, "w")
    if file == nil then
        if not overlayFileWriteFailed then
            overlayFileWriteFailed = true
            log("overlay file write failed: " .. tostring(CHAT_OVERLAY_FILE))
        end
        return false
    end

    overlayFileWriteFailed = false

    for _, entry in ipairs(overlayLines) do
        file:write(tostring(entry.time), "\t", entry.text, "\n")
    end

    file:close()
    return true
end

local function recordChatOverlay(text)
    if not isClientRuntime() then
        return false
    end

    text = cleanMessage(text)
    if text == "" or not shouldShowChatOverlay(text) then
        return false
    end

    text = text:gsub("\t", " ")
    overlayLines[#overlayLines + 1] = {
        time = os.time(),
        text = text,
    }

    while #overlayLines > MAX_OVERLAY_LINES do
        table.remove(overlayLines, 1)
    end

    return writeOverlayFile()
end

local function makeNotificationText(text)
    local okFText, ftextValue = pcall(function()
        return FText(text)
    end)
    if okFText and ftextValue ~= nil then
        return ftextValue
    end
    return text
end

local function normalizeOverlayDisplayText(text)
    text = toText(text)
    if text == "" then
        return ""
    end

    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")

    local lines = {}
    for rawLine in text:gmatch("([^\n]+)") do
        local cleanLine = cleanMessage(rawLine)
        if cleanLine ~= "" then
            lines[#lines + 1] = cleanLine
        end
    end

    return table.concat(lines, NATIVE_LINE_SEPARATOR)
end

local function isOverlayLineStillVisible(entry, nowTime)
    if entry == nil or type(entry.time) ~= "number" then
        return false
    end

    nowTime = nowTime or os.time()
    return (nowTime - entry.time) < NATIVE_OVERLAY_VISIBLE_SECONDS
end

local function buildNativeMultilineText()
    if #overlayLines == 0 then
        return ""
    end

    local parts = {}
    local nowTime = os.time()
    local visibleEntries = {}

    for index = 1, #overlayLines do
        local entry = overlayLines[index]
        if isOverlayLineStillVisible(entry, nowTime) and type(entry.text) == "string" and entry.text ~= "" then
            visibleEntries[#visibleEntries + 1] = entry.text
        end
    end

    local startIndex = math.max(1, #visibleEntries - NATIVE_MULTILINE_VISIBLE_LINES + 1)
    for index = startIndex, #visibleEntries do
        parts[#parts + 1] = visibleEntries[index]
    end

    return table.concat(parts, NATIVE_LINE_SEPARATOR)
end

local function getMountedSideNotificationWidget()
    local deployer = nil

    local manager = getPlayerConnectedNotificationManager()
    if isValid(manager) then
        pcall(function()
            deployer = manager.NotificationDeployer
        end)
    end

    if not isValid(deployer) then
        local spawnManager = getSpawnNotificationManager()
        if isValid(spawnManager) then
            pcall(function()
                deployer = spawnManager.NotificationDeployer
            end)
        end
    end

    if not isValid(deployer) then
        return nil
    end

    local mounted = nil
    local okMounted = pcall(function()
        mounted = deployer.MountedNotification
    end)

    if okMounted and isValid(mounted) then
        return mounted
    end

    return nil
end

local function tryUpdateMountedNativeSideNotification(text)
    local mounted = getMountedSideNotificationWidget()
    if not isValid(mounted) then
        return false
    end

    local icon = nil
    pcall(function()
        icon = mounted.Icon
    end)

    local errorState = false
    pcall(function()
        errorState = mounted.bErrorState == true
    end)

    local notificationText = makeNotificationText(text)

    local ok = pcall(function()
        mounted:SetData(notificationText, icon, errorState)
    end)
    if ok then
        pcall(function()
            mounted:Draw()
        end)
        return true
    end

    ok = pcall(function()
        mounted.ShownText = notificationText
    end)
    if ok then
        pcall(function()
            mounted:Draw()
        end)
        return true
    end

    return false
end

local function tryPrimeNativeSideNotification(text)
    if tryUpdateMountedNativeSideNotification(text) then
        return true
    end

    local manager = getPlayerConnectedNotificationManager()
    if isValid(manager) then
        local ok = pcall(function()
            manager:ShowNotification(makeNotificationText(text))
        end)
        if ok then
            return true
        end

        cachedNotificationManager = nil
    end

    local spawnManager = getSpawnNotificationManager()
    if isValid(spawnManager) then
        local ok = pcall(function()
            spawnManager:ShowNotification(makeNotificationText(text), false)
        end)
        if ok then
            return true
        end

        cachedSpawnNotificationManager = nil
    end

    return false
end

local function tryShowMainTextNotification(text)
    local manager = getMainNotificationManager()
    if not isValid(manager) then
        return false
    end

    local widgetClass = getMainNotificationWidgetClass()
    if not isValid(widgetClass) then
        return false
    end

    local ok = pcall(function()
        manager:ShowNotification(
            widgetClass,
            makeNotificationText(text),
            makeNotificationText(""),
            {},
            0,
            nil,
            0
        )
    end)

    return ok
end

local function flushNativeMultilineOverlay()
    nativeOverlayRefreshPending = false

    local text = cleanMessage(pendingNativeOverlayText)
    local worldContext = pendingNativeOverlayContext

    pendingNativeOverlayText = nil
    pendingNativeOverlayContext = nil

    if text == "" then
        return false
    end

    local shown = tryPrimeNativeSideNotification(text)

    if shown then
        if loggedOverlayBackend ~= "native-side-notification-single" then
            loggedOverlayBackend = "native-side-notification-single"
            log("client overlay active via single-line native side notification")
        end
        return true
    end

    if printOnScreen(text, worldContext) then
        if loggedOverlayBackend ~= "print-string-fallback" then
            loggedOverlayBackend = "print-string-fallback"
            log("client overlay active via PrintString fallback")
        end
        return true
    end

    local now = os.clock()
    if now - lastOverlayWarningAt > 10.0 then
        lastOverlayWarningAt = now
        log("chat overlay unavailable; message stayed in ClientMessage console path")
    end

    return false
end

local function scheduleNativeMultilineOverlay(text, worldContext)
    pendingNativeOverlayText = text
    pendingNativeOverlayContext = worldContext

    if nativeOverlayRefreshPending then
        return true
    end

    nativeOverlayRefreshPending = true

    if type(ExecuteInGameThreadWithDelay) == "function" then
        ExecuteInGameThreadWithDelay(NATIVE_MULTILINE_REFRESH_DELAY_MS, function()
            flushNativeMultilineOverlay()
        end)
        return true
    end

    return flushNativeMultilineOverlay()
end

local function showChatOverlay(text, worldContext)
    recordChatOverlay(text)

    if ENABLE_CLIENT_OVERLAY ~= true then
        return false
    end

    text = cleanMessage(text)
    if text == "" or not shouldShowChatOverlay(text) then
        return false
    end

    return scheduleNativeMultilineOverlay(text, worldContext)
end

local function sendClientMessage(controller, text, lifetime)
    if not isValid(controller) then
        return false
    end

    local isLocalController = isLocalPlayerController(controller)

    local chatType = getChatType()
    local ok = pcall(function()
        controller:ClientMessage(text, chatType, lifetime or MESSAGE_LIFETIME_SECONDS)
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        controller:ClientMessage(text, "Chat", lifetime or MESSAGE_LIFETIME_SECONDS)
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        controller:ClientMessage(text)
    end)

    if ok then
        return true
    end

    if isLocalController then
        return showChatOverlay(text, controller)
    end

    return false
end

function getLocalPlayerController()
    if UEHelpers ~= nil and type(UEHelpers.GetPlayerController) == "function" then
        local ok, controller = pcall(function()
            return UEHelpers.GetPlayerController()
        end)
        if ok and isValid(controller) then
            return controller
        end
    end

    local okFirst, controller = pcall(FindFirstOf, "PlayerController")
    if okFirst and isValid(controller) then
        return controller
    end

    return nil
end

local function isPlayerController(controller)
    if not isValid(controller) then
        return false
    end

    local ok, result = pcall(function()
        return controller:IsPlayerController()
    end)
    if ok and result == true then
        return true
    end

    ok, result = pcall(function()
        return controller:IsLocalPlayerController()
    end)
    return ok and result == true
end

local function addController(controller)
    controller = unwrap(controller)
    if not isPlayerController(controller) then
        return
    end

    knownControllers[objectKey(controller)] = controller
end

local function removeController(controller)
    controller = unwrap(controller)
    if controller == nil then
        return
    end

    knownControllers[objectKey(controller)] = nil
end

local function collectControllers()
    local controllers = {}
    local seen = {}

    for key, controller in pairs(knownControllers) do
        if isPlayerController(controller) then
            controllers[#controllers + 1] = controller
            seen[objectKey(controller)] = true
        else
            knownControllers[key] = nil
        end
    end

    local okAll, allControllers = pcall(FindAllOf, "PlayerController")
    if okAll and allControllers ~= nil then
        for _, controller in ipairs(allControllers) do
            if isPlayerController(controller) then
                local key = objectKey(controller)
                knownControllers[key] = controller
                if not seen[key] then
                    controllers[#controllers + 1] = controller
                    seen[key] = true
                end
            end
        end
    end

    return controllers
end

local function playerName(controller)
    if not isValid(controller) then
        return "Player"
    end

    local okPlayerState, playerState = pcall(function()
        return controller.PlayerState
    end)
    if okPlayerState and isValid(playerState) then
        local okName, name = pcall(function()
            return playerState:GetPlayerName()
        end)
        name = cleanMessage(toText(okName and name or nil))
        if name ~= "" then
            return name
        end
    end

    local okControllerName, controllerName = pcall(function()
        return controller:GetName()
    end)
    controllerName = cleanMessage(toText(okControllerName and controllerName or nil))
    if controllerName ~= "" then
        return controllerName
    end

    return "Player"
end

local function isDuplicate(sender, message)
    local now = os.clock()
    local key = objectKey(sender) .. "\n" .. message
    local last = recentMessages[key]

    recentMessages[key] = now

    for cachedKey, timestamp in pairs(recentMessages) do
        if now - timestamp > 10.0 then
            recentMessages[cachedKey] = nil
        end
    end

    return last ~= nil and now - last < DEDUPE_SECONDS
end

local function broadcastChat(sender, message)
    message = cleanMessage(message)
    if message == "" then
        return false
    end

    if isDuplicate(sender, message) then
        return true
    end

    addController(sender)

    local line = string.format("[Chat] %s: %s", playerName(sender), message)
    local count = 0

    appendServerChatLog(line)

    for _, controller in ipairs(collectControllers()) do
        if sendClientMessage(controller, line, MESSAGE_LIFETIME_SECONDS) then
            count = count + 1
        end
    end

    log(string.format("broadcast from %s to %d controller(s): %s", playerName(sender), count, message))
    return count > 0
end

local function parseServerCommand(commandText)
    commandText = trim(toText(commandText))
    if commandHead(commandText) ~= SERVER_COMMAND then
        return nil
    end

    return stripCommand(commandText)
end

local function handleServerCommand(sender, commandText)
    local message = parseServerCommand(commandText)
    if message == nil then
        return false
    end

    log("server received chat command")

    return broadcastChat(sender, message)
end

sendChatFromClient = function(fullCommand)
    local message = stripCommand(fullCommand)
    if message == "" then
        local controller = getLocalPlayerController()
        sendClientMessage(controller, "[Chat] Usage: chat message", 5.0)
        log("empty client chat command")
        return true
    end

    local controller = getLocalPlayerController()
    if not isValid(controller) then
        log("cannot send chat: local player controller not found")
        return true
    end

    local serverCommand = SERVER_COMMAND .. " " .. message
    local ok = pcall(function()
        controller:ServerExecRPC(serverCommand)
    end)
    if not ok then
        ok = pcall(function()
            controller:ServerExec(serverCommand)
        end)
    end

    if not ok then
        sendClientMessage(controller, "[Chat] Could not send message to server.", 5.0)
        log("ServerExec failed")
    else
        log("chat command sent to server via RPC")
    end

    return true
end

local function registerHookSafe(path, callback)
    local ok, err = pcall(function()
        RegisterHook(path, callback)
    end)

    if ok then
        log("hook active: " .. path)
    else
        log("hook unavailable: " .. path .. " / " .. tostring(err))
    end
end

local function registerConsoleCommand(command)
    local ok, err = pcall(function()
        RegisterConsoleCommandGlobalHandler(command, function(fullCommand)
            return sendChatFromClient(fullCommand)
        end)
    end)

    if ok then
        log("console command active: " .. command)
    else
        log("console command unavailable: " .. command .. " / " .. tostring(err))
    end
end

for _, command in ipairs(CLIENT_COMMANDS) do
    registerConsoleCommand(command)
end

registerHookSafe("/Script/Engine.GameModeBase:K2_PostLogin", function(_, newPlayer)
    local controller = unwrap(newPlayer)
    addController(controller)
    if isValid(controller) then
        sendClientMessage(controller, "[Chat] Use console: chat your message", 8.0)
    end
end)

registerHookSafe("/Script/Engine.GameModeBase:K2_OnLogout", function(_, exitingController)
    removeController(exitingController)
end)

registerHookSafe("/Script/Engine.PlayerController:ClientMessage", function(context, messageText)
    local text = toText(messageText)
    if clientMessageHookDebugCount < 3 and shouldShowChatOverlay(text) then
        clientMessageHookDebugCount = clientMessageHookDebugCount + 1
        log("ClientMessage hook saw chat line")
    end

    showChatOverlay(text, unwrap(context))
end)

registerHookSafe("/Script/Engine.PlayerController:ServerExec", function(context, commandText)
    if isClientRuntime() then
        return
    end

    local sender = unwrap(context)
    handleServerCommand(sender, commandText)
end)

registerHookSafe("/Script/Engine.PlayerController:ServerExecRPC", function(context, commandText)
    if isClientRuntime() then
        return
    end

    local sender = unwrap(context)
    handleServerCommand(sender, commandText)
end)

if type(RegisterProcessConsoleExecPreHook) == "function" then
    pcall(function()
        RegisterProcessConsoleExecPreHook(function(context, commandText, _, _, executor)
            if isClientRuntime() then
                return nil
            end

            local sender = unwrap(executor)
            if not isValid(sender) then
                sender = unwrap(context)
            end

            if handleServerCommand(sender, commandText) then
                return true
            end

            return nil
        end)
    end)
end

log("overlay bridge file: " .. tostring(CHAT_OVERLAY_FILE))
log("loaded " .. VERSION)
