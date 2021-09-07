# Introduction
This Koha plugin enables a library to accept online payments from patrons using the Swedbank Pay platform.

# Installing
This plugin needs the following perl modules:
* Locale::Currency::Format (liblocale-currency-format-perl)

To set up the Koha plugin system you must first make some changes to your install.

* Change `<enable_plugins>0<enable_plugins>` to `<enable_plugins>1</enable_plugins>` in your koha-conf.xml file
* Confirm that the path to `<pluginsdir>` exists, is correct, and is writable by the web server
* Add the pluginsdir to your apache PERL5LIB paths and koha-plack startup scripts PERL5LIB
* Restart your webserver

Once set up is complete, navigate to /cgi-bin/koha/plugins/plugins-home.pl

# Apache setup

You will need to add to the apache config for your site:
```
   Alias /plugin/ "/var/lib/koha/kohadev/plugins/"
   # The stanza below is needed for Apache 2.4+
   <Directory /var/lib/koha/kohadev/plugins/>
         Options Indexes FollowSymLinks
         AllowOverride None
         Require all granted
         Options +ExecCGI
         AddHandler cgi-script .pl
    </Directory>
```

# Plugin configuration

* Make sure that Koha's OPACBaseURL system preference is correctly set
* Report your Swedbank Payee ID and Payee Name in the plugin configuration page
