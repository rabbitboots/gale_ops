local path = ... and (...):match("(.-)[^%.]+$") or ""

local xmlToTable = {
	_VERSION = "1.0.0",
	_URL = "https://github.com/rabbitboots/xml_to_table",
	_DESCRIPTION = "Converts a subset of XML to a Lua table.",
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
	This file should cooperate with 'strict.lua', a common Lua troubleshooting snippet / library.
--]]

-- Submodules
local xmlObj = require(path .. "xml_obj")

local xmlShared = require(path .. "xml_shared")
local _assertArgType = xmlShared.assertArgType
local _assertArgNumGE = xmlShared.assertArgNumGE


-- Libraries
local utf8Tools = require(path .. "lib.utf8_tools")
local stringReader = require(path .. "lib.string_reader")
local labelStack = require(path .. "lib.label_stack")

-- Module-wide config
local options = {}
xmlToTable.options = options

options.prepass = {}
-- Check entire XML string for Nul chars, which are prohibited by the spec.
options.prepass.doc_check_nul = true

-- Check entire XML string for code points that are not supported per the spec.
options.prepass.doc_check_xml_unsupported_chars = true

-- Convert '\r\n' and '\r' to '\n', per the spec. You may disable this if you control the incoming
-- XML strings, and know for a fact that they are already normalized. (Doing this in Lua may
-- generate up to two temporary versions of the XML document string.)
options.prepass.normalize_end_of_line = true

-- Confirm that XML Names conform to the characters in 'lut_name_start_char' and 'lut_name_char'.
options.validate_names = true

-- Fail on duplicate attribute declarations within an element.
-- (The spec forbids this.)
options.check_dupe_attribs = true

-- Allow bad escape sequences through as-is, so long as they start with '&' and end with ';'
-- Not recommended, and forbidden by the spec.
options.ignore_bad_escapes = false

-- Keep character data entities which are comprised solely of whitespace between element tags
options.keep_insignificant_whitespace = false -- XXX this may not be working correctly.


-- Lookup Tables and Patterns

-- Set up a lookup table
local function makeLUT(t)
	local lut = {}
	for i, v in ipairs(t) do
		lut[v] = true
	end
	return lut
end


-- Set up an inverse lookup table
local function makeInverseLUT(t)
	local lut = {}
	for k, v in pairs(t) do
		lut[v] = k
	end
	return lut
end


--- Check if a value is within one of a series of ranges.
local function checkRangeLUT(lut, value)
	for _, range in ipairs(lut) do
		if type(range) == "number" then
			if value == range then
				return true
			elseif value < range then
				return false
			end
		else
			if value >= range[1] and value <= range[2] then
				return true
			elseif value < range[1] then
				return false
			end
		end
	end
	return false
end


local lut_attrib_escape = {
	["<"] = "lt",
	[">"] = "gt",
	["&"] = "amp",
	["\""] = "quot",
	["'"] = "apos"
}
-- "&#n;", where 'n' is a series of 0-9 digits
-- "&#xn;", where 'n' is a series of 0-f hex values
local lut_attrib_reverse = makeInverseLUT(lut_attrib_escape)


-- Valid code points and code point ranges for an XML document as a whole.
-- https://www.w3.org/TR/xml/#charsets
-- https://en.wikipedia.org/wiki/Valid_characters_in_XML
local lut_xml_unicode = {
	0x0009,
	0x000a,
	0x000d,
	{0x0020, 0xd7ff},
	{0xe000, 0xfffd},
	{0x10000, 0x10ffff},
}

-- Valid code points for the start of a name
local lut_name_start_char = {
	string.byte(":"),
	{string.byte("A"), string.byte("Z")},
	string.byte("_"),
	{string.byte("a"), string.byte("z")},
	{0xC0, 0xD6},
	{0xD8, 0xF6},
	{0xF8, 0x2FF},
	{0x370, 0x37D},
	{0x37F, 0x1FFF},
	{0x200C, 0x200D},
	{0x2070, 0x218F},
	{0x2C00, 0x2FEF},
	{0x3001, 0xD7FF},
	{0xF900, 0xFDCF},
	{0xFDF0, 0xFFFD},
	{0x10000, 0xEFFFF},
}

-- Valid code points for names. (This is in addition to lut_name_start_char.)
local lut_name_char = {
	string.byte("-"),
	string.byte("."),
	{string.byte("0"), string.byte("9")},
	0xB7,
	{0x0300, 0x036F},
	{0x203F, 0x2040},
}

-- / Lookup Tables and Patterns

local function indent(reps)
	return string.rep(" ", reps)
end


--- Parse an escaped character (ie &lt;)
-- @param chunk Contents of the escape sequence, with the opening '&' and closing ';' omitted.
-- @return the code unit, or the original chunk plus error string if there was a problem. Caller is responsible
-- for deciding whether to use the bad data or not. When called through gsub, this second
-- return value is discarded.
local function _unescape(chunk)
	-- Direct escape match?
	if lut_attrib_reverse[chunk] then
		return lut_attrib_reverse[chunk]

	-- Try numeric codes
	elseif string.sub(chunk, 1, 1) == "#" then
		-- Decimal (&#n;)
		local base, start_i = 10, 2

		-- Adjustments for hex numbers (&#xn;)
		if string.sub(chunk, 2, 2) == "x" then
			base, start_i = 16, 3
		end

		local code_from_str = tonumber(string.upper(string.sub(chunk, start_i, #chunk)), base)
		if not code_from_str then
			return chunk, "parsing numeric escape value failed"
		end

		local u8_unit, err = utf8Tools.u8CodePointToUnit(code_from_str)
		if err then
			return chunk, "code point to code unit conversion failed"
		end

		return u8_unit
	end

	return chunk, "no escape match found"
end


--- Normalize whitespace characters (0x20, 0xD, 0xA, 0x9) to 0x20 (" ")
local function normalizeAttribWhitespace(str)
	-- https://www.w3.org/TR/REC-xml/#AVNormalize
	return string.gsub(str, "[\x20\x0D\x0A\x09]", "\x20")
end


local function unescapeXMLString(sub_str)
	if string.match(sub_str, "<") then
		return false, "'<' literal is not allowed in quoted values."
	end

	-- Convert whitespace symbols to 0x20 (" ")
	sub_str = normalizeAttribWhitespace(sub_str)

	-- Prepass: if no ampersands, just return the original string without going through
	-- the trouble of table.concat().
	if not string.find(sub_str, "&") then
		return sub_str
	end

	local seq = {}
	local i, j, chunk = 1, 0, nil

	while true do
		local last_pos = i
		i, j = string.find(sub_str, "&", j + 1)

		-- End of string
		if not i then
			table.insert(seq, string.sub(sub_str, last_pos, #sub_str))
			break
		end

		local pos_amp = i

		i, j, chunk = string.find(sub_str, "^(.-);", j + 1)
		if not i then
			return false, "couldn't parse escape sequence: found '&' without closing ';'"
		end

		-- Add string contents from last point to just before ampersand
		table.insert(seq, string.sub(sub_str, last_pos, pos_amp - 1))

		-- Advance past semicolon
		i = j + 1

		local u8_unit, err = _unescape(chunk)
		if err then
			if not options.ignore_bad_escapes then
				return false, "unknown escape code (failure to parse content between '&' and ';')"

			else
				-- This seems like a very bad idea, but it might be helpful when debugging.
				u8_unit = "&" .. chunk .. ";"
			end
		end
		table.insert(seq, u8_unit)
	end

	return table.concat(seq)
end


--- gsub-powered version of unescapeXMLString(). Probably faster, but doesn't handle failure scenarios.
--[[
local function unescapeXMLString(sub_str) -- XXX untested
	return string.gsub(sub_str, "&(.*);", _unescape)
end
--]]


local function stepEq(self)
	self:ws()
	self:fetchReq("^=", false, "failed to parse eq (=) separating key-value pair")
	self:ws()
end

local function getAttribQuoted(self, err_reason)
	--[[
	NOTE: illegal use of the '<' literal appearing in quoted text is checked in unescapeXMLString().
	--]]
	self:cap("^([\"'])(.-)%1")
	local in_quotes = self.c[2]
	self:clearCaptures()

	-- Raise error only if 'err_reason' was populated
	if not in_quotes and err_reason then
		self:errorHalt(err_reason)
	end

	local esc, esc_err = unescapeXMLString(in_quotes)
	if esc_err then
		self:errorHalt(esc_err)
	end

	return esc
end


local function validateXMLName(self, name)
	for i = 1, #name do
		local u8_unit, u8_err = utf8Tools.getCodeUnit(name, i)
		if not u8_unit then
			self:errorHalt("failed to read character #" .. i .. " in XML Name: " .. u8_err)
		end

		local u8_code = utf8Tools.u8UnitToCodePoint(u8_unit)
		if not u8_code then
			self:errorHalt("failed to convert character #" .. i .. " in XML Name to a code point")
		end

		if not checkRangeLUT(lut_name_start_char, u8_code) then
			if i == 1 then
				self:errorHalt("invalid first character in XML Name")

			elseif not checkRangeLUT(lut_name_char, u8_code) then
				self:errorHalt("invalid character #" .. i .. " in XML Name")
			end
		end
	end
end


local function getXMLName(self, err)
	local name = self:fetch("^([^%s=\"'<>/&]+)")

	if name and options.validate_names then
		validateXMLName(self, name)

	-- If 'err' was populated, throw an error. Silently ignore match failure otherwise.
	elseif not name then
		self:errorHalt(err)
	end

	return name
end


local function getXMLDecl(self, xml_state, pos_initial)
	if pos_initial ~= 1 then
		self:errorHalt("XML Declaration can only appear at start of document")
	end
	-- The other forbidden stuff -- max 1 xmlDecl per document, no xmlDecl after
	-- document root is declared -- are prevented by the requirement for it to
	-- be the very first thing in the doc with no preceding whitespace.

	local version_num, encoding_val, standalone_val

	self:fetchReq("^%s+version", false, "couldn't read xmlDecl mandatory version identifier")
	stepEq(self)

	self:capReq("^([\"'])(1%.[0-9]+)%1", "couldn't read xmlDecl version value")
	version_num = self.c[2]

	if self:fetch("^%s+encoding") then
		stepEq(self)
		encoding_val = getAttribQuoted(self, "couldn't read xmlDecl encoding value")
	end

	if self:fetch("^%s+standalone") then
		stepEq(self)
		standalone_val = getAttribQuoted(self, "couldn't read xmlDecl standalone value")
	end

	self:fetchReq("^(%?>)", false, "couldn't find xmlDecl closing '?>'")

	local decl = {}
	decl.id = "xml_decl"
	decl.version = version_num
	decl.encoding = encoding_val
	decl.standalone = standalone_val
	-- no metatable

	return decl
end


local function getXMLComment(self, xml_state)

	-- Find the comment close and collect an exclusive substring
	local pos_start = self.pos

	self:fetchReq("%-%-", false, "couldn't find closing '--'")
	self:fetchReq("^>", false, "couldn't find '>' to go with closing '--'")

	local pos_end = self.pos - 4

	--[[
	local entity = {}
	entity.id = "comment"
	entity.text = string.sub(self.str, pos_start, pos_end)
	-- no metatable

	-- Don't escape comments

	return entity
	--]]
end


local function getXMLProcessingInstruction(self, xml_state)
	local pi_name = getXMLName(self, "failed to read PI name")

	-- Find the PI close and collect an exclusive substring
	local pos_start = self.pos
	self:fetchReq("%?>", false, "failed to locate PI tag close ('?>')")

	local pos_end = self.pos - 3

	local entity = {}
	entity.id = "pi"
	entity.name = pi_name
	entity.text = string.sub(self.str, pos_start, pos_end)
	setmetatable(entity, xmlObj._mt_pi)

	-- Don't escape PI contents.
	-- Application is responsible for parsing this, basically.

	return entity
end


local function getXMLDocType(self, xml_state)
	if xml_state.doc_root then
		self:errorHalt("Document Type Declaration cannot appear once document root is declared.")

	elseif xml_state.doc_type then
		self:errorHalt("Only one Document Type Declaration is permitted per document.")
	end

	error("sorry, !DOCTYPE tags are not supported yet")
end


local function getXMLElement(self, xml_state)
	if xml_state.doc_close then
		self:errorHalt("element appears after root element close")
	end

	local element_name = getXMLName(self, "failed to read element name")

	local attribs = {}
	local attribs_hash = {}
	local is_empty_tag = false

	if self:lit(">") then
		-- Just eat the char

	elseif self:lit("/>") then
		is_empty_tag = true

	else
		self:wsReq("missing required space after element name")

		-- Loop to get key-value attribute pairs
		while true do
			if self:isEOS() then
				self:errorHalt("reached end of file while looping for element attribs.")

			elseif self:lit(">") then
				break

			elseif self:lit("/>") then
				is_empty_tag = true
				break
			end

			local a_name = getXMLName(self, "fetching element attrib key failed")

			if options.check_dupe_attribs and attribs_hash[a_name] then
				self:errorHalt("duplicate element attribute key")
			end
			stepEq(self)
			local a_val = getAttribQuoted(self, "fetching element quoted attribute value failed")

			local attrib = {}

			attrib.name = a_name
			attrib.value = a_val

			table.insert(attribs, attrib)
			attribs_hash[a_name] = #attribs

			self:ws()
		end
	end

	local entity = {}
	entity.id = "element"
	entity.name = element_name
	entity.attribs = attribs
	entity.attribs_hash = attribs_hash
	entity.children = {}

	setmetatable(entity, xmlObj._mt_element)

	return entity, is_empty_tag
end


local function getXMLCharacterData(self, xml_state)

	local con_t = {}

	-- NOTE: This handles both character data and "CDATA" sections. As CDATA is essentially a
	-- way to escape characters that otherwise don't play well with XML, I have opted to
	-- combine them into one text entity.
	while true do
		-- CDATA sections
		if self:lit("<![CDATA[") then
			local pos_start = self.pos
			-- Find closing CDATA tag.
			self:fetchReq("%]%]>", false, "couldn't find closing CDATA tag")
			local pos_end = self.pos - 3

			-- Don't escape CDATA Sections.
			table.insert(con_t, string.sub(self.str, pos_start, pos_end))
			break

		-- Normal Character Data sections
		else
			local pos_start = self.pos
			local pos_end
			-- Need some special handling to account for whitespace following the end of the
			-- root element (which is permitted) versus non-ws pcdata (which is disallowed)
			if not xml_state.doc_close then
				self:fetchReq("<", false, "Couldn't find '<' that ends character data")
				self.pos = self.pos - 1
				pos_end = self.pos - 1

			else
				if self:fetch("<") then
					self.pos = self.pos - 1
				else
					self:goEOS()
				end
				pos_end = self.pos - 1
			end

			local temp_str = string.sub(self.str, pos_start, pos_end)
			-- https://www.w3.org/TR/REC-xml/#syntax
			if string.match(temp_str, "%]%]>") then
				self:errorHalt("the sequence ']]>' is not permitted in plain character data")
			end

			local str_esc, esc_err = unescapeXMLString(temp_str)
			if esc_err then
				self:errorHalt(esc_err)
			end

			table.insert(con_t, str_esc)
			break
		end
	end

	local combined = table.concat(con_t)

	local contains_non_whitespace = string.find(combined, "%S")
	if contains_non_whitespace then
		if not xml_state.doc_root then
			self:errorHalt("Character data appears before root element is declared")
		end
		if xml_state.doc_close then
			self:errorHalt("Character data appears after root element close")
		end
	end

	local entity = {}
	entity.id = "character_data"
	entity.text = combined
	setmetatable(entity, xmlObj._mt_parser_char_data)

	return entity
end


local function handleXMLClosingTag(self, xml_state, top)
	local close_name = getXMLName(self, "Couldn't read closing tag name")
	self:ws()
	self:litReq(">", "Couldn't read '>' for closing tag")
	if top.id ~= "element" or top.name ~= close_name then
		self:errorHalt("Opening/closing tag name mismatch")
	end
end


local function handleXMLCharacterData(self, xml_state, top, entity)
	if options.keep_insignificant_whitespace or string.find(entity.text, "%S") then
		-- If the previous entity was also character data, merge their contents
		local entity_prev = top.children[#top.children]
		if entity_prev and entity_prev.id == "character_data" then
			entity_prev.text = entity_prev.text .. entity.text

		else
			table.insert(top.children, entity)
		end
	end
end


local function _parseLoop(self, xml_state, stack)

	while true do
		xml_state.label:push("_parseLoop")

		local top = stack[#stack]
		local pos_initial = self.pos

		-- End of string
		if self:isEOS() then
			if not xml_state.doc_root then
				self:errorHalt("reached end of string without finding opening root tag")

			elseif not xml_state.doc_close then
				self:errorHalt("reached end of string without closing root element")
			end
			xml_state.label:pop()
			break

		-- XML Declaration
		elseif self:lit("<?xml") then
			xml_state.label:push("xmlDecl")

			xml_state.decl = getXMLDecl(self, xml_state, pos_initial)
			self:ws()

			xml_state.label:pop()

		-- Document Type Declaration / DTD
		elseif self:lit("<!DOCTYPE") then
			xml_state.label:push("XML DocType")

			xml_state.doc_type = getXMLDocType(self, xml_state)

			xml_state.label:pop()

		-- XML Comment
		elseif self:lit("<!--") then
			xml_state.label:push("XML Comment")

			-- Can appear after doc root close.
			local entity = getXMLComment(self, xml_state)
			-- Attaching comments would break character data nodes
			--table.insert(top.children, entity)
			self:ws()

			xml_state.label:pop()

		-- Processing Instruction / PI
		elseif self:lit("<?") then
			xml_state.label:push("XML PI")

			-- Can appear after doc root close.
			local entity = getXMLProcessingInstruction(self, xml_state)
			table.insert(top.children, entity)
			self:ws()

			xml_state.label:pop()

		-- Character Data -- CDATA entry point
		elseif self:peek(0, #"<![CDATA["-1) == "<![CDATA[" then
			xml_state.label:push("XML Character Data (CDATA Entry Point)")

			local entity = getXMLCharacterData(self, xml_state)
			handleXMLCharacterData(self, xml_state, top, entity)

			xml_state.label:pop()

		-- Closing tag
		elseif self:lit("</") then
			xml_state.label:push("XML Closing Tag")

			handleXMLClosingTag(self, xml_state, top)
			table.remove(stack)

			-- If we're back at the parser root, mark the document as closed.
			-- Comments, PIs, and whitespace may appear after the root element
			-- close tag.
			if #stack == 1 then
				xml_state.doc_close = true
			end

			xml_state.label:pop()

		-- Element
		elseif self:lit("<") then
			xml_state.label:push("XML Element")

			local entity, is_empty = getXMLElement(self, xml_state)

			-- Was this the document root?
			if not xml_state.doc_root then
				xml_state.doc_root = true
			end

			table.insert(top.children, entity)
			if not is_empty then
				table.insert(stack, entity)
			end

			self:ws()

			xml_state.label:pop()

		-- Character Data - non-CDATA entry point
		elseif self:peek() ~= "<" then
			xml_state.label:push("XML Character Data (non-CDATA Entry Point)")

			local entity = getXMLCharacterData(self, xml_state)
			handleXMLCharacterData(self, xml_state, top, entity)

			xml_state.label:pop()

		else
			xml_state.label:push("Unhandled Chunk")

			self:errorHalt("XML parsing failed. (Unable to read XMLDecl, PI, Comment, Character Data, CDATA Section or Element Open/Close)")

			xml_state.label:pop()
		end

		xml_state.label:pop()
	end
end


local function _parsePrepass(str)
	_assertArgType(1, str, "string")

	local err_pre = "XML prepass failure: "

	--[[
	Main Loop: UTF-8 Code Units
	Aux Loop: Individual bytes -- only runs if one of the associated options are active
	--]]

	local do_aux_loop = false
	if options.prepass.doc_check_nul then
		do_aux_loop = true
	end

	local i = 1
	while i <= #str do
		if i > #str then
			break
		end

		local u8_code, err = utf8Tools.getCodeUnit(str, i)
		if not u8_code then
			return false, err_pre .. "couldn't parse code unit at byte #" .. i .. ": " .. err
		end

		-- Check for UTF-8 code points that are explictly unsupported by the XML spec.
		-- This also checks for malformed code units, as it has to parse every code unit
		-- in the string.
		if options.prepass.doc_check_xml_unsupported_chars then
			local code_point = utf8Tools.u8UnitToCodePoint(u8_code)
			if not code_point then
				return false, err_pre .. "failed to convert UTF-8 code unit to Unicode code point. Position :" .. i

			elseif not checkRangeLUT(lut_xml_unicode, code_point) then
				return false, err_pre .. "unsupported character at position: " .. i
			end
		end

		if do_aux_loop then
			for j = 1, #u8_code do
				local byte = string.byte(u8_code, j)
				-- Check for Nul bytes (0000:0000), which are permitted in UTF-8
				-- but forbidden by the XML spec.
				if options.prepass.doc_check_nul then
					if byte == 0 then
						return false, err_pre .. "document cannot contain Nul (/0) bytes. Byte position: " .. i + (j-1)
					end
				end
			end
		end

		i = i + #u8_code
	end

	--[[
	The spec mandates that all instances of "\r\n" (0xd, 0xa) and "\r" (0xd) be normalized to just \n (0xa).
	As far as I can tell, this includes CDATA sections.
	-- https://www.w3.org/TR/REC-xml/#sec-line-ends
	--]]
	if options.prepass.normalize_end_of_line then
		str = string.gsub(str, "\x0D\x0A", "\x0A")
		str = string.gsub(str, "\x0D", "\x0A")
	end

	return str
end

-- Public Functions

function xmlToTable.convert(str)
	_assertArgType(1, str, "string")

	-- Only run the prepass if any checks are true.
	if options.prepass then
		for k, v in pairs(options.prepass) do
			if v == true then
				local err
				str, err = _parsePrepass(str)
				if not str then
					error("XML prepass failed: " .. err)
				end
				break
			end
		end
	end

	local self = stringReader.new(str)

	local xml_state = {}

	xml_state.id = "_parser_object_"
	xml_state.children = {}

	xml_state.decl = false
	xml_state.doc_type = false
	xml_state.doc_root = false
	xml_state.doc_close = false

	-- Debug help
	xml_state.label = labelStack.new()

	--xml_state.label.report_level = 999
	xml_state.label.report_level = 0

	xml_state.label:push("Begin Parse")

	-- Skip leading whitespace
	self:ws()

	local stack = {xml_state}

	_parseLoop(self, xml_state, stack)

	if not xml_state.doc_root then
		self:errorHalt("document root element not found") -- XXX might not ever trigger
	end

	-- NOTE: some entities are permitted after the document root.
	-- Non-whitespace character data is forbidden, though.

	setmetatable(xml_state, xmlObj._mt_parser_root)

	xml_state.label:pop()

	-- Remove build/debug fields
	xml_state.label = nil

	return xml_state
end

local function _indent(seq, level)
	if level > 0 then
		table.insert(seq, string.rep(" " , level))
	end
end

local function _dumpTree(entity, seq, _depth)
	for i, child in ipairs(entity.children) do
		_indent(seq, _depth)

		if child.id == "element" then
			table.insert(seq, "<" .. child.name)
			if #child.attribs > 0 then
				table.insert(seq, " ")
				for j, attrib in ipairs(child.attribs) do
					-- Switch quotes depending on attrib contents
					local quote = "\""
					if string.find(attrib.value, "\"") then
						quote = "'"
					end
					table.insert(seq, attrib.name .. "=\"" .. attrib.value .. "\"")
					if j < #child.attribs then
						table.insert(seq, " ")
					end
				end
			end
			if #child.children == 0 then
				table.insert(seq, " />\n")

			else
				table.insert(seq, ">\n")
				_dumpTree(child, seq, _depth + 1)
				_indent(seq, _depth)
				table.insert(seq, "</" .. child.name .. ">\n")
			end

		elseif child.id == "pi" then
			table.insert(seq, "<?" .. child.name .. " " .. child.text .. "?>")
			table.insert(seq, "\n")

		elseif child.id == "character_data" then
			table.insert(seq, child.text)
			table.insert(seq, "\n")

		else
			table.insert(seq, "(unknown element content)\n")
		end
	end
end


--- Dump a nested Lua table to the terminal, formatted like an XML string. NOTE: this is intended for debugging, and not guaranteed to generate valid XML. No processing is done on the table contents, so if you've made changes since the initial conversion, those will be passed through.
function xmlToTable.dumpTree(entity)
	_assertArgType(1, entity, "table")

	local seq = {}

	-- Handle bits that are outside of the document root
	if entity.id == "_parser_object_" then
		local decl = entity.decl
		if decl then
			table.insert(seq, "<?xml")
			if decl.version then
				table.insert(seq, " version=\"" .. decl.version .. "\"")
			end
			if decl.encoding then
				table.insert(seq, " encoding=\"" .. decl.encoding .. "\"")
			end
			if decl.standalone then
				table.insert(seq, " standalone=\"" .. decl.standalone .. "\"")
			end
			table.insert(seq, "?>\n")
		end

		if entity.doc_type then
			table.insert(seq, "<!-- (!DOCTYPE not implemented yet) -->")
		end

		if entity.doc_root then
			_dumpTree(entity, seq, 0)
		end
	end

	return table.concat(seq)
end

-- / Public Functions

return xmlToTable
