#!/usr/bin/env perl
# @author Guy Halse http://orcid.org/0000-0002-9388-8592
# @copyright Copyright (c) 2017, Tertiary Education and Research Network of South Africa
# @license https://github.com/safire-ac-za/monitoring-plugins/blob/master/LICENSE MIT License
#
use strict;
use warnings;
use 5.10.0;
use experimental 'smartmatch';
use DBI;
use Getopt::Long;
use Pod::Usage;
use Config::YAML;
use MIME::Base64::URLSafe;
use Crypt::CBC;
use Encode;

sub emailToken($$)
{
    my ($email, $key) = @_;
    my $cipher = Crypt::CBC->new(-key => $key, -cipher => 'DES');
    my $ciphertext = $cipher->encrypt($email);
    return MIME::Base64::URLSafe::encode($ciphertext);
}

# Read a config file
my $baseConfig = exists($ENV{'OMD_ROOT'}) ? $ENV{'OMD_ROOT'} . '/etc/djnro-realms.cfg' : '/etc/djnro-realms.cfg';
$baseConfig = 'djnro-realms.cfg' unless -f $baseConfig;
$baseConfig = "/dev/null" unless -f $baseConfig;    # allow an empty config file

my $c = Config::YAML->new(
    config => $baseConfig,
    nagiosConfigDir => (exists($ENV{'OMD_ROOT'}) ? $ENV{'OMD_ROOT'} . '/etc/nagios/conf.d' : '/etc/nagios/conf.d'),
    nagiosConfigFile => 'djnro-generated-realms.cfg',
    nagiosCheckCommand => '',
    nagiosRestartCommand => '',
    djnroDSN => 'DBI:mysql:database=djnro',
    djnroDbUser => '',
    djnroDbPass => '',
    disableContacts => [],
    credentialOverride => { 'example.ac.za' => { method=>'PEAP', 'phase2'=>'MSCHAPV2', 'anonymous'=>'anonymous@example.ac.za', 'username'=>'username@example.ac.za', 'pass'=>'password' } },
    tokenKey => 'changeme',
);
GetOptions($c,
    'config|c=s',
    'verbose|v!',
    'force|f!',
    'restart|reload|r!',
    'nagiosConfigDir|C=s',
    'nagiosConfigFile|F=s',
    'djnroDSN|dsn|d=s',
    'djnroDbUser|user|u=s',
    'djnroDbPass|pass|p=s',
    'tokenKey|key|k=s',
    'write|w=s',
    'dump|D!',
    'help|h|?',
) or pod2usage(2);
pod2usage(-exitval=>1, -verbose=>2) if defined $c->{'help'};
$c->read($c->{'config'}) if defined $c->{'config'};

# allow the config file to be saved
if (defined $c->{'write'}) {
    $c->set('_outfile', $c->{'write'});
    printf STDERR "Writing config to '%s'\n", $c->{'write'};
    delete($c->{'write'});
    $c->write;
    exit;
}
# allow config to be dumped for debugging
if (defined $c->{'dump'}) {
    use Data::Dumper;
    print Dumper($c);
    exit;
}

# First, some sanity checks
die('nagiosConfigDir does not exist') unless -d $c->{'nagiosConfigDir'};
die('nagiosConfigFile is not writable') unless -w $c->{'nagiosConfigDir'} . '/' . $c->{'nagiosConfigFile'} or (!-e $c->{'nagiosConfigDir'} . '/' . $c->{'nagiosConfigFile'} and -w $c->{'nagiosConfigDir'});

# Get a last modified timestamp
my $realmConfLastModified = 0;
$realmConfLastModified = (stat $c->{'nagiosConfigDir'} . '/' . $c->{'nagiosConfigFile'})[9] if (-e $c->{'nagiosConfigDir'} . '/' . $c->{'nagiosConfigFile'});

# Connect to the DjNRO database
my $dbh = DBI->connect($c->{'djnroDSN'}, $c->{'djnroDbUser'}, $c->{'djnroDbPass'})
    or die('Error connecting to DjNRO database: ' . $DBI::errstr);
$dbh->{'mysql_enable_utf8'} = 1;

# Check when realms were last updated (DjNRO timezone is odd)
my $sth = $dbh->prepare('SELECT unix_timestamp(max(action_time)) + 7200 AS last_updated FROM django_admin_log LEFT JOIN django_content_type ON (content_type_id=django_content_type.id) WHERE app_label = "edumanage" AND model IN ("instrealm","monlocalauthnparam","institutioncontactpool","contact");');
$sth->execute() or die('djnroLastUpdated ' . $dbh->errstr);
my ($djnroLastUpdated) = $sth->fetchrow_array();

if($djnroLastUpdated < $realmConfLastModified) {
    printf(STDERR "Nothing to do (djnroLastUpdated %d < %d)%s\n", $djnroLastUpdated, $realmConfLastModified, defined $c->{'force'} ? ' [FORCED]' : '') if defined $c->{'verbose'};
    exit if (!defined $c->{'force'});
}

# now get a list of realms to check
$sth = $dbh->prepare('SELECT realm,realm_id,name AS inst_name,instid_id,instrealmmonid_id,edumanage_monlocalauthnparam.id AS monlocauthpar_id,eap_method,phase2,username,pass FROM edumanage_instrealm LEFT JOIN edumanage_instrealmmon ON (edumanage_instrealm.id=realm_id) LEFT JOIN edumanage_monlocalauthnparam ON (edumanage_instrealmmon.id=instrealmmonid_id) LEFT JOIN edumanage_name_i18n ON (object_id=instid_id) WHERE mon_type = "localauthn" AND content_type_id=(SELECT id FROM django_content_type WHERE app_label = "edumanage" AND model="institution") AND lang="en" AND edumanage_monlocalauthnparam.id IS NOT NULL ORDER BY realm,eap_method,phase2;');
$sth->execute() or die('djnroRealms ' . $dbh->errstr);

if (!$sth->rows) {
    printf(STDERR "Nothing to do (realms = 0)%s\n", defined $c->{'force'} ? ' [FORCED]' : '') if defined $c->{'verbose'};
    exit if (!defined $c->{'force'});
}

# prepare to get contacts
my $sth_c = $dbh->prepare('SELECT contact_name,contact_email,contact_id,institution_id FROM edumanage_contact LEFT JOIN edumanage_institutioncontactpool ON (edumanage_contact.id=contact_id) WHERE contact_email!="" AND institution_id=? UNION DISTINCT SELECT contact_name,contact_email,contact_id,institution_id FROM edumanage_contact LEFT JOIN edumanage_institutiondetails_contact ON (edumanage_contact.id=contact_id) LEFT JOIN edumanage_institutiondetails ON (edumanage_institutiondetails.id=institutiondetails_id) WHERE contact_email!="" AND institution_id=? ORDER BY contact_email');

# write a file header
open(my $nagConf, '>', $c->{nagiosConfigDir} . '/' . $c->{nagiosConfigFile})
    or die('error opening $c->{nagiosConfigFile} for writing');
printf $nagConf "# Autogenerated: %s\n", scalar localtime();
print $nagConf "# Changes to this file will be overwritten - do not edit\n#\n";

while (my $realm = $sth->fetchrow_hashref) {
    printf(STDERR "REALM %s\n", $realm->{'realm'}) if defined $c->{'verbose'};

    my $defangedRealm = lc($realm->{'realm'}); $defangedRealm =~ s/\W+/_/g;
    my $regexRealm = $realm->{'realm'}; $regexRealm =~ s/\./\\./g; $regexRealm =~ s/\*/.+/;
    my $defangedPassword = $realm->{'pass'}; $defangedPassword =~ s/([#;])/\\$1/g;

    # Sanity check the realm
    $realm->{'username'} .= '@' . $realm->{'realm'} unless $realm->{'username'} =~ m/\@/ or not $realm->{'username'};
    if ($realm->{'username'} !~ m/\@(.+\.)?$regexRealm$/i) {
        printf(STDERR "Skipping test user %s in realm %s (%s)\n", $realm->{'username'}, $realm->{'realm'}, $regexRealm) if defined $c->{'verbose'};
        next;
    }

    # Clean up MSCHAPV2 for newer eapol_test
    $realm->{'phase2'} = 'MSCHAPV2' if defined $realm->{'phase2'} and $realm->{'phase2'} =~ m/^ms-?chapv2/i;

    $sth_c->execute($realm->{'instid_id'}, $realm->{'instid_id'});
    while (my $contact = $sth_c->fetchrow_hashref) {
        # Sanity check the contact
        if ($contact->{'contact_email'} !~ m/^([^@]+)\@[a-z0-9\.]+$/i) {
            printf(STDERR "Skipping contact %s in realm %s\n", $contact->{'contact_email'}, $realm->{'realm'}) if defined $c->{'verbose'};
            next;
        }
        my($defangedLocalPart) = lc($1); $defangedLocalPart =~ s/\W+/_/g;

        printf(STDERR "CONTACT %s\n", $contact->{'contact_email'}) if defined $c->{'verbose'};
        printf $nagConf "# CONTACT %s (contact_id=%d, institution_id=%d)\n", $contact->{'contact_email'}, $contact->{'contact_id'}, $contact->{'institution_id'};
        print  $nagConf "# AUTOGENERATED - DO NOT EDIT!\n";
        print  $nagConf "define contact {\n";
        printf $nagConf "  contact_name                   djnro-c-%s-%s\n", $defangedRealm, $defangedLocalPart;
        printf $nagConf "  alias                          %s\n", encode('utf-8', $contact->{'contact_name'}) if exists $contact->{'contact_name'};
        print  $nagConf "  use                            djnro-generated-contact\n";
        printf $nagConf "  contactgroups                  djnro-cg-%s\n", $defangedRealm;
        printf $nagConf "  email                          %s\n", $contact->{'contact_email'};
        # Disable contacts that were excluded
        if ($contact->{'contact_email'} ~~ $c->{disableContacts}) { # smartmatch
            print  $nagConf "  host_notification_options      n\n";
            print  $nagConf "  host_notifications_enabled     0\n";
            print  $nagConf "  service_notification_options   n\n";
            print  $nagConf "  service_notifications_enabled  0\n";
        }
        printf $nagConf "  _UNSUBSCRIBE_TOKEN             %s\n", emailToken($contact->{'contact_email'}, $c->{'tokenKey'});
        print  $nagConf "}\n\n";
    }

    # Create this as a contact group even if there is only one contact to ease the rest of the configuration
    printf $nagConf "# CONTACTGROUP %s\n", $realm->{'realm'};
    print  $nagConf "# AUTOGENERATED - DO NOT EDIT!\n";
    print  $nagConf "define contactgroup {\n";
    printf $nagConf "  contactgroup_name              djnro-cg-%s\n", $defangedRealm;
    printf $nagConf "  alias                          Realm: %s\n", $realm->{'realm'};
    print  $nagConf "}\n\n";

    printf $nagConf "# REALM %s (instid_id = %d, realm_id = %d, instrealmmonid_id = %d, monlocauthpar_id = %d)\n", $realm->{'realm'}, $realm->{'instid_id'}, $realm->{'realm_id'}, $realm->{'instrealmmonid_id'}, $realm->{'monlocauthpar_id'};
    print  $nagConf "# AUTOGENERATED - DO NOT EDIT!\n";
    printf $nagConf "# WARNING - HAS OVERRIDES IN %s\n", $c->{'_infile'} if exists $c->{'credentialOverride'}->{lc($realm->{'realm'})};
    print  $nagConf "define service {\n";
    printf $nagConf "  service_description            realm-%s\n", $defangedRealm;
    print  $nagConf "  use                            djnro-generated-realm\n";
    printf $nagConf "  contact_groups                 djnro-cg-%s\n", $defangedRealm;
    printf $nagConf "  display_name                   Realm: %s\n", $realm->{'realm'};
    printf $nagConf "  _EAP_ANONYMOUS                 %s\n", encode('utf-8', exists($c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'anonymous'}) ? $c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'anonymous'} : $realm->{'username'});
    printf $nagConf "  _EAP_METHOD                    %s\n", exists($c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'method'}) ? $c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'method'} : $realm->{'eap_method'};
    printf $nagConf "  _EAP_PASSWORD                  %s\n", encode('utf-8', exists($c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'pass'}) ? $c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'pass'} : $realm->{'pass'});
    printf $nagConf "  _EAP_PHASE2                    %s\n", exists($c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'phase2'}) ? $c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'phase2'} : $realm->{'phase2'};
    printf $nagConf "  _EAP_USERNAME                  %s\n", encode('utf-8', exists($c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'username'}) ? $c->{'credentialOverride'}->{lc($realm->{'realm'})}->{'username'} : $realm->{'username'});
    printf $nagConf "  _EDITURI                       monlocauthpar/edit/%d/%d\n", $realm->{'instrealmmonid_id'}, $realm->{'monlocauthpar_id'};
    printf $nagConf "  _INSTITUTION                   %s\n", encode('utf-8', $realm->{'inst_name'});
    printf $nagConf "  _REALM                         %s\n", lc($realm->{'realm'});
    print  $nagConf "}\n\n";

    # Service dependencies stop us sending notification when radsecproxy itself is broken
    printf $nagConf "# SERVICEDEPENDENCY %s\n", $realm->{'realm'};
    print  $nagConf "# AUTOGENERATED - DO NOT EDIT!\n";
    print  $nagConf "define servicedependency {\n";
    print  $nagConf "  use                            djnro-generated-servicedependency\n";
    printf $nagConf "  dependent_service_description  realm-%s\n", $defangedRealm;
    print  $nagConf "}\n\n";

    # Service escalations allow us to notify the SOC if nobody resolves the problem
    printf $nagConf "# SERVICEESCALATION %s\n", $realm->{'realm'};
    print  $nagConf "# AUTOGENERATED - DO NOT EDIT!\n";
    print  $nagConf "define serviceescalation {\n";
    printf $nagConf "  service_description            realm-%s\n", $defangedRealm;
    print  $nagConf "  use                            djnro-generated-serviceescalation\n";
    printf $nagConf "  contact_groups                 djnro-cg-%s\n", $defangedRealm;
    print  $nagConf "}\n\n";

}

# Do we need to restart naemon
if (defined $c->{'restart'} and $c->{'nagiosRestartCommand'}) {
    if ($c->{'nagiosCheckCommand'}) {
        system($c->{'nagiosCheckCommand'}) == 0
            or die ('nagios configuration failed, bailing out of restart');
    }
    print STDERR "Restarting monitoring process\n" if defined $c->{'verbose'};
    system($c->{'nagiosRestartCommand'});
}

__END__

=head1 NAME

update-djnro-realms.pl - create Nagios-style monitoring config for DjNRO

=head1 SYNOPSIS

update-djnro-realms.pl [-c C<config>] [--restart] [options...]

=head1 OPTIONS

=over 8

=item B<--config>=C<file>, -c C<file>

Specify the location of a YAML config file. Defaults to C<$OMD_ROOT/etc/djnro-realms.cfg>, and failing that looks for C<djnro-realms.cfg> in the current directory.

=item B<--verbose>, -v

Produce verbose output to STDERR

=item B<--force>, -f

Force writing a new Nagios config even if freshness tests say it is not necessary.

=item B<--restart>, --reload, -r

Restart/reload the monitoring system (requires that B<nagiosRestartCommand> is set in the config file).

=item B<--nagiosConfigDir>=C<dir>, -C C<dir>

Set the location of the Nagios config directory. Defaults to C<$OMD_ROOT/etc/nagios/conf.d>.

=item B<--nagiosConfigFile>=C<file>, -F C<file>

Set the location of the generated config file, relative to B<nagiosConfigDir>. Defaults to C<djnro-generated-realms.cfg>.

=item B<--djnroDSN>=C<dsn>, --dsn=C<dsn>, -d C<dsn>

Set the DSN of the DjNRO database

=item B<--djnroDbUser>=C<user>, --user=C<user>, -u C<user>

Set the DjNRO database user

=item B<--djnroDbPass>=C<pass>, --pass=C<pass>, -p C<pass>

Set the DjNRO database password.

=item B<--tokenKey>=C<string>, -k C<string>

Set an encryption key that is used to generate an opaque opt-out "unsubscribe" token for each contact defination. Defaults to C<changeme>.

=item B<--write>=C<file>, -w C<file>

Writes a new config file to C<file> (can be used to bootstrap a config file).

=item B<--dump>, -D

Dump the config with Data::Dumper for debugging.

=item B<--help>, -h, -?

Display usage information.

=back

=head1 CONFIG FILE

B<update-djnro-realms.pl> expects a YAML config file. All of the L<OPTIONS> above can also be expressed in the config file -- the primary option should be used as the YAML key. The following additional options exist:

=over 8

=item B<disableContacts>

A list of email addresses that should never receive notifications.

=item B<credentialOverride>

A map of credential options that override the DjNRO settings for a realm.

=back

=head2 SAMPLE CONFIG

 # This is the configuration for update-djnro-realms.pl
 ---
 nagiosConfigDir: /omd/sites/mysite/etc/nagios/conf.d
 nagiosConfigFile: djnro-generated-realms.cfg
 djnroDSN: DBI:mysql:database=djnro
 djnroDbUser: djnro
 djnroDbPass: djnro
 nagiosCheckCommand: naemon -v /omd/sites/mysite/tmp/naemon/naemon.cfg
 nagiosRestartCommand: omd restart naemon

 disableContacts:
  - eduroam@example.ac.za

 credentialOverride:
  example.ac.za: { method: PEAP, phase2: MSCHAPV2, anonymous: anonymous@example.ac.za, username: username@example.ac.za, pass: password }

=head1 LICENSE

This software is released under an MIT license.
