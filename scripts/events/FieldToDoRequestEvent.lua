--[[
    FieldToDoRequestEvent.lua
    Client -> server: "please apply this to-do op". Server-only run() (see FieldToDoSync).
]]

FieldToDoRequestEvent = {}
local FieldToDoRequestEvent_mt = Class(FieldToDoRequestEvent, Event)
InitEventClass(FieldToDoRequestEvent, "FieldToDoRequestEvent")

---@return FieldToDoRequestEvent
function FieldToDoRequestEvent.emptyNew()
    return Event.new(FieldToDoRequestEvent_mt)
end

---@param op number
---@param payload table|nil
---@return FieldToDoRequestEvent
function FieldToDoRequestEvent.new(op, payload)
    local self = FieldToDoRequestEvent.emptyNew()
    self.op = op
    self.payload = payload or {}
    return self
end

function FieldToDoRequestEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, FieldToDoSync.SCHEMA_VERSION)
    streamWriteUInt8(streamId, self.op)
    FieldToDoSync.writePayload(streamId, self.op, self.payload)
end

function FieldToDoRequestEvent:readStream(streamId, connection)
    local version = streamReadUInt8(streamId)
    if FieldToDoSync.isCompatibleSchemaVersion ~= nil
        and not FieldToDoSync.isCompatibleSchemaVersion(version) then
        if FieldToDoLog ~= nil then
            FieldToDoLog.warning(
                "FieldToDoRequestEvent: schema mismatch (got %s want %s)",
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

function FieldToDoRequestEvent:run(connection)
    if connection == nil or connection:getIsServer() then
        -- Requests only travel client -> server; a server-side connection here means we are
        -- the client and somehow received our own request type back. Ignore.
        return
    end

    local userId = FieldToDoSync.resolveUserIdFromConnection(connection)
    FieldToDoSync.handleRequest(self.op, self.payload, userId, connection)
end
