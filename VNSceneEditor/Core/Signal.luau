-- Minimal signal implementation used to push store changes out to the UI.

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(handler)
	local handlers = self._handlers
	table.insert(handlers, handler)

	return {
		Disconnect = function()
			local index = table.find(handlers, handler)
			if index then
				table.remove(handlers, index)
			end
		end,
	}
end

function Signal:Fire(...)
	for _, handler in ipairs(table.clone(self._handlers)) do
		local ok, err = pcall(handler, ...)
		if not ok then
			warn("[VNSceneEditor] signal handler failed: " .. tostring(err))
		end
	end
end

function Signal:Destroy()
	table.clear(self._handlers)
end

Signal.DisconnectAll = Signal.Destroy

return Signal
