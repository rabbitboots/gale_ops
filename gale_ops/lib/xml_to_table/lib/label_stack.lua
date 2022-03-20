-- Prerelease -- 2022-03-17

local labelStack = {}

local _mt_stack = {}
_mt_stack.__index = _mt_stack

local _stack_max = 65536

function labelStack.new()

	local self = {}

	-- 0: Print nothing
	-- 1: self:report() prints the current label
	-- 2: self:report() prints the entire label stack
	-- 3: self:report() prints every time a label is pushed or popped
	self.report_level = 0
	self.stack = {"<stack_root>"}

	self.top = self.stack[#self.stack]

	setmetatable(self, _mt_stack)

	return self
end

function _mt_stack:push(label)
	if #self.stack >= _stack_max then
		error("LabelStack overflow")
	end
	self.stack[#self.stack + 1] = label
	self.top = label
	if self.report_level >= 3 then
		print(string.rep(" ", #self.stack-1) .. "+" .. label)
	end
end

function _mt_stack:pop()
	local label
	label, self.stack[#self.stack] = self.stack[#self.stack], nil
	if self.report_level >= 3 then
		print(string.rep(" ", #self.stack) .. "-" .. label)
	end
	return label
end

function _mt_stack:report()
	if self.report_level >= 1 then
		if self.report_level == 1 then
			print("L " .. self.top)

		elseif self.report_level >= 2 then
			for i = 1, #self.stack do
				io.write("> (" .. i .. ") " .. self.stack[i])
			end
			io.write("n")
		end

		io.flush()
	end
end

return labelStack
