#!/usr/bin/perl

# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# **** End License ****

use strict;
use lib "/opt/vyatta/share/perl5";
use Vyatta::Config;

# handle "user"
my $uconfig = new Vyatta::Config;
$uconfig->setLevel("system login user");

my %users     = $uconfig->listNodeStatus();
my @user_keys = sort keys %users;

if (   ( scalar(@user_keys) <= 0 )
    || !( grep /^root$/, @user_keys )
    || ( $users{'root'} eq 'deleted' ) )
{

    # root is deleted
    print STDERR "User \"root\" cannot be deleted\n";
    exit 1;
}

# Exit codes form useradd.8 man page
my %reasons = (
    0  => 'success',
    1  => 'can´t update password file',
    2  => 'invalid command syntax',
    3  => 'invalid argument to option',
    4  => 'UID already in use (and no -o)',
    6  => 'specified group doesn´t exist',
    9  => 'username already in use',
    10 => 'can´t update group file',
    12 => 'can´t create home directory',
    13 => 'can´t create mail spool',
);

# Map of level to additional groups
my %level_map = (
    'admin'    => [ 'quaggavty', 'vyattacfg', 'sudo', 'adm', 'dip', 'disk'],
    'operator' => [ 'quaggavty', 'operator',  'adm', 'dip', ],
);

# Construct a map from existing users to group membership
# Use space seperated format
my %group_map;
while (my ($name, undef, undef, $members) = getgrent()) {
    foreach my $user (split / /,$members) {
	my $g = $group_map{$user};
	if ($g) {
	    my @l = split / /, $g;
	    push @l, $name;
	    $group_map{$user} = join(' ', sort @l);
	} else {
	    $group_map{$user} = $name;
	}

    }
}

# we have some users
for my $user (@user_keys) {
    if ( $users{$user} eq 'deleted' ) {
        system("sudo userdel -r '$user'") == 0
	    or die "userdel failed: $?\n"
    }
    elsif ( $users{$user} eq 'added' || $users{$user} eq 'changed' ) {
        $uconfig->setLevel("system login user $user");
        my $pwd  = $uconfig->returnValue('authentication encrypted-password');
	$pwd or die "Encrypted password not in configuration for $user";

        my $level  = $uconfig->returnValue('level');
	$level or die "Level not defined for $user";

	# map level to group membership
        my @groups = @{$level_map{$level}};
	# add any additional groups from configuration
        push( @groups, $uconfig->returnValues('group') );

        my $fname = $uconfig->returnValue('full-name');
        my $home = $uconfig->returnValue('home-directory');

        # Read existing settings
        my (undef, $opwd, $uid,  $gid, undef, $comment, 
	    undef, $dir, $shell, undef) = getpwnam($user);

        my $cmd;
	# not found in existing passwd, must be new
        if ( !defined $uid ) {
	    # make new user using vyatta shell
	    #  and make home directory (-m)
            #  and with default group of 100 (users)
            $cmd = 'useradd -s /bin/vbash -m -N';
        } else {
	    # If no part of password or group file changed
	    # then there is nothing to do here.
	    next if ( $opwd eq $pwd &&
		      (!$fname || $fname eq $comment) &&
		      (!$home  || $home eq $dir)  &&
		      join(' ',  sort @groups) eq $group_map{$user} );

            $cmd = "usermod";
        }

        $cmd .= " -p '$pwd'";
        $cmd .= " -c \"$fname\"" if ( defined $fname );
        $cmd .= " -d \"$home\"" if ( defined $home );
        $cmd .= ' -G ' . join( ',', @groups );
        system("sudo $cmd $user") == 0
	    or die "sudo $cmd $user failed: $?";
    }
}

## setup tacacs+ server info
# add tacacs to PAM file
sub add_tacacs {
    my $param_string = shift;
    my $pam = shift;

    my $cmd =
        'sudo sh -c "'
      . 'sed -i \'s/^\('
      . "$pam"
      . '\trequired\tpam_unix\.so.*\)$/'
      . "$pam"
      . '\tsufficient\tpam_tacplus.so\t'
      . "$param_string # Vyatta"
      . '\n\1/\' '
      . "/etc/pam.d/common-$pam\"";

    system($cmd);
    return 0 if ( $? >> 8 );
    return 1;
}

# remove tacacs from PAM files
sub remove_tacacs {
    my $cmd =
        'sudo sh -c "'
      . 'sed -i \'/\(.*pam_tacplus.*# Vyatta\)/ D\' '
      . '/etc/pam.d/common-auth '
      . '/etc/pam.d/common-account '
      . '/etc/pam.d/common-session "';

    system($cmd);
    return 0 if ($? >> 8);
    return 1;
}

# main tacacs
# There is a race confition in here betwen radius and tacacs currently.
# Also should probably add a chack to see if we ned to actually reconfig 
# PAM rather than jusy doing it each commit.
# Finally, service and protocol will need to be removed.  They are just 
# in there for troubleshootig purposes right now.
#
my $tconfig = new Vyatta::Config;
if ($tconfig->isDeleted("system login tacacs-plus")) { remove_tacacs; }
$tconfig->setLevel("system login tacacs-plus");
my @tacacs_params = $tconfig->listNodes();

if ( scalar(@tacacs_params) > 0 ) {
    remove_tacacs;
    my ($acctall, $debug, $firsthit, $noencrypt);
    if ( $tconfig->exists("acct-all") ) { $acctall = 1; }
    if ( $tconfig->exists("debug") ) { $debug = 1; }
    if ( $tconfig->exists("first-hit") ) { $firsthit = 1; }
    if ( $tconfig->exists("no-encrypt") ) { $noencrypt = 1; }
    my $protocol = $tconfig->returnValue("protocol");
    my $secret = $tconfig->returnValue("secret");
    my $server = $tconfig->returnValue("server");
    my $service = $tconfig->returnValue("service");

    if ( $server ne '' && $secret ne '') {
      my ($authstr, $accountstr, $sessionstr, $ip);
      my @servers = split /\s/, $server;

      ## 3 common options
      # encrypt this session
      if (! $noencrypt ) { $authstr = "encrypt "; }
      # single secret
      $authstr .= "secret=$secret ";
      # and debug
      if ($debug) { $authstr .= "debug "; }

      ## now they get specific
      $accountstr = $sessionstr = $authstr;

      # can be multiple servers for auth and session
      foreach my $ip (@servers) {
        $authstr    .= "server=$ip ";
        $sessionstr .= "server=$ip ";
      }

      # first hit for auth
      if ($firsthit) { $authstr .= "firsthit "; }

      # acctall for session
      if ($acctall) { $sessionstr .= "acctall "; }

      # service and protocol for account and session
      if ($service)  { $accountstr .= "service=$service "; $sessionstr .= "service=$service "; }
      if ($protocol) { $accountstr .= "protocol=$protocol "; $sessionstr .= "protocol=$protocol "; }

      add_tacacs("$authstr", "auth");
      add_tacacs("$accountstr", "account");
      add_tacacs("$sessionstr", "session");
    }
    else { exit 1; }
}
## end tacacs

my $PAM_RAD_CFG   = '/etc/pam_radius_auth.conf';
my $PAM_RAD_BEGIN = '# BEGIN Vyatta Radius servers';
my $PAM_RAD_END   = '# END Vyatta Radius servers';

sub is_pam_radius_present {
    open( my $auth , '<' , '/etc/pam.d/common-auth' ) 
	or die "Cannot open /etc/pam.d/common-auth\n";

    my $present;
    while (<$auth>) {
        if (/\ssufficient\spam_radius_auth\.so$/) {
            $present = 1;
            last;
        }
    }
    close $auth;
    return $present;
}

sub remove_pam_radius {
    return 1 if ( !is_pam_radius_present() );
    my $cmd =
        'sudo sh -c "'
      . 'sed -i \'/\tsufficient\tpam_radius_auth\.so$/d;'
      . '/\tpam_unix\.so /{s/ use_first_pass$//}\' '
      . '/etc/pam.d/common-auth && '
      . 'sed -i \'/\tsufficient\tpam_radius_auth\.so$/d\' '
      . '/etc/pam.d/common-account"';
    system($cmd);
    return 0 if ( $? >> 8 );
    return 1;
}

sub add_pam_radius {
    return 1 if ( is_pam_radius_present() );
    my $cmd =
        'sudo sh -c "'
      . 'sed -i \'s/^\(auth\trequired\tpam_unix\.so.*\)$'
      . '/auth\tsufficient\tpam_radius_auth.so\n\1 use_first_pass/\' '
      . '/etc/pam.d/common-auth && '
      . 'sed -i \'s/^\(account\trequired\tpam_unix\.so.*\)$'
      . '/account\tsufficient\tpam_radius_auth.so\n\1/\' '
      . '/etc/pam.d/common-account"';
    system($cmd);
    return 0 if ( $? >> 8 );
    return 1;
}

sub remove_radius_servers {
    system( "sudo sed -i '/^$PAM_RAD_BEGIN\$/,/^$PAM_RAD_END\$/{d}' "
          . "$PAM_RAD_CFG" );
    return 0 if ( $? >> 8 );
    return 1;
}

sub add_radius_servers {
    my $str = shift;
    system( "sudo sh -c \""
          . "echo '$PAM_RAD_BEGIN\n$str$PAM_RAD_END\n' >> $PAM_RAD_CFG\"" );
    return 0 if ( $? >> 8 );
    return 1;
}

# handle "radius-server"
my $rconfig = new Vyatta::Config;
$rconfig->setLevel("system login radius-server");
my %servers     = $rconfig->listNodeStatus();
my @server_keys = sort keys %servers;
if ( scalar(@server_keys) <= 0 ) {

    # all radius servers deleted
    exit 1 if ( !remove_pam_radius() );
    exit 0;
}

# we have some servers
my $all_deleted = 1;
my $server_str  = '';
remove_radius_servers();
for my $server (@server_keys) {
    if ( $servers{$server} ne 'deleted' ) {
        $all_deleted = 0;
        my $port    = $rconfig->returnValue("$server port");
        my $secret  = $rconfig->returnValue("$server secret");
        my $timeout = $rconfig->returnValue("$server timeout");
        $server_str .= "$server:$port\t$secret\t$timeout\n";
    }
}

if ($all_deleted) {

    # all radius servers deleted
    exit 1 if ( !remove_pam_radius() );
} else {
    exit 1 if ( !add_radius_servers($server_str) );
    exit 1 if ( !add_pam_radius() );
}

exit 0;
