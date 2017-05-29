-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

-- Default to not using any Lua code on the filesystem.
-- (Can be overridden with -P argument: see below.)
package.path = ''

local STP = require("lib.lua.StackTracePlus")
local ffi = require("ffi")
local zone = require("jit.zone")
local lib = require("core.lib")
local shm = require("core.shm")
local C   = ffi.C
-- Load ljsyscall early to help detect conflicts
-- (e.g. FFI type name conflict between Snabb and ljsyscall)
local S = require("syscall")

require("lib.lua.strict")
require("lib.lua.class")

-- ljsyscall returns error as a cdata instead of a string, and the standard
-- assert doesn't use tostring on it.
_G.assert = function (v, ...)
   if v then return v, ... end
   error(tostring(... or "assertion failed!"))
end

-- Reserve names that we want to use for global module.
-- (This way we avoid errors from the 'strict' module.)
_G.config, _G.engine, _G.memory, _G.link, _G.packet, _G.timer, _G.timeline,
   _G.main = nil

ffi.cdef[[
      extern int argc;
      extern char** argv;
]]

-- Enable developer-level debug if SNABB_DEBUG env variable is set.
_G.developer_debug = lib.getenv("SNABB_DEBUG") ~= nil
debug_on_error = _G.developer_debug

function main ()
   zone("startup")
   require "lib.lua.strict"
   -- Warn on unsupported platforms
   if ffi.arch ~= 'x64' or ffi.os ~= 'Linux' then
      error("fatal: "..ffi.os.."/"..ffi.arch.." is not a supported platform\n")
   end
   initialize()
   local program, args = select_program(parse_command_line())
   if not lib.have_module(modulename(program)) then
      print("unsupported program: "..program:gsub("_", "-"))
      usage(1)
   else
      require(modulename(program)).run(args)
   end
end

-- Take the program name from the first argument, unless the first
-- argument is "snabb", in which case pop it off, handle any options
-- passed to snabb itself, and use the next argument.
function select_program (args)
   local program = programname(table.remove(args, 1))
   if program == 'snabb' then
      while #args > 0 and args[1]:match('^-') do
         local opt = table.remove(args, 1)
         if opt == '-h' or opt == '--help' then
            usage(0)
         else
            print("unrecognized option: "..opt)
            usage(1)
         end
      end
      if #args == 0 then usage(1) end
      program = programname(table.remove(args, 1))
   end
   return program, args
end

function usage (status)
   print("Usage: "..ffi.string(C.argv[0]).." <program> ...")
   local programs = require("programs_inc"):gsub("%S+", "  %1")
   print()
   print("This snabb executable has the following programs built in:")
   print(programs)
   print("For detailed usage of any program run:")
   print("  snabb <program> --help")
   print()
   print("If you rename (or copy or symlink) this executable with one of")
   print("the names above then that program will be chosen automatically.")
   os.exit(status)
end

function programname (name)
   return name:gsub("^.*/", "")
              :gsub("-[0-9.]+[-%w]+$", "")
              :gsub("-", "_")
              :gsub("^snabb_", "")
end

function modulename (program)
   program = programname(program)
   return ("program.%s.%s"):format(program, program)
end

-- Return all command-line paramters (argv) in an array.
function parse_command_line ()
   local array = {}
   for i = 0, C.argc - 1 do 
      table.insert(array, ffi.string(C.argv[i]))
   end
   return array
end

function exit (status)
   os.exit(status)
end

--- Globally initialize some things. Module can depend on this being done.
function initialize ()
   require("core.lib")
   require("core.clib_h")
   require("core.lib_h")
   -- Global API
   _G.config = require("core.config")
   _G.engine = require("core.app")
   _G.memory = require("core.memory")
   _G.link   = require("core.link")
   _G.packet = require("core.packet")
   _G.timer  = require("core.timer")
   _G.timeline = require("core.timeline")
   _G.main   = getfenv()
end

function handler (reason)
   print(reason)
   print(debug.traceback())
   if debug_on_error then debug.debug() end
   os.exit(1)
end

-- Cleanup after Snabb process.
function shutdown (pid)
   if not _G.developer_debug and not lib.getenv("SNABB_SHM_KEEP") then
      shm.unlink("/"..pid)
   end
end

function selftest ()
   print("selftest")
   assert(programname("/bin/snabb-1.0") == "snabb",
      "Incorrect program name parsing")
   assert(programname("/bin/snabb-1.0-alpha2") == "snabb",
      "Incorrect program name parsing")
   assert(programname("/bin/snabb-nfv") == "nfv",
      "Incorrect program name parsing")
   assert(programname("/bin/nfv-1.0") == "nfv",
      "Incorrect program name parsing")
   assert(modulename("nfv-sync-master-2.0") == "program.nfv_sync_master.nfv_sync_master",
      "Incorrect module name parsing")
   local pn = programname
   -- snabb foo => foo
   assert(select_program({ 'foo' }) == "foo",
      "Incorrect program name selected")
   -- snabb-foo => foo
   assert(select_program({ 'snabb-foo' }) == "foo",
      "Incorrect program name selected")
   -- snabb snabb-foo => foo
   assert(select_program({ 'snabb', 'snabb-foo' }) == "foo",
      "Incorrect program name selected")
end

-- Fork a child process that monitors us and performs cleanup actions
-- when we terminate.
local snabbpid = S.getpid()
if assert(S.fork()) ~= 0 then
   -- parent process: run snabb
   xpcall(main, handler)
else
   -- child process: supervise parent & perform cleanup
   -- Subscribe to SIGHUP on parent death
   S.prctl("set_name", "[snabb sup]")
   S.prctl("set_pdeathsig", "hup")
   -- Trap relevant signals to a file descriptor
   local exit_signals = "hup, int, quit, term"
   local signalfd = S.signalfd(exit_signals)
   S.sigprocmask("block", exit_signals)
   -- wait until we receive a signal
   local signals
   repeat signals = assert(S.util.signalfd_read(signalfd)) until #signals > 0
   -- cleanup after parent process
   shutdown(snabbpid)
   -- exit with signal-appropriate status
   os.exit(128 + signals[1].signo)
end
