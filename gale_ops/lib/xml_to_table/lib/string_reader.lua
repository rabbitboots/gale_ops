local path = ... and (...):match("(.-)[^%.]+$") or ""

local stringReader = {
	_VERSION = "1.0.0",
	_URL = "https://github.com/rabbitboots/string_reader",
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

local dummy_t = {}

local _mt_reader = {}
_mt_reader.__index = _mt_reader
stringReader._mt_reader = _mt_reader

-- Assertions

local function _errStrBadArg(arg_n, val, expected)
	return "bad argument #" .. arg_n .. " (expected " .. expected .. ", got " .. type(val) .. ")"
end


local function _assertArgType(arg_n, val, expected)
	if type(val) ~= expected then
		error(_errStrBadArg(arg_n, val, expected))
	end
end


local function _assertArgSeqType(arg_n, seq_n, val, expected)
	if type(val) ~= expected then
		error("argument # " .. arg_n .. ": bad table index #" .. seq_n
			.. " (expected " .. expected .. ", got " .. type(val) .. ")")
	end	
end


local function _assertNumGE(arg_n, val, ge)
	if type(val) ~= "number" then
		error(_errStrBadArg(arg_n, val, "number"), 2)
	elseif val < ge then
		error("bad argument #" .. arg_n .. ": number must be at least " .. ge, 2)
	end
end


-- (Checks the reader object internal state.)
local function _assertState(str, pos)
	if type(str) ~= "string" then
		error("state assertion failure: str is not of type 'string'", 2)
	elseif type(pos) ~= "number" then
		error("state assertion failure: pos is not of type 'number'", 2)
	elseif pos < 1 then
		error("state assertion failure: pos must be at least 1", 2)
	end
	-- 'pos' being beyond #str is considered 'eos'
end

-- / Assertions

-- Internal Functions

--- Get the length marker from a UTF-8 code unit's first byte.
-- @param byte The first byte to check.
-- @return 1, 2, 3 or 4, or false if the byte was a trailing octet, or nil if it couldn't be interpreted as a UTF-8 byte.
local function _u8GetOctetLengthMarker(byte)
	return (byte < 0x80) and 1 -- 0000:0000 - 0111:1111 (ASCII)
		or (byte >= 0xC0 and byte < 0xE0) and 2 -- 1100:0000 - 1101:1111
		or (byte >= 0xE0 and byte < 0xF0) and 3 -- 1110:0000 - 1110:1111
		or (byte >= 0xF0 and byte < 0xF8) and 4 -- 1111:0000 - 1111:0111
		or (byte >= 0x80 and byte < 0xBF) and false -- 1000:0000 - 1011:1111 (Trailing octet)
		or nil -- Not a UTF-8 byte?
end


-- Try to determine the line number and character column in 'str' based on the index in 'byte_pos'.
local function _lineNum(str, byte_pos)
	if byte_pos > #str then
		return "(End of string)", "(n/a)"
	end

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

		-- Try to step around the Windows carriage return + line feed pair
		if byte == 0xd then
			local byte2 = string.byte(str, i + 1)
			if byte2 == 0xa then
				i = i + 1
			end
		end

		-- line feed
		if byte == 0xa then
			line_num = line_num + 1
			column = 0
		end
		column = column + 1
	end

	return line_num, column
end


local function _getLineInfo(self)
	if self.hide_line_num then
		return ""
	end

	local line_num, char_col

	-- Calling reader state assertions while handling an error risks overruling more
	-- valuable error messages with generic "bad state" ones.
	if type(self.str) ~= "string" or type(self.pos) ~= "number" then
		line_num, char_col = "Unknown (Corrupt reader)", "Unknown"

	else
		line_num, char_col = _lineNum(self.str, self.pos)
		-- Couldn't get current line: return unknown
		if not line_num then
			line_num, char_col = "(Unknown)", "(Unknown)"
		end
	end

	char_col = char_col or "(Unknown)"

	local line_info = "line " .. line_num
	if not self.hide_char_num then
		line_info = line_info .. " position " .. char_col
	end

	return line_info
end


local function _lit(str, pos, chunk)
	return (string.sub(str, pos, pos + #chunk-1) == chunk)
end


local function _fetch(str, pos, ptn, literal)
	local i, j = string.find(str, ptn, pos, literal)
	if i then
		return j + 1, string.sub(str, i, j)
	end

	return nil
end


local function _cap(str, pos, ptn)
	local i, j, c1, c2, c3, c4, c5, c6, c7, c8, c9 = string.find(str, ptn, pos)
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

	-- self:peek() -> string.sub(self.str, self.pos, self.pos)
	-- self:peek(1) -> string.sub(self.str, self.pos + 1, self.pos + 1)
	-- self.peek(0, 5) -> string.sub(self.str, self.pos, self.pos + 4) -- (reads 5 bytes)

	return string.sub(self.str, self.pos + n, self.pos + n2)
end


--- Try to read one UTF-8 code unit from self.str starting at self.pos. If successful, advance position. If position is eos, return nil. If the current byte is not the start of a valid UTF-8 code unit, or is not a valid UTF-8 byte, raise an error.
-- @param _guard Internal use, leave nil.
-- @return String containing the char or code unit, or nil if reached end of string.
function _mt_reader.u8Char(self, _guard)
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


--- Try to read n UTF-8 code units in self.str, beginning at self.pos. If successful, advance position. If either the starting or final position is eos, return nil. If there is a problem decoding the UTF-8 bytes, raise a Lua error.
-- @param n (Required) How many code units to read from pos. Must be at least 1.
-- @return String chunk plus bytes read, or nil if reached end of string.
function _mt_reader.u8Chars(self, n)
	_assertState(self.str, self.pos)
	_assertNumGE(1, n, 1)
	_clearCaptures(self.c)

	local orig_pos = self.pos
	local temp_pos = self.pos
	local u8_count = 0

	-- Find the last byte of the last u8Char in the specified range.
	while true do
		if u8_count >= n then
			break

		-- eos
		elseif temp_pos > #self.str then
			return nil
		end

		local u8_len = _u8GetOctetLengthMarker(string.byte(self.str, temp_pos))

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


--- Try to read a one-byte string from self.str at self.pos. If successful, advance position. If position is eos, return nil.
-- @param _guard Internal use, must be left nil. Intended to help catch byteChar|byteChars mispellings.
-- @return String containing the char, or nil if reached end of string.
function _mt_reader:byteChar(_guard)
	-- **WARNING**: This may return incomplete portions of multi-byte UTF-8 code units.
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
	-- **WARNING**: This may return incomplete portions of multi-byte UTF-8 code units.
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


--- Check for 'chunk' anchored to the current position, as a string literal (no pattern matching.) If found, advance position and return the chunk. If not found, stay put and return nil.
-- @param chunk The string literal to check.
-- @return the chunk string if found, nil if not.
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

--- Version of self:lit() that raises an error if the match isn't successful.
-- @param chunk The string literal to check.
-- @param err_reason (Optional) An error message to pass to the error handler, if the search was not successful.
-- @return the chunk string, if found. If not, raises an error.
function _mt_reader:litReq(chunk, err_reason)
	local retval = self:lit(chunk)
	if not retval then
		err_reason = err_reason or "litReq failed"
		self:errorHalt(err_reason)
	end

	return retval
end


--- Search for 'ptn' starting at the current position.
-- @param ptn The string pattern to find.
-- @param literal (Default: false) When true, conducts a "plain" search with no magic pattern tokens. (Unlike self:lit(), this is not anchored to the current position.)
-- @return The successful string match, or nil if the search failed.
function _mt_reader:fetch(ptn, literal)
	_assertState(self.str, self.pos)
	_assertArgType(1, ptn, "string")
	literal = literal ~= nil and literal or false
	_assertArgType(2, literal, "boolean")
	_clearCaptures(self.c)

	local new_pos, chunk = _fetch(self.str, self.pos, ptn, literal)
	if new_pos then
		self.pos = new_pos
		return chunk
	end

	return nil
end


--- Version of self:fetch() which raises an error if the pattern search failed.
-- @param ptn The string pattern to find.
-- @param literal (Default: false) When true, conducts a "plain" search with no magic pattern tokens. (Unlike self:lit(), this is not anchored to the current position.)
-- @param err_reason (Optional) An error message that can be passed to the error handler there wasn't a match.
-- @return The pattern match substring on success. On failure, raise a Lua error.
function _mt_reader:fetchReq(ptn, literal, err_reason)
	local chunk = self:fetch(ptn, literal)
	if not chunk then
		err_reason = err_reason or "fetch failed"
		self:errorHalt(err_reason)
	end
	return chunk
end


--- Search for a string pattern containing capture definitions. If the first capture was successful, assign the capture results to an internal table, advance position, and return true. If false, clear existing captures and return false.
-- @param ptn A string pattern with at least one capture definition. Lua supports up to nine captures per string search. 
-- @return true on successful pattern match, nil if the pattern match failed. Successful captures can be read in 'self.c[1..9]'.
function _mt_reader:cap(ptn)
	_assertState(self.str, self.pos)
	_assertArgType(1, ptn, "string")
	_clearCaptures(self.c)

	-- The reason for storing captures and not returning them directly is so that you
	-- can include self:cap() in an if/elseif/else chain.

	local new_pos, c1, c2, c3, c4, c5, c6, c7, c8, c9 = _cap(self.str, self.pos, ptn)
	if c1 then
		self.pos = new_pos
		local c = self.c
		c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9] = c1, c2, c3, c4, c5, c6, c7, c8, c9
		return true
	end

	return nil
end


--- A version of self:cap() which raises an error if the match was unsuccessful.
-- @param ptn A string pattern with at least one capture definition. Lua supports up to nine captures per string search. 
-- @param err_reason (Optional) An error message that can be passed to the error handler there wasn't a match.
-- @return Nothing. Successful captures can be read in 'self.c[1..9]'. On failure, raises a Lua error.
function _mt_reader:capReq(ptn, err_reason)
	local success = self:cap(ptn)
	if not success then
		err_reason = err_reason or "capReq failed"
		self:errorHalt(err_reason)
	end
end


--- Step over optional whitespace.
-- @return true if the position advanced, false if not.
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


--- Pass over mandatory whitespace, raising an error if none is encountered.
-- @param err_reason (Optional) An error message that can be passed to the error handler there wasn't a match.
-- @return Nothing.
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


--- Manually clear stored captures. (Most methods do this automatically as a first step.)
-- @return nothing.
function _mt_reader:clearCaptures()
	_clearCaptures(self.c)
end


--- Check if reader is past the end of the string.
-- @return true if end of string reached, false otherwise.
function _mt_reader:isEOS()
	_assertState(self.str, self.pos)
	return self.pos > #self.str
end


--- Move the reader position to the end of the string. (#self.str + 1)
-- @return nothing.
function _mt_reader:goEOS()
	_assertState(self.str, self.pos)
	self.pos = #self.str + 1
end

-- / Reader Methods: Main Interface

-- Reader Methods: Util

--- Get the current line number. Line start is determined by the number of line feed characters from byte 1 to (self.pos - 1).
-- @return Count of newlines, or "(End of String)" if position is out of bounds.
function _mt_reader:lineNum()
	_assertState(self.str, self.pos)
	return _lineNum(self.str, self.pos)
end


function _mt_reader:warn(warn_str)
	_assertArgType(1, warn_str, "string")

	if self.terse_errors then
		return
	end

	print(_getLineInfo(self) .. ": " .. warn_str)
end


--- Raise a Lua error with the current position's line number included in the output.
-- @param err_str The string to print. If not a string, a generic string indicating the object type will be used instead (similar to passing a bad type to error() in Lua 5.4.)
-- @param err_level (Default: 1) The stack level to pass to error().
function _mt_reader:errorHalt(err_str, err_level)
	if self.terse_errors then
		error("Parsing failed.")
	end

	err_level = err_level ~= nil and err_level or 2

	-- error() would normally catch a bad arg #1, but we may need to concatenate this to the line and char numbers.
	if type(err_str) ~= "string" then
		err_str = "(err_str is a " .. type(err_str) .. " object)"
	end

	error(_getLineInfo(self) .. ": " .. err_str, err_level)
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
	self.hide_char_num = opts.hide_char_num or false -- 'hide_line_num == true' overrides this
	-- Replaces all error messages with "Parsing failed", and silences warnings.
	-- This also hides the line number and character number.
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


-- / Public Functions

-- Debug

-- Uncomment the next block to enable the '_status()' debug method.
--[[

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
			io.write("\t" .. i .. ": " .. tostring(self.c[i]))
		end
	end

	io.flush()
end
--]]

-- / Debug

return stringReader

