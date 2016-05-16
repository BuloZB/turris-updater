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

require 'lunit'

local requests = require "requests"
local postprocess = require "postprocess"
local utils = require "utils"

module("postprocess-tests", package.seeall, lunit.testcase)

local function repo_fake(name, uri, ok, content)
	local result =  {
		tp = "repository",
		name = name,
		repo_uri = uri
	}
	utils.private(result).index_uri = {
		[""] = {
			tp = "uri",
			uri = uri .. "/Packages",
			cback = function(self, cback)
				cback(ok, content)
			end,
			events = {}
		}
	}
	return result
end

local example_output = {
	{
		content = {
			[""] = {
				list = {
					["6in4"] = {
						Architecture = "all",
						Depends = {"libc", "kmod-sit"},
						Description = [[Provides support for 6in4 tunnels in /etc/config/network.
 Refer to http://wiki.openwrt.org/doc/uci/network for
 configuration details.]],
						Filename = "6in4_21-2_all.ipk",
						["Installed-Size"] = "1558",
						License = "GPL-2.0",
						MD5Sum = "a2a58a05c002cf7b45fbe364794d96a5",
						Maintainer = "Jo-Philipp Wich <xm@subsignal.org>",
						Package = "6in4",
						SHA256sum = "06c3e5630a54a6c2d95ff13945b76e4122ac1a9e533fe4665c501ae26d55933d",
						Section = "net",
						Size = "2534",
						Source = "package/network/ipv6/6in4",
						Version = "21-2",
						uri_raw = "http://example.org/test1/6in4_21-2_all.ipk"
					},
					["6rd"] = {
						Architecture = "all",
						Depends = {"libc", "kmod-sit"},
						Description = [[Provides support for 6rd tunnels in /etc/config/network.
 Refer to http://wiki.openwrt.org/doc/uci/network for
 configuration details.]],
						Filename = "6rd_9-2_all.ipk",
						["Installed-Size"] = "3432",
						License = "GPL-2.0",
						MD5Sum = "2b46cba96c887754f879676be77615e5",
						Maintainer = "Steven Barth <cyrus@openwrt.org>",
						Package = "6rd",
						SHA256sum = "e1081e495d0055f962a0ea4710239447eabf596f7acb06ccf0bd6f06b125fda8",
						Section = "net",
						Size = "4416",
						Source = "package/network/ipv6/6rd",
						Version = "9-2",
						uri_raw = "http://example.org/test1/6rd_9-2_all.ipk"
					}
				},
				tp="pkg-list"
			}
		},
		name="test1",
		repo_uri="http://example.org/test1",
		tp="parsed-repository"
	}
}
example_output[1].content[""].list["6in4"].repo = example_output[1]
example_output[1].content[""].list["6rd"].repo = example_output[1]

function test_get_repos_plain()
	requests.known_repositories_all = {
		repo_fake("test1", "http://example.org/test1", true, [[
Package: 6in4
Version: 21-2
Depends: libc, kmod-sit
Source: package/network/ipv6/6in4
License: GPL-2.0
Section: net
Maintainer: Jo-Philipp Wich <xm@subsignal.org>
Architecture: all
Installed-Size: 1558
Filename: 6in4_21-2_all.ipk
Size: 2534
MD5Sum: a2a58a05c002cf7b45fbe364794d96a5
SHA256sum: 06c3e5630a54a6c2d95ff13945b76e4122ac1a9e533fe4665c501ae26d55933d
Description:  Provides support for 6in4 tunnels in /etc/config/network.
 Refer to http://wiki.openwrt.org/doc/uci/network for
 configuration details.

Package: 6rd
Version: 9-2
Depends: libc, kmod-sit
Source: package/network/ipv6/6rd
License: GPL-2.0
Section: net
Maintainer: Steven Barth <cyrus@openwrt.org>
Architecture: all
Installed-Size: 3432
Filename: 6rd_9-2_all.ipk
Size: 4416
MD5Sum: 2b46cba96c887754f879676be77615e5
SHA256sum: e1081e495d0055f962a0ea4710239447eabf596f7acb06ccf0bd6f06b125fda8
Description:  Provides support for 6rd tunnels in /etc/config/network.
 Refer to http://wiki.openwrt.org/doc/uci/network for
 configuration details.
]])
	}
	assert_nil(postprocess.get_repos())
	assert_table_equal(example_output, requests.known_repositories_all)
end

function test_get_repos_gzip()
	local datadir = (os.getenv("S") or ".") .. "/tests/data"
	local content = utils.slurp(datadir .. "/Packages.gz")
	requests.known_repositories_all = {repo_fake("test1", "http://example.org/test1", true, content)}
	assert_nil(postprocess.get_repos())
	assert_table_equal(example_output, requests.known_repositories_all)
end

local multierror = utils.exception("multiple", "Multiple exceptions (1)")
local sub_err = utils.exception("unreachable", "Fake network is down")
sub_err.why = "missing"
sub_err.repo = "test1/http://example.org/test1/Packages"
multierror.errors = {sub_err}

function test_get_repos_broken_fatal()
	-- When we can't download the thing, it throws
	requests.known_repositories_all = {repo_fake("test1", "http://example.org/test1", false, utils.exception("unreachable", "Fake network is down"))}
	local ok, err = pcall(postprocess.get_repos)
	assert_false(ok)
	assert_table_equal(multierror, err)
end

function test_get_repos_broken_nonfatal()
	requests.known_repositories_all = {repo_fake("test1", "http://example.org/test1", false, utils.exception("unreachable", "Fake network is down"))}
	requests.known_repositories_all[1].ignore = {"missing"}
	assert_table_equal(multierror, postprocess.get_repos())
	assert_table_equal({
		{
			content = {
				[""] = sub_err
			},
			ignore = {"missing"},
			name = "test1",
			repo_uri = "http://example.org/test1",
			tp = "parsed-repository"
		}
	}, requests.known_repositories_all)
end

function test_pkg_merge()
	requests.known_repositories_all = {
		{
			content = {
				[""] = {
					tp = 'pkg-list',
					list = {
						xyz = {Package = "xyz"},
						abc = {Package = "abc"}
					}
				}
			}
		},
		{
			content = {
				a = {
					tp = 'pkg-list',
					list = {
						abc = {Package = "abc"}
					}
				},
				b = {
					tp = 'pkg-list',
					list = {
						another = {Package = "another"}
					}
				},
				c = utils.exception("Just an exception", "Just an exception")
			}
		}
	}
	requests.known_packages = {
		{
			tp = 'package',
			order_after = "abc",
			name = 'xyz',
			reboot = 'finished',
			deps = "abc"
		},
		{
			tp = 'package',
			name = 'xyz',
			deps = {"another", "xyz"}
		},
		{
			tp = 'package',
			name = 'virt',
			virtual = true,
			deps = {"xyz", "abc"}
		}
	}
	postprocess.pkg_aggregate()
	-- Build the expected data structure
	local exp = {
		abc = {
			candidates = {{Package = "abc"}, {Package = "abc"}},
			modifier = {name = "abc"}
		},
		another = {
			candidates = {{Package = "another"}},
			modifier = {name = "another"}
		},
		virt = {
			candidates = {{tp = "package", name = "virt", deps = {"xyz", "abc"}, virtual = true}},
			modifier = {name = "virt"},
			virtual = true
		},
		xyz = {
			candidates = {{Package = "xyz"}},
			modifier = {
				name = "xyz",
				order_after = {abc = true},
				deps = utils.arr2set({"abc", "another", "xyz"}),
				reboot = "finished"
			}
		}
	}
	-- Fill in default values for the ones that are not mentioned above
	local modifier_def = {
		tp = "package",
		abi_change = {},
		deps = {},
		order_after = {},
		order_before = {},
		post_install = {},
		post_remove = {},
		pre_install = {},
		pre_remove = {},
		reboot = false
	}
	for _, pkg in pairs(exp) do
		for name, def in pairs(modifier_def) do
			if pkg.modifier[name] == nil then
				pkg.modifier[name] = def
			end
		end
	end
	assert_table_equal(exp, postprocess.available_packages)
	assert_table_equal(utils.private(postprocess.available_packages.virt.candidates[1]).group, exp.virt)
end

function teardown()
	requests.known_repositories_all = {}
	requests.known_packages = {}
	postprocess.available_packages = {}
end