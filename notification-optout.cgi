#!/usr/bin/perl -T
# @author Guy Halse http://orcid.org/0000-0002-9388-8592
# @copyright Copyright (c) 2017, SAFIRE - South African Identity Federation
# @license https://github.com/safire-ac-za/monitoring-plugins/blob/master/LICENSE MIT License
#
use strict;
use warnings;
use 5.10.0;
use experimental 'smartmatch';
use Config::YAML;
use MIME::Base64::URLSafe;
use Crypt::CBC;
use CGI::Fast;
use CGI::Carp qw/fatalsToBrowser/;

sub _error($)
{
    my ($m) = @_;
    print STDERR "$0 error: $m\n";
    print "<p>The following error occurred while attempting to opt-out from notifications:<p>\n";
    print "<blockquote>$m</blockquote>\n";
    printf "<p>Please correct the error and try again, or contact %s for assistance.</p>\n", $ENV{'SERVER_ADMIN'};
}

sub _header($)
{
    my ($q) = @_;
    print $q->header();
    print << "EOM";
<!DOCTYPE html>
<html lang="en">
<head>
  <title>Notification Opt-Out</title>
  <style>
  body { font-family:Geneva, Arial, Helvetica, sans-serif; margin:1em; padding:1em; border:#999999 2px solid; }
  h1 { padding:8px; margin:0; color:white; background:#999999; }
  </style>
</head>
<body>
  <h1>$ENV{SERVER_NAME} notification opt-out</h1>
EOM
}

sub tokenEmail($$)
{
    my ($token, $key) = @_;
    my $cleartext;
    eval {
        my $cipher = Crypt::CBC->new(-key => $key, -cipher => 'DES');
        $cleartext = $cipher->decrypt(
            MIME::Base64::URLSafe::decode($token)
        );
    } || die 'Unable to retrieve email address from token';
    return $cleartext;
}

sub globalConfig()
{
    my $baseConfig = $ENV{'OMD_ROOT'} . '/etc/omd-notification-optout.cfg';
    $baseConfig = '/etc/omd-notification-optout.cfg' unless -f $baseConfig;
    $baseConfig = 'omd-notification-optout.cfg' unless -f $baseConfig;
    $baseConfig = "/dev/null" unless -f $baseConfig;    # allow an empty config file
    my $c = Config::YAML->new(
        config => $baseConfig,
        defaultTokenKey => 'changeme',
        configMapping => { },
    );
    return $c;
}

sub siteConfig($)
{
    my ($c) = @_;
    if (exists $ENV{'SERVER_NAME'} and exists $c->{'configMapping'}->{$ENV{'SERVER_NAME'}}) {
        print "<!-- " . $c->{'configMapping'}->{$ENV{'SERVER_NAME'}} . " -->\n";
        my $s = Config::YAML->new(
            config => $c->{'configMapping'}->{$ENV{'SERVER_NAME'}},
            disableContacts => [],
        );
        return $s;
    }
}

sub uniq($)
{
    my %seen;
    return grep { !$seen{$_}++ } @_;
}

while (my $q = CGI::Fast->new) {
    _header($q);

    my $c = globalConfig();
    my $s = siteConfig($c);
    unless (defined $s and $s) {
        _error(sprintf "Could not read config for %s.", $ENV{'SERVER_NAME'}); next;
    }

    my $key = $s->{'tokenKey'} || $c->{'defaultTokenKey'};
    unless (defined $key and $key) {
        _error("Someone forgot to configure a token decryption key?"); next;
    }

    my $token = $q->param('q') || $q->path_info();
    unless (defined $token and $token) {
        _error("Did not find a valid token in the URL or query string."); next;
    }

    my $email = tokenEmail($token, $key);
    unless (defined $email and $email =~ m/^.+\@.+\..+$/) {
        _error("Token did not translate to a valid email address."); next;
    }

    if ($email ~~ $s->{'disableContacts'}) {    # smartmatch
        _error(sprintf("<b>%s</b> has already been disabled for notifications from %s.", $email, $ENV{'SERVER_NAME'})); next;
    }

    if ($q->param('List-Unsubscribe') eq 'One-Click') {

        push(@{$s->{'disableContacts'}}, $email);

        unless ($s->write()) {
            _error("Error saving opt-out preference, please try again later."); next;
        }

        printf "<p>Successfully disabled notifications for <b>%s</b> from %s :-)</p>\n", $email, $ENV{'SERVER_NAME'};

    } else {
        printf "<p>Please confirm you want to opt-out of notifications for <b>%s</b>\n", $email;
        print  '<form>';
        printf '<input type="hidden" name="q" value="%s">', $token;
        print  '<input type="hidden" name="List-Unsubscribe" value="One-Click">';
        print  '<input type="submit" value="Confirm Opt-Out">';
        print  "</form>\n";
    }

    print '</body></html>';
}
