# monitoring-plugins
Simple Nagios-compatible monitoring plugins based on the [Monitoring::Plugin](https://www.monitoring-plugins.org/) Perl module.

We use [OMD](http://omdistro.org/) and had a few monitoring requirements that weren't easily dealt with using the stock plugins or anything we could readily find. These are really developed to solve SAFIRE and the South African eduroam NRO's requirements, but are made available here in case they're more generically useful to others.

[update-djnro-realms.pl](https://github.com/tenet-ac-za/monitoring-plugins/blob/master/docs/update-djnro-realms.md) isn't a monitoring plugin per-se; it's a tool to generate monitoring config for [DjNRO](http://djnro.grnet.gr/). Likewise, [update-samlmd-idps.pl](https://github.com/tenet-ac-za/monitoring-plugins/blob/master/docs/update-samlmd-idps.md) does the same function from SAML metadata. [notification-optout.cgi](https://github.com/tenet-ac-za/monitoring-plugins/blob/master/docs/notification-optout.md) provides a way to handle opt-out for these scripts. More detailed [documentation is available](https://github.com/tenet-ac-za/monitoring-plugins/blob/master/docs/).

[check_pptp](https://github.com/tenet-ac-za/monitoring-plugins/blob/master/check_pptp) is licensed differently. See the comments in the file.

