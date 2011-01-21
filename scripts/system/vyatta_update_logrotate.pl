#!/usr/bin/perl

use strict;

my $file = "messages";
my $log_file = "/var/log/messages";
if ($#ARGV == 3) {
  $file = shift;
  $log_file = "/var/log/user/$file";
}
my $files = shift;
my $size = shift;
my $set = shift;
my $log_conf = "/etc/logrotate.d/$file";

if (!defined($files) || !defined($size) || !defined($set)) {
  exit 1;
}

if (!($files =~ m/^\d+$/) || !($size =~ m/^\d+$/)) {
  exit 2;
}

# just remove it and make a new one below
# (the detection mechanism in XORP doesn't work anyway)
unlink $log_conf;

open my $out, '>>', $log_conf
    or exit 3;
if ($set == 1) {
  print $out <<EOF;
$log_file {
  missingok
  notifempty
  rotate $files
  size=${size}k
  postrotate
  	invoke-rc.d rsyslog reload >/dev/null
  endscript
}
EOF
}
close $out;

exec '/usr/sbin/invoke-rc.d', 'rsyslog', 'restart';
exit 4;
