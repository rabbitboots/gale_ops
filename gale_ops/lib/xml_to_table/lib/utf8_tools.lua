--local path = ... and (...):match("(.-)[^%.]+$") or ""
local utf8Tools = {
	_VERSION = "1.0.0",
	_URL = "https://github.com/rabbitboots/utf8_tools",
	_DESCRIPTION = "UTF-8 utility functions for Lua.",
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

--[[
	References:
	UTF-8 RFC 3629:
	https://tools.ietf.org/html/rfc3629

	Wikipedia page on UTF-8:
	https://en.wikipedia.org/wiki/UTF-8

	Wikipedia page on Unicode:
	https://en.wikipedia.org/wiki/Unicode
--]]

local options = {}
utf8Tools.options = options

-- Check the Unicode surrogate range. Code points in this range are forbidden by the spec,
-- but some decoders allow them through.
options.check_surrogates = true

-- Exclude certain bytes forbidden by the spec when calling getCodeUnit().
options.match_exclude = true

-- Lookup Tables and Patterns

local function makeLUT(seq)
	local lut = {}
	for i, val in ipairs(seq) do
		lut[val] = true
	end
	return lut
end

--[[
	Here are some Lua string patterns which can be used to parse UTF-8 code units.

	charpattern: This is a (slightly modified) pattern from Lua 5.3's utf8 library
		which matches exactly one UTF-8 code unit. It assumes the string being parsed
		is valid UTF-8. (It can match overly long code units.)
		Source: http://www.lua.org/manual/5.3/manual.html#6.5

	u8_ptn_t: Table of patterns used to grab UTF-8 code units in getCodeUnit(). All
		patterns are anchored with '^'.

	u8_ptn_excl_t: Like u8_ptn_t, but some forbidden bytes are excluded in the pattern
		ranges.

	u8_oct_1: Just the first byte from utf8.charpattern. Matches a "first octet",
		and could be used to skip to the next code unit in a string, without failing
		on further issues in the subsequent bytes.

--]]

utf8Tools.charpattern = "[%z\x01-\x7F\xC2-\xFD][\x80-\xBF]*"

utf8Tools.u8_oct_1 = "[%z\x01-\x7F\xC2-\xFD]"

utf8Tools.u8_ptn_t = {
	"^[%z\x01-\x7F]",
	"^[\xC0-\xDF][\x80-\xBF]",
	"^[\xE0-\xEF][\x80-\xBF][\x80-\xBF]",
	"^[\xF0-\xF7][\x80-\xBF][\x80-\xBF][\x80-\xBF]",
}

utf8Tools.u8_ptn_excl_t = {
	"^[%z\x01-\x7F]",
	"^[\xC2-\xDF][\x80-\xBF]",
	"^[\xE0-\xEF][\x80-\xBF][\x80-\xBF]",
	"^[\xF0-\xF4][\x80-\xBF][\x80-\xBF][\x80-\xBF]",
}


-- Octets 0xc0, 0xc1, and (0xf5 - 0xff) should never appear in a UTF-8 value
utf8Tools.lut_invalid_octet = makeLUT( {
	-- 1100:0000, 1100:0001
	0xc0, 0xc1,
	-- 1111:0101 - 1111:1111
	0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
	0xfb, 0xfc, 0xfd, 0xfe, 0xff
	}
)

-- Used to verify number length against allowed octet ranges.
local lut_oct_min_max = {
	{0x00000, 0x00007f}, -- 1 octet
	{0x00080, 0x0007ff}, -- 2 octets
	{0x00800, 0x00ffff}, -- 3 octets
	{0x10000, 0x10ffff}, -- 4 octets
}

-- / Lookup Tables and Patterns

-- Assertions, Error Messages

local function _assertArgType(arg_n, var, expected)
	if type(var) ~= expected then
		error("bad argument #" .. arg_n .. " (Expected " .. expected .. ", got " .. type(var) .. ")", 2)
	end
end

local function _errStrInvalidOctet(pos, val)
	return "Invalid octet value (" .. val .. ") in byte #" .. pos
end


-- / Assertions, Error Messages

-- Internal Logic

-- Check octets 2-4 in a multi-octet code point
local function _checkFollowingOctet(octet, position, n_octets)
	-- NOTE: Do not call on the first octet.

	if not octet then
		return "Octet #" .. tostring(position) .. " is nil."

	-- Check some bytes which are prohibited in any position in a UTF-8 code point
	elseif utf8Tools.lut_invalid_octet[octet] then
		return _errStrInvalidOctet(position, octet)

	-- Nul is allowed in single-octet code points, but not multi-octet
	elseif octet == 0 then
		return "Octet #" .. tostring(position) .. ": Multi-byte code points cannot contain 0 / Nul bytes."

	-- Verify "following" byte mark	
	-- < 1000:0000
	elseif octet < 0x80 then
		return "Byte #" .. tostring(position) .. " is too low (" .. tostring(octet) .. ") for multi-byte encoding. Min: 0x80"

	-- >= 1100:0000
	elseif octet >= 0xC0 then
		return "Byte #" .. tostring(position) .. " is too high (" .. tostring(octet) .. ") for multi-byte encoding. Max: 0xBF"
	end
end


--- Convert 1-4 UTF-8 code unit octets (in number form) to the matching Unicode Code Point. Does no error detection.
-- @param n_octets Number of octets in the code unit, from 1 to 4.
-- @param b1 First byte in the code unit.
-- @param b2 Second byte in the code unit, if applicable.
-- @param b3 Third byte in the code unit, if applicable.
-- @param b4 Fourth byte in the code unit, if applicable.
-- @return the code point as a single number, or nil if 'n_octets' was not 1, 2, 3 or 4.
local function _numberFromOctets(n_octets, b1, b2, b3, b4)
	return n_octets == 1 and b1
	or n_octets == 2 and (b1 - 0xc0) * 0x40 + (b2 - 0x80)
	or n_octets == 3 and (b1 - 0xe0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
	or n_octets == 4 and (b1 - 0xf0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80)
	or nil
end


local function _getLengthMarker(byte)
	-- (returns a number on success, or error string on failure)
	return (byte < 0x80) and 1 -- 1 octet: 0000:0000 - 0111:1111
	or (byte >= 0xC0 and byte < 0xE0) and 2 -- 2 octets: 1100:0000 - 1101:1111	
	or (byte >= 0xE0 and byte < 0xF0) and 3 -- 3 octets: 1110:0000 - 1110:1111
	or (byte >= 0xF0 and byte < 0xF8) and 4 -- 4 octets: 1111:0000 - 1111:0111
	or (byte >= 0x80 and byte < 0xBF) and "trailing octet (2nd, 3rd or 4th) receieved as 1st" -- 1000:0000 - 1011:1111
	or "Unable to determine octet length indicator in first byte of UTF-8 value"
end


--- Check if a code point is bad.
-- @param code_point the numeric Unicode code point to check.
-- @param u8_len How many octets this code point would have if expressed as a UTF-8 code unit. Set to false to disable this check (if the code point didn't originate from a UTF-8 code unit.)
local function _checkCodePointIssue(code_point, u8_len)
	if options.check_surrogates then
		if code_point >= 0xd800 and code_point <= 0xdfff then
			return false, "UTF-8 prohibits values between 0xd800 and 0xdfff (the surrogate range.) Received: "
				.. string.format("0x%x", code_point)
		end
	end

	-- Look for overlong values based on the octet count
	-- (Only applicable if known to have originated from a code unit.)
	if u8_len ~= false then
		local min_max = lut_oct_min_max[u8_len]
		if code_point < min_max[1] or code_point > min_max[2] then
			return false, u8_len .. "-octet length mismatch. Got: " .. code_point
				.. ", must be in this range: " .. min_max[1] .. " - " .. min_max[2]
		end
	end

	return true
end


--- Check if a code unit string is bad.
-- @param str The string provided to getCodeUnit
-- @param pos Position where it failed
-- @return true if no issues found, or false plus error string with a diagnosis attempt
local function _checkCodeUnitIssue(str, pos)
	local b1, b2, b3, b4
	b1 = string.byte(str, pos)
	if not b1 then
		return false, "string.byte() failed at position " .. pos
	end

	-- Bad length marker in octet 1?
	local ok_or_err = _getLengthMarker(b1)
	if type(ok_or_err) == "string" then
		return false, "failed to parse octet Length marker: " .. ok_or_err
	end
	local u8_len = ok_or_err

	-- Check octet 1 against some bytes which are prohibited in any position in a UTF-8 code point
	if utf8Tools.lut_invalid_octet[b1] then
		return false, _errStrInvalidOctet(1, b1)
	end

	local err_str

	-- Check subsequent bytes in longer code units
	-- Two bytes
	if u8_len == 2 then
		b2 = string.byte(str, pos+1)

		err_str = _checkFollowingOctet(b2, 2, u8_len); if err_str then return false, err_str; end

	-- Three bytes
	elseif u8_len == 3 then
		b2, b3 = string.byte(str, pos+1, pos+2)

		err_str = _checkFollowingOctet(b2, 2, u8_len); if err_str then return false, err_str; end
		err_str = _checkFollowingOctet(b3, 3, u8_len); if err_str then return false, err_str; end

	-- Four bytes
	elseif u8_len == 4 then
		b2, b3, b4 = string.byte(str, pos+1, pos+3)

		err_str = _checkFollowingOctet(b2, 2, u8_len); if err_str then return false, err_str; end
		err_str = _checkFollowingOctet(b3, 3, u8_len); if err_str then return false, err_str; end
		err_str = _checkFollowingOctet(b4, 4, u8_len); if err_str then return false, err_str; end
	end

	-- Need to check some more prohibited values
	local num_check = _numberFromOctets(u8_len, b1, b2, b3, b4)
	local point_ok, point_err = _checkCodePointIssue(num_check, u8_len)
	if not point_ok then
		return false, point_err
	end

	return true
end


local function _codePointToBytes(number)
	if number < 0x80 then
		return number

	elseif number < 0x800 then
		local b1 = 0xc0 + math.floor(number / 0x40)
		local b2 = 0x80 + (number % 0x40)

		return b1, b2

	elseif number < 0x10000 then
		local b1 = 0xe0 + math.floor(number / 0x1000)
		local b2 = 0x80 + math.floor( (number % 0x1000) / 0x40)
		local b3 = 0x80 + (number % 0x40)

		return b1, b2, b3

	elseif number < 0x10ffff then
		local b1 = 0xf0 + math.floor(number / 0x40000)
		local b2 = 0x80 + math.floor( (number % 0x40000) / 0x1000)
		local b3 = 0x80 + math.floor( (number % 0x1000) / 0x40)
		local b4 = 0x80 + (number % 0x40)

		return b1, b2, b3, b4
	end
end


local function _bytesToCodeUnit(b1, b2, b3, b4)
	if b4 then
		return string.char(b1, b2, b3, b4)
	elseif b3 then
		return string.char(b1, b2, b3)
	elseif b2 then
		return string.char(b1, b2)
	else
		return string.char(b1)
	end
end

-- / Internal Logic

-- Public Functions -- Main Interface

--- Get a UTF-8 code unit from a string at a specific byte-position.
-- @param str The string to examine.
-- @param pos The starting byte-position of the code unit in the string.
-- @return The code unit, as a string, or nil + error string if unable to get a valid UTF-8 code unit.
function utf8Tools.getCodeUnit(str, pos)
	_assertArgType(1, str, "string")
	_assertArgType(2, pos, "number")

	if pos < 1 or pos > #str then
		return nil, "string index is out of bounds"
	end

	-- Run up to four patterns matching UTF-8 code units, 1-4 bytes in size, anchored to 'pos'.
	-- These patterns exclude bytes forbidden by the RFC (see: lut_invalid_octet)
	local u8_str
	local u8_ptn = options.match_exclude and utf8Tools.u8_ptn_excl_t or utf8Tools.u8_ptn_t
	for i = 1, 4 do
		u8_str = string.match(str, u8_ptn[i], pos)
		if u8_str then
			break
		end
	end

	-- The Lua string library isn't able to communicate why a pattern failed, so if there's
	-- a problem, we'll have to do some additional work to identify the root cause.
	if not u8_str then
		local _, issue = _checkCodeUnitIssue(str, pos)
		issue = issue or "(Diagnosis failed. Possible issue with parsing or error handler?)"

		return nil, "Unable to get code unit: " .. issue
	end

	-- Three-byte code units contain a forbidden surrogate range of 0xd800 to 0xdfff.
	-- In UTF-8 form, this goes from ED A0 80 to ED A3 BF. it can be tested
	-- by checking if the first two bytes are (0xed, 0xa0-0xa3).
	if #u8_str == 3 and options.check_surrogates then
		if string.find(u8_str, "^\xED[\xA0-\xA3]") then
			return nil, "Code point is in the surrogate range, which is invalid for UTF-8"
		end
	end

	return u8_str
end


--- If str[pos] is not a start byte, return the index of the next byte which resembles the first octet of a UTF-8 code unit. Does not validate the following bytes.
-- @param str The string to march through.
-- @param pos Starting position in the string.
-- @return The next start index (or the same old index if it appeared to be a start byte), or nil if none found.
function utf8Tools.step(str, pos)
	_assertArgType(1, str, "string")
	_assertArgType(2, pos, "number")

	if pos < 1 or pos > #str then
		error("argument #2 is out of bounds")
	end

	local i = string.find(str, utf8Tools.u8_oct_1, pos)
	return (i) or nil
end

-- / Public Functions -- Main Interface

-- Public Functions -- Diagnostics

--- Scan a string for bytes that are forbidden by the UTF-8 spec. (see: lut_invalid_octet)
-- @param str The string to check.
-- @return Index and value of the first bad byte encountered, or nil if none found.
function utf8Tools.invalidByteCheck(str)
	_assertArgType(1, str, "string")

	for i = 1, #str do
		local bad_byte = utf8Tools.lut_invalid_octet[string.byte(str, i)]
		if bad_byte then
			return i, string.byte(str, i)
		end
	end

	return nil
end


--- Scan a string for malformed UTF-8 code units (forbidden bytes[*1], code points in the surrogate range[*2], and
--  mismatch between length marker and number of bytes.)
--  [*1] 'options.match_exclude' must be true.
--  [*2] 'options.check_surrogates' must be true.
-- @param str The string to check.
-- @return Index, plus a string which attempts to diagnose the issue, or nil if no malformed code units were found.
function utf8Tools.hasMalformedCodeUnits(str)
	_assertArgType(1, str, "string")

	local i = 1
	while i <= #str do
		local u8_str, err = utf8Tools.getCodeUnit(str, i)
		if not u8_str then
			return i, err
		end
		i = i + #u8_str
	end

	return nil
end

-- / Public Functions: Diagnostics

-- Public Functions: Conversions

--- Try to convert a UTF-8 Code Unit in string form to a Unicode Code Point number.
-- @param unit_str The string to convert. Must be between 1-4 bytes in size.
-- @return The code point in number form, which may be invalid, and an error string if a problem
-- was detected. If the second return value is nil, then this module thinks it's valid. Caller
-- is responsible for deciding whether to accept or deny bad results.
function utf8Tools.u8UnitToCodePoint(unit_str)
	_assertArgType(1, unit_str, "string")
	if #unit_str < 1 or #unit_str > 4 then
		error("argument #1 must be a string 1-4 bytes in size")
	end

	local ok, err = _checkCodeUnitIssue(unit_str, 1)

	local code_point = _numberFromOctets(#unit_str, string.byte(unit_str, 1, 4))

	-- (No point in error-checking the code point if a problem was found with the code unit.)
	if err == nil then
		local _
		_, err = _checkCodePointIssue(code_point, #unit_str)
	end

	return code_point, err
end


--- Try to convert a Unicode Code Point in numeric form to a UTF-8 Code Unit string.
-- @param code_point_num The code point to convert. Must be an integer and at least 0. (WARNING: The high-end limit is not checked.)
-- @return the code unit in string form, which may be invalid, and an error string if there was a problem 
-- validating the code unit.
-- If the second return value is nil, then this module thinks it's valid. Caller is responsible for
-- deciding whether to accept or deny bad results.
function utf8Tools.u8CodePointToUnit(code_point_num)
	if type(code_point_num) ~= "number" or code_point_num < 0 or code_point_num ~= math.floor(code_point_num) then
		error("argument #1 must be an integer >= 0")
	end

	local b1, b2, b3, b4 = _codePointToBytes(code_point_num)
	if not b1 then
		return "�", "failed to convert code point to UTF-8 bytes"
	end

	local u8_unit = _bytesToCodeUnit(b1, b2, b3, b4)
	local ok, err = _checkCodeUnitIssue(u8_unit, 1)

	return u8_unit, err
end

-- / Public Functions: Conversions

return utf8Tools
