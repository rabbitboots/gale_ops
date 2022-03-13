-- Prerelease -- 2022-03-13
local path = ... and (...):match("(.-)[^%.]+$") or ""

-- Object methods for xmlToTable.

--[[
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
--]]

local xmlObj = {}

-- Submodules
local xmlShared = require(path .. "xml_shared")
local _assertArgType = xmlShared.assertArgType
local _assertArgNumGE = xmlShared.assertArgNumGE

-- Entity metatables

-- Elements
local _mt_element = {}
_mt_element.__index = _mt_element
xmlObj._mt_element = _mt_element

local _mt_parser_root = {}
_mt_parser_root.__index = _mt_parser_root
xmlObj._mt_parser_root = _mt_parser_root

local _mt_parser_char_data = {}
_mt_parser_char_data.__index = _mt_parser_char_data
xmlObj._mt_parser_char_data = _mt_parser_char_data



-- XXX Consider removing. The same thing can be accomplished by setting 'options.keep_insignificant_whitespace' to false.
--[=[
--- Recursively delete all character data entities which contain only whitespace.
-- @param self The calling entity.
-- @return Nothing.
local function _stripWhitespaceNodes(self)
	-- Don't assert 'self'

	for i = #self.children, 1, -1 do
		local child = self.children[i]

		if child.id == "character_data" then
			if not string.find(child.text, "%S") then
				table.remove(self.children, i)
			end

		elseif child.id == "element" then
			child:stripWhitespaceNodes()
		end
	end
end
_mt_parser_root.stripWhitespaceNodes = _stripWhitespaceNodes
_mt_element.stripWhitespaceNodes = _stripWhitespaceNodes
--]=]

--- Get an attribute key="value" pair based on its key.
-- @param The calling entity.
-- @param key_id String ID to check.
-- @return The attribute value, or nil if it wasn't populated in this element.
local function _getAttribute(self, key_id)
	-- Don't assert 'self'
	_assertArgType(1, key_id, "string")

	local index = self.attribs_hash[key_id]
	local attrib_t = self.attribs[index]

	if attrib_t then
		return attrib_t.value
	end

	return nil
end
_mt_element.getAttribute = _getAttribute
-- The parser root isn't part of the XML document and doesn't have attributes


--- Find the first child element starting from 'i' with the name 'id'.
-- @param id String ID of the child element.
-- @param i (Default: 1) Where to start searching in the child table.
-- @return Child element table and child index, or nil if not found or if the list is empty.
local function _findChild(self, id, i)
	-- Don't assert 'self'
	i = (i == nil) and 1 or i
	_assertArgType(1, id, "string")
	_assertArgNumGE(2, i, 1)

	if i == 1 and #self.children == 0 then
		return nil
	end

	for ii = i, #self.children do
		local child = self.children[ii]
		if child.name == id then
			return child, ii
		end
	end
	return nil
end
_mt_parser_root.findChild = _findChild
_mt_element.findChild = _findChild

return xmlObj
