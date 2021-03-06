#!/usr/bin/perl

=head1 NAME

 iMSCP::Service - Package providing a set of functions for service management

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2014 by internet Multi Server Control Panel
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# @category    i-MSCP
# @copyright   2010-2014 by i-MSCP | http://i-mscp.net
# @author      Laurent Declercq <l.declercq@nuxwin.com>
# @link        http://i-mscp.net i-MSCP Home Site
# @license     http://www.gnu.org/licenses/gpl-2.0.html GPL v2

package iMSCP::Service;

use strict;
use warnings;

use iMSCP::Debug;
use iMSCP::Execute;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 Package providing a set of functions for service management.

=head1 PUBLIC METHODS

=over 4

=item start($serviceName [, $pattern = $serviceName ])

 Start the given service

 Param string $serviceName Service name
 Param string $pattern OPTIONAL Pattern as expected by the pgrep/pkill commands or 'retval' (default to service name)
 Return int 0 on succcess, other on failure

=cut

sub start
{
	my ($self, $serviceName, $pattern) = @_;

	$pattern ||= $serviceName;

	my $ret = $self->_runCommand("$self->{'service_provider'} $serviceName start");

	unless($pattern eq 'retval') {
		my $loopCount = 0;

		do {
			return 0 unless $self->status($serviceName, $pattern);
			sleep 1;
			$loopCount++;
		} while ($loopCount < 5);

		$self->status($serviceName, $pattern);
	} else {
		$ret;
	}
}

=item stop($serviceName [, $pattern = $serviceName ])

 Stop the given service

 Param string $serviceName Service name
 Param string $pattern OPTIONAL Pattern as expected by the pgrep/pkill commands or 'retval' (default to service name)
 Return int 0 on succcess, other on failure

=cut

sub stop
{
	my ($self, $serviceName, $pattern) = @_;

	$pattern ||= $serviceName;

	my $ret = $self->_runCommand("$self->{'service_provider'} $serviceName stop");

	unless($pattern eq 'retval') {
		my $loopCount = 0;

		do {
			return 0 if $self->status($serviceName, $pattern);
			sleep 1;
			$loopCount++;
		} while ($loopCount < 5);

		# Try by sending TERM signal (soft way)
		$self->_runCommand("$main::imscpConfig{'CMD_PKILL'} -TERM $pattern");

		sleep 3;

		return 0 if $self->status($serviceName, $pattern);

		# Try by sending KILL signal (hard way)
		$self->_runCommand("$main::imscpConfig{'CMD_PKILL'} -KILL $pattern");

		sleep 2;

		! $self->status($serviceName, $pattern);
	} else {
		$ret;
	}
}

=item restart($serviceName [, $pattern = $serviceName ])

 Restart the given service

 Param string $serviceName Service name
 Param string $pattern OPTIONAL Pattern as expected by the pgrep/pkill commands or 'retval' (default to service name)
 Return int 0 on succcess, other on failure

=cut

sub restart
{
	my ($self, $serviceName, $pattern) = @_;

	$pattern ||= $serviceName;

	unless($pattern eq 'retval') {
		if($self->status($pattern)) { # In case the service is not running, we start it
			$self->_runCommand("$self->{'service_provider'} $serviceName start");
		} else {
			$self->_runCommand("$self->{'service_provider'} $serviceName restart");
		}

		my $loopCount = 0;

		do {
			return 0 unless $self->status($serviceName, $pattern);
			sleep 1;
			$loopCount++;
		} while ($loopCount < 5);

		$self->status($serviceName, $pattern);
	} else {
		$self->_runCommand("$self->{'service_provider'} $serviceName restart");
	}
}

=item reload($serviceName [, $pattern = $serviceName ])

 Reload the given service

 Param string $serviceName Service name
 Param string $pattern OPTIONAL Pattern as expected by the pgrep/pkill commands or 'retval' (default to service name)
 Return int 0 on succcess, other on failure

=cut

sub reload
{
	my ($self, $serviceName, $pattern) = @_;

	$pattern ||= $serviceName;

	unless($pattern eq 'retval') {
		if($self->status($pattern)) { # In case the service is not running, we start it
			$self->_runCommand("$self->{'service_provider'} $serviceName start");
		} else {
			$self->_runCommand("$self->{'service_provider'} $serviceName reload");
		}

		my $loopCount = 0;

		do {
			return 0 unless $self->status($serviceName, $pattern);
			sleep 1;
			$loopCount++;
		} while ($loopCount < 5);

		$self->status($serviceName, $pattern);
	} else {
		$self->_runCommand("$self->{'service_provider'} $serviceName reload");
	}
}

=item status($serviceName [, $pattern = $serviceName ])

 Get status of the given service

 Param string $serviceName Service name
 Param string $pattern OPTIONAL Pattern as expected by the pgrep/pkill commands or 'retval' (default to service name)
 Return int 0 if the service is running, 1 if the service is not running

=cut

sub status
{
	my ($self, $serviceName, $pattern) = @_;

	$pattern ||= $serviceName;

	unless($pattern eq 'retval') {
		$self->_runCommand("$self->{'service_status_provider'} $pattern");
	} else {
		$self->_runCommand("$self->{'service_provider'} $serviceName status");
	}
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return iMSCP::Service

=cut

sub _init
{
	my $self = $_[0];

	$self->{'service_provider'} = $main::imscpConfig{'SERVICE_MNGR'};
	$self->{'service_status_provider'} = $main::imscpConfig{'CMD_PGREP'};

	$self;
}

=item _runCommand($command)

 Run the given command

 Return int 0 on success, other on failure

=cut

sub _runCommand
{
	my ($self, $command) = @_;

	my ($stdout, $stderr);
	my $rs = execute($command, \$stdout, \$stderr);
	debug($stderr) if $stderr;

	$rs;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
