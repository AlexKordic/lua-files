--libjpeg binding
local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue' --fcall, index, pass
local stdio = require'stdio' --fopen
local jit = require'jit' --off
require'libjpeg_h'
local C = ffi.load'libjpeg'

local LIBJPEG_VERSION = 62

local pixel_formats = {
	[C.JCS_GRAYSCALE]= 'g',
	[C.JCS_YCbCr]    = 'ycc',
	[C.JCS_CMYK]     = 'cmyk',
	[C.JCS_YCCK]     = 'ycck',
	[C.JCS_RGB]      = 'rgb',
	[C.JCS_EXT_RGB]  = 'rgb',
	[C.JCS_EXT_BGR]  = 'bgr',
	[C.JCS_EXT_RGBX] = 'rgbx',
	[C.JCS_EXT_BGRX] = 'bgrx',
	[C.JCS_EXT_XRGB] = 'xrgb',
	[C.JCS_EXT_XBGR] = 'xbgr',
	[C.JCS_EXT_RGBA] = 'rgba',
	[C.JCS_EXT_BGRA] = 'bgra',
	[C.JCS_EXT_ARGB] = 'argb',
	[C.JCS_EXT_ABGR] = 'abgr',
}

local color_spaces = glue.index(pixel_formats)

--all conversions that libjpeg implements, in order of preference. {source = {dest1, ...}}.
local conversions = {
	ycc = {'rgb', 'bgr', 'rgba', 'bgra', 'argb', 'abgr', 'rgbx', 'bgrx', 'xrgb', 'xbgr', 'g'},
	g = {'rgb', 'bgr', 'rgba', 'bgra', 'argb', 'abgr', 'rgbx', 'bgrx', 'xrgb', 'xbgr'},
	ycck = {'cmyk'},
}

--easiest conversions that libjpeg implements to a format that bmpconv can use as input.
local fallback_conversions = {
	ycc = 'rgb',
	g = 'g',
	ycck = 'cmyk',
}

local function best_pixel_format(pixel, accept)
	if not accept or accept[pixel] then return pixel end --no preference or source format accepted
	if conversions[pixel] then
		for _,pixel in ipairs(conversions[pixel]) do
			if accept[pixel] then return pixel end --convertible to the best accepted format
		end
		--not directly convertible but convertible to a format that bmpconv can use as input
		return fallback_conversions[pixel]
	end
	return pixel --not convertible
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

--create a callback manager object and its destructor.
local function callback_manager(mgr_ctype, callbacks)
	local mgr = ffi.new(mgr_ctype)
	local cbt = {}
	for k,f in pairs(callbacks) do
		if type(f) == 'function' then
			cbt[k] = ffi.cast(string.format('jpeg_%s_callback', k), f)
			mgr[k] = cbt[k]
		else
			mgr[k] = f
		end
	end
	local function free_mgr()
		ffi.gc(mgr, nil)
		for k,cb in pairs(cbt) do
			mgr[k] = nil
			cb:free()
		end
	end
	ffi.gc(mgr, free_mgr)
	return mgr, free_mgr
end

--end-of-image marker, inserted on EOF for partial display of broken images.
local JPEG_EOI = string.char(0xff, 0xD9):rep(32)

local dct_methods = {
	accurate = C.JDCT_ISLOW,
	fast = C.JDCT_IFAST,
	float = C.JDCT_FLOAT,
}

local function load(t)
	return glue.fcall(function(finally)

		--create the state object and output image
		local cinfo = ffi.new'jpeg_decompress_struct'
		local img = {}

		--setup error handling
		local jerr = ffi.new'jpeg_error_mgr'
		C.jpeg_std_error(jerr)
		local err_cb = ffi.cast('jpeg_error_exit_callback', function(cinfo)
			local buf = ffi.new'uint8_t[512]'
			cinfo.err.format_message(cinfo, buf)
			error(ffi.string(buf))
		end)
		local warnbuf --cache this buffer because there are a ton of messages
		local emit_cb = ffi.cast('jpeg_emit_message_callback', function(cinfo, level)
			if t.warning then
				warnbuf = warnbuf or ffi.new'uint8_t[512]'
				cinfo.err.format_message(cinfo, warnbuf)
				t.warning(ffi.string(warnbuf), level)
			end
		end)
		finally(function()
			C.jpeg_std_error(jerr)
			err_cb:free()
			emit_cb:free()
		end)
		jerr.error_exit = err_cb
		jerr.emit_message = emit_cb
		cinfo.err = jerr

		--init state
		C.jpeg_CreateDecompress(cinfo, LIBJPEG_VERSION, ffi.sizeof(cinfo))
		finally(function() C.jpeg_destroy_decompress(cinfo) end)

		--setup input source
		if t.stream then
			C.jpeg_stdio_src(cinfo, t.stream)
		elseif t.path then
			local f = stdio.fopen(t.path, 'rb')
			finally(function()
				C.jpeg_stdio_src(cinfo, nil)
				f:close()
			end)
			C.jpeg_stdio_src(cinfo, f)
		elseif t.string or t.cdata or t.read then
			local read = t.read
				or t.string and one_shot_reader(t.string)
				or t.cdata  and one_shot_reader(t.cdata, t.size)

			--create source callbacks
			local cb = {}
			cb.init_source = glue.pass
			cb.term_source = glue.pass
			cb.resync_to_restart = C.jpeg_resync_to_restart

			local partial_loading = t.partial_loading == nil or t.partial_loading

			local buf, sz, s --these must be upvalues so they don't get collected between calls
			function cb.fill_input_buffer(cinfo)
				s = nil --release the string from the last call if any
				buf, sz = read() --release the buffer from the last call and pin a new one
				if not buf then
					if partial_loading then
						buf = JPEG_EOI
						img.partial = true
					else
						error'eof'
					end
				end
				if type(buf) == 'string' then
					s = buf --pin buf in upvalue s
					buf = ffi.cast('const uint8_t*', s) --const prevents string copy
					sz = #s
				end
				assert(sz > 0, 'eof')
				cinfo.src.bytes_in_buffer = sz
				cinfo.src.next_input_byte = buf
				return true
			end

			function cb.skip_input_data(cinfo, sz)
				if sz <= 0 then return end
				while sz > cinfo.src.bytes_in_buffer do
					sz = sz - cinfo.src.bytes_in_buffer
					cb.fill_input_buffer(cinfo)
				end
				cinfo.src.next_input_byte = cinfo.src.next_input_byte + sz
				cinfo.src.bytes_in_buffer = cinfo.src.bytes_in_buffer - sz
			end

			--create a source manager and set it up
			local mgr, free_mgr = callback_manager('jpeg_source_mgr', cb)
			cinfo.src = mgr
			finally(function() --the finalizer needs to pin mgr or it gets collected
				cinfo.src = nil
				free_mgr()
			end)

			cinfo.src.bytes_in_buffer = 0
			cinfo.src.next_input_byte = nil
		else
			error'source missing'
		end

		--read header
		assert(C.jpeg_read_header(cinfo, 1) ~= 0, 'eof')

		img.file = {}
		img.file.w = cinfo.image_width
		img.file.h = cinfo.image_height
		img.file.pixel = assert(pixel_formats[tonumber(cinfo.jpeg_color_space)])
		assert(cinfo.num_components == #img.file.pixel)

		img.file.jfif = cinfo.saw_JFIF_marker == 1 and {
			maj_ver = cinfo.JFIF_major_version,
			min_ver = cinfo.JFIF_minor_version,
			density_unit = cinfo.density_unit,
			x_density = cinfo.X_density,
			y_density = cinfo.Y_density,
		} or nil

		img.file.adobe = cinfo.saw_Adobe_marker == 1 and {
			transform = cinfo.Adobe_transform,
		} or nil

		if t.header_only then
			return img
		end

		--find the best accepted output pixel format
		img.pixel = best_pixel_format(img.file.pixel, t.accept)

		--set decompression options
		cinfo.out_color_space = assert(color_spaces[img.pixel])
		cinfo.output_components = #img.pixel
		cinfo.scale_num = t.scale_num or 1
		cinfo.scale_denom = t.scale_denom or 1
		cinfo.dct_method = assert(dct_methods[t.dct_method or 'accurate'], 'invalid dct_method')
		cinfo.do_fancy_upsampling = t.fancy_upsampling or false
		cinfo.do_block_smoothing = t.block_smoothing or false
		cinfo.buffered_image = C.jpeg_has_multiple_scans(cinfo) and t.render_scan and 1 or 0

		--start decompression, which fills the info about the output image
		C.jpeg_start_decompress(cinfo)

		--get info about the output image
		img.w = cinfo.output_width
		img.h = cinfo.output_height

		--compute the stride
		img.stride = cinfo.output_width * cinfo.output_components
		if t.accept and t.accept.padded then
			img.stride = pad_stride(img.stride)
		end

		--allocate image and rows buffers
		img.size = img.h * img.stride
		img.data = ffi.new('uint8_t[?]', img.size)
		local rows = ffi.new('uint8_t*[?]', img.h)

		--arrange row pointers top-down or bottom-up
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

			--read all the scanlines into the row buffers
			while cinfo.output_scanline < img.h do

				--read several scanlines at once, depending on the size of the output buffer
				local i = cinfo.output_scanline
				local n = math.min(img.h - i, cinfo.rec_outbuf_height)
				local actual = C.jpeg_read_scanlines(cinfo, rows + i, n)
				assert(actual == n)
				assert(cinfo.output_scanline == i + actual)

				--call the line-level callback
				if t.update_lines then
					t.update_lines(img)
				end
			end

			--convert the image with bmpconv if its pixel format is not among accepted ones.
			--the resulting image may be a new image object with a new buffer, a new image object
			--with the same buffer as img, or can be img itself.
			outimg = img
			if t.accept and not t.accept[img.pixel] then
				local bmpconv = require'bmpconv'
				outimg = bmpconv.convert_best(img, t.accept, {force_copy = multiple_scans})
			end

			--call the rendering callback on the converted image
			if t.render_scan then
				t.render_scan(outimg, scan_number)
			end
		end

		if cinfo.buffered_image == 1 then --multiscan reading
			while C.jpeg_input_complete(cinfo) == 0 do

				--read all the scanlines of the current scan
				repeat
					local ret = C.jpeg_consume_input(cinfo)
					assert(ret ~= C.JPEG_SUSPENDED)
				until ret == C.JPEG_REACHED_EOI or ret == C.JPEG_SCAN_COMPLETED

				--render the scan
				C.jpeg_start_output(cinfo, cinfo.input_scan_number)
				render_scan(cinfo.output_scan_number, true)
				C.jpeg_finish_output(cinfo)
			end
		else
			render_scan(1)
		end

		C.jpeg_finish_decompress(cinfo)
		return outimg
	end)
end

jit.off(load, true) --can't call error() from callbacks called from C

if not ... then require'libjpeg_demo' end

return {
	load = load,
	C = C,
}

