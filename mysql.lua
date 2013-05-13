--mysql low level binding per mySQL 5.7 manual by Cosmin Apreutesei.
local ffi = require'ffi'
local bit = require'bit'
require'mysql_h'
local C = ffi.load'libmysql'
local M = {C = C}

--error reporting

--we compare NULL pointers against NULL instead of nil for compatibility with luaffi.
local NULL = ffi.cast('void*', nil)

local function cstring(data)
	if data == NULL or data[0] == 0 then return end
	return ffi.string(data)
end

local int64 = ffi.new'int64_t'
local uint64 = ffi.new'uint64_t'
local function is_int64(v)
	return type(v) == 'cdata' and ffi.istype(v, int64) or ffi.istype(v, uint64)
end

local function myerror(mysql)
	local err = cstring(C.mysql_error(mysql))
	if not err then return end
	error(string.format('mysql error: %s', err))
end

local function checkz(mysql, ret)
	if ret == 0 then return end
	myerror(mysql)
end

local function checkh(mysql, ret)
	if ret ~= NULL then return ret end
	myerror(mysql)
end

local function enum(e, prefix)
	return type(e) == 'string' and (prefix and C[prefix..e] or C[e]) or e
end

--client library info

function M.thread_safe()
	return C.mysql_thread_safe() == 1
end

function M.client_info()
	return cstring(C.mysql_get_client_info())
end

M.client_version = C.mysql_get_client_version

--connections

local function bool_ptr(b)
	return ffi.new('my_bool[1]', b or false)
end

local function uint_bool_ptr(b)
	return ffi.new('uint32_t[1]', b or false)
end

local function uint_ptr(i)
	return ffi.new('uint32_t[1]', i)
end

local function proto_ptr(proto) --proto is 'MYSQL_PROTOCOL_*' or mysql.C.MYSQL_PROTOCOL_*
	return ffi.new('uint32_t[1]', enum(proto))
end

local function ignore_arg()
	return nil
end

local option_encoders = {
	MYSQL_ENABLE_CLEARTEXT_PLUGIN = bool_ptr,
	MYSQL_OPT_LOCAL_INFILE = uint_bool_ptr,
	MYSQL_OPT_PROTOCOL = proto_ptr,
	MYSQL_OPT_READ_TIMEOUT = uint_ptr,
	MYSQL_OPT_WRITE_TIMEOUT = uint_ptr,
	MYSQL_OPT_USE_REMOTE_CONNECTION = ignore_arg,
	MYSQL_OPT_USE_EMBEDDED_CONNECTION = ignore_arg,
	MYSQL_OPT_GUESS_CONNECTION = ignore_arg,
	MYSQL_SECURE_AUTH = bool_ptr,
	MYSQL_REPORT_DATA_TRUNCATION = bool_ptr,
	MYSQL_OPT_RECONNECT = bool_ptr,
	MYSQL_OPT_SSL_VERIFY_SERVER_CERT = bool_ptr,
	MYSQL_ENABLE_CLEARTEXT_PLUGIN = bool_ptr,
	MYSQL_OPT_CAN_HANDLE_EXPIRED_PASSWORDS = bool_ptr,
}

function M.connect(t, ...)
	local host, user, pass, db, charset, port
	local unix_socket, flags, options, attrs
	local key, cert, ca, capath, cipher
	if type(t) == 'string' then
		host, user, pass, db, charset, port = t, ...
	else
		host, user, pass, db, charset, port = t.host, t.user, t.pass, t.db, t.charset, t.port
		unix_socket, flags, options, attrs = t.unix_socket, t.flags, t.options, t.attrs
		key, cert, ca, capath, cipher = t.key, t.cert, t.ca, t.capath, t.cipher
	end
	port = port or 0

	local client_flag = 0
	if type(flags) == 'number' then
		client_flag = flags
	elseif flags then
		for k,v in pairs(flags) do
			local flag = enum(k, 'MYSQL_') --'CLIENT_*' or mysql.C.MYSQL_CLIENT_* enum
			client_flag = v and bit.bor(client_flag, flag) or bit.band(client_flag, bit.bnot(flag))
		end
	end

	local mysql = assert(C.mysql_init(nil))
	ffi.gc(mysql, C.mysql_close)

	if options then
		for k,v in pairs(options) do
			local opt = enum(k) --'MYSQL_OPT_*' or mysql.C.MYSQL_OPT_* enum
			local encoder = option_encoders[k]
			if encoder then v = encoder(v) end
			assert(C.mysql_options(mysql, opt, ffi.cast('const void*', v)) == 0, 'invalid option')
		end
	end

	if attrs then
		for k,v in pairs(attrs) do
			assert(C.mysql_options4(mysql, C.MYSQL_OPT_CONNECT_ATTR_ADD, k, v) == 0)
		end
	end

	if key then
		checkz(mysql, C.mysql_ssl_set(mysql, key, cert, ca, capath, cipher))
	end

	checkh(mysql, C.mysql_real_connect(mysql, host, user, pass, db, port, unix_socket, client_flag))

	if charset then mysql:set_charset(charset) end

	return mysql
end

local conn = {} --connection methods

function conn.close(mysql)
	C.mysql_close(mysql)
	ffi.gc(mysql, nil)
end

function conn.set_charset(mysql, charset)
	checkz(mysql, C.mysql_set_character_set(mysql, charset))
end

function conn.select_db(mysql, db)
	checkz(mysql, C.mysql_select_db(mysql, db))
end

function conn.change_user(mysql, user, pass, db)
	checkz(mysql, C.mysql_change_user(mysql, user, pass, db))
end

function conn.set_multiple_statements(mysql, yes)
	checkz(mysql, C.mysql_set_server_option(mysql, yes and C.MYSQL_OPTION_MULTI_STATEMENTS_ON or
																			 C.MYSQL_OPTION_MULTI_STATEMENTS_OFF))
end

--connection info

function conn.charset(mysql)
	return cstring(C.mysql_character_set_name(mysql))
end

function conn.charset_info(mysql)
	local info = ffi.new'MY_CHARSET_INFO'
	checkz(C.mysql_get_character_set_info(mysql, info))
	assert(info.name ~= NULL)
	assert(info.csname ~= NULL)
	return {
		number = info.number,
		state = info.state,
		name = cstring(info.csname), --csname and name are inverted from the spec
		collation = cstring(info.name),
		comment = cstring(info.comment),
		dir = cstring(info.dir),
		mbminlen = info.mbminlen,
		mbmaxlen = info.mbmaxlen,
	}
end

function conn.ping(mysql)
	local ret = C.mysql_ping(mysql)
	if ret == 0 then return true end
	if ret == C.MYSQL_CR_SERVER_GONE_ERROR then return false end
	myerror(mysql)
end

conn.thread_id = C.mysql_thread_id

function conn.stat(mysql)
	return cstring(checkh(mysql, C.mysql_stat(mysql)))
end

function conn.server_info(mysql)
	return cstring(checkh(mysql, C.mysql_get_server_info(mysql)))
end

function conn.host_info(mysql)
	return cstring(checkh(mysql, C.mysql_get_host_info(mysql)))
end

conn.server_version = C.mysql_get_server_version
conn.proto_info = C.mysql_get_proto_info


function conn.ssl_cipher(mysql)
	return cstring(C.mysql_get_ssl_cipher(mysql))
end

--transactions

function conn.commit(mysql) checkz(mysql, C.mysql_commit(mysql)) end
function conn.rollback(mysql) checkz(mysql, C.mysql_rollback(mysql)) end
function conn.set_autocommit(mysql, yes) checkz(mysql, C.mysql_autocommit(mysql, yes == nil or yes)) end

--queries

function conn.escape_tobuffer(mysql, data, size, buf, sz)
	size = size or #data
	assert(sz >= size * 2 + 1)
	return C.mysql_real_escape_string(mysql, buf, data, size)
end

function conn.escape(mysql, data, size)
	size = size or #data
	local sz = size * 2 + 1
	local buf = ffi.new('uint8_t[?]', sz)
	sz = conn.escape_tobuffer(mysql, data, size, buf, sz)
	return ffi.string(buf, sz)
end

function conn.query(mysql, data, size)
	checkz(mysql, C.mysql_real_query(mysql, data, size or #data))
end

--query info

conn.field_count = C.mysql_field_count

local minus1_64bit = ffi.cast('uint64_t', ffi.cast('int64_t', -1))
function conn.affected_rows(mysql)
	local n = C.mysql_affected_rows(mysql)
	if n == minus1_64bit then myerror(mysql) end
	return tonumber(n)
end

conn.insert_id = C.mysql_insert_id
conn.errno = C.mysql_errno

function conn.sqlstate(mysql)
	return cstring(C.mysql_sqlstate(mysql))
end

conn.warning_count = C.mysql_warning_count

function conn.info(mysql)
	return cstring(C.mysql_info(mysql))
end

--query results

function conn.next_result(mysql) --multiple statement queries return multiple results
	local ret = C.mysql_next_result(mysql)
	if ret == 0 then return true end
	if ret == -1 then return false end
	myerror(mysql)
end

function conn.more_results(mysql)
	return C.mysql_more_results(mysql) == 1
end

local function result_function(func)
	return function(mysql)
		local res = checkh(mysql, func(mysql))
		return ffi.gc(res, C.mysql_free_result)
	end
end

conn.store_result = result_function(C.mysql_store_result)
conn.use_result = result_function(C.mysql_use_result)

local res = {} --result methods

function res.free(res)
	C.mysql_free_result(res)
	ffi.gc(res, nil)
end

function res.row_count(res)
	return tonumber(C.mysql_num_rows(res))
end

res.field_count = C.mysql_num_fields

function res.eof(res)
	return C.mysql_eof(res) ~= 0
end

--field info

local field_type_names = {
	[C.MYSQL_TYPE_DECIMAL]     = 'decimal',    --DECIMAL or NUMERIC
	[C.MYSQL_TYPE_TINY]        = 'tinyint',
	[C.MYSQL_TYPE_SHORT]       = 'smallint',
	[C.MYSQL_TYPE_LONG]        = 'integer',
	[C.MYSQL_TYPE_FLOAT]       = 'float',
	[C.MYSQL_TYPE_DOUBLE]      = 'double',     --DOUBLE or REAL
	[C.MYSQL_TYPE_NULL]        = 'null',
	[C.MYSQL_TYPE_TIMESTAMP]   = 'timestamp',
	[C.MYSQL_TYPE_LONGLONG]    = 'bigint',
	[C.MYSQL_TYPE_INT24]       = 'mediumint',
	[C.MYSQL_TYPE_DATE]        = 'date',       --pre mysql 5.0, storage = 4 bytes
	[C.MYSQL_TYPE_TIME]        = 'time',
	[C.MYSQL_TYPE_DATETIME]    = 'datetime',
	[C.MYSQL_TYPE_YEAR]        = 'year',
	[C.MYSQL_TYPE_NEWDATE]     = 'date',       --mysql 5.0+, storage = 3 bytes
	[C.MYSQL_TYPE_VARCHAR]     = 'varchar',
	[C.MYSQL_TYPE_BIT]         = 'bit',
	[C.MYSQL_TYPE_TIMESTAMP2]  = 'timestamp',  --mysql 5.6+, can store fractional seconds
	[C.MYSQL_TYPE_DATETIME2]   = 'datetime',   --mysql 5.6+, can store fractional seconds
	[C.MYSQL_TYPE_TIME2]       = 'time',       --mysql 5.6+, can store fractional seconds
	[C.MYSQL_TYPE_NEWDECIMAL]  = 'decimal',    --mysql 5.0+, Precision math DECIMAL or NUMERIC
	[C.MYSQL_TYPE_ENUM]        = 'enum',
	[C.MYSQL_TYPE_SET]         = 'set',
	[C.MYSQL_TYPE_TINY_BLOB]   = 'tinyblob',
	[C.MYSQL_TYPE_MEDIUM_BLOB] = 'mediumblob',
	[C.MYSQL_TYPE_LONG_BLOB]   = 'longblob',
	[C.MYSQL_TYPE_BLOB]        = 'text',       --TEXT or BLOB
	[C.MYSQL_TYPE_VAR_STRING]  = 'varchar',    --VARCHAR or VARBINARY
	[C.MYSQL_TYPE_STRING]      = 'char',       --CHAR or BINARY
	[C.MYSQL_TYPE_GEOMETRY]    = 'spatial',    --Spatial field
}

local binary_field_type_names = {
	[C.MYSQL_TYPE_BLOB]        = 'blob',
	[C.MYSQL_TYPE_VAR_STRING]  = 'varbinary',
	[C.MYSQL_TYPE_STRING]      = 'binary',
}

local field_flag_names = {
	[C.MYSQL_NOT_NULL_FLAG]         = 'not_null',
	[C.MYSQL_PRI_KEY_FLAG]          = 'pri_key',
	[C.MYSQL_UNIQUE_KEY_FLAG]       = 'unique_key',
	[C.MYSQL_MULTIPLE_KEY_FLAG]     = 'key',
	[C.MYSQL_BLOB_FLAG]             = 'is_blob',
	[C.MYSQL_UNSIGNED_FLAG]         = 'unsigned',
	[C.MYSQL_ZEROFILL_FLAG]         = 'zerofill',
	[C.MYSQL_BINARY_FLAG]           = 'is_binary',
	[C.MYSQL_ENUM_FLAG]             = 'is_enum',
	[C.MYSQL_AUTO_INCREMENT_FLAG]   = 'autoincrement',
	[C.MYSQL_TIMESTAMP_FLAG]        = 'is_timestamp',
	[C.MYSQL_SET_FLAG]              = 'is_set',
	[C.MYSQL_NO_DEFAULT_VALUE_FLAG] = 'no_default',
	[C.MYSQL_ON_UPDATE_NOW_FLAG]    = 'on_update_now',
	[C.MYSQL_NUM_FLAG]              = 'is_number',
}

function res.field_info(res, i)
	assert(i >= 1 and i <= res:field_count(), 'index out of range')
	local info = C.mysql_fetch_field_direct(res, i-1)
	local type_flag = tonumber(info.type)
	local t = {
		name       = cstring(info.name, info.name_length),
		org_name   = cstring(info.org_name, info.org_name_length),
		table      = cstring(info.table, info.table_length),
		org_table  = cstring(info.org_table, info.org_table_length),
		db         = cstring(info.db, info.db_length),
		catalog    = cstring(info.catalog, info.catalog_length),
		def        = cstring(info.def, info.def_length),
		length     = info.length,
		max_length = info.max_length,
		decimals   = info.decimals,
		charsetnr  = info.charsetnr,
		type_flag  = type_flag,
		type       = field_type_names[type_flag],
		flags      = info.flags,
		extension  = info.extension ~= NULL and info.extension or nil,
	}
	if info.charsetnr == 63 then --BINARY not CHAR, VARBYNARY not VARCHAR, BLOB not TEXT
		local bin_type = binary_field_type_names[type_flag]
		if bin_type then t.type = bin_type end
	end
	for flag, name in pairs(field_flag_names) do
		t[name] = bit.band(flag, info.flags) ~= 0
	end
	return t
end

--convenience name fetcher for fields (less garbage)
function res.field_name(res, i)
	assert(i >= 1 and i <= res:field_count(), 'index out of range')
	local info = C.mysql_fetch_field_direct(res, i-1)
	return cstring(info.name, info.name_length)
end

--convenience field iterator, shortcut of: for i=1,res:field_count() do local field = res:field_info(i) ... end
function res.fields(res)
	local n = res:field_count()
	local i = 0
	return function()
		if i == n then return end
		i = i + 1
		return i, res:field_info(i)
	end
end

--row data

ffi.cdef('double strtod(const char*, char**);')
local function parse_number(data, sz) --using strtod to avoid string creation
	return ffi.C.strtod(data, nil)
end

local function parse_float(data, sz)
	return tonumber(ffi.cast('float', ffi.C.strtod(data, nil))) --because windows is missing strtof()
end

ffi.cdef('int64_t strtoll(const char*, char**, int) ' ..(ffi.os == 'Windows' and ' asm("_strtoi64")' or '') .. ';')
local function parse_number64(data, sz)
	return ffi.C.strtoll(data, nil, 10)
end

local function parse_bit(data, sz)
 	local n = data[0] --bit fields always come in little-endian byte order
	if sz > 6 then --we can cover up to 6 bytes with Lua numbers
		n = ffi.cast('uint64_t', n)
	end
	for i=1,sz-1 do
		n = n * 256 + data[i]
	end
	return n
end

local function parse_date_(data, sz)
	assert(sz >= 10)
	local z = ('0'):byte()
	local year  = (data[0] - z) * 1000 + (data[1] - z) * 100 + (data[2] - z) * 10 + (data[3] - z)
	local month = (data[5] - z) * 10 + (data[6] - z)
	local day   = (data[8] - z) * 10 + (data[9] - z)
	return year, month, day
end

local function parse_time_(data, sz)
	assert(sz >= 8)
	local z = ('0'):byte()
	local hour = (data[0] - z) * 10 + (data[1] - z)
	local min  = (data[3] - z) * 10 + (data[4] - z)
	local sec  = (data[6] - z) * 10 + (data[7] - z)
	local frac = 0
	for i = 9, sz-1 do
		frac = frac * 10 + (data[i] - z)
	end
	return hour, min, sec, frac
end

local function parse_date(data, sz)
	local year, month, day = parse_date_(data, sz)
	return {year = year, month = month, day = day}
end

local function parse_time(data, sz)
	local hour, min, sec, frac = parse_time_(data, sz)
	return {hour = hour, min = min, sec = sec, frac = frac}
end

local function parse_datetime(data, sz)
	local year, month, day = parse_date_(data, sz)
	local hour, min, sec, frac = parse_time_(data + 11, sz - 11)
	return {year = year, month = month, day = day, hour = hour, min = min, sec = sec, frac = frac}
end

local field_decoders = {
	[C.MYSQL_TYPE_TINY] = parse_number,
	[C.MYSQL_TYPE_SHORT] = parse_number,
	[C.MYSQL_TYPE_LONG] = parse_number,
	[C.MYSQL_TYPE_FLOAT] = parse_float,
	[C.MYSQL_TYPE_DOUBLE] = parse_number,
	[C.MYSQL_TYPE_TIMESTAMP] = parse_datetime,
	[C.MYSQL_TYPE_LONGLONG] = parse_number64,
	[C.MYSQL_TYPE_INT24] = parse_number,
	[C.MYSQL_TYPE_DATE] = parse_date,
	[C.MYSQL_TYPE_TIME] = parse_time,
	[C.MYSQL_TYPE_DATETIME] = parse_datetime,
	[C.MYSQL_TYPE_NEWDATE] = parse_date,
	[C.MYSQL_TYPE_TIMESTAMP2] = parse_datetime,
	[C.MYSQL_TYPE_DATETIME2] = parse_datetime,
	[C.MYSQL_TYPE_TIME2] = parse_time,
	[C.MYSQL_TYPE_YEAR] = parse_number,
	[C.MYSQL_TYPE_BIT] = parse_bit,
}

local function fetch_buffers(res)
	local values = C.mysql_fetch_row(res)
	if values == NULL then
		if res.conn ~= NULL then --buffered read: check for errors
			myerror(res.conn)
		end
		return
	end
	local sizes = C.mysql_fetch_lengths(res)
	local field_count = C.mysql_num_fields(res)
	local fields = C.mysql_fetch_fields(res)
	return values, sizes, field_count, fields
end

local function decode_value(i, values, sizes, fields, decode)
	if values[i] == NULL then return nil end
	local decoder = decode and field_decoders[tonumber(fields[i].type)] or ffi.string
	return decoder(values[i], sizes[i])
end

local function mode_flags(mode)
	local numeric = not mode or mode:find'n'
	local assoc   = mode and mode:find'a'
	local packed  = mode and (numeric or assoc)
	local decode  = not mode or not mode:find's'
	return packed, numeric, assoc, decode
end

function res.fetch(res, mode, t)
	t = t or {}
	local packed, numeric, assoc, decode = mode_flags(mode)
	local values, sizes, field_count, fields = fetch_buffers(res)
	if not values then return nil end

	for i=0,field_count-1 do
		local v = decode_value(i, values, sizes, fields, decode)
		if numeric then
			t[i+1] = v
		end
		if assoc then
			local k = ffi.string(fields[i].name, fields[i].name_length)
			t[k] = v
		end
	end

	if packed then
		return t
	else
		return true, unpack(t)
	end
end

function res.rows(res, mode, t)
	local packed = mode_flags(mode)
	local i = 0
	res:seek(1)
	local function pass(t, ...)
		if not t then return end
		i = i + 1
		if packed then
			return i, t
		else
			return i, ...
		end
	end
	return function()
		return pass(res:fetch(mode, t))
	end
end

res.tell = C.mysql_row_tell

function res.seek(res, where) --use in conjunction with res:row_count()
	if type(where) == 'number' then
		C.mysql_data_seek(res, where-1)
	else
		C.mysql_row_seek(res, where)
	end
end

--reflection

local function list_function(func)
	return function(mysql, wild)
		local res = checkh(mysql, func(mysql, wild))
		return ffi.gc(res, C.mysql_free_result)
	end
end

conn.list_dbs = list_function(C.mysql_list_dbs)
conn.list_tables = list_function(C.mysql_list_tables)
conn.list_processes = result_function(C.mysql_list_processes)

--remote control

function conn.kill(mysql, pid)
	checkz(mysql, C.mysql_kill(mysql, pid))
end

function conn.shutdown(mysql, level)
	checkz(mysql, C.mysql_shutdown(mysql, enum(level)))
end

function conn.refresh(mysql, t) --options are 'REFRESH_*' or mysql.C.MYSQL_REFRESH_* enums
	local options = 0
	if type(t) == 'number' then
		options = t
	else
		for k,v in pairs(t) do
			if v then
				options = bit.bor(options, enum(k, 'MYSQL_'))
			end
		end
	end
	checkz(mysql, C.mysql_refresh(mysql, options))
end

function conn.dump_debug_info(mysql)
	checkz(mysql, C.mysql_dump_debug_info(mysql))
end

--prepared statements

local function sterror(stmt)
	local err = cstring(C.mysql_stmt_error(stmt))
	if not err then return end
	error(string.format('mysql error: %s', err))
end

local function stcheckz(stmt, ret)
	if ret == 0 then return end
	sterror(stmt)
end

local function stcheckbool(stmt, ret)
	if ret == 1 then return end
	sterror(stmt)
end

local function stcheckh(stmt, ret)
	if ret ~= NULL then return ret end
	sterror(stmt)
end

function conn.prepare(mysql, query)
	local stmt = checkh(mysql, C.mysql_stmt_init(mysql))
	ffi.gc(stmt, C.mysql_stmt_close)
	stcheckz(stmt, C.mysql_stmt_prepare(stmt, query, #query))
	return stmt
end

local stmt = {} --statement methods

function stmt.close(stmt)
	stcheckbool(stmt, C.mysql_stmt_close(stmt))
	ffi.gc(stmt, nil)
end

function stmt.exec(stmt)
	stcheckz(stmt, C.mysql_stmt_execute(stmt))
end

function stmt.next_result(stmt)
	local ret = C.mysql_stmt_next_result(stmt)
	if ret == 0 then return true end
	if ret == -1 then return false end
	sterror(stmt)
end

function stmt.store_result(stmt)
	stcheckz(stmt, C.mysql_stmt_store_result(stmt))
end

function stmt.free_result(stmt)
	stcheckbool(stmt, C.mysql_stmt_free_result(stmt))
end

function stmt.row_count(stmt)
	return tonumber(C.mysql_stmt_num_rows(stmt))
end

function stmt.affected_rows(stmt)
	local n = C.mysql_stmt_affected_rows(stmt)
	if n == minus1_64bit then sterror(stmt) end
	return tonumber(n)
end

stmt.insert_id = C.mysql_stmt_insert_id
stmt.field_count = C.mysql_stmt_field_count

stmt.errno = C.mysql_stmt_errno

function stmt.sqlstate(stmt)
	return cstring(C.mysql_stmt_sqlstate(stmt))
end

function stmt.result_metadata(stmt)
	local res = stcheckh(stmt, C.mysql_stmt_result_metadata(stmt))
	return ffi.gc(res, C.mysql_free_result)
end

function stmt.result_fields(stmt)
	local res = stmt:result_metadata()
	local fields = res:fields()
	res:free()
	return fields
end

function stmt.fetch(stmt)
	local ret = C.mysql_stmt_fetch(stmt)
	if ret == 0 then return true end
	if ret == C.MYSQL_NO_DATA then return false end
	if ret == C.MYSQL_DATA_TRUNCATED then return true, 'truncated' end
	sterror(stmt)
end

function stmt.reset(stmt)
	stcheckz(stmt, C.mysql_stmt_reset(stmt))
end

stmt.tell = C.mysql_stmt_row_tell

function stmt.seek(stmt, where) --use in conjunction with stmt:row_count()
	if type(where) == 'number' then
		C.mysql_stmt_data_seek(stmt, where-1)
	else
		C.mysql_stmt_row_seek(stmt, where)
	end
end

function stmt.send_long_data(stmt, param_number, data, size)
	stcheckz(stmt, C.mysql_stmt_send_long_data(stmt, param_number, data, size or #data))
end

function stmt.update_max_length(stmt)
	local attr = ffi.new'my_bool[1]'
	stcheckz(stmt, C.mysql_stmt_attr_get(stmt, C.STMT_ATTR_UPDATE_MAX_LENGTH, attr))
	return attr[0] == 1
end

function stmt.set_update_max_length(stmt, yes)
	local attr = ffi.new('my_bool[1]', yes)
	stcheckz(stmt, C.mysql_stmt_attr_set(stmt, C.STMT_ATTR_CURSOR_TYPE, attr))
end

function stmt.cursor_type(stmt)
	local attr = ffi.new'uint32_t[1]'
	stcheckz(stmt, C.mysql_stmt_attr_get(stmt, C.STMT_ATTR_CURSOR_TYPE, attr))
	return attr[0]
end

function stmt.set_cursor_type(stmt, cursor_type)
	local attr = ffi.new('uint32_t[1]', enum(cursor_type, 'MYSQL_'))
	stcheckz(stmt, C.mysql_stmt_attr_set(stmt, C.STMT_ATTR_CURSOR_TYPE, attr))
end

function stmt.prefetch_rows(stmt)
	local attr = ffi.new'uint32_t[1]'
	stcheckz(stmt, C.mysql_stmt_attr_get(stmt, C.STMT_ATTR_PREFETCH_ROWS, attr))
	return attr[0]
end

function stmt.set_prefetch_rows(stmt, n)
	local attr = ffi.new('uint32_t[1]', n)
	stcheckz(stmt, C.mysql_stmt_attr_set(stmt, C.STMT_ATTR_PREFETCH_ROWS, attr))
end

--statement bindings

local bind_buffer_types_input = {
	tinyint    = C.MYSQL_TYPE_TINY,
	smallint   = C.MYSQL_TYPE_SHORT,
	integer    = C.MYSQL_TYPE_LONG,
	bigint     = C.MYSQL_TYPE_LONGLONG,
	float      = C.MYSQL_TYPE_FLOAT,
	double     = C.MYSQL_TYPE_DOUBLE,
	time       = C.MYSQL_TYPE_TIME,
	date       = C.MYSQL_TYPE_DATE,
	datetime   = C.MYSQL_TYPE_DATETIME,
	timestamp  = C.MYSQL_TYPE_TIMESTAMP,
	text       = C.MYSQL_TYPE_STRING,
	char       = C.MYSQL_TYPE_STRING,
	varchar    = C.MYSQL_TYPE_STRING,
	blob       = C.MYSQL_TYPE_BLOB,
	binary     = C.MYSQL_TYPE_BLOB,
	varbinary  = C.MYSQL_TYPE_BLOB,
	null       = C.MYSQL_TYPE_NULL,
}

local bind_buffer_types_output = {
	tinyint    = C.MYSQL_TYPE_TINY,
	smallint   = C.MYSQL_TYPE_SHORT,
	mediumint  = C.MYSQL_TYPE_INT24,      --int32
	integer    = C.MYSQL_TYPE_LONG,
	bigint     = C.MYSQL_TYPE_LONGLONG,
	float      = C.MYSQL_TYPE_FLOAT,
	double     = C.MYSQL_TYPE_DOUBLE,
	real       = C.MYSQL_TYPE_DOUBLE,
	decimal    = C.MYSQL_TYPE_NEWDECIMAL, --char[]
	numeric    = C.MYSQL_TYPE_NEWDECIMAL, --char[]
	year       = C.MYSQL_TYPE_SHORT,
	time       = C.MYSQL_TYPE_TIME,
	date       = C.MYSQL_TYPE_DATE,
	datetime   = C.MYSQL_TYPE_DATETIME,
	timestamp  = C.MYSQL_TYPE_TIMESTAMP,
	char       = C.MYSQL_TYPE_STRING,
	binary     = C.MYSQL_TYPE_STRING,
	varchar    = C.MYSQL_TYPE_VAR_STRING,
	varbinary  = C.MYSQL_TYPE_VAR_STRING,
	tinyblob   = C.MYSQL_TYPE_TINY_BLOB,
	tinytext   = C.MYSQL_TYPE_TINY_BLOB,
	blob       = C.MYSQL_TYPE_BLOB,
	text       = C.MYSQL_TYPE_BLOB,
	mediumblob = C.MYSQL_TYPE_MEDIUM_BLOB,
	mediumtext = C.MYSQL_TYPE_MEDIUM_BLOB,
	longblob   = C.MYSQL_TYPE_LONG_BLOB,
	longtext   = C.MYSQL_TYPE_LONG_BLOB,
	bit        = C.MYSQL_TYPE_BIT,
	set        = C.MYSQL_TYPE_BLOB, --undocumented
	enum       = C.MYSQL_TYPE_BLOB, --undocumented
}

local number_types = {
	[C.MYSQL_TYPE_TINY]      = 'int8_t[1]',
	[C.MYSQL_TYPE_SHORT]     = 'int16_t[1]',
	[C.MYSQL_TYPE_LONG]      = 'int32_t[1]',
	[C.MYSQL_TYPE_INT24]     = 'int32_t[1]',
	[C.MYSQL_TYPE_LONGLONG]  = 'int64_t[1]',
	[C.MYSQL_TYPE_FLOAT]     = 'float[1]',
	[C.MYSQL_TYPE_DOUBLE]    = 'double[1]',
}

local time_types = {
	[C.MYSQL_TYPE_TIME]      = true,
	[C.MYSQL_TYPE_DATE]      = true,
	[C.MYSQL_TYPE_DATETIME]  = true,
	[C.MYSQL_TYPE_TIMESTAMP] = true,
}

local time_struct_types = {
	[C.MYSQL_TYPE_TIME] = C.MYSQL_TIMESTAMP_TIME,
	[C.MYSQL_TYPE_DATE] = C.MYSQL_TIMESTAMP_DATE,
	[C.MYSQL_TYPE_DATETIME] = C.MYSQL_TIMESTAMP_DATETIME,
	[C.MYSQL_TYPE_TIMESTAMP] = C.MYSQL_TIMESTAMP_DATETIME,
}

local bind = {} --bind buffer methods
local bind_meta = {__index = bind}

local function bind_buffer(defs, bind_buffer_types)
	local self = setmetatable({}, bind_meta)

	self.field_count = #defs
	self.buffer = ffi.new('MYSQL_BIND[?]', #defs)
	self.data = {} --data buffers, one for each field
	self.lengths = ffi.new('uint32_t[?]', #defs) --length buffers, one for each field
	self.null_flags = ffi.new('my_bool[?]', #defs) --null flag buffers, one for each field
	self.error_flags = ffi.new('my_bool[?]', #defs) --error (truncation) flag buffers, one for each field

	for i,def in ipairs(defs) do
		local btype = assert(bind_buffer_types[def.type:lower()], 'invalid type')
		local size = def.size
		local data = def.data
		if not data then
			if number_types[btype] then
				data = ffi.new(number_types[btype])
				size = 0 --size is ignored for number types
			elseif time_types[btype] then
				data = ffi.new'MYSQL_TIME'
				data.time_type = time_struct_types[btype]
				size = 0 -- size is ignored for time types
			elseif btype == C.MYSQL_TYPE_NULL then
				data = nil
				size = 0
			elseif btype == C.MYSQL_TYPE_BIT then
				data = ffi.new('uint8_t[?]', 8)
				size = 8 --bit types can be up to 64 bits
			else
				if size then
					data = ffi.new('uint8_t[?]', size)
				else
					data = nil
					size = 0
				end
			end
		end
		self.null_flags[i-1] = true
		self.data[i] = data
		self.lengths[i-1] = size
		self.buffer[i-1].buffer_type = btype
		self.buffer[i-1].buffer = data
		self.buffer[i-1].buffer_length = size
		self.buffer[i-1].is_null = self.null_flags + (i - 1)
		self.buffer[i-1].error = self.error_flags + (i - 1)
		self.buffer[i-1].length = self.lengths + (i - 1)
	end
	return self
end

local function bind_check_range(self, i)
	assert(i >= 1 and i <= self.field_count, 'index out of bounds')
end

local function set_date(tm, year, month, day)
	--mysql says we should normalize the values
	tm.year   = math.max(0, math.min(year  or 0, 9999))
	tm.month  = math.max(1, math.min(month or 1, 12))
	tm.day    = math.max(1, math.min(day   or 1, 31))
end

local function set_time(tm, hour, min, sec, frac)
	--mysql says we should normalize the values
	tm.hour   = math.max(0, math.min(hour  or 0, 59))
	tm.minute = math.max(0, math.min(min   or 0, 59))
	tm.second = math.max(0, math.min(sec   or 0, 59))
	tm.second_part = math.max(0, frac or 0)
end

function bind:get_date(i)
	bind_check_range(self, i)
	assert(tonumber(self.buffer[i-1].buffer_type) == C.MYSQL_TYPE_DATE, 'invalid type')
	local tm = self.data[i]
	return tm.year, tm.month, tm.day
end

function bind:set_date(i, year, month, day)
	bind_check_range(self, i)
	assert(tonumber(self.buffer[i-1].buffer_type) == C.MYSQL_TYPE_DATE, 'invalid type')
	set_date(self.data[i], year, month, day)
end

function bind:get_time(i)
	bind_check_range(self, i)
	assert(tonumber(self.buffer[i-1].buffer_type) == C.MYSQL_TYPE_TIME, 'invalid type')
	local tm = self.data[i]
	return tm.hour, tm.minute, tm.second, tm.second_part
end

function bind:set_time(i, hour, min, sec, frac)
	bind_check_range(self, i)
	assert(tonumber(self.buffer[i-1].buffer_type) == C.MYSQL_TYPE_TIME, 'invalid type')
	set_time(self.data[i], hour, min, sec, frac)
end

function bind:get_datetime(i)
	bind_check_range(self, i)
	local btype = tonumber(self.buffer[i-1].buffer_type)
	assert(btype == C.MYSQL_TYPE_DATETIME or btype == C.MYSQL_TYPE_TIMESTAMP, 'invalid type')
	local tm = self.data[i]
	return tm.year, tm.month, tm.day, tm.hour, tm.minute, tm.second, tm.second_part
end

function bind:set_datetime(i, year, month, day, hour, min, sec, frac)
	bind_check_range(self, i)
	local btype = tonumber(self.buffer[i-1].buffer_type)
	assert(btype == C.MYSQL_TYPE_DATETIME or btype == C.MYSQL_TYPE_TIMESTAMP, 'invalid type')
	set_date(self.data[i], year, month, day)
	set_time(self.data[i], hour, min, sec, frac)
end

function bind:set(i, value, size)
	bind_check_range(self, i)

	if value == nil or value == NULL then
		self.null_flags[i-1] = true
		return
	end

	local btype = tonumber(self.buffer[i-1].buffer_type)

	if btype == C.MYSQL_TYPE_NULL then
		error('attempt to set a null type field')
	elseif number_types[btype] then
		self.data[i][0] = value
	elseif time_types[btype] then
		set_date(self.data[i], value.year, value.month, value.day)
		set_time(self.data[i], value.hour, value.min, value.sec, value.frac)
	elseif btype == C.MYSQL_TYPE_BIT then
		elseif type(value) == 'string' then -- bits as '010101...' in little-endian
			local n = 0
			for i=1,#value do
				n = n * 2 + (value:byte(i) == ('1'):byte(1) and 1 or 0)
			end
		if type(value) == 'number' or is_int64(value) then --number or int64 or uint64 in CPU-endian
			local n = 0
			error'NYI'
		else
			error('invalid bit value')
		end
	else --var-sized types
		size = size or #value
		local bsize = self.buffer[i-1].buffer_length
		assert(bsize >= size, 'string too long')
		ffi.copy(data, value, size)
		self.lengths[i-1] = size
	end

	self.null_flags[i-1] = false
end

function bind:get(i)
	bind_check_range(self, i)

	local btype = tonumber(self.buffer[i-1].buffer_type)

	if btype == C.MYSQL_TYPE_NULL or self.null_flags[i-1] == 1 then
		return nil
	end

	if number_types[btype] then
		return self.data[i][0] --ffi converts these to lua numbers except for 64 bit types.
	elseif time_types[btype] then
		local t = self.data[i]
		if t.time_type == C.MYSQL_TIMESTAMP_TIME then
			return {hour = t.hour, min = t.minute, sec = t.second, frac = t.second_part}
		elseif t.time_type == C.MYSQL_TIMESTAMP_DATE then
			return {year = t.year, month = t.month, day = t.day}
		elseif t.time_type == C.MYSQL_TIMESTAMP_DATETIME then
			return {year = t.year, month = t.month, day = t.day,
						hour = t.hour, min = t.minute, sec = t.second, frac = t.second_part}
		else
			return nil --invalid time
		end
	else
		local sz = math.min(self.buffer[i-1].buffer_length, self.lengths[i-1])
		if btype == C.MYSQL_TYPE_BIT then
			return parse_bit(self.data[i], sz)
		else
			return ffi.string(self.data[i], sz)
		end
	end
end

function bind:is_null(i) --returns true if the field is null
	bind_check_range(self, i)
	local btype = self.buffer[i-1].buffer_type
	return btype == C.MYSQL_TYPE_NULL or self.null_flags[i-1] == 1
end

function bind:is_truncated(i) --returns true if the field value was truncated
	bind_check_range(self, i)
	return self.error_flags[i-1] == 1
end

function stmt.bind_params(stmt, params)
	local bb = bind_buffer(params, bind_buffer_types_input)
	stcheckz(stmt, C.mysql_stmt_bind_param(stmt, bb.buffer))
	return bb
end

local function gen_result_defs(stmt)
	local n = stmt:field_count()
	local result_fields = stmt:result_fields()
	for i=1,n do
		error'auto defs NYI'
	end
end

function stmt.bind_result(stmt, defs)
	if not defs then
		defs = gen_result_defs(stmt)
	end
	assert(stmt:field_count() == #defs, 'wrong number of fields')
	local bb = bind_buffer(defs, bind_buffer_types_output)
	stcheckz(stmt, C.mysql_stmt_bind_result(stmt, bb.buffer))
	return bb
end

--publish methods

if not rawget(_G, '__MYSQL') then
_G.__MYSQL = true
ffi.metatype('MYSQL', {__index = conn})
ffi.metatype('MYSQL_RES', {__index = res})
ffi.metatype('MYSQL_STMT', {__index = stmt})
end

if not ... then require'mysql_test' end

return M
