--[[
	LÖVE usage example for galeOps, using example wrapper functions.

	(For the actual library files, see subdir: ./gale_ops)

	Tested LÖVE versions: 11.4
--]]
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


local galeOps = require("gale_ops.gale_ops")

-- Some wrappers to help interact with GaleOps.
local galeConv = require("gale_ops.gale_conv")

local state = {}


function love.load(arguments)
	love.window.setTitle("Gale loader test")

	love.graphics.setDefaultFilter("nearest", "nearest")
	love.graphics.setBackgroundColor(0.2, 0.5, 0.3, 1.0)	

	-- For demonstration purposes, we will load a multi-frame, multi-layer Gale file and play it back as a series of images.
	local gal_path = "joggers.gal"

	state.frames = {}
	local gale_img = galeConv.fileToGaleImage(gal_path)

	for i, g_frame in ipairs(gale_img.frames) do
		local frame = {}
		frame.layers = {}
		frame.delay = g_frame.delay
		for j, g_layer in ipairs(g_frame.layers) do
			frame.layers[j] = love.graphics.newImage(galeOps.makeImageData(g_layer))
		end
		state.frames[i] = frame
	end

	state.x = 0
	state.y = 0
	state.time = 0
	state.frame_index = 1

	state.layers_enabled = {true, true, true}
end

function love.update(dt)
	local t = love.timer.getTime()
	state.x = math.cos(t / 4) * math.cos(t / 1.24) * 32
	state.y = math.sin(t / 4) * math.cos(t / 1.24) * 32

	local this_frame = state.frames[state.frame_index]
	state.time = state.time + dt

	if state.time >= this_frame.delay / 1000 then
		state.time = state.time - this_frame.delay / 1000
		state.frame_index = state.frame_index % #state.frames + 1
	end
end


function love.draw()
	love.graphics.setColor(1, 1, 1, 1)

	love.graphics.push("all")

	love.graphics.scale(3, 3)
	love.graphics.translate(64, 64)

	local frame = state.frames[state.frame_index]
	for j, id_layer in ipairs(frame.layers) do
		if state.layers_enabled[j] then
			love.graphics.draw(id_layer, state.x, state.y)
		end
	end

	love.graphics.pop()

	local l_en = state.layers_enabled
	love.graphics.print("1-3: Toggle Layers", 16, 16)
	love.graphics.print("1 (Top): " .. tostring(l_en[3]), 16, 48)
	love.graphics.print("2 (Mid): " .. tostring(l_en[2]), 16, 64)
	love.graphics.print("3 (Bot): " .. tostring(l_en[1]), 16, 80)
end

function love.keypressed(kc, sc)
	if sc == "escape" then
		love.event.quit()
	end
	-- Toggle layers
	local num = tonumber(sc)
	if num and num >= 1 and num <= 3 then
		num = 3 - num + 1
		state.layers_enabled[num] = not state.layers_enabled[num]
	end
end
