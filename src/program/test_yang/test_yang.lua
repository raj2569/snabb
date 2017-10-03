module(..., package.seeall)

local ffi     = require("ffi")
local schema  = require("lib.yang.schema")
local yang    = require('lib.yang.yang')

function run (parameters)
   local schema_name = 'test-schema-v1'
   local schema = schema.load_schema_by_name(schema_name)
   local conf = yang.load_configuration(parameters[1],{schema_name=schema_name, verbose = true})

   local test_list = conf.test_list.entry
   for k,v in pairs(test_list) do
      print (k, v)
   end
   
   
   local cid = tonumber(ffi.typeof(conf.test_list.entry.entry_type))
   while cid do
      local info = ffi.typeinfo(cid)
      print(cid, info.info, info.size, info.name)
      cid = info.sib
   end
   -- cid = 1499
   -- while cid do
   --    local info = ffi.typeinfo(cid)
   --    print(cid, info.info, info.size, info.name)
   --    cid = info.sib
   -- end

   -- local entry = conf.test_list.entry.entry_type
   -- print (entry.ip01)
   local c = config.new()
   engine.configure(c)
   engine.main({duration=1})
end
