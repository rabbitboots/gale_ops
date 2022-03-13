local path = ... and (...):match("(.-)[^%.]+$") or ""

local galeOps = {
	_VERSION = "1.0.0",
	_URL = "https://github.com/rabbitboots/gale_ops",
	_DESCRIPTION = "A LÖVE module for reading GraphicsGale .gal image files.",
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
	Requirements:
		* LÖVE 11.x
		* Lua 5.3+ utf8 library (LÖVE 0.9.2+ includes it)
		* LuaJIT, and the LuaJIT BitOps library. LÖVE includes these by default.
--]]

--[[
	Layout of a GaleImage table:

	GaleImage
		GalePaletteColors
		GaleFrames
			GaleLayers
--]]


-- LÖVE Supplemental
local utf8 = require("utf8")

-- LuaJIT
local bit = require("bit")
local bAND = bit.band
local bLSHIFT = bit.lshift
local bRSHIFT = bit.rshift

-- Sub-Libraries
local xmlToTable = require(path .. "lib.xml_to_table.xml_to_table")

-- Lookup Tables

-- Some masks for reading in portions of bytes.
local lut_bit_masks = {0x80, 0x40, 0x20, 0x10, 0x8, 0x4, 0x2, 0x1}
local lut_nibble_masks = {0xf0, 0xf}

-- When per-layer opacity is set, Gale images with indexed color apply a 4x4 dither mask instead of semi-transparency.
-- Per-layer opacity and per-layer alpha channel are mutually exclusive.
-- For each 4x4 set of pixels, if opacity >= this number, then it should be visible.
lut_trans_dither_mask = { -- index as [(y-1) % 4 + 1][(x-1) % 4 + 1]
	{  1, 128,  32, 160},
	{192,  64, 224,  96},
	{ 48, 176,  16, 144},
	{240, 112, 208,  80},
}

-- / Lookup Tables

galeOps.layer_options_default = {
	-- If layer visibility is off, return a transparent black pixel.
	respect_visibility = true,

	-- Whether to allow per-layer opacity. Layer alpha channel disables this.
	respect_opacity = true,

	-- Whether to use the layer's transparent color-key ("TransColor"). Layer alpha channel disables this.
	respect_trans_color_key = true,

	indexed_dithered_transparency = true,
}

-- Helper Functions

--- Convert string to floored integer.
-- @param str The string to convert.
-- @return An integer from the string.
local function strToInt(str)
	return math.floor(tonumber(str))
end


local intAttr = function(element, id)
	return assert(strToInt(element:getAttribute(id)), "strToInt(getAttribute()) failed")
end


local strAttr = function(element, id)
	return assert(element:getAttribute(id), "getAttribute() failed")
end


local function tryCloseFile(file)
	if file:isOpen() then
		file:close()
	end
end

-- / Helper Functions

--- Convert string from ISO 8859-1 / Latin 1 to UTF-8.
-- @param str The Latin 1 string to convert.
-- @return A UTF-8 version of the string.
local function latin1ToUTF8(str)
	local temp = {}

	for i = 1, #str do
		temp[#temp + 1] = utf8.char(string.byte(str:sub(i, i)))
	end

	return table.concat(temp)
end


--- Convert a 4-byte binary string to an unsigned Lua number.
-- @param four_byte_str The binary string to convert.
-- @return Unsigned number version of the string.
local function strUint32ToLuaNumber(four_byte_str)
	if type(four_byte_str) ~= "string" then
		return false, "Bad type for arg #1. Expected string, got: " .. type(four_byte_str)

	elseif #four_byte_str ~= 4 then
		return false, "Bad byte size for string in arg #1. Must be 4 bytes, received: " .. tostring(#four_byte_str)
	end

	local a, b, c, d = string.byte(four_byte_str, 1, 4)

	return a + b*0x100 + c*0x10000 + d*0x1000000
end


function debugPrintByteBinary(num)
	if num < 0 or num > 255 or num ~= math.floor(num) then
		error("Bad argument #1: 'num' needs to be an integer in the range of 0 - 255.")
	end

	local mask = 0x80

	while mask >= 1 do
		local value = bAND(num, mask)
		if value ~= 0 then
			value = 1
		end
		io.write(tostring(value))

		mask = mask / 2
	end
	io.write(" ")
end


--- Debug: write decompressed block data to terminal, emitting the header as plain XML and subsequent data blocks as columns of hex numbers.
-- @param emit_mode "xml-header" for the first block, or "hex" or "binary" for the rest.
-- @param block The data block to print out.
-- @return Nothing.
local function debugPrintBlock(emit_mode, block)
	local index = 0

	if #block == 0 then
		print("(Empty Block)")

	elseif emit_mode == "xml-header" then
		local to_text = latin1ToUTF8(block)
		print(to_text)

	elseif emit_mode == "binary" then
		local col = 1
		for i = 1, #block do
			debugPrintByteBinary(string.byte(block, i, i))

			col = col + 1
			if col > 8 then
				col = 1
				io.write("\n")
			end
		end

	elseif emit_mode == "hex" then
		local col = 1
		for i = 1, #block do
			local byte = string.byte(block, i, i)
			io.write(string.format("%02x", byte))
			io.write(" ")

			col = col + 1
			if col > 32 then
				col = 1
				io.write("\n")
			end
		end

	else
		io.write("\n")
		error("Unknown emit_mode: '" .. tostring(emit_mode) .. "'")
	end
	io.write("\n")
end


--- Make a Gale layer table with default/uninitialized header info.
-- @return The layer table.
local function _newGaleLayer()
	local layer = {}

	layer.left = 0
	layer.top = 0
	layer.visible = 1
	layer.trans_color = -1
	layer.alpha = 0 -- AKA opacity
	layer.alpha_on = 0 -- Whether or not the alpha channel is enabled. (NOTE: alpha channel can exist and be disabled for a layer.)
	layer.name = "(Uninitialized)"
	layer.lock = 0

	-- Table of indexed color values or RGB values.
	layer.data = {}

	-- Table of alpha values
	layer.a_data = {}

	-- Holds offset + length for associated compressed data blocks in source Gale file.
	layer._block_offset = -1
	layer._block_bytes = -1
	layer._block_offset_a = -1
	layer._block_bytes_a = -1

	-- Simplifies getPixel()
	layer._bpp = -1
	layer._bg_color = -1
	layer._not_fill_bg = -1
	layer._w = -1
	layer._h = -1
	layer._palette = false -- points to frame.palette

	-- Helps with '_not_fill_bg'
	layer._is_bottom_layer = false

	-- Some options that control how getPixel() works. See 'galeOps.layer_options_default' for values.
	layer._options = false

	return layer
end


--- Make a Gale frame table with default/uninitialized header info.
-- @return The frame table.
local function _newGaleFrame()
	local frame = {}

	frame.name = "(Uninitialized)"

	-- Transparency color key
	frame.trans_color = -1

	-- Frame animation delay time, in milliseconds
	frame.delay = 0

	-- Related to GIF export.
	frame.disposal = 2

	-- In the XML, these are stored in a nested element called 'Layers'
	frame.layer_count = 0
	frame.layer_width = 0
	frame.layer_height = 0
	frame.layer_bpp = 0

	-- Note: layers are stored bottom-to-top.
	frame.layers = {}
	frame.palette = {}

	return frame
end


--- Make a Gale image table with default/uninitialized header info.
-- @return The Gale image table.
local function _newGaleImage()
	local image = {}

	image.version = "(Uninitialized)"
	image.width = 0
	image.height = 0
	image.bpp = 0
	image.count = 0
	image.sync_pal = 0
	image.randomized = 0 -- (Unknown)
	image.comp_type = 0 -- (Unknown)
	image.comp_level = 0 -- (Unknown)
	image.bg_color = 0
	image.block_width = 0 -- (Unknown)
	image.block_height = 0 -- (Unknown)
	image.not_fill_bg = 0

	image.frames = {}

	-- Header offset + length in source Gale file
	image._block_header_offset = -1
	image._block_header_bytes = -1

	return image
end


--- If file isn't open or isn't in read mode, raise an error.
-- @param file The file object to check.
-- @return Nothing.
local function assertFileOpenReadMode(file)
	if not file:isOpen() or file:getMode() ~= "r" then
		tryCloseFile(file)
		error("File object must be open in read (\"r\") mode.")
	end
end


--- Read a length tag from an open file, advancing the file offset by 4 units.
-- @param file The file object to read.
-- @return Size tag, and number of bytes read, or nil, 0 if the number of bytes read was zero.
local function getLengthTag(file)
	local str4b, bytes_read = file:read(4)
	if bytes_read == 0 then
		return nil, 0
	end

	local num, err = strUint32ToLuaNumber(str4b)
	if not num then
		tryCloseFile(file)
		error("getLengthTag(): " .. err)
	end

	return num, bytes_read
end


--- Parse Gale RGB text string to a series of GalePaletteColor tables.
-- @param text The decompressed text to convert.
-- @return Table of GalePaletteColors.
local function _parseRGBText(text)
	local colors = {}

	local i = 1
	while true do
		-- NOTE: Gale palette slots have no alpha value.
		local color = {r = 0, g = 0, b = 0}

		-- Colors are stored in a hex string format as 'BBGGRR'. There is no alpha value.
		color.b = tonumber(string.sub(text, i, i + 1), 16)
		i = i + 2
		color.g = tonumber(string.sub(text, i, i + 1), 16)
		i = i + 2
		color.r = tonumber(string.sub(text, i, i + 1), 16)
		i = i + 2

		colors[#colors + 1] = color

		-- debug
		--print((i-1) / 6, ":", color.r, color.g, color.b)

		if i > #text then
			break
		end
	end

	return colors
end


--- Parse Gale header block from pseudo-XML to a nested Lua table structure. The structure is essentially a skeleton with no graphical data attached.
-- @param header_block The first binary block string, which is the header.
-- @return A skeleton structure with applied header data.
local function _parseHeader(header_block)

	-- debug
	--debugPrintBlock("xml-header", header_block)

	local gal_image = _newGaleImage()

	-- Convert header from latin-1 to UTF-8
	local header_u8 = latin1ToUTF8(header_block)

	--print(header_u8)

	-- Parse XML-like header data.
	local xml_state = xmlToTable.convert(header_u8, true)

	-- Need to do some digging to find the root element.
	local root
	for i, elem in ipairs(xml_state.children) do
		if elem.id == "element" then
			root = elem
			break
		end
	end
	if not root then
		error("Couldn't locate XML root element in GaleImage header.")
	end

	-- Set up 'Frames' header
	gal_image.version = intAttr(root, "Version")
	gal_image.width = intAttr(root, "Width")
	gal_image.height = intAttr(root, "Height")
	gal_image.bpp = intAttr(root, "Bpp")
	gal_image.count = intAttr(root, "Count")
	gal_image.sync_pal = intAttr(root, "SyncPal")
	gal_image.randomized = intAttr(root, "Randomized")
	gal_image.comp_type = intAttr(root, "CompType")
	gal_image.comp_level = intAttr(root, "CompLevel")
	gal_image.bg_color = intAttr(root, "BGColor")

	gal_image.block_width = intAttr(root, "BlockWidth")
	gal_image.block_height = intAttr(root, "BlockHeight")
	gal_image.not_fill_bg = intAttr(root, "NotFillBG")

	-- Set up each frame
	for i, child in ipairs(root.children) do
		local frame = _newGaleFrame()

		frame.name = strAttr(child, "Name")
		frame.trans_color = intAttr(child, "TransColor")
		frame.delay = intAttr(child, "Delay")
		frame.disposal = intAttr(child, "Disposal")

		-- Set up layers within this frame
		local layer_element = child:findChild("Layers")

		frame.layer_count = intAttr(layer_element, "Count")
		frame.layer_width = intAttr(layer_element, "Width")
		frame.layer_height = intAttr(layer_element, "Height")
		frame.layer_bpp = intAttr(layer_element, "Bpp")

		gal_image.frames[#gal_image.frames + 1] = frame

		-- Run through the layers.
		-- Because of how elements are nested, 'Frames' only has one child. To access the
		-- real layer data, you need to read frame's child's children.		
		local layer_set = child.children[1].children

		for i = 1, #layer_set do
			local sub = layer_set[i]

			-- For indexed color files, the palette is the first child element within the layers element.
			-- This is not included in the header's count of layers.
			if sub.name == "RGB" then
				frame.palette = _parseRGBText(sub.children[1].text)

			elseif sub.name == "Layer" then

				local layer = _newGaleLayer()

				layer.left = intAttr(sub, "Left")
				layer.top = intAttr(sub, "Top")
				layer.visible = intAttr(sub, "Visible")
				layer.trans_color = intAttr(sub, "TransColor")
				layer.alpha = intAttr(sub, "Alpha")
				layer.alpha_on = intAttr(sub, "AlphaOn")
				layer.name = strAttr(sub, "Name")
				layer.lock = intAttr(sub, "Lock")

				layer._bpp = gal_image.bpp
				layer._bg_color = gal_image.bg_color
				layer._not_fill_bg = gal_image.not_fill_bg
				layer._w = frame.layer_width
				layer._h = frame.layer_height
				layer._palette = frame.palette

				if i == 1 then
					layer._is_bottom_layer = true
				end

				frame.layers[#frame.layers + 1] = layer

				-- Layer data will be added after all blocks are split and decompressed.
			end
		end
	end

	return gal_image
end


--- Load and decompress one Gale data block.
-- @param gal_file The file object containing compressed data. Must be opened in read mode ("r") before calling.
-- @param offset Starting offset of the block in the file (after the 4-byte size tag.)
-- @param bytes Length of the block in bytes.
-- @return Decompressed block string.
local function _loadBlock(gal_file, offset, bytes)
	assertFileOpenReadMode(gal_file)

	-- XXX check gal_image type
	if type(offset) ~= "number" or offset < 0 or offset ~= math.floor(offset) then
		tryCloseFile(gal_file)
		error("Bad argument #2: 'offset' must be a whole number >= 0.")

	elseif type(bytes) ~= "number" or bytes < 0 or bytes ~= math.floor(bytes) then
		tryCloseFile(gal_file)
		error("Bad argument #3: 'bytes' must be a whole number >= 0.")
	end

	gal_file:seek(offset)

	local decompressed_block

	-- NOTE: When a layer has no alpha channel, GraphicsGale still assigns a zero-length block.
	if bytes > 0 then
		local compressed_data = gal_file:read(bytes)

		if #compressed_data ~= bytes then
			tryCloseFile(gal_file)
			error("Compressed Block data doesn't match size tag")
		end

		decompressed_block = love.data.decompress("string", "zlib", compressed_data)

	-- Assign empty string
	else
		decompressed_block = ""
	end

	return decompressed_block
end



--- Load a Gale file's header and block offsets, only loading the remaining block data if specified.
-- @param gal_file The source Gale file to load. Must be open in read ("r") mode.
-- @param load_immediately If true, load, decompress and parse blocks as their offsets are determined.
-- @return GaleImage skeleton with header decompressed and layer offsets assigned.
function galeOps.loadSkeleton(gal_file, load_immediately)
	assertFileOpenReadMode(gal_file)
	gal_file:seek(0)

	-- Verify version string
	local version_string = gal_file:read(8)

	-- Unsupported file formats
	local check_old_ver = string.sub(version_string, 1, 7)
	if check_old_ver == "Gale102" or check_old_ver == "Gale106" then
		error("Sorry, the .gal format version '" .. check_old_ver .. "' is not supported by this script. Try loading and saving the .gal file in the latest version of GraphicsGale.")
	end

	if version_string ~= "GaleX200" then
		tryCloseFile(gal_file)
		error("Couldn't parse Gale version string at start of file.")
	end

	local offset_pos = 8 -- skip version string

	-- Decompress and parse header
	local header_sz, header_bytes_read = getLengthTag(gal_file)
	offset_pos = offset_pos + header_bytes_read

	local header_block = _loadBlock(gal_file, offset_pos, header_sz)
	offset_pos = offset_pos + header_sz

	local gal_image = _parseHeader(header_block)

	-- Determine block offset + length values
	--local block_number = 1 -- debug
	local frame_number = 1
	local layer_number = 1
	local which_data = 1 -- 1 == expecting main RGB or indexed data, 2 == expecting alpha block -- XXX clean up

	while true do

		-- Get length tag
		local block_sz, bytes_read = getLengthTag(gal_file)
		offset_pos = offset_pos + bytes_read

		if bytes_read == 0 then
			--print("DEBUG: No block size (EOF)")
			break
		end

		if frame_number > #gal_image.frames then
			tryCloseFile(gal_file)
			error("Frames + Layers exhausted before reaching end of data blocks.")
		end

		--print("DEBUG: block_number", block_number, "block_sz", block_sz)

		local layer = gal_image.frames[frame_number].layers[layer_number]

		if which_data == 1 then
			layer._block_offset = offset_pos
			layer._block_bytes = block_sz

			if load_immediately then
				local bin_main = _loadBlock(gal_file, layer._block_offset, layer._block_bytes)
				galeOps.applyBlockMain(layer, bin_main)
			end
		else
			layer._block_offset_a = offset_pos
			layer._block_bytes_a = block_sz

			if load_immediately then
				local bin_alpha = _loadBlock(gal_file, layer._block_offset_a, layer._block_bytes_a)
				galeOps.applyBlockAlpha(layer, bin_alpha)
			end
		end

		-- Increment main-vs-alpha, layer, frame counters.
		which_data = which_data + 1
		if which_data > 2 then
			which_data = 1
			layer_number = layer_number + 1
			if layer_number > #gal_image.frames[frame_number].layers then
				layer_number = 1
				frame_number = frame_number + 1
			end
		end

		--block_number = block_number + 1 -- debug
		offset_pos = offset_pos + block_sz
		gal_file:seek(offset_pos)
	end

	return gal_image
end


--- Load and convert one layer's data blocks to Lua array tables.
-- @param gal_file The source file object containing the compressed data blocks. Must be opened in read mode ("r").
-- @param gal_layer A GaleLayer table which is part of a GaleImage.
-- @return Nothing. The layer data is modified in-place.
function galeOps.populateLayer(gal_file, gal_layer)
	assertFileOpenReadMode(gal_file)

	local bin_main = _loadBlock(gal_file, gal_layer._block_offset, gal_layer._block_bytes)
	local bin_alpha  = _loadBlock(gal_file, gal_layer._block_offset_a, gal_layer._block_bytes_a)

	--[[
	print(".....................")
	debugPrintBlock("binary", bin_main)
	print(".....................")
	debugPrintBlock("hex", bin_alpha)
	print(".....................")
	--]]

	galeOps.applyBlockMain(gal_layer, bin_main)
	galeOps.applyBlockAlpha(gal_layer, bin_alpha)
end


--- Load and convert all layer data to Lua tables.
-- @param gal_file The source file object containing the compressed data blocks. Must be opened in read mode ("r").
-- @param gal_image A GaleImage skeleton table created with galeOps.loadSkeleton().
-- @return Nothing. gal_image is modified in-place.
function galeOps.populateAllLayers(gal_file, gal_image)
	assertFileOpenReadMode(gal_file)

	for f, frame in ipairs(gal_image.frames) do
		for l, layer in ipairs(frame.layers) do
			galeOps.populateLayer(gal_file, layer)
		end
	end
end


--- Convert Gale layer main data from a binary string to a Lua array.
-- @param main_data The layer's main (non-alpha) pixel data.
-- @param block The binary string to be parsed.
-- @return Nothing. The layer data is modified in-place.
function galeOps.applyBlockMain(layer, block)

	--[[
	Every layer can have two data blocks associated with it. The first is the main pixel data, and the second
	is alpha data which is stored separately. If no alpha channel exists for the layer, this second block
	will be empty.

	In all modes, each horizontal line is padded with zero bits so that its length is a multiple of 4 bytes.
	--]]

	local main_data = layer.data
	local bpp = layer._bpp

	-- Get main pixel info.
	-- 1bpp: eight pixels per byte, starting on the left with the most significant bit.
	if bpp == 1 then
		local valid_bits_per_line = layer._w
		local padded_bits_per_line = math.ceil(valid_bits_per_line / 32) * 32

		for y = 0, layer._h - 1 do
			for x = 0, valid_bits_per_line - 1 do
				local b = y*padded_bits_per_line + x + 1

				local mask = lut_bit_masks[((b-1) % 8) + 1]
				local byte_n = math.floor((b-1) / 8) + 1
				local byte = string.byte(block, byte_n, byte_n)
				local value = bAND(byte, mask)

				if value ~= 0 then
					value = 1
				end

				main_data[#main_data + 1] = value -- These are indexes into a palette of two colors.
			end
		end

	-- 4bpp: two pixels per byte, LR.
	elseif bpp == 4 then
		local valid_nibbles_per_line = layer._w
		local padded_nibbles_per_line = math.ceil(valid_nibbles_per_line / 8) * 8

		for y = 0, layer._h - 1 do
			for x = 0, valid_nibbles_per_line - 1 do
				local b = y*padded_nibbles_per_line + x + 1

				local mask = lut_nibble_masks[((b-1) % 2) + 1]
				local byte_n = math.floor((b-1) / 2) + 1
				local byte = string.byte(block, byte_n, byte_n)
				local value = bAND(byte, mask)

				if mask > 0xf then
					value = bRSHIFT(value, 4)
				end

				main_data[#main_data + 1] = value
			end
		end

	--# 8bpp: one byte == one pixel.
	elseif bpp == 8 then
		local valid_bytes_per_line = layer._w
		local padded_bytes_per_line = math.ceil(valid_bytes_per_line / 4) * 4

		for y = 0, layer._h - 1 do
			for x = 0, valid_bytes_per_line - 1, 1 do
				local b = y*padded_bytes_per_line + x + 1
				-- NOTE: Palette index values are zero-based, so add 1 in getPixel() to get the right palette offset.
				local pal_index = string.byte(block, b, b)
				if not pal_index or pal_index < 0 or pal_index > 255 then
					error("Palette index error at byte #" .. tostring(b))
				end
				main_data[#main_data + 1] = pal_index
			end
		end

	-- 15bpp: 5 bits per component, packed as two bytes per pixel. One bit is unused.
	elseif bpp == 15 then
		local valid_bytes_per_line = layer._w * 2
		local padded_bytes_per_line = math.ceil(valid_bytes_per_line / 4) * 4

		for y = 0, layer._h - 1 do
			for x = 0, valid_bytes_per_line - 1, 2 do
				--[[
				Color layout: 'gggbbbbb 0rrrrrgg'
				Green starts at the 13th bit and wraps around to the other byte. The 7th bit is always zero.
				--]]

				local b = y*padded_bytes_per_line + x + 1

				local byte1 = string.byte(block, b, b)
				local byte2 = string.byte(block, b + 1, b + 1)

				local blue = bAND(byte1, 0x1f)
				local green = bRSHIFT(bAND(byte1, 0xe0), 5) + bLSHIFT(bAND(byte2, 0x3), 3)
				local red = bRSHIFT(bAND(byte2, 0x7c), 2)

				main_data[#main_data + 1] = red
				main_data[#main_data + 1] = green
				main_data[#main_data + 1] = blue
			end
		end

	-- 16bpp: 5 bits for red, 6 bits for green, 5 bits for blue. Two bytes per pixel.
	elseif bpp == 16 then
		local valid_bytes_per_line = layer._w * 2
		local padded_bytes_per_line = math.ceil(valid_bytes_per_line / 4) * 4

		for y = 0, layer._h - 1 do
			for x = 0, valid_bytes_per_line - 1, 2 do
				--[[
				Color layout: 'gggbbbbb rrrrrggg'
				Green starts at the 13th bit and wraps around to the other byte.
				--]]

				local b = y*padded_bytes_per_line + x + 1

				local byte1 = string.byte(block, b, b)
				local byte2 = string.byte(block, b + 1, b + 1)

				local blue = bAND(byte1, 0x1f)
				local green = bRSHIFT(bAND(byte1, 0xe0), 5) + bLSHIFT(bAND(byte2, 0x7), 3)
				local red = bRSHIFT(bAND(byte2, 0xf8), 3)

				main_data[#main_data + 1] = red
				main_data[#main_data + 1] = green
				main_data[#main_data + 1] = blue
			end
		end

	-- 24bpp: three bytes per pixel, in this order: blue, green, red
	elseif bpp == 24 then
		local valid_bytes_per_line = layer._w * 3
		local padded_bytes_per_line = math.ceil(valid_bytes_per_line / 4) * 4

		for y = 0, layer._h - 1 do
			for x = 0, valid_bytes_per_line - 1, 3 do
				local b = y*padded_bytes_per_line + x + 1

				main_data[#main_data + 1] = string.byte(block, b + 2, b + 2)
				main_data[#main_data + 1] = string.byte(block, b + 1, b + 1)
				main_data[#main_data + 1] = string.byte(block, b, b)
			end
		end

	else
		error("Unknown bpp mode for Gale image: " .. tostring(bpp))
	end
end


--- Convert Gale layer alpha data from a binary string to a Lua array.
-- @param alpha_data The layer's alpha pixel channel data.
-- @param block The binary string to be parsed.
-- @return Nothing. The layer data is modified in-place.
function galeOps.applyBlockAlpha(layer, block)

	-- Alpha channels, if present, are always one byte per pixel.
	-- Each horizontal line is padded to be a multiple of 4 bytes.

	-- If the block is zero-length, the Gale file has no alpha channel.
	if #block == 0 then
		return
	end

	local alpha_data = layer.a_data

	local valid_bytes_per_line = layer._w
	local padded_bytes_per_line = math.ceil(valid_bytes_per_line / 4) * 4

	for y = 0, layer._h - 1 do
		for x = 0, valid_bytes_per_line - 1, 1 do
			local b = y*padded_bytes_per_line + x + 1
			alpha_data[#alpha_data + 1] = string.byte(block, b, b)
		end
	end
end


--- Convert a 5-bit component to 8-bit.
-- @param input The 5-bit value to convert. Range: 0-31
-- @return A version of the input multiplied to the range of 0-255.
function get5bppComponent(input)
	if input == 0 then
		return 0

	else
		return (input + 1) * 8 - 1
	end
end

--- Convert a 6-bit component to 8-bit.
-- @param input The 6-bit value to convert. Range: 0-63
-- @return A version of the input multiplied to the range of 0-255.
function get6bppComponent(input)
	if input == 0 then
		return 0

	else
		return (input + 1) * 4 - 1
	end
end


--- Helper function to unpack 'BGColor' and 'TransColor'.
-- @param num The number to unpack.
-- @param bpp The layer bpp setting. BGColors are always 24bpp, TransColor depends on the image bpp.
-- @param palette For 8bpp or lower, pass in the palette table here. Not required otherwise.
-- @return Palette index for indexed color modes, or RGBA values in a form that matches the layer data (ie not necessarily 0-255), or nil if the number is -1 (indicating that the feature is disabled.)
local function _unpackIntColor(num, bpp, palette)

	-- -1 == Feature disabled
	if num == -1 then
		return nil
	end

	local r, g, b

	if bpp <= 8 then
		-- Just return the palette index.
		local ind = num + 1 -- convert to 1-indexed
		if not palette[ind] then
			error("Out of bounds index for palette.")
		end

		return ind

	elseif bpp == 15 then
		--'0rrrrrgg gggbbbbb'
		r = bRSHIFT(bAND(num, 0x7C00), 10)
		g = bRSHIFT(bAND(num, 0x3e0), 5)
		b = bAND(num, 0x1f)

	elseif bpp == 16 then
		--'rrrrrggg gggbbbbb'
		r = bRSHIFT(bAND(num, 0x7800), 11)
		g = bRSHIFT(bAND(num, 0x7e0), 5)
		b = bAND(num, 0x1f)

	elseif bpp == 24 then
		b = num % 256
		num = math.floor(num / 256)

		g = num % 256
		num = math.floor(num / 256)

		r = num % 256
		num = math.floor(num / 256)

	else
		error("Unknown bpp setting: " .. tostring(bpp))
	end

	return r, g, b
end


--- Get a pixel from a Gale layer, accounting for alpha / opacity when applicable. Colors are in the range of 0-255. Layer '_options' table affects how the data is read.
-- @param layer The GaleLayer to sample from.
-- @param x X coordinate of the pixel to sample.
-- @param y Y coordinate of the pixel to sample.
-- @return Red, green, blue and alpha values for the pixel, in the range of 0-255.
function galeOps.getPixel(layer, x, y)
	local options = layer._options or galeOps.layer_options_default

	-- Indices for main data and alpha data. Main index may be modified below depending on the bpp.
	local index_m = (1 + y*layer._w + x)
	local index_a = (1 + y*layer._w + x)

	-- GraphicsGale has three transparency implementations: per-layer opacity (called just "Alpha"
	-- in the layer attributes), a transparent color-key (per-layer "TransColor"), and a full alpha channel.
	-- Creating an alpha channel disables opacity and overrides the color-key.

	-- Check layer visibility, if applicable
	if options.respect_visibility and layer.visible == 0 then
		return 0, 0, 0, 0
	end

	-- Default to fully opaque
	local alpha = 255
	local ak_r, ak_g, ak_b

	if options.respect_trans_color_key and layer.trans_color >= 0 then -- -1 == disabled
		ak_r, ak_g, ak_b = _unpackIntColor(layer.trans_color, layer._bpp, layer._palette)
	end

	-- Negative per-layer alpha means the feature is disabled.
	local layer_alpha = layer.alpha
	if layer_alpha < 0 then
		layer_alpha = 255
	end

	-- Alpha channel
	-- NOTE: Alpha can be toggled, even if an alpha channel block exists in the GaleImage.
	if layer.alpha_on == 1 and #layer.a_data > 0 then
		-- Alpha handling is the same across all RGB modes.
		-- I'm not sure if the alpha channel is really supported for indexed modes.
		alpha = layer.a_data[index_a]

	-- Per-layer opacity
	elseif options.respect_opacity and layer.alpha > 0 then
		-- Indexed modes use a dither mask instead of alpha blending.
		if options.indexed_dithered_transparency and layer._bpp <= 8 then
			if layer.alpha >= lut_trans_dither_mask[(y-1) % 4 + 1][(x-1) % 4 + 1] then
				alpha = 255
			else
				alpha = 0
			end

		-- RGB modes, or dithered transparency disabled in options
		else
			alpha = layer.alpha
		end

		-- Transparency color-key is handled below.
	end

	-- If NotFillBG is active and there is no alpha channel, the bottom layer should always be opaque.
	-- The presence of an active alpha channel overrides this.
	local bottom_layer_transparency_override = false
	if layer._is_bottom_layer and layer.alpha_on == 0 and layer._not_fill_bg == 1 then
		alpha = 255
		bottom_layer_transparency_override = true
	end

	-- Indexed color lookups
	if layer._bpp <= 8 then
		local ind = layer.data[index_m] + 1 -- Convert to one-indexed
		local color = layer._palette[ind]

		if not color then
			error("Invalid color palette index: " .. tostring(index_m))
		end

		-- Check color-key
		if not bottom_layer_transparency_override then
			if ak_r and ind == ak_r then
				alpha = 0
			end
		end

		return color.r, color.g, color.b, alpha

	-- 15bpp: Converted to three numbers which are kept in the range of 0-31 until this point.
	elseif layer._bpp == 15 then
		-- Multiply offset value to get three indices
		index_m = (index_m - 1) * 3 + 1

		local red = get5bppComponent(layer.data[index_m])
		local green = get5bppComponent(layer.data[index_m + 1])
		local blue = get5bppComponent(layer.data[index_m + 2])

		-- Check color-key
		if not bottom_layer_transparency_override then
			if ak_r and red == ak_r and green == ak_g and blue == ak_b then
				alpha = 0
			end
		end

		return red, green, blue, alpha

	-- 16bpp: Similar to 15bpp, but green is 6 bits instead of 5.
	elseif layer._bpp == 16 then
		-- Multiply offset value to get three indices
		index_m = (index_m - 1) * 3 + 1

		local red = get5bppComponent(layer.data[index_m])
		local green = get6bppComponent(layer.data[index_m + 1])
		local blue = get5bppComponent(layer.data[index_m + 2])

		-- Check color-key
		if not bottom_layer_transparency_override then
			if ak_r and red == ak_r and green == ak_g and blue == ak_b then
				alpha = 0
			end
		end

		return red, green, blue, alpha

	-- 24bpp.
	elseif layer._bpp == 24 then
		-- As each pixel is three bytes, multiply offset value
		index_m = (index_m - 1) * 3 + 1
		local red = layer.data[index_m]
		local green = layer.data[index_m + 1]
		local blue = layer.data[index_m + 2]

		-- Check color-key, if applicable.
		if not bottom_layer_transparency_override then
			if ak_r and red == ak_r and green == ak_g and blue == ak_b then
				alpha = 0
			end
		end

		return red, green, blue, alpha

	else
		error("Invalid bpp setting:" .. tostring(layer._bpp))
	end
end


--- Mix two RGBA colors. All components are in the range of 0-1.
-- @param r1 Destination red component.
-- @param g1 Destination green component.
-- @param b1 Destination blue component.
-- @param a1 Destination alpha component.
-- @param r2 Incoming red component.
-- @param g2 Incoming green component.
-- @param b2 Incoming blue component.
-- @param a2 Incoming alpha component.
-- @return Mixed red, green, blue and alpha values.
function galeOps.mixRGBA(r1, g1, b1, a1, r2, g2, b2, a2)
	-- https://love2d.org/wiki/BlendMode_Formulas

	local r = r1 * (1 - a2) + r2 * a2
	local g = g1 * (1 - a2) + g2 * a2
	local b = b1 * (1 - a2) + b2 * a2
	local a = a1 * (1 - a2) + a2

	return r, g, b, a
end


--- Blend the pixel contents of two LÖVE ImageData objects. The objects must have the same dimensions.
-- @param existing The ImageData to write to.
-- @param to_apply The ImageData to apply to 'existing'.
-- @return Nothing. 'existing' is modified in-place.
function galeOps.blendImageData(existing, to_apply)
	-- Confirm dimensions match
	local w1, h1 = existing:getDimensions()
	local w2, h2 = to_apply:getDimensions()
	if w1 ~= w2 or h1 ~= h2 then
		error("ImageData dimensions mismatch. 'src': " .. tostring(w1) .. "x" .. tostring(h1)
		.. ", 'dst': " .. tostring(w2) .. "x" .. tostring(h2) .. ".")
	end

	for y = 0, h1 - 1 do
		for x = 0, w1 - 1 do
			local dr, dg, db, da = existing:getPixel(x, y)
			local sr, sg, sb, sa = to_apply:getPixel(x, y)

			local mr, mg, mb, ma = galeOps.mixRGBA(dr, dg, db, da, sr, sg, sb, sa)

			existing:setPixel(x, y, mr, mg, mb, ma)
		end
	end
end


--- Blend a sequence of ImageData objects, bottom-to-top. All ImageData objects must share the same dimensions.
-- @param i_data_list Sequence of ImageData objects.
-- @return A new combined ImageData.
function galeOps.combineImageData(i_data_list) -- XXX Untested

	-- Work off a copy of the first ImageData.
	local i_main = i_data_list[1]:clone()

	for i = 2, #i_data_list do
		galeOps.blendImageData(i_main, i_data_list[i])
	end

	return i_main
end


--- Apply a frame's transparency color-key to an ImageData. Any pixel in any layer matching this RGB value should be transparent. In GraphicsGale, the presence of an alpha channel in a layer overrides this. The alpha of the ImageData is not considered.
-- @param i_data The ImageData to modify.
-- @param r Red component of the transparency color-key, in the range of 0-255.
-- @param g Green component of the transparency color-key, in the range of 0-255.
-- @param b Blue component of the transparency color-key, in the range of 0-255.
-- @return Nothing. ImageData is modified in-place.
function galeOps.applyFrameTransparency(i_data, r, g, b) -- XXX Untested.
	for y = 0, i_data:getHeight() - 1 do
		for x = 0, i_data:getWidth() - 1 do
			local pr, pg, pb = i_data:getPixel(x, y)

			if r/255 == pr and g/255 == pg and b/255 == pb then
				i_data:setPixel(x, y, 0, 0, 0, 0) -- XXX could be mapPixel()
			end
		end
	end
end


--- Generate a LÖVE ImageData from a GaleLayer.
-- @param layer The GaleLayer source table.
-- @return The resulting ImageData.
function galeOps.makeImageData(layer)

	local i_data = love.image.newImageData(layer._w, layer._h, "rgba8")

	for y = 0, layer._h - 1 do
		for x = 0, layer._w - 1 do
			local r, g, b, a = galeOps.getPixel(layer, x, y)
			if a == nil then
				a = 255
			end
			i_data:setPixel(x, y, r / 255, g / 255, b / 255, a / 255)
		end
	end

	return i_data
end


--- Generate a nested table of LÖVE ImageData objects from a GaleImage.
-- @param gal_image The GaleImage to convert.
-- @return A table containing an array of subtables for every frame, each containing an array of ImageData objects for every layer.
function galeOps.makeImageDataAll(gal_image)

	local collection = {}

	for f = 1, #gal_image.frames do
		local frame = gal_image.frames[f]
		local out_frame = {}
		collection[#collection + 1] = out_frame

		for l = 1, #frame.layers do
			local i_data = galeOps.makeImageData(frame.layers[l])

			out_frame[#out_frame + 1] = i_data
		end
	end

	return collection
end


local map_BGColor_t = {}
local function map_BGColor(x, y, r, g, b, a)
	return map_BGColor_t[1], map_BGColor_t[2], map_BGColor_t[3], 1.0
end
--- Generate a blank LÖVE ImageData filled with a GaleImage's 'BGColor' value (File -> Properties -> Background Color)
-- @param gal_image The GaleImage.
-- @return The pre-filled ImageData.
function galeOps.makeImageDataBGColor(gal_image) -- XXX untested

	-- Preview window aside, this normally only shows when "Disable Transparency of Bottom Layer" (NotFillBG) is unchecked in File -> Properties.

	local r, g, b = _unpackIntColor(gal_image.bg_color, 24, nil)
	map_BGColor_t[1] = r / 255
	map_BGColor_t[2] = g / 255
	map_BGColor_t[3] = b / 255

	local i_data = love.image.newImageData(gal_image.width, gal_image.height)
	i_data:mapPixel(map_BGColor)
end

return galeOps
