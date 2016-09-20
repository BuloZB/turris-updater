--[[
Copyright 2016, CZ.NIC z.s.p.o. (http://www.nic.cz/)

This file is part of the turris updater.

Updater is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Updater is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Updater.  If not, see <http://www.gnu.org/licenses/>.
]]--

local ipairs = ipairs
local pairs = pairs
local type = type
local tostring = tostring
local error = error
local next = next
local assert = assert
local unpack = unpack
local table = table
local DIE = DIE
local DBG = DBG
local WARN = WARN
local utils = require "utils"
local backend = require "backend"
local sat = require "sat"

module "planner"

-- luacheck: globals candidate_choose required_pkgs filter_required pkg_dep_iterate plan_sorter

--[[
Choose the best candidate to install.
]]
function candidate_choose(candidates, name)
	-- First choose the candidates from the repositories with the highest priority
	candidates = utils.filter_best(candidates, function (c) return c.repo.priority end, function (_1, _2) return _1 > _2 end)
	-- Then according to package versions
	candidates = utils.filter_best(candidates, function (c) return c.Version end, function (_1, _2) return backend.version_cmp(_1, _2) == 1 end)
	-- Then according to the repo order
	candidates = utils.filter_best(candidates, function (c) return c.repo.serial end, function (_1, _2) return _1 < _2 end)
	if #candidates > 1 then
		WARN("Multiple best candidates for " .. name)
	end
	return candidates[1]
end

--[[
Build dependencies for all touched packages. We do it recursively across
dependencies of requested packages, this makes searched space smaller and building
it faster.

Note that we are not checking if package has some real candidates or if it even
exists. This must be resolved later.
--]]
local function build_deps(sat, satmap, pkgs, requests)
	local dep_traverse -- predefine function as local
	-- Returns sat variable for given package. If it is not yet added, then we create new variable and add all its dependencies too.
	-- TODO handle packages. If we have object of type package, then it is dependency to specific package. We have to solve this as part of alternatives
	local function dep(name)
		if satmap.pkg2sat[name] then 
			return satmap.pkg2sat[name] -- Already known variable, return it.
		end
		-- Create new variable for this package and new sat clauses batch
		local pkg_var = sat:var()
		DBG("SAT add package " .. name .. " with var: " .. tostring(pkg_var))
		satmap.pkg2sat[name] = pkg_var
		local pkg = pkgs[name]
		local candidate
		if pkg and pkg.candidates and next(pkg.candidates) then
			-- Found candidate only if we have some to chose from
			-- TODO For now we chose only single candidate, in future all candidates should be in SAT
			candidate = candidate_choose(pkg.candidates, name)
			satmap.pkg2candidate[name] = candidate
		end
		-- Add dependencies of package
		local alldeps = { utils.multi_index(pkg, 'modifier', 'deps') }
		utils.arr_append(alldeps, (candidate or {}).deps or {})
		-- Note that for no dependencies we will receive dummy variable that isn't in any clause.
		local dep_var = dep_traverse(alldeps)
		sat:clause(-pkg_var, dep_var) -- We only do implication here. Equivalence could result in package selection because its dependencies are satisfied.
		-- And return variable for this package
		return pkg_var
	end
	-- Recursively adds implications for given package to its dependencies. It returns sat variable for whole dependency.
	-- As additional to canonized dependencies it also supports table without any type as and, this is for convenience.
	function dep_traverse(deps)
		if type(deps) == 'string' or deps.tp == 'package' or deps.tp == 'dep-package' then
			local name = deps
			if deps.tp then -- TODO This is just for now, this makes dependency on whole group instead of single version as it should been
				name = deps.name
			end
			return dep(name)
		end
		if deps.tp == 'dep-not' then
			assert(#deps.sub == 1)
			-- just do negation of var, so 'not' is propagated to upper clause
			return -dep_traverse(deps.sub[1])
		end
		local wvar = sat:var()
		if (type(deps) == 'table' and not deps.tp) or deps.tp == 'dep-and' then
			-- wid <=> var for every variable. Result is that they are all in and statement.
			for _, sub in ipairs(deps.sub or deps) do
				local var = dep_traverse(sub)
				sat:clause(-wvar, var)
				sat:clause(-var, wvar)
			end
		elseif deps.tp == 'dep-or' then
			-- If wvar is true, at least one of sat variables must also be true, so vwar => vars...
			-- Same as if one of vars is true, wvar must be also true, so var => wvar
			local vars = {}
			local prev_penalty = nil
			for _, sub in ipairs(deps.sub) do
				local var = dep_traverse(sub)
				-- var => wvar
				sat:clause(-var, wvar)
				-- penalty => not var and potentially prev_penalty => penalty
				if #vars ~= 0 then -- skip first one, it isn't penalized.
					local penalty = sat:var()
					if prev_penalty then
						sat:clause(-prev_penalty, penalty)
					end
					sat:clause(-penalty, -var)
					prev_penalty = penalty
					satmap.penaltysat[penalty] = true -- store that this is penalty variable
				end
				-- wvar => vars...
				table.insert(vars, var)
			end
			sat:clause(-wvar, unpack(vars))
		else
			error(utils.exception('bad value', "Invalid dependency description " .. (deps.tp or "<nil>")))
		end
		return wvar
	end

	-- Go trough requests and add them to SAT
	for _, req in ipairs(requests) do
		local req_var = sat:var()
		local target_var = dep(req.package.name)
		if req.tp == 'install' then
			sat:clause(-req_var, target_var) -- implies true
		elseif req.tp == 'uninstall' then
			sat:clause(-req_var, -target_var) -- implies false
		else
			error(utils.exception('bad value', "Unknown type " .. tostring(req.tp)))
		end
		satmap.req2sat[req] = req_var
	end
end

-- Iterate trough all packages in given dependency tree.
function pkg_dep_iterate(pkg_deps)
	local function iterate_internal(deps)
		if #deps == 0 then
			return nil
		end
		local d = deps[#deps]
		deps[#deps] = nil
		if type(d) == 'string' or d.tp == 'package' or d.tp == 'dep-package' then
			return deps, d
		else
			assert(type(d) == 'table')
			utils.arr_append(deps, d.sub or d)
			return iterate_internal(deps)
		end
	end
	return iterate_internal, { pkg_deps }
end

--[[
Create new plan, sorted so that packages with dependency on some other installed
package is planned after such package. This is not of course always possible
and so when we encounter cyclic dependencies we just cut circle in some random
point and prints warning for packages that will be inconsistent during
installation process. Exception is critical packages, for those no cycles are
allowed and result would be error.
If packages has no candidate (so can't be installed) we fail or if it should be
ignored, we print warning. We remember whole stack of previous packages to check
if some other planned package won't be affected too.
It returns sorted plan.
]]--
local function build_plan(pkgs, requests, sat, satmap)
	local plan = {}
	local planned = {} -- Table where key is name of already planned package group and value is index in plan
	local wstack = {} -- array of packages we work on
	local inwstack = {} -- table of all packages we work on where key is name and value is index
	local inconsistent = {} -- Set of potentially inconsistent packages (might fail their post-install scrips)
	local missing_dep = {} -- Set of all packages that depends on some missing dependency
	--[[
	Plans given package (request) and all of its dependencies. Argument pkg is
	"package" or string (name of package group).  ignore_missing is extra option
	of package allowing ignore of missing dependencies.  ignore_missing_pkg is
	extra option of package allowing to ignore request if there is not target for
	such package. And parent_str is string used for warning and error messages
	containing information about who requested given package.
	--]]
	local function pkg_plan(pkg, ignore_missing, ignore_missing_pkg, parent_str)
		local name = pkg.name or pkg
		if not sat[satmap.pkg2sat[name]] then return end -- This package is not selected, so we ignore it.
		if planned[name] then -- Already in plan, which is OK
			if missing_dep[name] then -- Package was added to plan with ignored missing dependency
				if ignore_missing or ignore_missing_pkg then
					WARN(parent_str .. " " .. name .. " that's missing or misses some dependency. Ignoring as requested")
				else
					error(utils.exception('inconsistent', parent_str .. " " .. name .. " that's missing or misses some dependency. See previous warnings for more info."))
				end
			end
			return plan[planned[name]]
		end
		-- Check for cycles --
		if inwstack[name] then -- Already working on it. Found cycle.
			for i = inwstack[name], #wstack, 1 do
				local inc_name = wstack[i]
				if not inconsistent[inc_name] then -- Do not warn again
					WARN("Package " .. inc_name .. " is in cyclic dependency. It might fail its post-install script.")
				end
				inconsistent[inc_name] = true
			end
			return
		end
		-- Check if we have candidate --
		local pkg = pkgs[name]
		if not satmap.pkg2candidate[name] then
			if ignore_missing or ignore_missing_pkg then
				missing_dep[name] = true
				utils.table_merge(missing_dep, utils.arr2set(wstack)) -- Whole working stack is now missing dependency
				WARN(parent_str .. " " .. name .. " that is missing, ignoring as requested.")
			else
				error(utils.exception('inconsistent', parent_str .. " " .. name .. " that is not available."))
			end
		end
		-- Recursively add all packages this package depends on --
		inwstack[name] = #wstack + 1 -- Signal that we are working on this package group.
		table.insert(wstack, name)
		local alldeps = { utils.multi_index(pkg, 'modifier', 'deps') }
		utils.arr_append(alldeps, (satmap.pkg2candidate[name] or {}).deps or {})
		for _, p in pkg_dep_iterate(alldeps) do
			pkg_plan(p, ignore_missing or utils.arr2set(utils.multi_index(pkg, 'modifier', 'ignore') or {})["deps"], false, "Package " .. name .. " requires package")
		end
		table.remove(wstack, inwstack[name])
		inwstack[name] = nil -- Our recursive work on this package group ended.
		if not satmap.pkg2candidate[name] then -- If no candidate, then we have nothing to be planned
			return
		end
		-- And finally plan it --
		planned[name] = #plan + 1
		local r = {
			action = 'require',
			package = satmap.pkg2candidate[name],
			modifier = (pkg or {}).modifier or {},
			name = name
		}
		plan[#plan + 1] = r
		return r
	end

	for _, req in pairs(requests) do
		if sat[satmap.req2sat[req]] and req.tp == "install" then -- Plan only if we can satisfy given request and it is install request
			local pkg_name = req.package.name
			local pln = pkg_plan(req.package.name, false, utils.arr2set(req.ignore or {})["missing"], 'Requested package')
			if req.reinstall and pln then
				pln.action = 'reinstall'
			end
			if req.critical and inconsistent[req.package.name] then -- Check if critical didn't end up in cyclic dependency
				error(utils.exception('inconsistent-critical', 'Package ' .. pkg_name .. ' is requested as critical. Cyclic dependency is not allowed for critical requests.'))
			end
		end
	end

	return plan
end

--[[
Take list of available packages (in the format of pkg candidate groups
produced in postprocess.available_packages) and list of requests what
to install and remove. Produce list of packages, in the form:
{
  {action = "require"/"reinstall"/"remove", package = pkg_source, modifier = modifier}
}

The action specifies if the package should be made present in the system (installed
if missing), reinstalled (installed no matter if it is already present) or
removed from the system.
• Required to be installed
• Required to be reinstalled even when already present (they ARE part of the previous set)
• Required to be removed if present (they are not present in the previous two lists)

The pkg_source is the package object (in case it contains the source field or is virtual)
or the description produced from parsing the repository. The modifier is the object
constructed from package objects during the aggregation, holding additional processing
info (hooks, etc).

TODO: The current version is very tentative and minimal. It ignores any specialities
like package versions, alternative dependencies, blocks or enforced order.
]]
function required_pkgs(pkgs, requests)
	local sat = sat.new()
	-- Tables that's mapping packages, requests and candidates with sat variables
	local satmap = {
		pkg2sat = {},
		req2sat = {},
		pkg2candidate = {}, -- TODO replace with candidate2sat
		penaltysat = {} -- Set of all penalty variables
	}
	-- Build dependencies
	build_deps(sat, satmap, pkgs, requests)

	-- Sort all requests to groups by priority
	local reqs_by_priority = {}
	local reqs_critical = {}
	for _, req in pairs(requests) do
		if req.tp == 'install' and req.critical then
			table.insert(reqs_critical, req)
		else
			if not req.priority then req.priority = 50 end
			if not reqs_by_priority[req.priority] then reqs_by_priority[req.priority] = {} end
			if req.tp ~= (utils.map(reqs_by_priority[req.priority], function(_, r) return r.package.name, r.tp end)[req.package.name] or req.tp) then
				error(utils.exception('invalid-request', 'Requested both Install and Uninstall with same priority for package ' .. req.package.name))
			end
			table.insert(reqs_by_priority[req.priority], req)
		end
	end
	local prios = utils.set2arr(reqs_by_priority)
	table.sort(prios, function(a, b) return a > b end)
	local reqs_prior = {}
	for _, p in ipairs(prios) do
		table.insert(reqs_prior, reqs_by_priority[p])
	end

	-- Executes sat solver and adds clauses for maximal satisfiable set
	local function clause_max_satisfiable()
		sat:satisfiable()
		local maxassume = sat:max_satisfiable() -- assume only maximal satisfiable set
		for assum, _ in pairs(maxassume) do
			sat:clause(assum)
		end
		sat:satisfiable() -- Reset assumptions (TODO isn't there better solution to reset assumptions?)
	end

	-- Install critical packages requests (set all critical packages to be true)
	DBG("Resolving critical packages")
	for _, req in ipairs(reqs_critical) do
		sat:clause(satmap.req2sat[req])
	end
	if not sat:satisfiable() then
		-- TODO This exception should probably be saying more about why. We can assume variables first and inspect maximal satisfiable set then.
		utils.exception('inconsistent', "Packages marked as critical can't satisfy their dependencies together.")
	end

	-- Install and Uninstall requests.
	DBG("Resolving Install and Uninstall requests")
	for _, reqs in ipairs(reqs_prior) do
		for _, req in pairs(reqs) do
			-- Assume all request for this priority
			sat:assume(satmap.req2sat[req])
		end
		clause_max_satisfiable()
	end

	-- Deny any packages missing or without candidates if possible
	DBG("Denying packages without any candidate")
	for name, var in pairs(satmap.pkg2sat) do
		local pkg = pkgs[name]
		if not pkg or not pkg.candidates or not next(pkg.candidates) then
			sat:assume(-var)
		end
	end
	clause_max_satisfiable()

	-- Chose alternatives with penalty variables
	DBG("Forcing penalty on expressions with free alternatives")
	for var, _ in pairs(satmap.penaltysat) do
		sat:assume(var)
	end
	clause_max_satisfiable()

	-- Now solve all packages selections from dependencies of already selected packages
	DBG("Deducing minimal set of required packages")
	for _, var in pairs(satmap.pkg2sat) do
		-- We assume false (not selected) for all packages
		sat:assume(-var)
	end
	clause_max_satisfiable()
	-- We call this here again to calculate variables with all new clauses.
	-- Previous call in clause_max_satisfiable is with assumptions, so results
	-- from such calls aren't correct.
	sat:satisfiable() -- Set variables to result values

	return build_plan(pkgs, requests, sat, satmap)
end

--[[
Go through the list of requests on the input. Pass the needed ones through
and leave the extra (eg. requiring already installed package) out. Add
requests to remove not required packages.
]]
function filter_required(status, requests)
	local installed = {}
	for pkg, desc in pairs(status) do
		if not desc.Status or desc.Status[3] == "installed" then
			installed[pkg] = desc.Version or ""
		end
	end
	local unused = utils.clone(installed)
	local result = {}
	-- Go through the requests and look which ones are needed and which ones are satisfied
	for _, request in ipairs(requests) do
		local installed_version = installed[request.name]
		-- TODO: Handle virtual and stand-alone packages
		local requested_version = request.package.Version or ""
		if request.action == "require" then
			if not installed_version or installed_version ~= requested_version then
				DBG("Want to install/upgrade " .. request.name)
				table.insert(result, request)
			else
				DBG("Package " .. request.name .. " already installed")
			end
			unused[request.name] = nil
		elseif request.action == "reinstall" then
			-- Make a shallow copy and change the action requested
			local new_req = {}
			for k, v in pairs(request) do
				new_req[k] = v
			end
			new_req.action = "require"
			DBG("Want to reinstall " .. request.name)
			table.insert(result, new_req)
			unused[request.name] = nil
		elseif request.action == "remove" then
			if installed[request.name] then
				DBG("Want to remove " .. request.name)
				table.insert(result, request)
			else
				DBG("Package " .. request.name .. " not installed, ignoring request to remove")
			end
			unused[request.name] = nil
		else
			DIE("Unknown action " .. request.action)
		end
	end
	-- Go through the packages that are installed and nobody mentioned them and mark them for removal
	-- TODO: Order them according to dependencies
	for pkg in pairs(unused) do
		DBG("Want to remove left-over package " .. pkg)
		table.insert(result, {
			action = "remove",
			name = pkg,
			package = status[pkg]
		})
	end
	-- If we are requested to replan after some package, wipe the rest of the plan
	local wipe = false
	for i, request in ipairs(result) do
		if wipe then
			result[i] = nil
		elseif request.action == "require" and request.modifier.replan then
			wipe = true
		end
	end
	return result
end

return _M