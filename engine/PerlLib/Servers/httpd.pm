#!/usr/bin/perl

=head1 NAME

 Servers::httpd - i-MSCP Httpd Server implementation

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
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# @category    i-MSCP
# @copyright   2010-2014 by i-MSCP | http://i-mscp.net
# @author      Laurent Declercq <l.declercq@nuxwin.com>
# @link        http://i-mscp.net i-MSCP Home Site
# @license     http://www.gnu.org/licenses/gpl-2.0.html GPL v2

package Servers::httpd;

use strict;
use warnings;

use iMSCP::Debug;

=head1 DESCRIPTION

 i-MSCP Httpd server implementation.

=head1 PUBLIC METHODS

=over 4

=item factory([ $sName = $main::imscpConfig{'HTTPD_SERVER'} || 'no' ])

 Create and return Httpd server instance

 Param string $sName OPTIONAL Name of Httpd server implementation to instantiate
 Return Httpd server instance

=cut

sub factory
{
	my ($self, $sName) = @_;

	$sName ||= $main::imscpConfig{'HTTPD_SERVER'} || 'no';

	my $package = ($sName eq 'no') ? 'Servers::noserver' : "Servers::httpd::$sName";

	eval "require $package";

	fatal($@) if $@;

	$package->getInstance();
}

END
{
	unless($main::execmode && $main::execmode eq 'setup') {
		my $httpd = __PACKAGE__->factory();
		my $rs = 0;

		if($httpd->{'start'}) {
			$rs = $httpd->start();
		} elsif($httpd->{'restart'}) {
			$rs = $httpd->restart();
		}

		$? ||= $rs;
	}
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
