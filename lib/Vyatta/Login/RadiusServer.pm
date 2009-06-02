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

package Vyatta::Login::RadiusServer;
use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";
use Vyatta::Config;
use File::Compare;

my $PAM_RAD_CFG = '/etc/pam_radius_auth.conf';
my $PAM_RAD_TMP = "/tmp/pam_radius_auth.$$";

my $PAM_RAD_BEGIN = '# BEGIN Vyatta Radius servers';
my $PAM_RAD_END   = '# END Vyatta Radius servers';

sub is_pam_radius_present {
    open( my $auth, '<', '/etc/pam.d/common-auth' )
      or die "Cannot open /etc/pam.d/common-auth\n";
    my $present = grep { /\ssufficient\spam_radius_auth\.so$/ } <$auth>;
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

sub update {
    my $rconfig = new Vyatta::Config;
    $rconfig->setLevel("system login radius-server");
    my %servers = $rconfig->listNodeStatus();
    my $count   = 0;

    if (%servers) {
        my $cmd = "sed -e '/$PAM_RAD_BEGIN/,/$PAM_RAD_END/d' < $PAM_RAD_CFG";
        system("sudo sh -c \"$cmd\" > $PAM_RAD_TMP") == 0
          or die "$cmd failed";

        open( my $newcfg, '>>', $PAM_RAD_TMP )
          or die "Can't open $PAM_RAD_TMP: $!\n";

        print $newcfg "$PAM_RAD_BEGIN\n";

        for my $server ( sort keys %servers ) {
            next if ( $servers{$server} eq 'deleted' );
            my $port    = $rconfig->returnValue("$server port");
            my $secret  = $rconfig->returnValue("$server secret");
            my $timeout = $rconfig->returnValue("$server timeout");
            print $newcfg "$server:$port\t$secret\t$timeout\n";
            ++$count;
        }
        print $newcfg "$PAM_RAD_END\n";
        close $newcfg;

        if ( compare( $PAM_RAD_CFG, $PAM_RAD_TMP ) != 0 ) {
            system("sudo cp $PAM_RAD_TMP $PAM_RAD_CFG") == 0
              or die "Copy of $PAM_RAD_TMP to $PAM_RAD_CFG failed";
        }
        unlink($PAM_RAD_TMP);
    }

    if ( $count > 0 ) {
        exit 1 if ( !add_pam_radius() );
    }
    else {
        exit 1 if ( !remove_pam_radius() );
    }
}

1;
