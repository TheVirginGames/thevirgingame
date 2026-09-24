-- Flag values, condition evaluation and the two flag writing events.

local Schema = require(script.Parent.Parent.Core.Schema)

local Conditions = {}

-- "true" / "false" / numbers become real values; anything else stays a string.
function Conditions.parseValue(text)
	if type(text) == "boolean" or type(text) == "number" then
		return text
	end

	if type(text) == "string" then
		local trimmed = Schema.trimName(text)
		local lowered = trimmed:lower()
		if lowered == "true" then
			return true
		end

		if lowered == "false" then
			return false
		end

		local number = tonumber(trimmed)
		if number then
			return number
		end

		return trimmed
	end

	return tostring(text)
end

local function toNumber(value)
	if type(value) == "number" then
		return value
	end

	if type(value) == "boolean" then
		return value and 1 or 0
	end

	return tonumber(value) or 0
end

local function equal(a, b)
	return type(a) == type(b) and a == b
end

function Conditions.check(condition, flags, chapter, scene)
	local current = flags[condition.flag]
	local definition = Schema.resolveFlag(chapter, scene, condition.flag)
	if (chapter or scene) and not definition then
		-- A deleted/renamed flag is an invalid condition, not an implicit false
		-- value that might accidentally satisfy "== false".
		return false
	end

	local expected = definition
		and Schema.coerceFlagValue(definition, condition.value)
		or Conditions.parseValue(condition.value)
	local op = condition.op

	if current == nil then
		return false
	end
	if definition then
		current = Schema.coerceFlagValue(definition, current)
	end

	if op == "==" then
		return equal(current, expected)
	elseif op == "~=" then
		return not equal(current, expected)
	elseif op == ">" then
		return toNumber(current) > toNumber(expected)
	elseif op == "<" then
		return toNumber(current) < toNumber(expected)
	elseif op == ">=" then
		return toNumber(current) >= toNumber(expected)
	elseif op == "<=" then
		return toNumber(current) <= toNumber(expected)
	end

	return false
end

-- All conditions must pass. An empty list always passes.
function Conditions.evaluate(conditions, flags, chapter, scene)
	for _, condition in ipairs(conditions or {}) do
		if not Conditions.check(condition, flags or {}, chapter, scene) then
			return false
		end
	end

	return true
end

-- Mutates flags for FlowSetFlag / FlowIncrement. Returns true when changed.
function Conditions.applyEvent(flags, event, chapter, scene)
	local flagId = type(event.params.flag) == "string" and event.params.flag or ""
	local definition = Schema.resolveFlag(chapter, scene, flagId)
	if (chapter or scene) and not definition then
		-- Do not create hidden runtime flags from stale event references.
		return false
	end

	local nextValue = nil
	if event.type == "FlowSetFlag" then
		if flagId ~= "" then
			nextValue = definition
				and Schema.coerceFlagValue(definition, event.params.value)
				or Conditions.parseValue(event.params.value)
		end
	elseif event.type == "FlowIncrement" then
		if flagId ~= "" and (not definition or definition.kind == "int") then
			nextValue = toNumber(flags[flagId]) + (tonumber(event.params.amount) or 1)
			if definition then
				nextValue = Schema.coerceFlagValue(definition, nextValue)
			end
		end
	end

	if nextValue == nil then
		return false
	end

	local changed = flags[flagId] ~= nextValue or type(flags[flagId]) ~= type(nextValue)
	flags[flagId] = nextValue
	return changed
end

function Conditions.describe(condition)
	return string.format("%s %s %s", Schema.displayFlagRef(condition.flag), condition.op, tostring(condition.value))
end

function Conditions.describeAll(conditions)
	if #conditions == 0 then
		return "always"
	end

	local parts = {}
	for _, condition in ipairs(conditions) do
		table.insert(parts, Conditions.describe(condition))
	end
	return table.concat(parts, " and ")
end

function Conditions.formatValue(value)
	if type(value) == "boolean" then
		return value and "true" or "false"
	end
	return tostring(value)
end

return Conditions
