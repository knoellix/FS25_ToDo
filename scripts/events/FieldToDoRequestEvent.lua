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

    local userId = nil
    if connection.getUserId ~= nil then
        local ok, result = pcall(connection.getUserId, connection)
        if ok then
            userId = result
        end
    end

    FieldToDoSync.handleRequest(self.op, self.payload, userId, connection)
end
