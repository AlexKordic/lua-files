--codedit cursor: caret-based navigation and editing
local editor = require'codedit_editor'
local glue = require'glue'
local str = require'codedit_str'

editor.cursor = {
	--navigation policies
	restrict_eol = true, --don't allow caret past end-of-line
	restrict_eof = false, --don't allow caret past end-of-file
	land_bof = true, --go at bof if cursor goes up past it
	land_eof = true, --go at eof if cursor goes down past it
	word_chars = '^[a-zA-Z]', --for jumping through words
	--editing policies
	insert_mode = true, --insert or overwrite when typing characters
	auto_indent = true, --pressing enter copies the indentation of the current line over to the following line
	tabs = 'indent', --never, indent, always
	tab_align_list = true, --align to the next word on the above line; incompatible with tabs = 'always'
	tab_align_args = true, --align to the char after '(' on the above line; incompatible with tabs = 'always'
}

function editor:create_cursor(visible)
	return self.cursor:new(self, visible)
end

local cursor = editor.cursor

function cursor:new(editor, visible)
	self = glue.inherit({editor = editor, visible = visible}, self)
	self.line = 1
	self.col = 1 --current real col
	self.vcol = 1 --wanted visual col, when navigating up/down
	self.editor.cursors[self] = true
	return self
end

function cursor:free()
	assert(self.editor.cursor ~= self) --can't delete the default, key-bound cursor
	self.editor.cursors[self] = nil
end

--cursor navigation ------------------------------------------------------------------------------------------------------

--move to a specific position, restricting the final position according to navigation policies
function cursor:move(line, col, keep_vcol)
	col = math.max(1, col)
	if line < 1 then
		line = 1
		if self.land_bof then
			col = 1
		elseif self.restrict_eol then
			col = math.min(col, self.editor:last_col(line) + 1)
		end
	elseif line > self.editor:last_line() then
		if self.restrict_eof then
			line = self.editor:last_line()
			if self.land_eof then
				col = self.editor:last_col(line) + 1
			end
		elseif self.restrict_eol then
			col = 1
		end
	elseif self.restrict_eol then
		col = math.min(col, self.editor:last_col(line) + 1)
	end
	self.line = line
	self.col = col

	if not keep_vcol then
		--store the visual col of the cursor to be used as the wanted landing col by move_vert()
		self.vcol = self.editor:visual_col(self.line, self.col)
	end
end

--navigate horizontally
function cursor:move_horiz(cols)
	local line, col = self.editor:near_pos(self.line, self.col, cols, self.restrict_eol)
	self:move(line, col)
end

--navigate vertically, using the stored visual column as target column
function cursor:move_vert(lines)
	local line = self.line + lines
	local col = self.editor:real_col(line, self.vcol)
	self:move(line, col, true)
end

function cursor:move_left()  self:move_horiz(-1) end
function cursor:move_right() self:move_horiz(1) end
function cursor:move_up()    self:move_vert(-1) end
function cursor:move_down()  self:move_vert(1) end

function cursor:move_home()  self:move(1, 1) end
function cursor:move_bol()   self:move(self.line, 1) end

function cursor:move_end()
	local line, col = self.editor:clamp_pos(1/0, 1/0)
	self:move(line, col)
end

function cursor:move_eol()
	local line, col = self.editor:clamp_pos(self.line, 1/0)
	self:move(line, col)
end

function cursor:move_up_page()
	self:move_vert(-self.editor:pagesize())
end

function cursor:move_down_page()
	self:move_vert(self.editor:pagesize())
end

function cursor:move_left_word()
	local s = self.editor:getline(self.line)
	if not s or self.col == 1 then
		return self:move_left(-1)
	elseif self.col <= self.editor:indent_col(self.line) then --skip indent
		self:move(self.line, 1)
		return
	end
	local col = str.char_index(s, str.prev_word_break(s, str.byte_index(s, self.col), self.word_chars))
	col = math.max(1, col) --if not found, consider it found at bol
	self:move_horiz(-(self.col - col))
end

function cursor:move_right_word()
	local s = self.editor:getline(self.line)
	if not s then
		return self:move_horiz(1)
	elseif self.col > self.editor:last_col(self.line) then --skip indent
		if self.line + 1 > self.editor:last_line() then
			self:move(self.line + 1, 1)
		else
			self:move(self.line + 1, self.editor:indent_col(self.line + 1))
		end
		return
	end
	local col = str.char_index(s, str.next_word_break(s, str.byte_index(s, self.col), self.word_chars))
	self:move_horiz(col - self.col)
end

function cursor:move_to_selection(sel)
	self:move(sel.line2, sel.col2)
end

function cursor:move_to_coords(x, y)
	local line, vcol = self.editor:char_at(x, y)
	local col = self.editor:real_col(line, vcol)
	self:move(line, col)
end

--cursor-based editing ---------------------------------------------------------------------------------------------------

--extend the buffer to reach the cursor so we can edit there
function cursor:extend()
	if self.restrict_eof and self.restrict_eol then return end --cursor already restricted to the text
	self.editor:extend(self.line, self.col)
end

--insert a string at cursor and move the cursor to after the string
function cursor:insert_string(s)
	self:extend()
	local line, col = self.editor:insert_string(self.line, self.col, s)
	self:move(line, col)
end

--insert a string block at cursor and move the cursor to after the string
function cursor:insert_block(s)
	self:extend()
	local line, col = self.editor:insert_block(self.line, self.col, s)
	self:move(line, col)
end

--insert or overwrite a char at cursor, depending on insert mode
function cursor:insert_char(c)
	if not self.insert_mode then
		self:extend()
		self.editor:remove_string(self.line, self.col, self.line, self.col + str.len(c))
	end
	self:insert_string(c)
end

--delete the char at cursor
function cursor:delete_char()
	self:extend()
	local line, col = self.editor:right_pos(self.line, self.col, true)
	line, col = self.editor:clamp_pos(line, col)
	self.editor:remove_string(self.line, self.col, line, col)
end

--delete the char before the cursor
function cursor:delete_prev_char()
	self:extend()
	local line, col = self.editor:left_pos(self.line, self.col)
	self.editor:remove_string(line, col, self.line, self.col)
	self:move(line, col)
end

--add a new line, optionally copying the indent of the current line, and carry the cursor over
function cursor:insert_newline()
	local indent
	if self.auto_indent then
		local indent_col = self.editor:indent_col(self.line)
		if indent_col > 1 and self.col >= indent_col then --cursor is after the indent whitespace, we're auto-indenting
			indent = self.editor:sub(self.line, 1, indent_col - 1)
		end
	end
	self:insert_string'\n'
	if indent then
		self:insert_string(indent)
	end
end

--insert a tab character, expanding it according to tab expansion policies
function cursor:insert_tab()
	if false and (self.tab_align_list or self.tab_align_args) then
		--look in the line above for the vcol of the first non-space char after at least one space or '(', starting at vcol
		if str.first_nonspace(s1) < #s1 then
			local vcol = self.editor:visual_col(self.line, self.col)
			local col1 = self.editor:real_col(self.line-1, vcol)
			local stage = 0
			local s0 = self.editor:getline(self.line-1)
			for i in str.byte_indices(s0) do
				if i >= col1 then
					if stage == 0 and (str.isspace(s0, i) or str.isascii(s0, i, '(')) then
						stage = 1
					elseif stage == 1 and not str.isspace(s0, i) then
						stage = 2
						break
					end
					col1 = col1 + 1
				end
			end
			if stage == 2 then
				local vcol1 = self.editor:visual_col(self.line-1, col1)
				c = string.rep(' ', vcol1 - vcol)
			else
				c = string.rep(' ', self.editor.tabsize)
			end
		end
	elseif self.tabs == 'never' then
		self:insert_string(string.rep(' ', self.editor.tabsize))
		return
	elseif self.tabs == 'indent' then
		if self.editor:getline(self.line) and self.col > self.editor:indent_col(self.line) then
			self:insert_string(string.rep(' ', self.editor.tabsize))
			return
		end
	end
	self:insert_string'\t'
end

function cursor:outdent_line()
	self:extend()
	local old_sz = #self.editor:getline(self.line)
	self.editor:outdent_line(self.line)
	local new_sz = #self.editor:getline(self.line)
	local col = self.col + new_sz - old_sz --TODO: this doesn't work for multi-byte chars
	self:move(self.line, col)
end

function cursor:move_line_up()
	self.editor:move_line(self.line, self.line - 1)
	self:move_up()
end

function cursor:move_line_down()
	self.editor:move_line(self.line, self.line + 1)
	self:move_down()
end

--cursor scrolling -------------------------------------------------------------------------------------------------------

function cursor:make_visible()
	if not self.visible then return end
	local vcol = self.editor:visual_col(self.line, self.col)
	self.editor:make_visible(self.line, vcol)
end


if not ... then require'codedit_demo' end
