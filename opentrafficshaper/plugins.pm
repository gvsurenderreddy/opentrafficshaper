# OpenTrafficShaper Plugin Handler
# Copyright (C) 2007-2015, AllWorldIT
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.



package opentrafficshaper::plugins;

use strict;
use warnings;

use opentrafficshaper::logger;

# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
	isPluginLoaded
);
@EXPORT_OK = qw(
	plugin_register
);

# Our own copy of the globals
my $globals;



# Check if a plugin is loaded
sub isPluginLoaded
{
	my $pluginName = shift;


	return defined($globals->{'plugins'}->{$pluginName});
}



# Function to register a plugin
sub plugin_register
{
	my ($plugin,$systemPlugin) = @_;
	# Setup our environment
	my $logger = $globals->{'logger'};


	# Package components
	my @components = split(/\//,$plugin);
	my $packageName = join("::",@components);
	my $pluginName = pop(@components);


	# System plugins are in the top dir
	my $package;
	if ($systemPlugin) {
		$package = sprintf("opentrafficshaper::plugins::%s",$packageName);
	} else {
		$package = sprintf("opentrafficshaper::plugins::%s::%s",$packageName,$pluginName);
	}

	# Core configuration manager
	my $res = eval("
		use $package;
		_plugin_register(\$plugin,\$opentrafficshaper::plugins::${packageName}::pluginInfo);
	");
	if ($@ || (defined($res) && $res != 0)) {
		if ($@ || (defined($res) && $res != 0)) {
			# Check if the error is critical or not
			if ($systemPlugin) {
				$logger->log(LOG_ERR,"[PLUGINS] Error loading plugin '%s', things WILL BREAK! (%s)",$pluginName,$@);
				exit;
			} else {
				$logger->log(LOG_WARN,"[PLUGINS] Error loading plugin '%s' (%s)",$pluginName,$@);
				exit;
			}
		} else {
			$logger->log(LOG_DEBUG,"[PLUGINS] Plugin '%s' loaded.",$pluginName);
		}
	}
}



# Setup our main config ref
sub init
{
	my $globalsref = shift;

	$globals = $globalsref;
}


#
# Internal functions
#


# Register plugin info
sub _plugin_register {
	my ($pluginName,$pluginInfo) = @_;
	# Setup our environment
	my $logger = $globals->{'logger'};


	# If no info, return
	if (!defined($pluginInfo)) {
		$logger->log(LOG_WARN,"[MAIN] Plugin info not found for plugin => %s",$pluginName);
		return -1;
	}

	# Check Requires
	if (defined($pluginInfo->{'Requires'})) {
		# Loop with plugin requires
		foreach my $require (@{$pluginInfo->{'Requires'}}) {
			# Check if plugin is loaded
			my $found = isPluginLoaded($require);
			# If still not found ERR out
			if (!$found) {
				$logger->log(LOG_ERR,"[MAIN] Dependency '%s' for plugin '%s' NOT MET. Make sure its loaded before '%s'",
						$require,
						$pluginName,
						$pluginName
				);
				last;
			}
		}
	}

	my $res = 1;
	# If we should, init the module
	if (defined($pluginInfo->{'Init'})) {
		if (my $res = $pluginInfo->{'Init'}($globals)) {
			# Set real module name & save
			$pluginInfo->{'Plugin'} = $pluginName;
			$globals->{'plugins'}->{$pluginName} = $pluginInfo;
		} else {
			$logger->log(LOG_ERR,"[MAIN] Intialization of plugin failed => %s",$pluginName);
		}
	}

	return 0;
}



1;
# vim: ts=4
