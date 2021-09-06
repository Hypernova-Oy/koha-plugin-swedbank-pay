package Koha::Plugin::Com::imCode::SwedbankPay;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;
use Koha::Patrons;

use Locale::Currency::Format;
use HTML::Entities;

## Here we set our plugin version
our $VERSION = "00.00.01";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Swedbank Payments Plugin',
    author          => 'imCode',
    date_authored   => '2021-09-06',
    date_updated    => "2021-09-06",
    minimum_version => '17.11.00.000',
    maximum_version => '',
    version         => $VERSION,
    description     => 'This plugin implements online payments using '
      . 'Swedbank payments platform. https://developer.swedbankpay.com/payment-instruments/swish/redirect '
      . 'Forked from DIBS Payments Plugin by Matthias Meusburger '
      . 'https://github.com/Libriotech/koha-plugin-dibs-payments',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub _version_check {
    my ( $self, $minversion ) = @_;

    $minversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;

    my $kohaversion = Koha::version();

    # remove the 3 last . to have a Perl number
    $kohaversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;

    return ( $kohaversion > $minversion );
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return $self->retrieve_data('enable_opac_payments') eq 'Yes';
}

## Initiate the payment process
sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi    = $self->{'cgi'};
    my $schema = Koha::Database->new()->schema();

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    # Get the borrower
    my $borrower_result = Koha::Patrons->find($borrowernumber);

    # Add the accountlines to pay off
    my @accountline_ids = $cgi->multi_param('accountline');
    my $accountlines    = $schema->resultset('Accountline')
      ->search( { accountlines_id => \@accountline_ids } );
    my $now               = DateTime->now;
    my $dateoftransaction = $now->ymd('-') . ' ' . $now->hms(':');

    my $active_currency = Koha::Acquisition::Currencies->get_active;
    my $local_currency;
    if ($active_currency) {
        $local_currency = $active_currency->isocode;
        $local_currency = $active_currency->currency unless defined $local_currency;
    } else {
        $local_currency = 'EUR';
    }
    my $decimals = decimal_precision($local_currency);

    my $sum = 0;
    for my $accountline ( $accountlines->all ) {
        # Track sum
        my $amount = sprintf "%." . $decimals . "f", $accountline->amountoutstanding;
        $sum = $sum + $amount;
    }

    # Create a transaction
    my $dbh   = C4::Context->dbh;
    my $table = $self->get_qualified_table_name('swedbank_pay_transactions');
    my $sth = $dbh->prepare("INSERT INTO $table (`transaction_id`, `borrowernumber`, `accountlines_ids`, `amount`) VALUES (?,?,?,?)");
    $sth->execute("NULL", $borrowernumber, join(" ", $cgi->multi_param('accountline')), $sum);

    my $transaction_id =
      $dbh->last_insert_id( undef, undef, qw(swedbank_pay_transactions transaction_id) );

    # DIBS require "The smallest unit of an amount in the selected currency, following the ISO4217 standard." 
    if ($decimals > 0) {
        $sum = $sum * 10**$decimals;
    }

    # Construct redirect URI
    my $accepturl = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account-pay-return.pl?payment_method=Koha::Plugin::Com::imCode::SwedbankPay" );

    # Construct callback URI
    my $callback_url =
      URI->new( C4::Context->preference('OPACBaseURL')
          . $self->get_plugin_http_path()
          . "/callback.pl" );

    # Construct cancel URI
    my $cancel_url = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account.pl?payment_method=Koha::Plugin::Com::imCode::SwedbankPay" );


    # Test mode?
    my $test = $self->retrieve_data('testMode');

	$template->param(

        DIBSURL => 'https://payment.architrade.com/paymentweb/start.action',

        # Required fields
        accepturl    => $accepturl,
        amount       => $sum,
        callbackurl  => $callback_url,
        currency     => $local_currency,
        merchant     => $self->retrieve_data('SwedbankPayPayeeID'),
        orderid      => $transaction_id,
        
        # Optional fields
        lang               => C4::Languages::getlanguage(),
        billingFirstName   => $borrower_result->firstname,
        billingLastName    => $borrower_result->surname,
        billingAddress     => $borrower_result->streetnumber . " " . $borrower_result->address,
        billingAddress2    => $borrower_result->address2,
        billingPostalCode  => $borrower_result->zipcode,
        billingPostalPlace => $borrower_result->city,
        email              => $borrower_result->email,
        test               => $test
    );

    $self->output_html( $template->output() );
}

## Complete the payment process
sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my $transaction_id = $cgi->param('orderid');

    # Check payment went through here
    my $table = $self->get_qualified_table_name('swedbank_pay_transactions');
    my $dbh   = C4::Context->dbh;
    my $sth   = $dbh->prepare(
        "SELECT accountline_id FROM $table WHERE transaction_id = ?");
    $sth->execute($transaction_id);
    my ($accountline_id) = $sth->fetchrow_array();

    my $line =
      Koha::Account::Lines->find( { accountlines_id => $accountline_id } );
    my $transaction_value = $line->amount;
    my $transaction_amount = sprintf "%.2f", $transaction_value;
    $transaction_amount =~ s/^-//g;

    my $active_currency = Koha::Acquisition::Currencies->get_active;
    my $local_currency;
    if ($active_currency) {
        $local_currency = $active_currency->isocode;
        $local_currency = $active_currency->currency unless defined $local_currency;
    } else {
        $local_currency = 'EUR';
    }

    if ( defined($transaction_value) ) {
        $template->param(
            borrower      => scalar Koha::Patrons->find($borrowernumber),
            message       => 'valid_payment',
            currency      => $local_currency,
            message_value => $transaction_amount
        );
    }
    else {
        $template->param(
            borrower => scalar Koha::Patrons->find($borrowernumber),
            message  => 'no_amount'
        );
    }

    $self->output_html( $template->output() );
}

## If your plugin needs to add some javascript in the OPAC, you'll want
## to return that javascript here. Don't forget to wrap your javascript in
## <script> tags. By not adding them automatically for you, you'll have a
## chance to include other javascript files if necessary.
sub opac_js {
    my ($self) = @_;

    # We could add in a preference driven 'enforced pay all' option here.
    return q|
        <script></script>
    |;
}

## If your tool is complicated enough to needs it's own setting/configuration
## you will want to add a 'configure' method to your plugin like so.
## Here I am throwing all the logic into the 'configure' method, but it could
## be split up like the 'report' method is.
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
            SwedbankPayPayeeID   => $self->retrieve_data('SwedbankPayPayeeID'),
            SwedbankPayPayeeName => $self->retrieve_data('SwedbankPayPayeeName'),
            testMode             => $self->retrieve_data('testMode')
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                SwedbankPayPayeeID   => $cgi->param('SwedbankPayPayeeID'),
                SwedbankPayPayeeName => $cgi->param('SwedbankPayPayeeName'),
                testMode             => $cgi->param('testMode')
            }
        );
        $self->go_home();
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('swedbank_pay_transactions');

    return C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS $table (
            `transaction_id` INT( 11 ) NOT NULL AUTO_INCREMENT,
            `accountline_id` INT( 11 ),
            `borrowernumber` INT( 11 ),
            `accountlines_ids` mediumtext,
            `amount` decimal(28,6),
            `updated` TIMESTAMP,
            PRIMARY KEY (`transaction_id`)
        ) ENGINE = INNODB;
    " );
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
#sub upgrade {
#    my ( $self, $args ) = @_;
#
#    my $dt = dt_from_string();
#    $self->store_data(
#        { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );
#
#    return 1;
#}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
#sub uninstall() {
#    my ( $self, $args ) = @_;
#
#    my $table = $self->get_qualified_table_name('mytable');
#
#    return C4::Context->dbh->do("DROP TABLE $table");
#}

1;

