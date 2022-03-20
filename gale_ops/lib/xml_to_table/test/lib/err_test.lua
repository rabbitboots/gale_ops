--local path = ... and (...):match("(.-)[^%.]+$") or ""

local errTest = {
	_VERSION = "1.0.0",
	_URL = "https://github.com/rabbitboots/err_test",
	_DESCRIPTION = "A module for testing pcall-wrapped error calls in functions.",
	_LICENSE = [[
	Copyright (c) 2022 RBTS

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
	]]
}

-- Config

-- Set to false to replace output of certain types as '<type>' instead of 'type: 0x012345678..'
-- Might help with diffing two results.
errTest.type_hide = {
	["function"] = false,
	["table"] = false,
	["thread"] = false,
	["userdata"] = false,
	["cdata"] = false,
}

-- / Config

-- Internal State

-- Holds string labels for functions.
local _registry = {}

-- / Internal State

-- Assertions

local function _assertArgType(arg_n, var, allowed_types)
	-- 'allowed_types' can be a single string or a table sequence of strings.
	if type(allowed_types) == "table" then
		for i, type_enum in ipairs(allowed_types) do
			if type(var) == type_enum then
				return
			end
		end
		error("bad argument #" .. arg_n .. " (Expected (" .. table.concat(allowed_types, ", ") .. "), got " .. type(var) .. ")", 2)

	elseif type(var) ~= allowed_types then
		error("bad argument #" .. arg_n .. " (Expected " .. allowed_types .. ", got " .. type(var) .. ")", 2)
	end
end
local allowed_nil_str = {"nil", "string"}

-- / Assertions

-- Helpers

local function _varargsToString(...)
	-- (Track number of args so we can step over nil sequence gaps.)
	local n_args = select("#", ...)
	if n_args == 0 then
		return ""
	end

	local arguments_t = {...}

	for i = 1, n_args do
		local argument = arguments_t[i]

		-- Optional address hiding
		if errTest.type_hide[type(argument)] then
			arguments_t[i] = "<" .. type(argument) .. ">"

		else
			arguments_t[i] = tostring(argument)
		end
	end

	return table.concat(arguments_t, ", ")
end


local function _try(func, ...)
	return pcall(func, ...)
end


local function _okErrTry(func, ...)
	return func(...)
end


local function _getLabel(func)
	return _registry[func] or ""
end


-- / Helpers

-- Public Interface

--- Associate a label string with a function (or remove it.) A function may have only one label at a time. Multiple identical labels across different functions is discouraged but may be used.
-- @param func The function to (un)register. Must not already have a label registered.
-- @param label The string ID to assign to this function. Pass nil to unregister the function.
-- @return The provided label string (to help with constructing print messages.)
function errTest.register(func, label)

	_assertArgType(1, func, "function")
	_assertArgType(2, label, allowed_nil_str)

	if label then
		if _registry[func] then
			error("This function is already registered.")
		end

	else
		if not _registry[func] then
			error("This function is not currently registered.")
		end
	end

	_registry[func] = label
	
	return label
end


--- Unregister all functions.
-- @return Nothing.
function errTest.unregisterAll()
	for k in pairs(_registry) do
		_registry[k] = nil
	end
end


--- Run a function via pcall(), and report if it was successful or not.
-- @param func The function to run.
-- @param ... Arguments for the function.
-- @return the first two results of the wrapped pcall (first is true on success run, false if not)
function errTest.try(func, ...)

	_assertArgType(1, func, "function")
	io.write("(try) " .. _getLabel(func) .. "(" .. _varargsToString(...)  .. "): ")
	io.flush()

	local ok, res = _try(func, ...)

	if ok then
		io.write("[Pass]\n")

	else
		io.write("[Fail]\n" .. tostring(res) .. "\n")
	end

	return ok, res
end


--- Run a function via pcall(), raising an error if it does not complete successfully.
-- @param func The function to run.
-- @param ... Arguments for the function.
-- @return Nothing.
function errTest.expectPass(func, ...)

	_assertArgType(1, func, "function")
	io.write("(expectPass) " .. _getLabel(func) .. "(" .. _varargsToString(...)  .. "): ")
	io.flush()
	
	local ok, res = _try(func, ...)
	if not ok then
		error("Expected passing call failed:\n\t" .. tostring(res))

	else
		io.write("[Pass]\n")
	end

	return ok, res
end


--- Run a function via pcall(), raising an error if it does complete successfully.
-- @param func The function to run.
-- @param ... Arguments for the function.
-- @return Nothing.
function errTest.expectFail(func, ...)

	_assertArgType(1, func, "function")
	io.write("(expectFail) " .. _getLabel(func) .. "(" .. _varargsToString(...)  .. "): ")
	io.flush()

	local ok, res = _try(func, ...)
	if ok == true then
		error("Expected failing call passed:\n\t" .. tostring(res))

	else
		io.write("[Fail]\n-> " .. tostring(res) .. "\n")
	end

	return ok, res
end


--- Run a function which normally returns false/nil plus an error string in the event of a failure, and report on whether it was successful or not. pcall() is not used.
-- @param func The function to run.
-- @param ... Arguments for the function.
-- @return true on success, false if the function returned false/nil.
function errTest.okErrTry(func, ...)

	_assertArgType(1, func, "function")
	io.write("(okErrTry) " .. _getLabel(func) .. "(" .. _varargsToString(...)  .. "): ")
	io.flush()

	local ok, res = _okErrTry(func, ...)
	if ok then
		io.write("[Pass]\n")

	else
		io.write("[Fail]\n")
	end
	
	return ok, res
end


--- Run a function expected to return truthy (non-false, non-nil) as its first argument, and raise an error if it doesn't.
-- @param func The function to run.
-- @param ... Arguments for the function.
-- @return Nothing.
function errTest.okErrExpectPass(func, ...)

	_assertArgType(1, func, "function")
	io.write("(okErrExpectPass) " .. _getLabel(func) .. "(" .. _varargsToString(...)  .. "): ")
	io.flush()

	local ok, res = _okErrTry(func, ...)
	if not ok then
		error("Expected passing call failed.")

	else
		io.write("[Pass]\n")
	end

	return ok, res
end


--- Run a function expected to return false/nil as its first argument and an error string as its second, and raise an error if it doesn't.
-- @param func The function to run.
-- @param ... Arguments for the function.
-- @return Nothing.
function errTest.okErrExpectFail(func, ...)

	_assertArgType(1, func, "function")
	io.write("(okErrExpectFail) " .. _getLabel(func) .. "(" .. _varargsToString(...)  .. "): ")
	io.flush()

	local ok, res = _okErrTry(func, ...)
	if ok then
		error("Expected failing call passed.")

	else
		io.write("[Fail]\n")
	end

	return ok, res
end

-- / Public Interface

return errTest
