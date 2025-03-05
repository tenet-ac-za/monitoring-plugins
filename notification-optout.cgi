#!/usr/bin/env perl
# @author Guy Halse http://orcid.org/0000-0002-9388-8592
# @copyright Copyright (c) 2017, Tertiary Education and Research Network of South Africa
# @license https://github.com/tenet-ac-za/monitoring-plugins/blob/master/LICENSE MIT License
#
exec($^X,'-T',$0,@ARGV) unless ${^TAINT}; # enforce taint checking
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
        my $cipher = Crypt::CBC->new(-key => $key, -cipher => 'DES', -pbkdf=>'pbkdf2');
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

        if (defined $c->{'resetConfigMtime'} and $c->{'resetConfigMtime'}) {
            utime(0, 0, $c->{'_outfile'});
            print "<p>This change will take affect when the monitoring system next reloads its config. This typically happens every few hours.</p>\n";
        }

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

__END__

=pod

=head1 NAME

notification-optout.cgi - provide an opt-out mechanism for automated monitoring

=head1 SYNOPSIS

This is a CGI script and is intended to be served via an appropriate
web server.

=head1 OPTIONS

=over 4

=item B<q=>

The value of the opaque token to parse. Can also be passed as C<PATH_INFO>.
If both are present, the query parameter takes precidence.

=item B<List-Unsubscribe=>

A value of C<One-Click> signifies that a real user has confirmed
the opt-out, rather than an automatic fetch of the URL by a content
filter, and any other value is ignored. The specific parameter name
and value are chosesn for compliance with RFC 8058 One-Click functionality.

=back

=head1 CONFIG FILE

B<notification-optout.cgi> expects a YAML config file. The following values are expected:

=over 4

=item B<defaultTokenKey>

A default token encryption key, for use when C<tokenKey> is not found
in the site-specific content. See L<SECURITY>.

=item B<resetConfigMtime>

A boolean (0 or 1) that indicates whether the mtime of the config file
should be set back to the epoch. This allows changes to be detected
and reloaded.

=item B<configMapping>

A hash mapping C<SERVER_NAME> to a site-specific update-* config file,
along the lines of:

 configMapping:
  example.ac.za: /path/to/config.yaml
  example.org: /another/config.yaml

=back

=head1 INTEGRATION

This CGI script is intented to provide a web-based opt-out mechanism
for the automatic monitoring config generators.

The update-* scripts add a custom variable into each contact definition
corresponding to C<$_CONTACTUNSUBSCRIBE_TOKEN$>. This can be passed to
a notification command with the B<-o> option, along the lines of:

 -o CONTACTUNSUBSCRIBE='$_CONTACTUNSUBSCRIBE_TOKEN$'

In turn this can be used in your mail-templates to generate
List-Unsubscribe: headers, along the lines of:

 Precedence: bulk
 List-Unsubscribe-Post: List-Unsubscribe=One-Click
 List-Unsubscribe: <https://example.ac.za/optout/[% CONTACTUNSUBSCRIBE %]>

Together with mod_rewrite, you can produce reasonably concise, opaque
URLs:

 RewriteEngine On
 RewriteBase /optout
 RewriteRule ^index\.cgi$ - [L]
 RewriteRule (.*) index.cgi?q=$1 [QSA]

=head1 SECURITY

The token value in the URL is a simple CBC DES encrypted string. DES
isn't hugely secure these days, but is opaque enough to prevent abuse
here (the risk is low), and produces shorter strings than Blowfish or
IDEA. The key can be set on a per-OMD instance (so we can use different
ones for DjNRO and SAML), or can have a default value in the config file.

=head1 LICENSE

This software is released under an MIT license.
