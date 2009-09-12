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

package Vyatta::Login::User;
use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";
use Vyatta::Config;

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
    'admin'    => [ 'quaggavty', 'vyattacfg', 'sudo', 'adm', 'dip', 'disk' ],
    'operator' => [ 'quaggavty', 'vyattaop', 'operator',  'adm',  'dip', ],
);

# Construct a map from existing users to group membership
sub get_groups {
    my %group_map;

    setgrent();
    while ( my ( $name, undef, undef, $members ) = getgrent() ) {
        foreach my $user ( split / /, $members ) {
            $group_map{$user} = [] unless ( $group_map{$user} );
            my $g = $group_map{$user};
            push @$g, $name;
        }
    }
    endgrent();

    return \%group_map;
}

sub update {
    my $membership = get_groups();
    my $uconfig = new Vyatta::Config;
    $uconfig->setLevel("system login user");
    my %users     = $uconfig->listNodeStatus();

    die "All users deleted!\n" unless %users;
    die "User root cannot be deleted\n" 
	if (! defined $users{'root'} || $users{'root'} eq 'deleted');

    foreach my $user ( keys %users ) {
        if ( $users{$user} eq 'deleted' ) {
            system("sudo userdel -r '$user'") == 0
              or die "userdel failed: $?\n";
        }
        elsif ( $users{$user} eq 'added' || $users{$user} eq 'changed' ) {
            $uconfig->setLevel("system login user $user");
            my $pwd =
              $uconfig->returnValue('authentication encrypted-password');
            $pwd or die "Encrypted password not in configuration for $user";

            my $level = $uconfig->returnValue('level');
            $level or die "Level not defined for $user";

            # map level to group membership
            my @new_groups = @{ $level_map{$level} };

            # add any additional groups from configuration
            push( @new_groups, $uconfig->returnValues('group') );

            my $fname = $uconfig->returnValue('full-name');
            my $home  = $uconfig->returnValue('home-directory');

            # Read existing settings
            my (
                undef,    $opwd, $uid, $gid,   undef,
                $comment, undef, $dir, $shell, undef
            ) = getpwnam($user);

            my $old_groups = $membership->{$user};

            my $cmd;
            my $og_str = (defined($old_groups))
                         ? (join(' ', sort @$old_groups)) : '';
            my $ng_str = join(' ', sort @new_groups);

            # not found in existing passwd, must be new
            if ( !defined $uid ) {

                # make new user using vyatta shell
                #  and make home directory (-m)
                #  and with default group of 100 (users)
                $cmd = 'useradd -s /bin/vbash -m -N';
            }
            elsif ($opwd eq $pwd
                && ( !$fname || $fname eq $comment )
                && ( !$home  || $home  eq $dir )
                && $og_str eq $ng_str)
            {

                # If no part of password or group file changed
                # then there is nothing to do here.
                next;
            }
            else {
                $cmd = "usermod";
            }

            $cmd .= " -p '$pwd'";
            $cmd .= " -c \"$fname\"" if ( defined $fname );
            $cmd .= " -d \"$home\"" if ( defined $home );
            $cmd .= ' -G ' . join( ',', @new_groups );
            system("sudo $cmd $user");
            next if ( $? == 0 );
            my $reason = $reasons{ ( $? >> 8 ) };
            die "Attempt to change user $user failed: $reason\n";
        }
    }

    # Remove any vyatta users that do not exist in current configuration
    # This can happen if user added but configuration not saved
    foreach my $grp (qw(vyattacfg vyattaop)) {
	my (undef, undef, undef, $members) = getgrnam($grp);
	next unless $members;

	foreach my $user (split / /, $members) {
	    next if ($user eq 'root');
	    next if ($user eq 'www-data');	# webgui
	    next if defined $users{$user};

	    warn "User $user not listed in current configuration\n";
	    system ("userdel --remove $user") == 0
		or die "Attempt to delete user $user failed: $!";
	}
    }
}

1;
