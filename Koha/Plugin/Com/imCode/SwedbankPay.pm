package Koha::Plugin::Com::imCode::SwedbankPay;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Auth qw( get_template_and_user );
use Koha::Account;
use Koha::Account::Lines;
use Koha::Logger;
use Koha::Patrons;

use Data::Dumper;
use JSON;
use HTML::Entities;
use HTTP::Request;
use Locale::Currency::Format;
use LWP::UserAgent;

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

our $transaction_status = {
    PENDING => 'pending',
    COMPLETED => 'completed',
    CANCELLED => 'cancelled',
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
    my $logger = Koha::Logger->get;

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

    my @order_items;
    my $sum = 0;
    for my $accountline ( $accountlines->all ) {
        # Track sum
        my $amount = sprintf "%." . $decimals . "f", $accountline->amountoutstanding;
        $sum = $sum + $amount;

        my $acc_reference = ($accountline->debit_type_code ? $accountline->debit_type_code->code : "Fee") || "Fee";
        my $acc_name = $accountline->description || "";
        my $acc_class = $acc_reference;
        $acc_class =~ s/[^\w-]//g;
        my $acc_amount = $amount;
        if ($decimals > 0) {
            $acc_amount = $acc_amount * 10**$decimals;
        }
        push @order_items, {
            reference => $acc_reference,
            name => $acc_name,
            type => 'PRODUCT',
            class => $acc_class,
            quantity => 1,
            quantityUnit => 'pcs',
            unitPrice => $acc_amount,
            vatPercent => 0,
            amount => $acc_amount,
            vatAmount => 0,
        }
    }

    # Create a transaction
    my $dbh   = C4::Context->dbh;
    my $table = $self->get_qualified_table_name('swedbank_pay_transactions');
    my $sth = $dbh->prepare("INSERT INTO $table (`transaction_id`, `borrowernumber`, `accountlines_ids`, `amount`) VALUES (?,?,?,?)");
    $sth->execute("NULL", $borrowernumber, join(" ", $cgi->multi_param('accountline')), $sum);

    my $transaction_id =
      $dbh->last_insert_id( undef, undef, qw(swedbank_pay_transactions transaction_id) );

    # Create orderReference, maxlength 50
    my $order_id = substr( ($transaction_id . '-' . join('', map{('a'..'z','A'..'Z',0..9)[rand 62]} 0..47)), 0, 50 );

    # Generate payee_reference
    my $instance_name = $self->retrieve_data('SwedbankPayKohaInstanceName');
    my $payee_reference = $instance_name . $transaction_id;
    $payee_reference =~ s/[^a-zA-Z0-9,]//g; # allowed characters by Swedbank

    $sth = $dbh->prepare("UPDATE $table SET `order_id`=?, `payee_reference`=? WHERE `transaction_id`=?");
    $sth->execute($order_id, $payee_reference, $transaction_id);

    # ISO4217
    if ($decimals > 0) {
        $sum = $sum * 10**$decimals;
    }

    # Construct host URI
    my $host_url = C4::Context->preference('OPACBaseURL');

    # Construct complete URI
    my $complete_url = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account-pay-return.pl?payment_method=Koha::Plugin::Com::imCode::SwedbankPay&order_id=$order_id" ) . "";

    # Construct callback URI
    my $callback_url =
      URI->new( C4::Context->preference('OPACBaseURL')
          . $self->get_plugin_http_path()
          . "/callback.pl?order_id=$order_id" ) . "";

    # Construct cancel URI
    my $cancel_url = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account.pl?payment_method=Koha::Plugin::Com::imCode::SwedbankPay&order_id=$order_id" ) . "";

    # Construct payment URI
    my $payment_url = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account.pl?payment_method=Koha::Plugin::Com::imCode::SwedbankPay&order_id=$order_id" ) . "";

    # Construct terms of service URI
    my $tos_url = $self->retrieve_data('SwedbankPayTosUrl');

    # Construct payer
    my $payer;
    $payer->{email} = $borrower_result->email if $borrower_result->email;

    # Construct orderItems
    my $order_items;

    # Create Payment Order
    # https://developer.swedbankpay.com/payment-menu/payment-order
    my $ua = LWP::UserAgent->new;

    my $host =
      $self->retrieve_data('testMode')
      ? 'api.externalintegration.payex.com'
      : 'api.payex.com';
    my $url = "https://$host/psp/paymentorders";

    my $language = C4::Languages::getlanguage() || "sv-SE";
    $language = 'en-US' if $language eq 'en'; # convert en to en-US

    my $content_type = 'application/json; charset=utf-8';
    my $auth_token = $self->retrieve_data('SwedbankPayMerchantToken');
    my @req_headers = (
        "Content-Type" => $content_type,
        "Accept" => 'application/problem+json; q=1.0, application/json; q=0.9',
        "Authorization" => "Bearer $auth_token",
    );

    my $req_json = {
        "paymentorder" => {
            "operation" => "Purchase",
            "currency" => $local_currency,
            "amount" => $sum,
            "vatAmount" => 0,
            "description" => "Koha",
            "userAgent" => "Mozilla/5.0 Koha",
            "language" => $language,
            "instrument" => JSON::null,
            "generateRecurrenceToken" => JSON::false,
            "generateUnscheduledToken" => JSON::false,
            "generatePaymentToken" => JSON::false,
            "urls" => {
                "hostUrls" => [ $host_url ],
                "completeUrl" => $complete_url,
                "cancelUrl" => $cancel_url,
                "callbackUrl" => $callback_url,
#                "paymentUrl" => $payment_url, # must be excluded if redirect method is used
                "termsOfServiceUrl" => $tos_url,
                "logoUrl" => "",
            },
            "payeeInfo" => {
                "payeeId" => $self->retrieve_data('SwedbankPayPayeeID'),
                "payeeReference" => $payee_reference,
                "orderReference" => $order_id,
            },
            "orderItems" => \@order_items,
        }
    };
    $req_json->{payer} = $payer if $payer;

    my $res = $ua->post( $url, 'Content' => encode_json $req_json, @req_headers );
    my $redirect_url;
    my $paymentorder_id;
    my $error;
    if ( $res->is_success && $res->code == 201 ) {
        my $res_json;

        # Validate JSON input
        $res_json = eval { from_json( $res->decoded_content ); };
        if ( $@ ) {
            $error = 'PAYMENT_ORDER_CREATE_FAILED_MALFORMED_RESPONSE_JSON';
            $logger->error( "SWEDBANKPAY $order_id: Malformed response JSON: " . $res->decoded_content );
        }

        # Make sure "operations" exists in response JSON
        unless ( $res_json->{operations} ) {
            $error = 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_OPERATIONS_MISSING';
        }

        # Get redirect-paymentorder URI
        my $operations = $res_json->{operations};
        foreach my $op ( @$operations ) {
            if ( $op->{rel} eq 'redirect-paymentorder' ) {
                $redirect_url = $op->{href};
            }
        };
        unless ( $redirect_url ) {
            $error = 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_OPERATIONS_REDIRECT_URL_MISSING';
        }

        # Make sure "paymentorder" exists in response JSON
        if ( !$res_json->{paymentOrder} or !$res_json->{paymentOrder}->{id} ) {
            $error = 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_PAYMENTORDER_ID_MISSING';
        } else {
            $paymentorder_id = $res_json->{paymentOrder}->{id};
            $sth = $dbh->prepare( "UPDATE $table SET `swedbank_paymentorder_id`=? WHERE `transaction_id`=?" );
            $sth->execute( $paymentorder_id, $transaction_id );
        }
    } else {
        $error = 'PAYMENT_ORDER_CREATE_FAILED';
        $logger->error( "SWEDBANKPAY $order_id: API error (" . $res->code . '): ' . Data::Dumper::Dumper( $res->decoded_content ) );
    }

    if ( $error ) {
        $template->param(
            error => $error,
        );
        $logger->error( "SWEDBANKPAY $order_id: $error" );
    } else {
        $template->param(
            # Required fields
            orderid               => $order_id,
            swedbank_redirect_url => $redirect_url,
        );
        $logger->info( "SWEDBANKPAY $order_id: Started new payment $table.order_id: $order_id, $table.paymentorder_id: $paymentorder_id" );
    }

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
            SwedbankPayMerchantToken => $self->retrieve_data('SwedbankPayMerchantToken'),
            SwedbankPayKohaInstanceName => $self->retrieve_data('SwedbankPayKohaInstanceName'),
            SwedbankPayPayeeID   => $self->retrieve_data('SwedbankPayPayeeID'),
            SwedbankPayPayeeName => $self->retrieve_data('SwedbankPayPayeeName'),
            SwedbankPayTosUrl    => $self->retrieve_data('SwedbankPayTosUrl'),
            testMode             => $self->retrieve_data('testMode'),
        );

        $self->output_html( $template->output() );
    }
    else {
        my $store_error_code;
        unless ( $cgi->param('SwedbankPayKohaInstanceName') ) {
            $store_error_code = 'EMPTY_KOHA_INSTANCE_NAME';
        }
        if ( length( $cgi->param('SwedbankPayKohaInstanceName') ) > 20 ) {
            $store_error_code = 'KOHA_INSTANCE_NAME_TOO_LONG';
        }

        if ( $store_error_code ) {
            my $template = $self->get_template( { file => 'configure.tt' } );

            $template->param(
                enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
                SwedbankPayKohaInstanceName => $self->retrieve_data('SwedbankPayKohaInstanceName'),
                SwedbankPayMerchantToken => $self->retrieve_data('SwedbankPayMerchantToken'),
                SwedbankPayPayeeID   => $self->retrieve_data('SwedbankPayPayeeID'),
                SwedbankPayPayeeName => $self->retrieve_data('SwedbankPayPayeeName'),
                SwedbankPayTosUrl    => $self->retrieve_data('SwedbankPayTosUrl'),
                testMode             => $self->retrieve_data('testMode'),
                error                => $store_error_code,
            );

            return $self->output_html( $template->output() );

        }
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                SwedbankPayMerchantToken => $cgi->param('SwedbankPayMerchantToken'),
                SwedbankPayKohaInstanceName => $cgi->param('SwedbankPayKohaInstanceName'),
                SwedbankPayPayeeID   => $cgi->param('SwedbankPayPayeeID'),
                SwedbankPayPayeeName => $cgi->param('SwedbankPayPayeeName'),
                SwedbankPayTosUrl    => $cgi->param('SwedbankPayTosUrl'),
                testMode             => $cgi->param('testMode'),
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

    my $transaction_status_list = join(",", map "'$_'", values(%$transaction_status));
    my $transaction_status_default = "'".$transaction_status->{PENDING}."'";

    # Set database name as default instance name
    $self->store_data(
        {
            SwedbankPayKohaInstanceName => substr( C4::Context->config('database'), 0, 20 ),
        }
    );

    return C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS $table (
            `transaction_id` INT( 11 ) NOT NULL AUTO_INCREMENT,
            `accountline_id` INT( 11 ),
            `borrowernumber` INT( 11 ),
            `order_id` VARCHAR( 50 ),
            `payee_reference` VARCHAR( 30 ) UNIQUE,
            `swedbank_paymentorder_id` VARCHAR( 255 ),
            `accountlines_ids` mediumtext,
            `amount` decimal(28,6),
            `status` ENUM($transaction_status_list) DEFAULT $transaction_status_default,
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

