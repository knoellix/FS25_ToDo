--[[
    FieldToDoNotifyEvent.lua
    Server -> clients: "this op was applied, mirror it locally". Client-only run().
]]

FieldToDoNotifyEvent = {}
local FieldToDoNotifyEvent_mt = Class(FieldToDoNotifyEvent, Event)
InitEventClass(FieldToDoNotifyEvent, "FieldToDoNotifyEvent")

---@return FieldToDoNotifyEvent
function FieldToDoNotifyEvent.emptyNew()
    return Event.new(FieldToDoNotifyEvent_mt)
end

---@param op number
---@param payload table|nil
---@return FieldToDoNotifyEvent
function FieldToDoNotifyEvent.new(op, payload)
    local self = FieldToDoNotifyEvent.emptyNew()
    self.op = op
    self.payload = payload or {}
    return self
end

function FieldToDoNotifyEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, FieldToDoSync.SCHEMA_VERSION)
    streamWriteUInt8(streamId, self.op)
    FieldToDoSync.writePayload(streamId, self.op, self.payload)
end

function FieldToDoNotifyEvent:readStream(streamId, connection)
    local version = streamReadUInt8(streamId)
    if FieldToDoSync.isCompatibleSchemaVersion ~= nil
        and not FieldToDoSync.isCompatibleSchemaVersion(version) then
        if FieldToDoLog ~= nil then
            FieldToDoLog.warning(
                "FieldToDoNotifyEvent: schema mismatch (got %s want %s)",
                tostring(version),
                tostring(FieldToDoSync.SCHEMA_VERSION)
            )
        end
        return
    end
    self.op = streamReadUInt8(streamId)
    self.payload = FieldToDoSync.readPayload(streamId, self.op)
    self:run(connection)
end

function FieldToDoNotifyEvent:run(connection)
    -- Listen/dedicated server already applied in handleRequest — never re-apply from broadcast.
    if g_currentMission ~= nil
        and g_currentMission.getIsServer ~= nil
        and g_currentMission:getIsServer() == true then
        return
    end

    if connection ~= nil and not connection:getIsServer() then
        -- Notify only travels server -> client.
        return
    end

    FieldToDoSync.applyNotify(self.op, self.payload)
end
