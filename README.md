# Introduction
This Koha plugin enables a library to accept online payments from patrons using the Swedbank Pay platform.

It uses Swedbank Payments API v3.1.

# Installing

To set up the Koha plugin system you must first make some changes to your install.

* Change `<enable_plugins>0<enable_plugins>` to `<enable_plugins>1</enable_plugins>` in your koha-conf.xml file
* Confirm that the path to `<pluginsdir>` exists, is correct, and is writable by the web server
* Add the pluginsdir to your apache PERL5LIB paths and koha-plack startup scripts PERL5LIB
* Restart your webserver

Once set up is complete, navigate to /cgi-bin/koha/plugins/plugins-home.pl

Click "Upload plugin" and upload the .kpz file

# Plugin configuration

* Make sure that Koha's OPACBaseURL system preference is correctly set
* Go to https://your_koha_hostname/cgi-bin/koha/plugins/plugins-home.pl
* Find Swedbank Payments Plugin, click Actions -> Configure
* From your Swedbank Pay merchant admin panel, you will find "Payee ID" and "Merchant ID"
* Add Payee ID and Merchant ID (Merchant Token) in the plugin configuration page.
* Add Payee Name, it will be displayed when redirected to Swedbank Pay
* Add Koha Instance Name. It MUST be unique among multiple Koha installations using the same Swedbank Pay account.
  It will also be visible on receipts, prefixing the receipt number.
* Add terms of service URL (e.g. https://your_library/payments_terms_of_service.pdf)

# Logging

This plugin will log evenets to `plack-opac-error.log` and `api-error.log`.

By enabling system preference `FinesLog`, this plugin logs payment events to Koha's action logs under `FINES` module.
