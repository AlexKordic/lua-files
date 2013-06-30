--libpng binding for libpng 1.5.6+
local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue' --fcall
local stdio = require'stdio' --fopen
local jit = require'jit' --off
require'libpng_h'
local C = ffi.load'libpng'

local PNG_LIBPNG_VER_STRING = '1.5.10'

local pixel_formats = {
	[C.PNG_COLOR_TYPE_GRAY] = 'g',
	[C.PNG_COLOR_TYPE_RGB] = 'rgb',
	[C.PNG_COLOR_TYPE_RGB_ALPHA] = 'rgba',
	[C.PNG_COLOR_TYPE_GRAY_ALPHA] = 'ga',
}

local function buffered_reader(read, bufsize)
	local buf, s --these must be upvalues so they don't get collected between calls
	local left = 0 --how much bytes left to consume from the current buffer
	local sbuf = nil --current pointer in buf
	return function(dbuf, dsz)
		while dsz > 0 do
			--if current buffer is empty, refill it
			if left == 0 then
				s, buf = nil --release current string and buffer
				buf, left = read(dsz) --load and pin a new buffer as the current buffer
				if not buf then
					error'eof'
				end
				if type(buf) == 'string' then
					s = buf --pin the new string
					buf = ffi.cast('const uint8_t*', s) --const prevents string copy
					left = #s
				else
					assert(left, 'size missing')
				end
				assert(left > 0, 'eof')
				sbuf = buf
			end
			--consume from buffer, till empty or till size
			local sz = math.min(dsz, left)
			ffi.copy(dbuf, sbuf, sz)
			sbuf = sbuf + sz
			dbuf = dbuf + sz
			left = left - sz
			dsz = dsz - sz
		end
	end
end

local function best_orientation(orientation, accept)
	return
		(not accept or (accept.top_down == nil and accept.bottom_up == nil)) and orientation --no preference, keep it
		or accept[orientation] and orientation --same as source, keep it
		or accept.top_down and 'top_down'
		or accept.bottom_up and 'bottom_up'
		or error('invalid orientation')
end

local function pad_stride(stride)
	return bit.band(stride + 3, bit.bnot(3))
end

local function one_shot_reader(buf, sz)
	local done
	return function()
		if done then return end
		done = true
		return buf, sz
	end
end

local function load(t)
	return glue.fcall(function(finally)

		--create the state objects
		local png_ptr = assert(C.png_create_read_struct(PNG_LIBPNG_VER_STRING, nil, nil, nil))
		local info_ptr = assert(C.png_create_info_struct(png_ptr))
		finally(function()
			local png_ptr = ffi.new('png_structp[1]', png_ptr)
			local info_ptr = ffi.new('png_infop[1]', info_ptr)
			C.png_destroy_read_struct(png_ptr, info_ptr, nil)
		end)

		--setup error handling
		local warning_cb = ffi.cast('png_error_ptr', function(png_ptr, err)
			if t.warning then
				t.warning(ffi.string(err))
			end
		end)
		local error_cb = ffi.cast('png_error_ptr', function(png_ptr, err)
			error(ffi.string(err))
		end)
		finally(function()
			C.png_set_error_fn(png_ptr, nil, nil, nil)
			error_cb:free()
			warning_cb:free()
		end)
		C.png_set_error_fn(png_ptr, nil, error_cb, warning_cb)

		--setup input source
		if t.stream then
			C.png_init_io(png_ptr, t.stream)
		elseif t.path then
			local f = stdio.fopen(t.path, 'rb')
			finally(function()
				C.png_init_io(png_ptr, nil)
				f:close()
			end)
			C.png_init_io(png_ptr, f)
		elseif t.string or t.cdata or t.read then

			--wrap cdata and string into a one-shot stream reader.
			local read = t.read or
				t.string and one_shot_reader(t.string) or
				t.cdata  and one_shot_reader(t.cdata, t.size)

			--wrap the stream reader into a buffered reader.
			local buffered_read = buffered_reader(read)

			--wrap the buffered reader into a png reader that raises errors through png_error().
			local function png_read(png_ptr, dbuf, dsz)
				local ok, err = pcall(buffered_read, dbuf, dsz)
				if not ok then C.png_error(png_ptr, err) end
			end

			--wrap the png reader into a RAII callback object.
			local read_cb = ffi.cast('png_rw_ptr', png_read)
			finally(function()
				C.png_set_read_fn(png_ptr, nil, nil)
				read_cb:free()
			end)

			--put the onion into the oven.
			C.png_set_read_fn(png_ptr, nil, read_cb)
		else
			error'source missing'
		end

		--read header
		C.png_read_info(png_ptr, info_ptr)
		local img = {}
		img.file = {}
		img.file.w = C.png_get_image_width(png_ptr, info_ptr)
		img.file.h = C.png_get_image_height(png_ptr, info_ptr)
		local color_type = C.png_get_color_type(png_ptr, info_ptr)
		img.file.paletted = bit.band(color_type, C.PNG_COLOR_MASK_PALETTE) == C.PNG_COLOR_MASK_PALETTE
		img.file.pixel = assert(pixel_formats[bit.band(color_type, bit.bnot(C.PNG_COLOR_MASK_PALETTE))])
		img.file.bit_depth = C.png_get_bit_depth(png_ptr, info_ptr)
		img.file.interlaced = C.png_get_interlace_type(png_ptr, info_ptr) ~= C.PNG_INTERLACE_NONE

		if t.header_only then
			return img
		end

		--mandatory conversions: expand palette and normalize pixel format to 8bpc.
		C.png_set_expand(png_ptr) --1,2,4bpp -> 8bpp, palette -> 8bpp, tRNS -> alpha
		C.png_set_scale_16(png_ptr) --16bpp -> 8bpp; since 1.5.4+
		C.png_read_update_info(png_ptr, info_ptr)
		local passes = C.png_set_interlace_handling(png_ptr)

		img.w = img.file.w
		img.h = img.file.h
		img.pixel = img.file.pixel

		if t.accept then

			local function set_alpha()
				C.png_set_alpha_mode(png_ptr, C.PNG_ALPHA_OPTIMIZED, t.gamma or 2.2) --> premultiply alpha
			end

			local function strip_alpha()
				local my_background = ffi.new('png_color_16', 0, 0xff, 0xff, 0xff, 0xff)
				local image_background = ffi.new'png_color_16'
				local image_background_p = ffi.new('png_color_16p[1]', image_background)
				if C.png_get_bKGD(png_ptr, info_ptr, image_background_p) then
					C.png_set_background(png_ptr, image_background, C.PNG_BACKGROUND_GAMMA_FILE, 1, 1.0)
				else
					C.png_set_background(png_ptr, my_background, PNG_BACKGROUND_GAMMA_SCREEN, 0, 1.0)
				end
			end

			if img.pixel == 'g' then
				if t.accept.g then
					--we're good
				elseif t.accept.ga then
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_AFTER)
					img.pixel = 'ga'
				elseif t.accept.ag then
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_BEFORE)
					img.pixel = 'ag'
				elseif t.accept.rgb then
					C.png_set_gray_to_rgb(png_ptr)
					img.pixel = 'rgb'
				elseif t.accept.bgr then
					C.png_set_gray_to_rgb(png_ptr)
					C.png_set_bgr(png_ptr)
					img.pixel = 'bgr'
				elseif t.accept.rgba then
					C.png_set_gray_to_rgb(png_ptr)
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_AFTER)
					img.pixel = 'rgba'
				elseif t.accept.argb then
					C.png_set_gray_to_rgb(png_ptr)
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_BEFORE)
					img.pixel = 'argb'
				elseif t.accept.bgra then
					C.png_set_gray_to_rgb(png_ptr)
					C.png_set_bgr(png_ptr)
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_AFTER)
					img.pixel = 'bgra'
				elseif t.accept.abgr then
					C.png_set_gray_to_rgb(png_ptr)
					C.png_set_bgr(png_ptr)
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_BEFORE)
					img.pixel = 'abgr'
				end
			elseif img.pixel == 'ga' then
				if t.accept.ga then
					set_alpha()
				elseif t.accept.ag then
					C.png_set_swap_alpha(png_ptr)
					set_alpha()
					img.pixel = 'ag'
				elseif t.accept.rgba then
					C.png_set_gray_to_rgb(png_ptr)
					set_alpha()
					img.pixel = 'rgba'
				elseif t.accept.argb then
					C.png_set_gray_to_rgb(png_ptr)
					C.png_set_swap_alpha(png_ptr)
					set_alpha()
					img.pixel = 'argb'
				elseif t.accept.bgra then
					C.png_set_gray_to_rgb(png_ptr)
					C.png_set_bgr(png_ptr)
					set_alpha()
					img.pixel = 'bgra'
				elseif t.accept.abgr then
					C.png_set_gray_to_rgb(png_ptr)
					C.png_set_bgr(png_ptr)
					C.png_set_swap_alpha(png_ptr)
					set_alpha()
					img.pixel = 'abgr'
				elseif t.accept.g then
					strip_alpha()
					img.pixel = 'g'
				elseif t.accept.rgb then
					C.png_set_gray_to_rgb(png_ptr)
					strip_alpha()
					img.pixel = 'rgb'
				elseif t.accept.bgr then
					C.png_set_gray_to_rgb(png_ptr)
					C.png_set_bgr(png_ptr)
					strip_alpha()
					img.pixel = 'bgr'
				else
					set_alpha()
				end
			elseif img.pixel == 'rgb' then
				if t.accept.rgb then
					--we're good
				elseif t.accept.bgr then
					C.png_set_bgr(png_ptr)
					img.pixel = 'bgr'
				elseif t.accept.rgba then
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_AFTER)
					img.pixel = 'rgba'
				elseif t.accept.argb then
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_BEFORE)
					img.pixel = 'argb'
				elseif t.accept.bgra then
					C.png_set_bgr(png_ptr)
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_AFTER)
					img.pixel = 'bgra'
				elseif t.accept.abgr then
					C.png_set_bgr(png_ptr)
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_BEFORE)
					img.pixel = 'abgr'
				elseif t.accept.g then
					C.png_set_rgb_to_gray_fixed(png_ptr, 1, -1, -1)
					img.pixel = 'g'
				elseif t.accept.ga then
					C.png_set_rgb_to_gray_fixed(png_ptr, 1, -1, -1)
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_AFTER)
					img.pixel = 'ga'
				elseif t.accept.ag then
					C.png_set_rgb_to_gray_fixed(png_ptr, 1, -1, -1)
					C.png_set_add_alpha(png_ptr, 0xff, C.PNG_FILLER_BEFORE)
					img.pixel = 'ag'
				end
			elseif img.pixel == 'rgba' then
				if t.accept.rgba then
					set_alpha()
				elseif t.accept.argb then
					C.png_set_swap_alpha(png_ptr)
					set_alpha()
					img.pixel = 'argb'
				elseif t.accept.bgra then
					C.png_set_bgr(png_ptr)
					set_alpha()
					img.pixel = 'bgra'
				elseif t.accept.abgr then
					C.png_set_bgr(png_ptr)
					C.png_set_swap_alpha(png_ptr)
					set_alpha()
					img.pixel = 'abgr'
				elseif t.accept.rgb then
					strip_alpha()
					img.pixel = 'rgb'
				elseif t.accept.bgr then
					C.png_set_bgr(png_ptr)
					strip_alpha()
					img.pixel = 'bgr'
				elseif t.accept.ga then
					C.png_set_rgb_to_gray_fixed(png_ptr, 1, -1, -1)
					img.pixel = 'ga'
				elseif t.accept.ag then
					C.png_set_rgb_to_gray_fixed(png_ptr, 1, -1, -1)
					C.png_set_swap_alpha(png_ptr)
					img.pixel = 'ag'
				elseif t.accept.g then
					C.png_set_rgb_to_gray_fixed(png_ptr, 1, -1, -1)
					strip_alpha()
					img.pixel = 'g'
				else
					set_alpha()
				end
			else
				assert(false)
			end

			--apply transformations and get the new transformed header
			C.png_read_update_info(png_ptr, info_ptr) --calling this twice is possible since 1.5.4+

			--[[
			img.w = C.png_get_image_width(png_ptr, info_ptr)
			img.h = C.png_get_image_height(png_ptr, info_ptr)
			local color_type = C.png_get_color_type(png_ptr, info_ptr)
			color_type = bit.band(color_type, bit.bnot(C.PNG_COLOR_MASK_PALETTE))
			img.paletted = bit.band(color_type, C.PNG_COLOR_MASK_PALETTE) == C.PNG_COLOR_MASK_PALETTE
			img.pixel = assert(pixel_formats[bit.band(color_type, bit.bnot(C.PNG_COLOR_MASK_PALETTE))])
			img.bit_depth = C.png_get_bit_depth(png_ptr, info_ptr)

			--if a pixel format was requested, check if conversion options had the desired effect.
			if img.pixel then
				assert(img.bit_depth == 8)
				if #img.pixel ~= #img.pixel then
					--print(img.pixel, img.pixel, t.accept.g)
				end
				--assert(#img.pixel == #img.pixel) --same number of channels
				--assert(not img.interlaced)
			end

			local channels = C.png_get_channels(png_ptr, info_ptr)
			assert(#img.pixel == channels) --each letter a channel
			]]

			img.pixel = img.pixel

		end --if t.accept

		--compute the stride
		img.stride = C.png_get_rowbytes(png_ptr, info_ptr)
		if t.accept and t.accept.padded then
			img.stride = pad_stride(img.stride)
		end

		--allocate image and rows buffers
		img.size = img.h * img.stride
		img.data = ffi.new('uint8_t[?]', img.size)
		local rows = ffi.new('uint8_t*[?]', img.h)

		--arrange row pointers according to accepted orientation
		img.orientation = best_orientation('top_down', t.accept)
		if img.orientation == 'bottom_up' then
			for i=0,img.h-1 do
				rows[img.h-1-i] = img.data + (i * img.stride)
			end
		else
			for i=0,img.h-1 do
				rows[i] = img.data + (i * img.stride)
			end
		end

		--finally, decompress the image
		local outimg
		local function render_scan(scan_number, multiple_scans)

			--convert the image with bmpconv if its pixel format is not among accepted ones.
			--the resulting image may be a new image object with a new buffer, a new image object
			--with the same buffer as img, or can be img itself.
			outimg = img
			--[[
			if t.accept and not t.accept[img.pixel] then
				local bmpconv = require'bmpconv'
				outimg = bmpconv.convert_best(img, t.accept, {force_copy = multiple_scans})
			end
			]]

			--call the rendering callback on the converted image
			if t.render_scan then
				t.render_scan(outimg, scan_number)
			end
		end

		if passes > 1 and t.render_scan then --multipass reading
			for pass = 1, passes do
				if t.sparkle then
					C.png_read_rows(png_ptr, rows, nil, img.h)
				else
					C.png_read_rows(png_ptr, nil, rows, img.h)
				end
				render_scan(pass, true)
			end
		else
			C.png_read_image(png_ptr, rows)
			render_scan(1)
		end

		C.png_read_end(png_ptr, info_ptr)
		return outimg
	end)
end

if not ... then require'libpng_demo' end

return {
	load = load,
	C = C,
}
