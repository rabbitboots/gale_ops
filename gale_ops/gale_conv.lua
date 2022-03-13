local path = (...):gsub("%.[^%.]+$", "")
-- Module: GaleConv
-- Description: Some example wrappers for working with GaleOps.
-- Version: 1.0
-- License: MIT
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


local galeConv = {}

local galeOps = require(path .. ".gale_ops")


local function wrapFileOpen(path, mode)
	local gal_file = love.filesystem.newFile(path)
	local ok, err = gal_file:open(mode)
	if not ok then
		error("unable to open file: " .. tostring(err))
	end

	return gal_file
end

--- Load a Gale file and convert it to a nested table of LÖVE ImageData objects.
-- @param filepath Full path to the .gal file.
-- @return Nested table of LÖVE ImageData objects.
function galeConv.fileToImageDataSet(filepath)
	local gal_image = galeConv.fileToGaleImage(filepath)
	local i_data_set = galeOps.makeImageDataAll(gal_image)

	return i_data_set
end


--- Load a Gale file, search for the first layer named 'layer_name', and convert it to a LÖVE ImageData object. Layers are stored bottom-to-top, so lower layers will be considered first.
-- @param filepath Full path to the .gal file.
-- @param layer_name String ID for the layer.
-- @return ImageData based on the layer data, or nil if it wasn't found.
function galeConv.fileToImageDataSingleLayer(filepath, layer_name)
	-- Use this if you only need one layer from a multi-layer, multi-frame Gale file.

	local gal_file = wrapFileOpen(filepath, "r")
	local gal_image = galeOps.loadSkeleton(gal_file)

	-- Look for layer
	local layer, layer_i_data

	for f, frame in ipairs(gal_image.frames) do
		for l, layer in ipairs(frame.layers) do
			if layer.name == layer_name then
				local bin_main = galeOps.loadBlock(gal_file, layer._block_offset, layer._block_bytes)
				local bin_alpha = galeOps.loadBlock(gal_file, layer._block_offset_a, layer._block_bytes_a)

				galeOps.applyBlockMain(layer, bin_main)
				galeOps.applyBlockAlpha(layer, bin_alpha)

				layer_i_data = galeConv.makeImageData(layer)

				break
			end
		end
	end

	gal_file:close()

	return layer_i_data
end


--- Load a .gal file and construct a GaleImage table
function galeConv.fileToGaleImage(filepath)

	local gal_file = wrapFileOpen(filepath, "r")

	local gal_image = galeOps.loadSkeleton(gal_file, true)

	gal_file:close()

	return gal_image
end


--- Troubleshooting: Dump all ImageData objects in an image set to the project save directory.
-- @param i_data_set The nested table of LÖVE ImageData objects.
-- @return Nothing. Check the save directory for the files.
function galeConv.dumpImageDataSet(i_data_set)
	for f, frame in ipairs(i_data_set) do
		for l, layer_data in ipairs(frame.layers) do
			layer_data:encode("png", "frame-" .. tostring(f) .. "-layer-" .. tostring(l) .. ".png")
		end
	end
end


--- Look for a frame by its name.
-- @return The first occurence, plus index, or nil if not found.
function galeConv.findFrameName(gal_image, frame_name)
	-- WARNING: Gale frames default to being called '%framenumber%', which is interpolated in the UI. galeOps leaves this as-is.
	for i = 1, #gal_image.frames do
		local frame = gal_image.frames[i]

		if frame.name == frame_name then
			return frame, i
		end
	end

	return nil
end


--- Look for a layer by name. Gale layers are stored bottom-to-top, so the first bottom-most match will be returned.
-- @param frame The GaleFrame to check.
-- @param layer_name The GaleLayer ID to search for. The first result is returned.
-- @return layer table plus index, or nil if not found.
function galeConv.findLayerName(frame, layer_name)
	for i = 1, #frame.layers do
		local layer = frame.layers[i]
		if layer.name == layer_name then
			return layer, i
		end
	end

	return nil
end

return galeConv

