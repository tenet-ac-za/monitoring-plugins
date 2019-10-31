# notification-optout.cgi

This CGI script interfaces with [update-djnro-realms.pl](update-djnro-realms.md) and/or [update-samlmd-idps.pl](update-samlmd-idps.md) to allow people to opt-out of notifications without interacting with the NREN.

The notification-optout.cgi script reads and understands the `disableContacts` stanzas used by these scripts, and can write new configuration files with the `disableContacts` stanza updated.

## Configuration

Configuration is done in a YAML config file. By default it looks for this in `OMD_ROOT/etc/omd-notification-optout.cfg` for OMD systems, or `/etc/omd-notification-optout.cfg` on other systems.

An important feature is the ability to select the config to use based on the FQDN of the monitoring system vhost, which is useful with OMD:
```yaml
---
configMapping:
  a.example.ac.aq: /omd/sites/example-a/etc/djnro-realms.cfg
  b.example.ac.aq: /omd/sites/example-b/etc/samlmd-idps.cfg
```

Full documentation of the config file can be obtained from perldoc(1)

## Apache configuration

You need to create Apache config pointing to the script that is similar to the following:
```
<Directory /var/www/html/optout>
    AddHandler cgi-script .cgi
    AcceptPathInfo On
    AllowOverride Indexes
    Options +ExecCGI
    RewriteEngine On
    RewriteBase /optout
    RewriteRule ^index\.cgi$ - [L]
    RewriteRule (.*) index.cgi?q=$1 [QSA]
</Directory>
```

## Tokens

Security and privacy is ensured by generating encrypted tokens. This requires a secret key be configured in the appropriate file using the `tokenKey` stanza. The master configuration can defined a `defaultTokenKey` to be used in the event a service-specific one is not found.

## Headers in notification mails

The script is capable of honouring [RFC 8058](https://tools.ietf.org/html/rfc8058) One-Click list opt out. To ensure this is supported by mail clients, it is advisable to set the following headers in your email notification templates:

```
Auto-Submitted: auto-generated
X-Auto-Response-Suppress: DR, RN, NRN, OOF
Precedence: bulk
List-Id: <samlmd.a.example.ac.aq>
List-Unsubscribe-Post: List-Unsubscribe=One-Click
List-Unsubscribe: <https://a.example.ac.aq/optout/[% CONTACTUNSUBSCRIBE %]>
```
Where CONTACTUNSUBSCRIBE is a variable that comes from the generated contact object in Nagios.
