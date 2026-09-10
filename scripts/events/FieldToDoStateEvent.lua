--[[
    FieldToDoStateEvent.lua
    Server -> one connection: full farm state (settings + planned crops + tasks) on join/resync.
]]

FieldToDoStateEvent = {}
local FieldToDoStateEvent_mt = Class(FieldToDoStateEvent, Event)
InitEventClass(FieldToDoStateEvent, "FieldToDoStateEvent")

---@return FieldToDoStateEvent
function FieldToDoStateEvent.emptyNew()
    return Event.new(FieldToDoStateEvent_mt)
end

---@param state table|nil
---@return FieldToDoStateEvent
function FieldToDoStateEvent.new(state)
    local self = FieldToDoStateEvent.emptyNew()
    self.state = state or {}
    return self
end

function FieldToDoStateEvent:writeStream(streamId, connection)
    FieldToDoSync.writeState(streamId, self.state)
end

function FieldToDoStateEvent:readStream(streamId, connection)
    self.state = FieldToDoSync.readState(streamId)
    self:run(connection)
end

function FieldToDoStateEvent:run(connection)
    FieldToDoSync.applyState(self.state)
end
