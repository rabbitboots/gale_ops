-- Prerelease -- 2022-03-13
local path = ... and (...):match("(.-)[^%.]+$") or ""

local xmlToTable = {
	_VERSION = "0.9.4", -- prerelease version, packaged with galeOps
	--_URL = "n/a: pending initial release",
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
	* Notes *

	* UTF-16 encoding is not supported yet. (The spec mandates it.)

	* The XML Declaration is parsed, but the parser doesn't actually do anything
	with the info yet.

	* DTDs (!DOCTYPE) tags are not implemented yet. The parser will throw an error
	upon encountering this tag.

	* This file should cooperate with 'strict.lua', a common Lua troubleshooting
	snippet / library.
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

-- Confirm that XML Names conform to the characters in 'lut_name_start_char' and 'lut_name_char'.
options.validate_names = true

-- Fail on duplicate attribute delcarations within an element.
-- (The spec forbids this.)
options.check_dupe_attribs = true

-- Allow bad escape sequences through as-is, so long as they start with '&' and end with ';'
-- Not recommended, and forbidden by the spec.
options.ignore_bad_escapes = false

-- Keep character data entities which are comprised solely of whitespace between element tags
options.keep_insignificant_whitespace = false


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


local lut_attrib_escape = {["<"] = "lt", [">"] = "gt", ["&"] = "amp", ["\""] = "quot", ["'"] = "apos"}
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


local xml_defs = {}
xml_defs.comment_start = "(^<!%-%-)"

xml_defs.pi_end = "^(%?>)"
xml_defs.tag_close_start = "^(</"
xml_defs.tag_start = "^(<)"

xml_defs.name = "^([^%s=\"'<>/&]+)"

xml_defs.decl_version_info = "^%s+version"
xml_defs.decl_version_num = "^([\"'])(1%.[0-9]+)%1"
xml_defs.decl_encoding = "^%s+encoding"
xml_defs.decl_standalone = "^%s+standalone"

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


local function unescapeXMLString(sub_str)
	local seq = {}
	local i, j, chunk = 1, 0, nil

	-- Prepass: if no ampersands, just return the original string without going through
	-- the trouble of table.concat().
	if not string.find(sub_str, "&") then
		return sub_str
	end

	while true do
		local last_pos = i
		i, j = string.find(sub_str, "&", j + 1)

		-- End of string
		if not i then
			table.insert(seq, string.sub(last_pos, #sub_str))
			break
		end

		local pos_amp = i

		i, j, chunk = string.find(sub_str, "(.-);", j + 1)
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
	self:fetchReq("^=", "failed to parse eq (=) separating key-value pair")
	self:ws()
end


local function getQuoted(self, err_reason)
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
	local name = self:fetch(xml_defs.name)

	if name and options.validate_names then
		validateXMLName(self, name)

	-- If 'err' was populated, throw an error. Silently ignore match failure otherwise.
	elseif err then
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

	self:fetchReq(xml_defs.decl_version_info, "couldn't read xmlDecl mandatory version identifier")
	stepEq(self)

	self:capReq(xml_defs.decl_version_num, "couldn't read xmlDecl version value")
	version_num = self.c[2]

	if self:fetch(xml_defs.decl_encoding) then
		stepEq(self)
		encoding_val = getQuoted(self, "couldn't read xmlDecl encoding value")
	end

	if self:fetch(xml_defs.decl_standalone) then
		stepEq(self)
		standalone_val = getQuoted(self, "couldn't read xmlDecl standalone value")
	end

	self:fetchReq(xml_defs.pi_end, "couldn't find xmlDecl closing '?>'")

	local entity = {}
	entity.id = "xml_decl"
	entity.decl_version = version_num
	entity.decl_encoding = encoding_val
	entity.decl_standalone = standalone_val
	-- no metatable

	return entity
end


local function getXMLComment(self, xml_state)

	-- Find the comment close and collect an exclusive substring
	local pos_start = self.pos

	self:fetchReq("%-%-", "couldn't find closing '--'")
	self:fetchReq("^>", "couldn't find '>' to go with closing '--'")

	local pos_end = self.pos - 4

	local entity = {}
	entity.id = "comment"
	entity.data = string.sub(self.str, pos_start, pos_end)
	-- no metatable

	-- Don't escape comments

	return entity
end


local function getXMLProcessingInstruction(self, xml_state)
	local pi_name = getXMLName(self, "failed to read PI name")

	-- Find the PI close and collect an exclusive substring
	local pos_start = self.pos
	self:fetchReq("%?>", "failed to locate PI tag close ('?>')")

	local pos_end = self.pos - 2

	local entity = {}
	entity.id = "pi"
	entity.name = pi_name
	entity.data = string.sub(self.str, pos_start, pos_end)
	-- no metatable

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
			local a_val = getQuoted(self, "fetching element quoted attribute value failed")

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
		if self:lit("<![CDATA[") then
			local pos_start = self.pos
			-- Find closing CDATA tag.
			self:fetchReq("%]%]>", "couldn't find closing CDATA tag")
			local pos_end = self.pos - 3

			-- Don't escape CDATA Sections.
			table.insert(con_t, string.sub(self.str, pos_start, pos_end))
			break

		else
			local pos_start = self.pos
			local pos_end
			-- Need some special handling to account for whitespace following the end of the
			-- root element (which is permitted) versus non-ws pcdata (which is disallowed)
			if not xml_state.doc_close then
				self:fetchReq("<", "Couldn't find '<' that ends character data")
				self.pos = self.pos - 1
				pos_end = self.pos - 1

			else
				if self:fetchOrEOS("<") then
					self.pos = self.pos - 1
				end
				pos_end = self.pos - 1
			end

			local str_esc, esc_err = unescapeXMLString(string.sub(self.str, pos_start, pos_end))
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


function xmlToTable._parseLoop(self, xml_state, stack)

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

-- Public Functions

function _parsePrepass(str)
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

	return true
end


function xmlToTable.convert(str)
	_assertArgType(1, str, "string")

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

	-- Only run the prepass if any checks are true.
	if options.prepass then
		for k, v in pairs(options.prepass) do
			if v == true then
				_parsePrepass(str)
				break
			end
		end
	end

	-- Skip leading whitespace
	self:ws()

	local stack = {xml_state}

	xmlToTable._parseLoop(self, xml_state, stack)

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

-- XXX Disabled for prerelease version to be bundled with galeOps.
--[=[
local function _dumpTree(entity, seq, _depth)
	for i, entity in ipairs(children) do
		if depth > 0 then
			table.insert(string.rep(" ", _depth))
		end

		if entity.id == "element" then
			table.insert(seq, "<" .. entity.name)
			if #entity.attribs > 0 then
				table.insert(seq, " ")
				for j, attrib in ipairs(entity.attribs) do
					-- Switch quotes depending on attrib contents
					local quote = "\""
					if string.find(attrib.value, "\"") then
						quote = "'"
					end
					table.insert(seq, attrib.name .. "=\"" .. attrib.value .. "\"")
					if j < #entity.attribs then
						table.insert(seq, " ")
					end
				end
			end
			if #entity.children == 0 then
				table.insert(seq, "/>\n")

			else
				table.insert(seq, ">\n")
				_dumpTree(entity, seq, _depth + 1)
				table.insert(seq, "</" .. entity.name .. ">\n")
			end
		--[[
		elseif entity.id == "comment" then
			table.insert(seq, "<!--")
			table.insert(seq, entity.data)
			table.insert(seq, "-->\n")
		--]]
		elseif entity.id == "pi" then
			table.insert(seq, "<?" .. entity.name .. " " .. entity.data .. "?>")
			table.insert(seq, "\n")

		elseif entity.id == "character_data" then
			table.insert(seq, entity.text)
			table.insert(seq, "\n")

		else
			table.insert(seq, "(unknown element content)\n")
		end
	end
end


function xmlToTable.dumpTree(entity)
	_assertArgType(1, entity, "table")

	local seq = {}

	-- Handle stuff that is outside of the root element
	if entity.id == "_parser_object_" then
		if entity.decl then
			table.insert(seq, "<?xml")
			if entity.decl_version then
				table.insert(seq, " version=\"" .. entity.decl_version .. "\"")
			end
			if entity.decl_encoding then
				table.insert(seq, " encoding=\"" .. entity.decl_encoding .. "\"")
			end
			if entity.decl_standalone then
				table.insert(seq, " standalone=\"" .. entity.decl_standalone .. "\"")
			end
			table.insert(seq, "?>")
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
--]=]

-- / Public Functions

return xmlToTable
