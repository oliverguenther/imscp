#!/usr/bin/perl

=head1 NAME

Package::FrontEnd::Installer - i-MSCP FrontEnd package installer

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

package Package::FrontEnd::Installer;

use strict;
use warnings;

no if $] >= 5.017011, warnings => 'experimental::smartmatch';

use iMSCP::Debug;
use iMSCP::Config;
use iMSCP::Dir;
use iMSCP::Execute;
use iMSCP::File;
use iMSCP::Rights;
use iMSCP::TemplateParser;
use iMSCP::SystemUser;
use iMSCP::OpenSSL;
use Package::FrontEnd;
use Servers::named;
use Data::Validate::Domain qw/is_domain/;
use File::Basename;
use Net::LibIDN qw/idn_to_ascii idn_to_unicode/;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP FrontEnd package installer.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners(\%eventManager)

 Register setup event listeners

 Param iMSCP::EventManager \%eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
	my ($self, $eventManager) = @_;

	my $rs = $eventManager->register(
		'beforeSetupDialog', sub { push @{$_[0]}, sub { $self->askHostname(@_) }, sub { $self->askSsl(@_) }; 0; }
	);
}

=item askDomain(\%dialog)

 Show hostname dialog

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askHostname
{
	my ($self, $dialog) = @_;

	my $vhost = main::setupGetQuestion('BASE_SERVER_VHOST');
	my %options =  (domain_private_tld => qr /.*/);

	my ($rs, @labels) = (0, $vhost ? split(/\./, $vhost) : ());

	if(
		$main::reconfigure ~~ ['panel_hostname', 'hostnames', 'all', 'forced'] ||
		! (@labels >= 3 && is_domain($vhost, \%options))
	) {
		$vhost = 'admin.' . main::setupGetQuestion('SERVER_HOSTNAME') unless $vhost;

		my $msg = '';

		do {
			($rs, $vhost) = $dialog->inputbox(
				"\nPlease enter the domain name from which i-MSCP frontEnd must be reachable: $msg",
				idn_to_unicode($vhost, 'utf-8')
			);
			$msg = "\n\n\\Z1'$vhost' is not a fully-qualified domain name (FQDN).\\Zn\n\nPlease, try again:";
			$vhost = idn_to_ascii($vhost, 'utf-8');
			@labels = split(/\./, $vhost);
		} while($rs != 30 && ! (@labels >= 3 && is_domain($vhost, \%options)));
	}

	main::setupSetQuestion('BASE_SERVER_VHOST', $vhost) if $rs != 30;

	$rs;
}

=item askSsl(\%dialog)

 Show SSL dialog

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub askSsl
{
	my ($self, $dialog) = @_;

	my $domainName = main::setupGetQuestion('BASE_SERVER_VHOST');
	my $sslEnabled = main::setupGetQuestion('PANEL_SSL_ENABLED');
	my $selfSignedCertificate = main::setupGetQuestion('PANEL_SSL_SELFSIGNED_CERTIFICATE', 'no');
	my $privateKeyPath = main::setupGetQuestion('PANEL_SSL_PRIVATE_KEY_PATH', '/root/');
	my $passphrase = main::setupGetQuestion('PANEL_SSL_PRIVATE_KEY_PASSPHRASE');
	my $certificatPath = main::setupGetQuestion('PANEL_SSL_CERTIFICATE_PATH', "/root/");
	my $caBundlePath = main::setupGetQuestion('PANEL_SSL_CA_BUNDLE_PATH', '/root/');
	my $baseServerVhostPrefix = main::setupGetQuestion('BASE_SERVER_VHOST_PREFIX', 'http://');

	my $openSSL = iMSCP::OpenSSL->new('openssl_path' => $main::imscpConfig{'CMD_OPENSSL'});

	my $rs = 0;

	if($main::reconfigure ~~ ['panel_ssl', 'ssl', 'all', 'forced'] || not $sslEnabled ~~ ['yes', 'no']) {
		SSL_DIALOG:

		# Ask for SSL
		($rs, $sslEnabled) = $dialog->radiolist(
			"\nDo you want to activate SSL for the control panel?", ['no', 'yes'], ($sslEnabled eq 'yes') ? 'yes' : 'no'
		);

		if($sslEnabled eq 'yes' && $rs != 30) {
			# Ask for self-signed certificate
			($rs, $selfSignedCertificate) = $dialog->radiolist(
				"\nDo you have an SSL certificate for the $domainName domain?",
				['yes', 'no'],
				($selfSignedCertificate ~~ ['yes', 'no']) ? (($selfSignedCertificate eq 'yes') ? 'no' : 'yes') : 'no'
			);

			$selfSignedCertificate = ($selfSignedCertificate eq 'no') ? 'yes' : 'no';

			if($selfSignedCertificate eq 'no' && $rs != 30) {
				# Ask for private key
				my $msg = '';

				do {
					$dialog->msgbox("$msg\nPlease select your private key in next dialog.");

					# Ask for private key container path
					do {
						($rs, $privateKeyPath) = $dialog->fselect($privateKeyPath);
					} while($rs != 30 && ! ($privateKeyPath && -f $privateKeyPath));

					if($rs != 30) {
						($rs, $passphrase) = $dialog->passwordbox(
							"\nPlease enter the passphrase for your private key if any:", $passphrase
						);
					}

					if($rs != 30) {
						$openSSL->{'private_key_container_path'} = $privateKeyPath;
						$openSSL->{'private_key_passphrase'} = $passphrase;

						if($openSSL->validatePrivateKey()) {
							$msg = "\n\\Z1Wrong private key or passphrase. Please try again.\\Zn\n\n";
						} else {
							$msg = '';
						}
					}
				} while($rs != 30 && $msg);

				# Ask for the CA bundle
				if($rs != 30) {
					# The codes used for "Yes" and "No" match those used for "OK" and "Cancel", internally no
					# distinction is made... Therefore, we override the Cancel value temporarly
					$ENV{'DIALOG_CANCEL'} = 1;
					$rs = $dialog->yesno("\nDo you have any SSL intermediate certificate(s) (CA Bundle)?");

					unless($rs) { # backup feature still available through ESC
						do {
							($rs, $caBundlePath) = $dialog->fselect($caBundlePath);
						} while($rs != 30 && ! ($caBundlePath && -f $caBundlePath));

						$openSSL->{'ca_bundle_container_path'} = $caBundlePath if $rs != 30;
					} else {
						$openSSL->{'ca_bundle_container_path'} = '';
					}

					$ENV{'DIALOG_CANCEL'} = 30;
				}

				if($rs != 30) {
					$dialog->msgbox("\nPlease select your SSL certificate in next dialog.");

					$rs = 1;

					do {
						$dialog->msgbox("\n\\Z1Wrong SSL certificate. Please try again.\\Zn\n\n") unless $rs;

						do {
							($rs, $certificatPath) = $dialog->fselect($certificatPath);
						} while($rs != 30 && ! ($certificatPath && -f $certificatPath));

						$openSSL->{'certificate_container_path'} = $certificatPath if $rs != 30;
					} while($rs != 30 && $openSSL->validateCertificate());
				}
			}

			if($rs != 30 && $sslEnabled eq 'yes') {
				($rs, $baseServerVhostPrefix) = $dialog->radiolist(
					"\nPlease, choose the default HTTP access mode for the control panel",
					['https', 'http'],
					$baseServerVhostPrefix eq 'https://' ? 'https' : 'http'
				);

				$baseServerVhostPrefix .= '://'
			}
		}
	} elsif($sslEnabled eq 'yes' && ! iMSCP::Getopt->preseed) {
		$openSSL->{'private_key_container_path'} = "$main::imscpConfig{'CONF_DIR'}/$domainName.pem";
		$openSSL->{'ca_bundle_container_path'} = "$main::imscpConfig{'CONF_DIR'}/$domainName.pem";
		$openSSL->{'certificate_container_path'} = "$main::imscpConfig{'CONF_DIR'}/$domainName.pem";

		if($openSSL->validateCertificateChain()) {
			$dialog->msgbox("\nYour SSL certificate for the control panel is missing or invalid.");
			goto SSL_DIALOG;
		}

		# In case the certificate is valid, we do not generate it again
		main::setupSetQuestion('PANEL_SSL_SETUP', 'no');
	}

	if($rs != 30) {
		main::setupSetQuestion('PANEL_SSL_ENABLED', $sslEnabled);
		main::setupSetQuestion('PANEL_SSL_SELFSIGNED_CERTIFICATE', $selfSignedCertificate);
		main::setupSetQuestion('PANEL_SSL_PRIVATE_KEY_PATH', $privateKeyPath);
		main::setupSetQuestion('PANEL_SSL_PRIVATE_KEY_PASSPHRASE', $passphrase);
		main::setupSetQuestion('PANEL_SSL_CERTIFICATE_PATH', $certificatPath);
		main::setupSetQuestion('PANEL_SSL_CA_BUNDLE_PATH', $caBundlePath);
		main::setupSetQuestion('BASE_SERVER_VHOST_PREFIX', ($sslEnabled eq 'yes') ? $baseServerVhostPrefix : 'http://');
	}

	$rs;
}

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
	my $self = $_[0];

	my $rs ||= $self->_setupSsl();
	$rs ||= $self->_setHttpdVersion();
	$rs ||= $self->_addMasterWebUser();
	$rs ||= $self->_makeDirs();
	$rs ||= $self->_buildPhpConfig();
	$rs ||= $self->_buildHttpdConfig();
	$rs ||= $self->_buildInitDefaultFile();
	$rs ||= $self->_addDnsZone();
	$rs ||= $self->_saveConfig();

	$rs;
}

=item setGuiPermissions()

 Set gui permissions

 Return int 0 on success, other on failure

=cut

sub setGuiPermissions
{
	my $self = $_[0];

	my $panelUName = $main::imscpConfig{'SYSTEM_USER_PREFIX'}.$main::imscpConfig{'SYSTEM_USER_MIN_UID'};
	my $panelGName = $main::imscpConfig{'SYSTEM_USER_PREFIX'}.$main::imscpConfig{'SYSTEM_USER_MIN_UID'};
	my $guiRootDir = $main::imscpConfig{'GUI_ROOT_DIR'};

	my $rs = setRights(
		$guiRootDir,
		{ 'user' => $panelUName, 'group' => $panelGName, 'dirmode' => '0550', 'filemode' => '0440', 'recursive' => 1 }
	);
	return $rs if $rs;

	$rs = setRights(
		"$guiRootDir/themes",
		{ 'user' => $panelUName, 'group' => $panelGName, 'dirmode' => '0550', 'filemode' => '0440', 'recursive' => 1 }
	);
	return $rs if $rs;

	$rs = setRights(
		"$guiRootDir/data",
		{ 'user' => $panelUName, 'group' => $panelGName, 'dirmode' => '0700', 'filemode' => '0600', 'recursive' => 1 }
	);
	return $rs if $rs;

	$rs = setRights(
		"$guiRootDir/data/persistent",
		{ 'user' => $panelUName, 'group' => $panelGName, 'dirmode' => '0750', 'filemode' => '0640', 'recursive' => 1 }
	);
	return $rs if $rs;

	$rs = setRights("$guiRootDir/data", { 'user' => $panelUName, 'group' => $panelGName, 'mode' => '0550' });
	return $rs if $rs;

	$rs = setRights(
		"$guiRootDir/i18n",
		{ 'user' => $panelUName, 'group' => $panelGName, 'dirmode' => '0700', 'filemode' => '0600', 'recursive' => 1 }
	);
	return $rs if $rs;

	$rs = setRights(
		"$guiRootDir/plugins",
		{ 'user' => $panelUName, 'group' => $panelGName, 'dirmode' => '0750', 'filemode' => '0640', 'recursive' => 1 }
	);

	$rs;
}

=item setEnginePermissions()

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
	my $self = $_[0];

	my $panelUName = $main::imscpConfig{'SYSTEM_USER_PREFIX'} . $main::imscpConfig{'SYSTEM_USER_MIN_UID'};
	my $panelGName = $main::imscpConfig{'SYSTEM_USER_PREFIX'} . $main::imscpConfig{'SYSTEM_USER_MIN_UID'};
	my $rootUName = $main::imscpConfig{'ROOT_USER'};
	my $rootGName = $main::imscpConfig{'ROOT_GROUP'};
	my $httpdUser = $self->{'config'}->{'HTTPD_USER'};
	my $httpdGroup = $self->{'config'}->{'HTTPD_GROUP'};

	my $rs = setRights(
		$self->{'config'}->{'HTTPD_CONF_DIR'},
		{ 'user' => $rootUName, 'group' => $rootGName, 'dirmode' => '0755', 'filemode' => '0644', 'recursive' => 1 }
	);
	return $rs if $rs;

	$rs = setRights(
		$self->{'config'}->{'HTTPD_LOG_DIR'},
		{ 'user' => $rootUName, 'group' => $rootGName, 'dirmode' => '0755', 'filemode' => '0640', 'recursive' => 1 }
	);
	return $rs if $rs;

	$rs = setRights(
		"$self->{'config'}->{'PHP_STARTER_DIR'}/master",
		{ 'user' => $panelUName, 'group' => $panelGName, 'dirmode' => '0550', 'filemode' => '0640', 'recursive' => 1 }
	);
	return $rs if $rs;

	$rs = setRights(
		"$self->{'config'}->{'PHP_STARTER_DIR'}/master/php5-fcgi-starter",
		{ 'user' => $panelUName, 'group' => $panelGName, 'mode' => '550' }
	);
	return $rs if $rs;

	$rs = setRights(
		"$self->{'config'}->{'PHP_STARTER_DIR'}/master/php5-fcgi-starter",
		{ 'user' => $panelUName, 'group' => $panelGName, 'mode' => '550' }
	);

	# Temporary directories as provided by nginx package (from Debian Team)
	if(-d "$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_DEBIAN'}") {
		$rs = setRights(
			$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_DEBIAN'}, { 'user' => $rootUName, 'group' => $rootGName }
		);

		for('body', 'fastcgi', 'proxy', 'scgi', 'uwsgi') {
			if(-d "$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_DEBIAN'}/$_") {
				$rs = setRights(
					"$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_DEBIAN'}/$_",
					{
						'user' => $httpdUser,
						'group' => $httpdGroup,
						'dirnmode' => '0700',
						'filemode' => '0640',
						'recursive' => 1
					}
				);
				return $rs if $rs;

				$rs = setRights(
					"$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_DEBIAN'}/$_",
					{ 'user' => $httpdUser, 'group' => $rootGName, 'mode' => '0700' }
				);
				return $rs if $rs;
			}
		}
	}

	# Temporary directories as provided by nginx package (from nginx Team)
	if(-d "$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_NGINX'}") {
		$rs = setRights(
			$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_NGINX'}, { 'user' => $rootUName, 'group' => $rootGName }
		);

		for('client_temp', 'fastcgi_temp', 'proxy_temp', 'scgi_temp', 'uwsgi_temp') {
			if(-d "$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_NGINX'}/$_") {
				$rs = setRights(
					"$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_NGINX'}/$_",
					{
						'user' => $httpdUser,
						'group' => $httpdGroup,
						'dirnmode' => '0700',
						'filemode' => '0640',
						'recursive' => 1
					}
				);
				return $rs if $rs;

				$rs = setRights(
					"$self->{'config'}->{'HTTPD_TMP_ROOT_DIR_NGINX'}/$_",
					{ 'user' => $httpdUser, 'group' => $rootGName, 'mode' => '0700' }
				);
				return $rs if $rs;
			}
		}
	}

	0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Package::FrontEnd::Installer

=cut

sub _init
{
	my $self = $_[0];

	$self->{'frontend'} = Package::FrontEnd->getInstance();
	$self->{'eventManager'} = $self->{'frontend'}->{'eventManager'};

	$self->{'cfgDir'} = $self->{'frontend'}->{'cfgDir'};
	$self->{'bkpDir'} = "$self->{'cfgDir'}/backup";
	$self->{'wrkDir'} = "$self->{'cfgDir'}/working";

	$self->{'config'} = $self->{'frontend'}->{'config'};

	my $oldConf = "$self->{'cfgDir'}/nginx.old.data";

	if(-f $oldConf) {
		tie %{$self->{'oldConfig'}}, 'iMSCP::Config', 'fileName' => $oldConf, 'noerrors' => 1;

		for(keys %{$self->{'oldConfig'}}) {
			if(exists $self->{'config'}->{$_}) {
				$self->{'config'}->{$_} = $self->{'oldConfig'}->{$_};
			}
		}
	}

	$self;
}

=item _setupSsl()

 Setup SSL

 Return int 0 on success, other on failure

=cut

sub _setupSsl
{
	my $domainName = main::setupGetQuestion('BASE_SERVER_VHOST');
	my $selfSignedCertificate = (main::setupGetQuestion('PANEL_SSL_SELFSIGNED_CERTIFICATE') eq 'yes') ? 1 : 0;
	my $privateKeyPath = main::setupGetQuestion('PANEL_SSL_PRIVATE_KEY_PATH');
	my $passphrase = main::setupGetQuestion('PANEL_SSL_PRIVATE_KEY_PASSPHRASE');
	my $certificatePath = main::setupGetQuestion('PANEL_SSL_CERTIFICATE_PATH');
	my $caBundlePath = main::setupGetQuestion('PANEL_SSL_CA_BUNDLE_PATH');
	my $baseServerVhostPrefix = main::setupGetQuestion('BASE_SERVER_VHOST_PREFIX');
	my $sslEnabled = main::setupGetQuestion('PANEL_SSL_ENABLED');

	if($sslEnabled eq 'yes' && main::setupGetQuestion('PANEL_SSL_SETUP', 'yes') eq 'yes') {
		if($selfSignedCertificate) {
			my $rs = iMSCP::OpenSSL->new(
				'openssl_path' => $main::imscpConfig{'CMD_OPENSSL'},
				'certificate_chains_storage_dir' =>  $main::imscpConfig{'CONF_DIR'},
				'certificate_chain_name' => $domainName
			)->createSelfSignedCertificate($domainName);
			return $rs if $rs;
		} else {
			my $rs = iMSCP::OpenSSL->new(
				'openssl_path' => $main::imscpConfig{'CMD_OPENSSL'},
				'certificate_chains_storage_dir' =>  $main::imscpConfig{'CONF_DIR'},
				'certificate_chain_name' => $domainName,
				'private_key_container_path' => $privateKeyPath,
				'private_key_passphrase' => $passphrase,
				'certificate_container_path' => $certificatePath,
				'ca_bundle_container_path' => $caBundlePath
			)->createCertificateChain();
			return $rs if $rs;
		}
	}

	0;
}

=item _setHttpdVersion()

 Set httpd version

 Return int 0 on success, other on failure

=cut

sub _setHttpdVersion()
{
	my $self = $_[0];

	my ($stderr);
	my $rs = execute("$self->{'config'}->{'CMD_NGINX'} -v", undef, \$stderr);
	debug($stderr) if $stderr;
	error($stderr) if $stderr && $rs;
	error('Unable to find Nginx version') if $rs;
	return $rs if $rs;

	if($stderr =~ m%nginx/([\d.]+)%) {
		$self->{'config'}->{'HTTPD_VERSION'} = $1;
		debug("Nginx version set to: $1");
	} else {
		error("Unable to parse Nginx version from Nginx version string: $stderr");
		return 1;
	}

	0;
}

=item _addMasterWebUser()

 Add master Web user

 Return int 0 on success, other on failure

=cut

sub _addMasterWebUser
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeFrontEndAddUser');
	return $rs if $rs;

	my $userName =
	my $groupName = $main::imscpConfig{'SYSTEM_USER_PREFIX'} . $main::imscpConfig{'SYSTEM_USER_MIN_UID'};

	my ($db, $errStr) = main::setupGetSqlConnect($main::imscpConfig{'DATABASE_NAME'});
	unless($db) {
		error("Unable to connect to SQL server: $errStr");
		return 1;
	}

	my $rdata = $db->doQuery(
		'admin_sys_uid',
		'
			SELECT
				admin_sys_name, admin_sys_uid, admin_sys_gname
			FROM
				admin
			WHERE
				admin_type = ?
			AND
				created_by = ?
			LIMIT
				1
		',
		'admin',
		'0'
	);

	unless(ref $rdata eq 'HASH') {
		error($rdata);
		return 1;
	} elsif(! %{$rdata}) {
		error('Unable to find admin user in database');
		return 1;
	}

	my $adminSysName = $rdata->{(%{$rdata})[0]}->{'admin_sys_name'};
	my $adminSysUid = $rdata->{(%{$rdata})[0]}->{'admin_sys_uid'};
	my $adminSysGname = $rdata->{(%{$rdata})[0]}->{'admin_sys_gname'};

	my ($oldUserName, undef, $userUid, $userGid) = getpwuid($adminSysUid);

	if(! $oldUserName || $userUid == 0) {
		# Creating i-MSCP Master Web user
		$rs = iMSCP::SystemUser->new(
			'username' => $userName,
			'comment' => 'i-MSCP Master Web User',
			'home' => $main::imscpConfig{'GUI_ROOT_DIR'},
			'skipCreateHome' => 1
		)->addSystemUser();
		return $rs if $rs;

		$userUid = getpwnam($userName);
		$userGid = getgrnam($groupName);
	} else {
		# Modify existents i-MSCP Master Web user
		my @cmd = (
			"$main::imscpConfig{'CMD_PKILL'} -KILL -u", escapeShell($oldUserName), ';',
			"$main::imscpConfig{'CMD_USERMOD'}",
			'-c', escapeShell('i-MSCP Master Web User'), # New comment
			'-d', escapeShell($main::imscpConfig{'GUI_ROOT_DIR'}), # New homedir
			'-l', escapeShell($userName), # New login
			'-m', # Move current homedir content to new homedir
			escapeShell($adminSysName) # Old username
		);
		my($stdout, $stderr);
		$rs = execute("@cmd", \$stdout, \$stderr);
		debug($stdout) if $stdout;
		debug($stderr) if $stderr && $rs;
		return $rs if $rs;

		# Modify existents i-MSCP Master Web group
		@cmd = (
			$main::imscpConfig{'CMD_GROUPMOD'},
			'-n', escapeShell($groupName), # New group name
			escapeShell($adminSysGname) # Current group name
		);
		debug($stdout) if $stdout;
		debug($stderr) if $stderr && $rs;
		$rs = execute("@cmd", \$stdout, \$stderr);
		return $rs if $rs;
	}

	# Update the admin.admin_sys_name, admin.admin_sys_uid, admin.admin_sys_gname and admin.admin_sys_gid columns
	$rdata = $db->doQuery(
		'dummy',
		'
			UPDATE
				admin
			SET
				admin_sys_name = ?, admin_sys_uid = ?, admin_sys_gname = ?, admin_sys_gid = ?
			WHERE
				admin_type = ?
		',
		$userName,
		$userUid,
		$groupName,
		$userGid,
		'admin'
	);
	unless(ref $rdata eq 'HASH') {
		error($rdata);
		return 1;
	}

	# Add the i-MSCP Master Web user into the i-MSCP group
	$rs = iMSCP::SystemUser->new('username' => $userName)->addToGroup($main::imscpConfig{'IMSCP_GROUP'});
	return $rs if $rs;

	# Add the httpd user into i-MSCP Master Web group
	$rs = iMSCP::SystemUser->new('username' => $self->{'config'}->{'HTTPD_USER'})->addToGroup($groupName);
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdAddUser');
}

=item _makeDirs()

 Create directories

 Return int 0 on success, other on failure

=cut

sub _makeDirs
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeFrontEndMakeDirs');
	return $rs if $rs;

	my $panelUName = $main::imscpConfig{'SYSTEM_USER_PREFIX'} . $main::imscpConfig{'SYSTEM_USER_MIN_UID'};
	my $panelGName = $main::imscpConfig{'SYSTEM_USER_PREFIX'} . $main::imscpConfig{'SYSTEM_USER_MIN_UID'};
	my $rootUName = $main::imscpConfig{'ROOT_USER'};
	my $rootGName = $main::imscpConfig{'ROOT_GROUP'};
	my $phpdir = $self->{'config'}->{'PHP_STARTER_DIR'};

	for (
		[$self->{'config'}->{'HTTPD_CONF_DIR'}, $rootUName, $rootUName, 0755],
		[$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}, $rootUName, $rootUName, 0755],
		[$self->{'config'}->{'HTTPD_SITES_ENABLED_DIR'}, $rootUName, $rootUName, 0755],
		[$self->{'config'}->{'HTTPD_LOG_DIR'}, $rootUName, $rootUName, 0755],
		[$phpdir, $rootUName, $rootGName, 0555],
		["$phpdir/master", $panelUName, $panelGName, 0550],
		["$phpdir/master/php5", $panelUName, $panelGName, 0550]
	) {
		$rs = iMSCP::Dir->new('dirname' => $_->[0])->make({ 'user' => $_->[1], 'group' => $_->[2], 'mode' => $_->[3] });
		return $rs if $rs;
	}

	$self->{'eventManager'}->trigger('afterFrontEndMakeDirs');
}

=item _buildPhpConfig()

 Build PHP configuration

 Return int 0 on success, other on failure

=cut

sub _buildPhpConfig
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeFrontEnddBuildPhpConfig');
	return $rs if $rs;

	my ($cfgTpl, $file);
	my $cfgDir = $self->{'cfgDir'};
	my $bkpDir = "$cfgDir/backup";
	my $wrkDir = "$cfgDir/working";

	my $timestamp = time;

	# Backup any current file
	for ('php5-fcgi-starter', 'php5/php.ini') {
		if(-f "$self->{'config'}->{'PHP_STARTER_DIR'}/master/$_") {
			my $fileName = basename($_);
			my $file = iMSCP::File->new('filename' => "$self->{'config'}->{'PHP_STARTER_DIR'}/master/$_");
			$rs = $file->copyFile("$bkpDir/$fileName.$timestamp");
			return $rs if $rs;
		}
	}

	# Build PHP FCGI starter script

	my $user = $main::imscpConfig{'SYSTEM_USER_PREFIX'} . $main::imscpConfig{'SYSTEM_USER_MIN_UID'};
	my $group = $main::imscpConfig{'SYSTEM_USER_PREFIX'} . $main::imscpConfig{'SYSTEM_USER_MIN_UID'};

	# Set template vars
	my $tplVars = {
		PHP_STARTER_DIR => $self->{'config'}->{'PHP_STARTER_DIR'},
		DOMAIN_NAME => 'master',
		PHP_FCGI_MAX_REQUESTS => $self->{'config'}->{'PHP_FCGI_MAX_REQUESTS'},
		PHP_FCGI_CHILDREN => $self->{'config'}->{'PHP_FCGI_CHILDREN'},
		WEB_DIR => $main::imscpConfig{'GUI_ROOT_DIR'},
		PANEL_USER => $user,
		PANEL_GROUP => $group,
		SPAWN_FCGI_BIN => $self->{'config'}->{'SPAWN_FCGI_BIN'},
		PHP_CGI_BIN => $self->{'config'}->{'PHP_CGI_BIN'}
	};

	$rs = $self->{'frontend'}->buildConfFile(
		"$cfgDir/parts/master/php5-fcgi-starter.tpl",
		$tplVars,
		{ 'destination' => "$wrkDir/master.php5-fcgi-starter", 'mode' => 0550, 'user' => $user, 'group' => $group }
	);
	return $rs if $rs;

	# Install file in production directory
	$rs = iMSCP::File->new('filename' => "$wrkDir/master.php5-fcgi-starter")->copyFile(
		"$self->{'config'}->{'PHP_STARTER_DIR'}/master/php5-fcgi-starter"
	);
	return $rs if $rs;

	# Build php.ini file

	# Set Set template vars
	$tplVars = {
		HOME_DIR => $main::imscpConfig{'GUI_ROOT_DIR'},
		WEB_DIR => $main::imscpConfig{'GUI_ROOT_DIR'},
		DOMAIN => $main::imscpConfig{'BASE_SERVER_VHOST'},
		CONF_DIR => $main::imscpConfig{'CONF_DIR'},
		PEAR_DIR => $main::imscpConfig{'PEAR_DIR'},
		RKHUNTER_LOG => $main::imscpConfig{'RKHUNTER_LOG'},
		CHKROOTKIT_LOG => $main::imscpConfig{'CHKROOTKIT_LOG'},
		OTHER_ROOTKIT_LOG => ($main::imscpConfig{'OTHER_ROOTKIT_LOG'} ne '')
			? ":$main::imscpConfig{'OTHER_ROOTKIT_LOG'}" : '',
		PHP_TIMEZONE => $main::imscpConfig{'PHP_TIMEZONE'},
	};

	# Build file using template from fcgi/parts/master/php5
	$rs = $self->{'frontend'}->buildConfFile(
		"$cfgDir/parts/master/php5/php.ini",
		$tplVars,
		{ 'destination' => "$wrkDir/master.php.ini", 'mode' => 0440, 'user' => $user, 'group' => $group }
	);
	return $rs if $rs;

	# Install new file in production directory
	$rs = iMSCP::File->new(
		'filename' => "$wrkDir/master.php.ini"
	)->copyFile(
		"$self->{'config'}->{'PHP_STARTER_DIR'}/master/php5/php.ini"
	);
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterFrontEndBuildPhpConfig');
}

=item _buildHttpdConfig()

 Build httpd configuration

 Return int 0 on success, other on failure

=cut

sub _buildHttpdConfig
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeFrontEndBuildHttpdConfig');
	return $rs if $rs;

	# Backup, build, store and install the nginx.conf file

	# Backup file
	if(-f "$self->{'wrkDir'}/nginx.conf") {
		$rs = iMSCP::File->new(
			'filename' => "$self->{'wrkDir'}/nginx.conf"
		)->copyFile("$self->{'bkpDir'}/nginx.conf." . time);
		return $rs if $rs;
	}

	my $nbCPUcores = $self->{'config'}->{'HTTPD_WORKER_PROCESSES'};

	if($nbCPUcores eq 'auto') {
		my ($stdout, $stderr);
		$rs = execute(
			"$main::imscpConfig{'CMD_GREP'} processor /proc/cpuinfo | $main::imscpConfig{'CMD_WC'} -l", \$stdout
		);
		debug($stdout) if $stdout;
		debug('Unable to detect number of CPU cores. nginx worker_processes value set to 2') if $rs;

		unless($rs) {
			chomp($stdout);
			$nbCPUcores = $stdout;
			$nbCPUcores = 4 if $nbCPUcores > 4; # Limit number of workers
		} else {
			$nbCPUcores = 2;
		}
	}

	# Build file
	$rs = $self->{'frontend'}->buildConfFile(
		"$self->{'cfgDir'}/nginx.conf",
		{
			'HTTPD_USER' => $self->{'config'}->{'HTTPD_USER'},
			'HTTPD_WORKER_PROCESSES' => $nbCPUcores,
			'HTTPD_WORKER_CONNECTIONS' => $self->{'config'}->{'HTTPD_WORKER_CONNECTIONS'},
			'HTTPD_RLIMIT_NOFILE' => $self->{'config'}->{'HTTPD_RLIMIT_NOFILE'},
			'HTTPD_LOG_DIR' => $self->{'config'}->{'HTTPD_LOG_DIR'},
			'HTTPD_PID_FILE' => $self->{'config'}->{'HTTPD_PID_FILE'},
			'HTTPD_CONF_DIR' => $self->{'config'}->{'HTTPD_CONF_DIR'},
			'HTTPD_LOG_DIR' => $self->{'config'}->{'HTTPD_LOG_DIR'},
			'HTTPD_SITES_ENABLED_DIR' => $self->{'config'}->{'HTTPD_SITES_ENABLED_DIR'}
		}
	);
	return $rs if $rs;

	# Install file
	my $file = iMSCP::File->new('filename' => "$self->{'wrkDir'}/nginx.conf");
	$rs = $file->copyFile("$self->{'config'}->{'HTTPD_CONF_DIR'}");

	# Backup, build, store and install the imscp_fastcgi.conf file

	# Backup file
	if(-f "$self->{'wrkDir'}/imscp_fastcgi.conf") {
		$rs = iMSCP::File->new(
			'filename' => "$self->{'wrkDir'}/imscp_fastcgi.conf"
		)->copyFile("$self->{'bkpDir'}/imscp_fastcgi.conf." . time);
		return $rs if $rs;
	}

	# Build file
	$rs = $self->{'frontend'}->buildConfFile("$self->{'cfgDir'}/imscp_fastcgi.conf");
	return $rs if $rs;

	# Install file
	$file = iMSCP::File->new('filename' => "$self->{'wrkDir'}/imscp_fastcgi.conf");
	$rs = $file->copyFile("$self->{'config'}->{'HTTPD_CONF_DIR'}");
	return $rs if $rs;

	# Backup, build, store and install imscp_php.conf file

	# Backup file
	if(-f "$self->{'wrkDir'}/imscp_php.conf") {
		$rs = iMSCP::File->new(
			'filename' => "$self->{'wrkDir'}/imscp_php.conf"
		)->copyFile("$self->{'bkpDir'}/imscp_php.conf." . time);
		return $rs if $rs;
	}

	# Build file
	$rs = $self->{'frontend'}->buildConfFile("$self->{'cfgDir'}/imscp_php.conf");
	return $rs if $rs;

	# Install file
	$file = iMSCP::File->new('filename' => "$self->{'wrkDir'}/imscp_php.conf");
	$rs = $file->copyFile("$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d");
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterFrontEndBuildHttpdConfig');

	$rs = $self->{'eventManager'}->trigger('beforeFrontEndBuildHttpdVhosts');
	return $rs if $rs;

	my $httpsPort = $main::imscpConfig{'BASE_SERVER_VHOST_HTTPS_PORT'};

	# Set needed data
	my $tplVars = {
		'BASE_SERVER_VHOST' => $main::imscpConfig{'BASE_SERVER_VHOST'},
		'BASE_SERVER_IP' => $main::imscpConfig{'BASE_SERVER_IP'},
		'BASE_SERVER_VHOST_HTTP_PORT' => $main::imscpConfig{'BASE_SERVER_VHOST_HTTP_PORT'},
		'BASE_SERVER_VHOST_HTTPS_PORT' => $httpsPort,
		'WEB_DIR' => $main::imscpConfig{'GUI_ROOT_DIR'},
		'CONF_DIR' => $main::imscpConfig{'CONF_DIR'}
	};

	# Build http vhost file

	# Force HTTPS if needed
	if($main::imscpConfig{'BASE_SERVER_VHOST_PREFIX'} eq 'https://') {
		$rs = $self->{'eventManager'}->register(
			'afterFrontEndBuildConf',
			sub {
				my ($cfgTpl, $tplName) = @_;

				if($tplName eq '00_master.conf') {
					$$cfgTpl = replaceBloc(
						"# SECTION custom BEGIN.\n",
						"# SECTION custom END.\n",

						"    # SECTION custom BEGIN.\n" .
						getBloc(
							"# SECTION custom BEGIN.\n",
							"# SECTION custom END.\n",
							$$cfgTpl
						) .
						"    rewrite .* https://\$host:$httpsPort\$request_uri redirect;\n" .
						"    # SECTION custom END.\n",
						$$cfgTpl
					);
				}

				0;
			}
		);
		return $rs if $rs;
	}

	# Build file
	$rs = $self->{'frontend'}->buildConfFile('00_master.conf', $tplVars);
	return $rs if $rs;

	# Install new file
	$rs = iMSCP::File->new(
		'filename' => "$self->{'wrkDir'}/00_master.conf"
	)->copyFile(
		"$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master.conf"
	);
	return $rs if $rs;

	$rs = $self->{'frontend'}->enableSites('00_master.conf');
	return $rs if $rs;

	# Build https vhost file if SSL is enabled, remove it otherwise

	if($main::imscpConfig{'PANEL_SSL_ENABLED'} eq 'yes') {
		# Build vhost
		$rs = $self->{'frontend'}->buildConfFile('00_master_ssl.conf', $tplVars);
		return $rs if $rs;

		# Install vhost in production directory
		iMSCP::File->new(
			'filename' => "$self->{'wrkDir'}/00_master_ssl.conf"
		)->copyFile(
			"$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master_ssl.conf"
		);
		return $rs if $rs;

		# Enable vhost
		$rs = $self->{'frontend'}->enableSites('00_master_ssl.conf');
		return $rs if $rs;
	} else {
		# Disable vhost if any
		$rs = $self->{'frontend'}->disableSites('00_master_ssl.conf');
		return $rs if $rs;

		# Remove vhost if any
		for(
			"$self->{'wrkDir'}/00_master_ssl.conf",
			"$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/00_master_ssl.conf"
		) {
			$rs = iMSCP::File->new('filename' => $_)->delFile() if -f $_;
			return $rs if $rs;
		}
	}

	# Disable default site if any (Nginx package as provided by Debian)
	$rs = $self->{'frontend'}->disableSites('default');
	return $rs if $rs;

	if(-f "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/default.conf") { # Nginx package as provided by Nginx Team
		$rs = iMSCP::File->new(
			'filename' => "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/default.conf"
		)->moveFile("$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/default.conf.disabled");
		return $rs if $rs;
	} else {
	}

	$self->{'eventManager'}->trigger('afterFrontEndBuildHttpdVhosts');
}

=item _buildInitDefaultFile()

 Build imscp_panel default init file

 Return int 0 on success, other on failure

=cut

sub _buildInitDefaultFile
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeFrontEndBuildInitDefaultFile');
	return $rs if $rs;

	my $imscpInitdConfDir = "$main::imscpConfig{'CONF_DIR'}/init.d";

	if(-f "$imscpInitdConfDir/imscp_panel.default") {
		# Backup, build, store and install the imscp_panel default file

		# Backup file
		if(-f "$imscpInitdConfDir/working/imscp_panel") {
			$rs = iMSCP::File->new(
				'filename' => "$imscpInitdConfDir/working/imscp_panel"
			)->copyFile("$imscpInitdConfDir/backup/imscp_panel." . time);
			return $rs if $rs;
		}

		# Build file
		$rs = $self->{'frontend'}->buildConfFile(
			"$imscpInitdConfDir/imscp_panel.default",
			{
				'MASTER_WEB_USER' => $main::imscpConfig{'SYSTEM_USER_PREFIX'} . $main::imscpConfig{'SYSTEM_USER_MIN_UID'}
			},
			{
				'destination' =>  "$imscpInitdConfDir/working/imscp_panel"
			}
		);
		return $rs if $rs;

		# Install file
		my $file = iMSCP::File->new('filename' => "$imscpInitdConfDir/working/imscp_panel");
		$rs = $file->copyFile('/etc/default');
		return $rs if $rs;
	}

	$self->{'eventManager'}->trigger('afterFrontEndBuildInitDefaultFile');
}

=item _addDnsZone()

 Add DNS zone

 Return int 0 on success, other on failure

=cut

sub _addDnsZone
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeNamedAddMasterZone');
	return $rs if $rs;

	$rs = Servers::named->factory()->addDmn(
		{
			'DOMAIN_NAME' => $main::imscpConfig{'BASE_SERVER_VHOST'},
			'DOMAIN_IP' => $main::imscpConfig{'BASE_SERVER_IP'},
			'MAIL_ENABLED' => 1
		}
	);
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterNamedAddMasterZone');
}

=item _saveConfig()

 Save configuration

 Return int 0 on success, other on failure

=cut

sub _saveConfig
{
	my $self = $_[0];

	my $rootUname = $main::imscpConfig{'ROOT_USER'};
	my $rootGname = $main::imscpConfig{'ROOT_GROUP'};

	my $file = iMSCP::File->new('filename' => "$self->{'cfgDir'}/nginx.data");

	my $rs = $file->owner($rootUname, $rootGname);
	return $rs if $rs;

	$rs = $file->mode(0640);
	return $rs if $rs;

	my $cfg = $file->get();
	unless(defined $cfg) {
		error("Unable to read $self->{'cfgDir'}/nginx.data");
		return 1;
	}

	$file = iMSCP::File->new('filename' => "$self->{'cfgDir'}/nginx.old.data");

	$rs = $file->set($cfg);
	return $rs if $rs;

	$rs = $file->save();
	return $rs if $rs;

	$file->owner($rootUname, $rootGname);
	return $rs if $rs;

	$file->mode(0640);
}

=back

=head1 AUTHORS

Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
