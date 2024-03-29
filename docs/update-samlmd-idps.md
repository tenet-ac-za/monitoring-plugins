# update-samlmd-idps.pl

update-samlmd-idps.pl interfaces with SAML federation metadata to automatically generate Nagios monitoring configuration for IdPSSODecriptors.

It relies on the presence of a Shibboleth service provider that can be used to originate the single-sign-on authn request. This service provider must have metadata for all of the IdPs to be tested.

## Configuration

Configuration is done in a YAML config file. By default it looks for this in `OMD_ROOT/etc/samlmd-idps.cfg` for OMD systems, or `/etc/samlmd-idps.cfg` on other systems.

```yaml
---
metadataURL: https://metadata.safire.ac.aq/safire-prod-idp.xml
```

Full documentation of the config file can be obtained from perldoc(1)

## Nagios templates

The generated configuration uses Nagios' template inheritance mechanism to create "default" information. The templates we use for this are as follows:

```
# Used by update-samlmd-idps.pl for autogenerated contacts out of SAML Metadata
define service {
  name                           samlmd-generated-idp
  host_name                      testsp.example.ac.aq
  use                            generic-service,srv-pnp
  check_command                  check_saml_sso!/Shibboleth.sso/Login?forceAuthn=true&entityID=$_SERVICEENTITYID$&target=http://$HOSTNAME$/!-R -S -C 15,7 --metadatacertinfo '$_SERVICECERTINFO$' --auth401=$_SERVICEALLOWAUTH401$
  check_interval                 15
  first_notification_delay       45
  max_check_attempts             3
  notes                          This service was auto-generated from SAML metadata. The test itself is rather simplistic - the monitoring system initiates an SSO login from the <a href="https://testsp.example.ac.aq/">Test Service Provider</a>, and confirms that it gets something that appears to be a login page from the identity provider. For queries about this IdP, please contact the help desk at $_SERVICEINSTITUTION$.
  notification_interval          10080
  notifications_enabled          1
  register                       0
  retry_interval                 2
  servicegroups                  +instidps
  stalking_options               w,c
  _INSTITUTION                   Home Organisation
}

# Used by update-samlmd-idps.pl for autogenerated contacts out of SAML Metadata
define contact {
  name                           samlmd-generated-contact
  alias                          SAML Metadata Generated Contact
  use                            generic-contact
  can_submit_commands            0
  host_notification_options      n
  host_notification_period       none
  host_notifications_enabled     0
  register                       0
  service_notification_commands  samlmd-idp-notify-by-email
  service_notification_options   w,c,r
  service_notification_period    samlmd-idp-contact-times
  service_notifications_enabled  1
}

# Used by update-samlmd-idps.pl for autogenerated contacts out of SAML Metadata
define serviceescalation {
  name                           samlmd-generated-serviceescalation
  host_name                      testsp.example.ac.aq
  contacts                       escalation-contact
  first_notification             4
  last_notification              0
  notification_interval          10080
  register                       0
}

# Used by update-samlmd-idps.pl for autogenerated contacts out of SAML Metadata
define servicedependency {
  name                           samlmd-generated-servicedependency
  service_description            HTTP
  host_name                      metadata.example.ac.aq
  dependent_host_name            testsp.example.ac.aq
  execution_failure_criteria     n
  inherits_parent                1
  notification_failure_criteria  w,u,c,p
  register                       0
}
```

## Disabling & adding contacts

Some contacts may not wish to receive notifications, and so it is possible to disable those contacts in the config file:

```yaml
---
disableContacts:
  - eduroam@tenet.ac.za
```
This mechanism is used automatically but the [notification-optout.cgi](notification-optout.md) script.

Similarly it is possible to add additional contacts:

```yaml
---
additionalContacts:
  - entityID: https://login.example.ac.aq/idp/shibboleth
    givenName: Joshia
    sn: Carberry
    mail: J.Carberry@example.ac.aq
```
