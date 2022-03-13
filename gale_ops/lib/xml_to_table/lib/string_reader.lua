-- Prerelease -- 2022-03-13
local path = ... and (...):match("(.-)[^%.]+$") or ""

local stringReader = {
	_VERSION = "0.9.0", -- prerelease version, packaged with galeOps
	_URL = "n/a",
	_DESCRIPTION = "Wrappers for Lua string functions.",
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

-- Is the 5.3+ utf8 library available?
local lua_utf8
local love = rawget(_G, "love")
--if love then
if false then
	lua_utf8 = require("utf8")
else
	lua_utf8 = rawget(_G, "utf8")
end

local dummy_t = {}

local _mt_reader = {}
_mt_reader.__index = _mt_reader
-- Allow attaching new methods
stringReader._mt_reader = _mt_reader

-- Assertions

local function errStrBadArg(arg_n, val, expected)
	return "Bad argument #" .. arg_n .. " (Expected " .. expected .. ", got " .. type(val) .. ")"
end


local function _assertArgType(arg_n, val, expected)
	if type(val) ~= expected then
		error(errStrBadArg(arg_n, val, expected))
	end
end


local function _assertArgSeqType(arg_n, seq_n, val, expected)
	if type(val) ~= expected then
		error("Argument # " .. arg_n .. ": bad table index #" .. seq_n
			.. " (Expected " .. expected .. ", got " .. type(val) .. ")")
	end	
end


local function _assertNumGE(arg_n, val, ge)
	if type(val) ~= "number" then
		error(errStrBadArg(arg_n, val, "number"), 2)
	elseif val < ge then
		error("Bad argument #" .. arg_n .. ": Number must be at least " .. ge, 2)
	end
end


-- (Checks the reader object internal state.)
local function _assertState(str, pos)
	if type(str) ~= "string" then
		error("State assertion failure: str is not of type 'string'", 2)
	elseif type(pos) ~= "number" then
		error("State assertion failure: pos is not of type 'number'", 2)
	elseif pos < 1 then
		error("State assertion failure: pos is lower than string start (1)")
	end
	-- 'pos' being beyond #str is considered 'eos'
end

-- / Assertions

-- Internal Functions

local function _u8GetOctetLengthMarker(byte)
	return (byte < 0x80) and 1 -- 0000:0000 - 0111:1111 (ASCII)
		or (byte >= 0xC0 and byte < 0xE0) and 2 -- 1100:0000 - 1101:1111
		or (byte >= 0xE0 and byte < 0xF0) and 3 -- 1110:0000 - 1110:1111
		or (byte >= 0xF0 and byte < 0xF8) and 4 -- 1111:0000 - 1111:0111
		or (byte >= 0x80 and byte < 0xBF) and false -- 1000:0000 - 1011:1111 (Trailing octet)
		or nil -- Not a UTF-8 byte?
end


local function u8UnitPosition(str, byte_start, byte_pos)
	local i, count = byte_start, 1

	while true do
		local byte = string.byte(str, i)
		if not byte then
			return false
		end
		local code_unit_length = _u8GetOctetLengthMarker(byte)
		if not code_unit_length then
			return false
		end
		i = i + code_unit_length
		if i >= byte_pos then
			break
		end
		count = count + 1
	end

	return count
end


local function _lineNum(str, byte_pos)
	-- March through every code-unit until we either catch up to 'pos'
	-- or we are unable to parse a code unit.
	local i, line_num, column = 1, 1, 1

	while true do
		local byte = string.byte(str, i)
		if not byte then
			return false
		end
		local code_unit_length = _u8GetOctetLengthMarker(byte)
		if not code_unit_length then
			return false
		end
		i = i + code_unit_length
		if i > byte_pos then
			break
		end
		-- carriage return -- XXX handle LF + CR scenario on Windows
		if byte == 0xa then
			line_num = line_num + 1
			column = 0
		end
		column = column + 1
	end

	return line_num, column
end


local function _lit(str, pos, chunk)
	return (string.sub(str, pos, pos + #chunk-1) == chunk)
end


local function _fetch(str, pos, ptn)
	local i, j = string.find(str, ptn, pos)
	if i then
		return j + 1, string.sub(str, i, j)
	end

	return nil
end


local function _cap(str, pos, ptn)
	local i, j, c1, c2, c3, c4, c5, c6, c7, c8, c9 = string.find(str, ptn, pos)
	--print("DEBUG: _cap", "i", i, "j", j, "c1-9", c1, c2, c3, c4, c5, c6, c7, c8, c9)
	if not c1 then
		return nil
	end

	return j + 1, c1, c2, c3, c4, c5, c6, c7, c8, c9	
end


local function _clearCaptures(c)
	for i = #c, 1, -1 do
		c[i] = nil
	end
end


-- / Internal Functions

-- Reader Methods: Main Interface

--- Extract a substring from (pos + n) to (pos + n2) without advancing the reader position.
-- @param n (Default: 0) First offset.
-- @param n2 (Default: n) Second offset.
-- @return The substring from (pos + n) to (pos + n2), or an empty string if that position is completely out of bounds.
function _mt_reader:peek(n, n2)
	-- **WARNING**: This operates on byte offsets, and may return invalid portions of multi-byte UTF-8 code units as a result.
	_assertState(self.str, self.pos)
	_clearCaptures(self.c)

	n = n == nil and 0 or n
	n2 = n2 == nil and n or n2
	_assertArgType(1, n, "number")
	_assertArgType(2, n2, "number")

	-- self:peek() == string.sub(self.str, self.pos, self.pos)
	-- self:peek(1) == string.sub(self.str, self.pos + 1, self.pos + 1)
	-- self.peek(0, 5) == string.sub(self.str, self.pos, self.pos + 4) -- (reads 5 bytes)

	return string.sub(self.str, self.pos + n, self.pos + n2)
end


--- Try to read one UTF-8 code unit from self.str starting at self.pos. If successful, advance position. If position is eos, return nil. If the current byte is not the start of a valid UTF-8 code unit or is not a UTF-8 valid byte, raise an error.
-- @param _guard Internal use, leave nil.
-- @return String containing the char or code unit, or nil if reached end of string.
local function _u8Char_plain(self, _guard)
	_assertState(self.str, self.pos)
	_assertArgType(1, _guard, "nil")
	_clearCaptures(self.c)

	-- eos
	if self.pos > #self.str then
		return nil
	end

	local u8_len = _u8GetOctetLengthMarker(string.byte(self.str, self.pos))
	if u8_len == false then
		error("encoding or parsing error: got trailing octet / continuation byte.")
	elseif u8_len == nil then
		error("encoding error: got non-UTF-8 byte")
	end

	local retval = string.sub(self.str, self.pos, self.pos + u8_len-1)
	self.pos = self.pos + u8_len

	return retval
end
_mt_reader.u8Char = _u8Char_plain


--- Version of self:u8char() that uses the utf8 library in Lua 5.3+.
local function _u8Char_utf8(self, _guard)
	_assertState(self.str, self.pos)
	_assertArgType(1, _guard, "nil")
	_clearCaptures(self.c)

	-- eos
	if self.pos > #self.str then
		return nil
	end

	local u8_pos2 = lua_utf8.offset(self.str, 2, self.pos)
	if not u8_pos2 then
		return nil
	end

	local retval = string.sub(self.str, self.pos, u8_pos2 - 1)
	self.pos = u8_pos2

	return retval
end


--- Try to read n UTF-8 code units in self.str, beginning at self.pos. If successful, advance position. If either the starting or final position is eos, return nil. If there is a problem decoding the UTF-8 bytes, raise a Lua error.
-- @param n (Required) How many code units to read from pos. Must be at least 1.
-- @return String chunk plus bytes read, or nil if reached end of string.
local function _u8Chars_plain(self, n)
	_assertState(self.str, self.pos)
	_assertNumGE(1, n, 1)
	_clearCaptures(self.c)

	local orig_pos = self.pos
	local temp_pos = self.pos
	local u8_count = 0

	-- Find the last byte of the last u8Char in the specified range.
	while true do
		if u8_count >= n then
			print("u8_count >= n", u8_count, n)
			break

		-- eos
		elseif temp_pos > #self.str then
			print("temp_pos > #self.str", temp_pos, #self.str, "u8_count", u8_count, "n", n)
			return nil
		end

		local u8_len = _u8GetOctetLengthMarker(string.byte(self.str, temp_pos))

		print("u8_len", u8_len, "temp_pos", temp_pos)

		if u8_len == false then
			error("encoding or parsing error: got trailing octet / continuation byte.")
		elseif u8_len == nil then
			error("encoding error: got non-UTF-8 byte")
		end

		u8_count = u8_count + 1
		temp_pos = temp_pos + u8_len
	end

	local retval = string.sub(self.str, orig_pos, temp_pos - 1)

	self.pos = temp_pos

	return retval, temp_pos - orig_pos
end
_mt_reader.u8Chars = _u8Chars_plain


--- Version of self:u8Chars() that uses the utf8 library in Lua 5.3+.
local function _u8Chars_utf8(self, n)
	_assertState(self.str, self.pos)
	_assertNumGE(1, n, 1)
	_clearCaptures(self.c)

	local orig_pos = self.pos
	local u8_count = 0

	-- eos
	if self.pos > #self.str then
		return nil
	end

	-- Find the last byte of the last u8Char in the specified range.
	local temp_pos = lua_utf8.offset(self.str, n + 1, self.pos)
	if temp_pos then
		temp_pos = temp_pos - 1
	end

	local retval = string.sub(self.str, orig_pos, temp_pos)

	self.pos = temp_pos + 1

	return retval, temp_pos - (orig_pos - 1)
end


--- Try to read a one-byte string from self.str at self.pos. If successful, advance position. If position is eos, return nil.
-- @param _guard Internal use, must be left nil. Intended to help catch byteChar|byteChars mispellings.
-- @return String containing the char, or nil if reached end of string.
function _mt_reader:byteChar(_guard)
	-- **WARNING**: Only use if you are certain the string contains single-byte code units (ASCII) only.
	_assertState(self.str, self.pos)
	_assertArgType(1, _guard, "nil")
	_clearCaptures(self.c)
	
	-- eos
	if self.pos > #self.str then
		return nil
	end

	local retval = string.sub(self.str, self.pos, self.pos)
	self.pos = self.pos + 1
	return retval
end


--- Try to read n chars (bytes) in self.str from self.pos to self.pos + n or #self.str, whichever is shorter. If successful, advance position. If range goes out of bounds (eos), return nil.
-- @param n (Required) How many bytes to read from pos. Must be at least 1.
-- @return String chunk plus bytes read, or nil if reached end of string.
function _mt_reader:byteChars(n)
	-- **WARNING**: Only use if you are certain the string contains single-byte code units (ASCII) only.
	_assertState(self.str, self.pos)
	_assertNumGE(1, n, 1)
	_clearCaptures(self.c)

	local orig_pos = self.pos

	-- eos
	if self.pos > #self.str then
		return nil
	end
	local far_pos = self.pos + n-1
	if far_pos > #self.str then
		return nil
	end

	local retval = string.sub(self.str, self.pos, far_pos)

	self.pos = far_pos + 1

	return retval, far_pos - (orig_pos - 1)
end


function _mt_reader:lit(chunk)
	_assertState(self.str, self.pos)
	_assertArgType(1, chunk, "string")
	_clearCaptures(self.c)

	if _lit(self.str, self.pos, chunk) then
		self.pos = self.pos + #chunk
		return chunk
	end

	return nil
end


function _mt_reader:litReq(chunk, err_reason)
	local retval = self:lit(chunk)
	if not retval then
		err_reason = err_reason or "litReq failed"
		self:errorHalt(err_reason)
	end

	return retval
end


function _mt_reader:litTab(chunk_t)
	_assertState(self.str, self.pos)

	for i = 1, #chunk_t do
		local chunk = chunk_t[i]
		_assertArgSeqType(1, i, chunk, "string")

		if _lit(self.str, self.pos, chunk) then

			self.pos = self.pos + #chunk
			return i, chunk
		end
	end

	return nil
end


function _mt_reader:litTabReq(chunk_t, err_reason)
	local ret_i, retval = self:litTab(chunk_t)
	if not retval then
		err_reason = err_reason or "litTabReq failed"
		self:errorHalt(err_reason)
	end

	return ret_i, retval
end


function _mt_reader:fetch(ptn)
	_assertState(self.str, self.pos)
	_assertArgType(1, ptn, "string")
	_clearCaptures(self.c)

	local new_pos, chunk = _fetch(self.str, self.pos, ptn)
	if new_pos then

		self.pos = new_pos
		return chunk
	end

	return nil
end


function _mt_reader:fetchOrEOS(ptn)
	local chunk = self:fetch(ptn)
	if not chunk then
		self.pos = math.max(self.pos, #self.str + 1)
	end
	return chunk
end


function _mt_reader:fetchReq(ptn, err_reason)
	local chunk = self:fetch(ptn)
	if not chunk then
		err_reason = err_reason or "fetch failed"
		self:errorHalt(err_reason)
	end
	return chunk
end


-- Try to get string captures. If successful, advance position.
-- @param ... One or multiple string patterns with capture definitions. Lua supports up to nine captures per string search. Patterns are tried in sequence until either one is successful or they all fail.
-- @return 1-9 capture strings from the successful pattern match, or nil if no patterns were found.
function _mt_reader:cap(ptn)
	_assertState(self.str, self.pos)
	_assertArgType(1, ptn, "string")
	_clearCaptures(self.c)

	local new_pos, c1, c2, c3, c4, c5, c6, c7, c8, c9 = _cap(self.str, self.pos, ptn)
	if c1 then
		self.pos = new_pos
		local c = self.c
		c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9] = c1, c2, c3, c4, c5, c6, c7, c8, c9
		return true
	end

	return nil
end


function _mt_reader:capReq(ptn, err_reason)
	local success = self:cap(ptn)
	if not success then
		err_reason = err_reason or "capReq failed"
		self:errorHalt(err_reason)
	end
end
	

function _mt_reader:capTab(ptn_t)
	_assertState(self.str, self.pos)
	_assertArgType(1, ptn_t, "table")
	_clearCaptures(self.c)

	for selection = 1, #ptn_t do
		local ptn = ptn_t[selection]
		_assertArgSeqType(1, selection, ptn, "string")
		local new_pos, c1, c2, c3, c4, c5, c6, c7, c8, c9 = _cap(self.str, self.pos, ptn)

		if c1 then
			self.pos = new_pos

			local c = self.c
			c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9] = c1, c2, c3, c4, c5, c6, c7, c8, c9
			return selection
		end
	end

	return nil
end


function _mt_reader:capTabReq(ptn_t, err_reason)
	local selection, c1, c2, c3, c4, c5, c6, c7, c8, c9 = self:capTab(ptn_t)
	if not selection then
		err_reason = err_reason or "capTabReq failed"
		self:errorHalt(err_reason)
	end
	return selection
end


-- Step over optional whitespace. Return true if the position advanced, false if not.
function _mt_reader:ws()
	_assertState(self.str, self.pos)
	_clearCaptures(self.c)

	local old_pos = self.pos

	local i, j = string.find(self.str, "%S", self.pos)

	if not i then -- marched to eos
		self.pos = #self.str + 1
	else
		self.pos = i
	end

	return self.pos ~= old_pos
end


-- Pass over mandatory whitespace, raising an error if none is encountered.
function _mt_reader:wsReq(err_reason)
	_assertState(self.str, self.pos)
	_clearCaptures(self.c)

	if not string.match(string.sub(self.str, self.pos, self.pos), "%s") then
		err_reason = err_reason or "mandatory whitespace not found"
		self:errorHalt(err_reason)
	end

	local i, j = string.find(self.str, "%s+", self.pos)

	if not i then -- marched to eos
		self.pos = #self.str + 1
	else
		self.pos = j + 1
	end
end


--- Assuming we are currently on non-whitespace, advance to the next whitespace character.
-- @return nothing.
function _mt_reader:wsNext()
	_assertState(self.str, self.pos)
	_clearCaptures(self.c)

	-- If current position is on whitespace, stay put.
	if string.match(string.sub(self.str, self.pos, self.pos), "%s") then
		return
	end
	local i, j = string.find(self.str, "%s", self.pos + 1)

	if i then
		self.pos = i
	else
		self.pos = #self.str + 1
	end
end


--- Assign a new string to the reader. Resets position to 1.
-- @param new_str The string to set.
-- @return Nothing.
function _mt_reader:newStr(new_str)
	_assertArgType(1, new_str, "string")
	_clearCaptures(self.c)

	self.str = new_str
	self.pos = 1
end


--- Reset position to start of string.
-- @return Nothing.
function _mt_reader:reset()
	_clearCaptures(self.c)
	self.pos = 1
end

function _mt_reader:clearCaptures()
	_clearCaptures(self.c)
end


--- Check if reader is past the end of the string.
-- @return true if end of string reached, false otherwise.
function _mt_reader:isEOS()
	_assertState(self.str, self.pos)
	return self.pos > #self.str
end

function _mt_reader:goEOS()
	_assertState(self.str, self.pos)
	self.pos = #self.str + 1
end

-- / Reader Methods: Main Interface

-- Reader Methods: Util

--- Get the current line number. Line start is determined by the number of line-breaks from byte 1 to (self.pos - 1).
-- @return Count of newlines, or "(End of String)" if position is out of bounds.
function _mt_reader:lineNum()
	_assertState(self.str, self.pos)
	return _lineNum(self.str, self.pos)
end


local function _getLineInfo(self)
	local line_num, char_col
	-- Calling reader state assertions while handling an error risks overruling more
	-- valuable error messages with generic "bad state" ones.
	if type(self.str) ~= "string" or type(self.pos) ~= "number" then
		line_num = "Unknown (Corrupt reader)"

	else
		line_num, char_col = _lineNum(self.str, self.pos)
		if not line_num then
			line_num = "(Unknown)"
		end
	end
	return line_num, char_col
end


function _mt_reader:warn(warn_str)
	_assertArgType(1, warn_str, "string")

	if self.terse_errors then
		return
	end

	local line_info
	if self.hide_line_num then
		line_info = "", ""

	else
		local line_num, char_col = _getLineInfo(self)
		line_info = "Line " .. line_num .. ", Position: " .. char_col .. ": "
	end

	print(line_info .. warn_str)
end


--- Raise a Lua error with the current position's line number included in the output.
-- @param err_str The string to print. If not a string, a generic string indicating the object type will be used instead (similar to passing a bad type to error() in Lua 5.4.)
-- @param err_level (Default: 1) The stack level to pass to error().
function _mt_reader:errorHalt(err_str, err_level)
	if self.terse_errors then
		error("Parsing failed.")
	end

	err_level = err_level or 2
	-- error() would normally catch a bad arg #1, but we may need to concatenate this to the line and char numbers.
	if type(err_str) ~= "string" then
		err_str = "(err_str is a " .. type(err_str) .. " object)"
	end

	local line_info, column
	if self.hide_line_num then
		line_info = ""

	else
		local line_num, column = _getLineInfo(self)
		column = column or "(Unknown)"

		line_info = "Line " .. line_num .. ", Position: " .. column .. ": "
	end

	error(line_info .. err_str, err_level)
end

-- / Reader Methods: Util

-- Public Functions

--- Make a new reader object.
-- @param str (Optional) The string to read. Default: empty string ("")
-- @param opts (Optional) Table of options to pass.
-- @param opts.terse_errors When true, all errorHalt() calls print just "Parsing failed.", and warn() is muted.
-- @param opts.hide_line_num When true, doesn't print the line and character number in errorHalt() and warn().
function stringReader.new(str, opts)
	str = (str == nil) and "" or str
	opts = (opts == nil) and dummy_t or opts

	_assertArgType(1, str, "string")
	_assertArgType(2, opts, "table")

	local self = {}

	self.str = str
	self.pos = 1

	-- Omits line number from error messages
	self.hide_line_num = opts.hide_line_num or false

	-- Replaces all error messages with "Parsing failed", and silences warnings.
	-- This also hides the line number.
	self.terse_errors = opts.terse_errors or false

	-- Capture results 1-9
	self.c = {}
	setmetatable(self, _mt_reader)

	return self
end


function stringReader.lineNum(str, pos)
	-- Don't assert reader state: this should be usable out of context.
	_assertArgType(1, str, "string")
	_assertArgType(2, pos, "number")

	return _lineNum(str, pos)
end


local function _setModuleFunctions()
	if lua_utf8 then
		_mt_reader.u8Char = _u8Char_utf8
		_mt_reader.u8Chars = _u8Chars_utf8
	else
		_mt_reader.u8Char = _u8Char_plain
		_mt_reader.u8Chars = _u8Chars_plain
	end
end


-- / Public Functions

-- Debug
-- [=====[

-- Uncomment the next block to enable the '_status()' debug method.
-- [====[

--- Debug: Print the current character (byte) and position.
-- @param show_captures (Optional) If true, show current state of the reader's capture registers.
-- @return Nothing. Output is printed to terminal.
function _mt_reader:_status(show_captures)
	_assertState(self.str, self.pos)

	if self.pos < 1 then
		print("(self.pos is out of bounds: " .. self.pos .. ")")

	elseif self.pos > #self.str then
		print("(eos)")

	else
		print("lineNum " .. self:lineNum()
			.. " |" .. string.sub(self.str, self.pos, self.pos) .. "| "
			.. self.pos .. " / " .. #self.str)
	end

	if show_captures then
		io.write("cap registers:")
		for i = 1, #self.c do
			io.write("\t" .. tostring(self.c[i]))
		end
	end

	io.flush()
end
--]====]

-- / Debug
--]=====]

-- Module Init

_setModuleFunctions()

-- / Module Init

return stringReader

