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
use Locale::Currency;
use Locale::Currency::Format;
use LWP::UserAgent;
use Scalar::Util qw(blessed);
use Try::Tiny;

use Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError;
use Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::Transaction;

## Here we set our plugin version
our $VERSION = "3.1.0";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Swedbank Payments Plugin',
    author          => 'imCode Partner AB and Hypernova Oy, Lari Taskula',
    date_authored   => '2021-09-06',
    date_updated    => "2025-11-03",
    minimum_version => '24.05.00.000',
    maximum_version => '',
    version         => $VERSION,
    description     => 'This plugin implements online payments using Swedbank payments platform v3.1.',

    #        . 'Forked from DIBS Payments Plugin by Matthias Meusburger '
    #        . 'https://github.com/Libriotech/koha-plugin-dibs-payments',
};

our $transaction_status = {
    PENDING   => 'pending',
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
    $self->{logger} = Koha::Logger->get;

    return $self;
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'swedbankpay';
}

sub _version_check {
    my ( $self, $minversion ) = @_;

    $minversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;

    my $kohaversion = Koha::version();

    # remove the 3 last . to have a Perl number
    $kohaversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;

    return ( $kohaversion > $minversion );
}

sub _get_koha_version {
    my ($self) = @_;

    my $koha_version = C4::Context->preference('Version');
    $koha_version =~ s/\.//g;
    $koha_version = substr( $koha_version, 0, 4 );    # this will be 2005, 2011, 2105 etc

    # returns Koha version as an integer, easy to compare
    return $koha_version;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return $self->retrieve_data('enable_opac_payments') eq 'Yes';
}

## Initiate the payment process
sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $schema = Koha::Database->new->schema;
    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my $language = $self->get_language();

    $template->param(
        koha_version => $self->_get_koha_version(),
        LANG         => $language,
        PLUGIN_DIR   => $self->bundle_path,
    );

    my @accountline_ids = $cgi->multi_param('accountline');
    my $accountlines    = $schema->resultset('Accountline')->search( { accountlines_id => \@accountline_ids } );

    my ( $error, $order_id, $transaction_id, $paymentorder_id, $redirect_url ) =
        $self->create_transaction( $borrowernumber, $accountlines, $template );

    if ($error) {
        $template->param(
            swedbank_error => $error,
        );
    } else {
        $template->param(
            order_id              => $order_id,
            swedbank_redirect_url => $redirect_url,
        );
        my $table = $self->get_qualified_table_name('transactions');
        $self->logger->info(
            "SWEDBANKPAY $order_id: Started new payment $table.order_id: $order_id, $table.paymentorder_id: $paymentorder_id"
        );
    }

    $self->output_html( $template->output() );
}

sub create_transaction {
    my ( $self, $borrowernumber, $accountlines, $template ) = @_;

    my $error;
    my $schema = Koha::Database->new->schema;

    # Get the borrower
    my $patron = Koha::Patrons->find($borrowernumber);

    # Add the accountlines to pay off
    my $now               = DateTime->now;
    my $dateoftransaction = $now->ymd('-') . ' ' . $now->hms(':');

    my $local_currency = $self->get_currency;
    my $decimals       = decimal_precision($local_currency);

    my @order_items;
    my $sum = 0;
    for my $accountline ( $accountlines->all ) {

        # Track sum
        my $amount = sprintf "%." . $decimals . "f", $accountline->amountoutstanding;
        $sum = $sum + $amount;

        my $acc_reference = ( $accountline->debit_type_code ? $accountline->debit_type_code->code : "Fee" ) || "Fee";
        my $acc_name      = $accountline->description                                                       || "";
        my $acc_class     = $acc_reference;
        $acc_class =~ s/[^\w-]//g;
        my $acc_amount = $amount;
        if ( $decimals > 0 ) {
            $acc_amount = $acc_amount * 10**$decimals;
        }
        push @order_items, {
            reference    => $acc_reference,
            name         => $acc_name,
            type         => 'PRODUCT',
            class        => $acc_class,
            quantity     => 1,
            quantityUnit => 'pcs',
            unitPrice    => $acc_amount,
            vatPercent   => 0,
            amount       => $acc_amount,
            vatAmount    => 0,
        };
    }

    # Create a transaction
    my $dbh                = C4::Context->dbh;
    my $table              = $self->get_qualified_table_name('transactions');
    my $table_accountlines = $self->get_qualified_table_name('accountlines');
    my $sth = $dbh->prepare("INSERT INTO $table (`transaction_id`, `borrowernumber`, `amount`) VALUES (?,?,?)");
    $sth->execute( "NULL", $borrowernumber, $sum );

    my $transaction_id = $dbh->last_insert_id( undef, undef, qw(swedbank_pay_transactions transaction_id) );

    foreach my $accountline ( $accountlines->all ) {
        my $accountline_id = $accountline->accountlines_id;
        my $sth = $dbh->prepare("INSERT INTO $table_accountlines (`transaction_id`, `accountline_id`) VALUES (?,?)");
        $sth->execute( $transaction_id, $accountline_id );
    }

    # Create orderReference, maxlength 50
    my $order_id = substr(
        ( $transaction_id . '-' . join( '', map { ( 'a' .. 'z', 'A' .. 'Z', 0 .. 9 )[ rand 62 ] } 0 .. 47 ) ),
        0, 50
    );

    # Generate payee_reference
    my $instance_name   = $self->retrieve_data('SwedbankPayKohaInstanceName');
    my $payee_reference = $instance_name . $transaction_id;
    $payee_reference =~ s/[^a-zA-Z0-9,]//g;    # allowed characters by Swedbank

    $sth = $dbh->prepare("UPDATE $table SET `order_id`=?, `payee_reference`=? WHERE `transaction_id`=?");
    $sth->execute( $order_id, $payee_reference, $transaction_id );

    # ISO4217
    if ( $decimals > 0 ) {
        $sum = $sum * 10**$decimals;
    }

    # Construct host URI
    my $host_url = C4::Context->preference('OPACBaseURL');

    # Construct complete URI
    my $complete_url =
        URI->new( C4::Context->preference('OPACBaseURL')
            . "/cgi-bin/koha/opac-account-pay-return.pl?payment_method=Koha::Plugin::Com::imCode::SwedbankPay&order_id=$order_id"
    )->as_string;

    # Construct callback URI
    my $api_namespace = $self->api_namespace;
    my $callback_url =
        URI->new( C4::Context->preference('OPACBaseURL') . "/api/v1/contrib/$api_namespace/callback/$order_id" )
        ->as_string;

    # Construct payment URI
    my $payment_url =
        URI->new( C4::Context->preference('OPACBaseURL')
            . "/cgi-bin/koha/opac-account.pl?payment_method=Koha::Plugin::Com::imCode::SwedbankPay&order_id=$order_id" )
        ->as_string;

    # Construct terms of service URI
    my $tos_url = $self->retrieve_data('SwedbankPayTosUrl');

    # Construct payer
    my $payer;
    $payer->{email} = $patron->email;

    # Create Payment Order
    # https://developer.swedbankpay.com/payment-menu/payment-order
    my $ua = LWP::UserAgent->new;

    my $host        = $self->get_host;
    my $url         = "$host/psp/paymentorders";
    my @req_headers = $self->get_headers;

    my $req_json = {
        "paymentorder" => {
            "operation"   => "Purchase",
            "currency"    => $local_currency,
            "amount"      => $sum,
            "vatAmount"   => 0,
            "description" => "Koha",
            "userAgent"   => "Mozilla/5.0 Koha",
            "language"    => $self->get_language(),
            "instrument"  => JSON::null,
            "urls"        => {
                "hostUrls"          => [$host_url],
                "completeUrl"       => $complete_url,
                "cancelUrl"         => $complete_url,
                "callbackUrl"       => $callback_url,
                "termsOfServiceUrl" => $tos_url,
                "logoUrl"           => "",
            },
            "payeeInfo" => {
                "payeeId"        => $self->retrieve_data('SwedbankPayPayeeID'),
                "payeeReference" => $payee_reference,
                "orderReference" => $order_id,
            },
            "orderItems" => \@order_items,
        }
    };
    $req_json->{payer} = $payer if $payer;

    my $paymentorder_id;
    my $redirect_url;

    try {
        my $res = $ua->post( $url, 'Content' => encode_json $req_json, @req_headers );
        if ( $res->is_success && $res->code == 201 ) {
            my $res_json;

            # Validate JSON input
            $res_json = eval { from_json( $res->decoded_content ); };
            if ($@) {
                Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MalformedJSON->throw(
                    error_code => 'PAYMENT_ORDER_CREATE_FAILED_MALFORMED_RESPONSE_JSON',
                    error      => 'Malformed JSON from payment order creation response',
                    content    => $res->decoded_content,
                    order_id   => $order_id,
                );
            }

            # Make sure "operations" exists in response JSON
            unless ( $res_json->{operations} ) {
                Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty->throw(
                    error_code => 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_OPERATIONS_MISSING',
                    error      => 'Response is missing a required property',
                    content    => $res->decoded_content,
                    order_id   => $order_id,
                    property   => 'operations'
                );
            }

            # Get redirect-checkout URI
            my $operations = $res_json->{operations};
            foreach my $op (@$operations) {
                if ( $op->{rel} eq 'redirect-checkout' ) {
                    $redirect_url = $op->{href};
                }
            }
            unless ($redirect_url) {
                Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingObject->throw(
                    error_code => 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_OPERATIONS_REDIRECT_URL_MISSING',
                    error      => 'Response is missing a required property',
                    content    => $res->decoded_content,
                    order_id   => $order_id,
                    object     => 'operations.rel => redirect-checkout'
                );
            }

            # Make sure "paymentorder" exists in response JSON
            if ( !exists $res_json->{paymentOrder} or !exists $res_json->{paymentOrder}->{id} ) {
                Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty->throw(
                    error_code => 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_PAYMENTORDER_MISSING',
                    error      => 'Response is missing a required property',
                    content    => $res->decoded_content,
                    order_id   => $order_id,
                    property   => 'paymentOrder'
                ) if !$res_json->{paymentOrder};

                Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty->throw(
                    error_code => 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_PAYMENTORDER_ID_MISSING',
                    error      => 'Response is missing a required property',
                    content    => $res->decoded_content,
                    order_id   => $order_id,
                    property   => 'paymentOrder.id'
                ) if !$res_json->{paymentOrder}->{id};
            } else {
                $paymentorder_id = $res_json->{paymentOrder}->{id};
                $sth = $dbh->prepare("UPDATE $table SET `swedbank_paymentorder_id`=? WHERE `transaction_id`=?");
                $sth->execute( $paymentorder_id, $transaction_id );
            }
        } else {
            Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError->throw(
                error_code => 'PAYMENT_ORDER_CREATE_FAILED',
                error      => 'Payment order creation failed',
                code       => $res->code,
                content    => $res->decoded_content,
                order_id   => $order_id,
                object     => 'operations.rel => redirect-checkout'
            );
        }
    } catch {
        if ( blessed $_ ) {
            if ( $_->isa('Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError') ) {
                $error = $_->error_code;
                $self->logger->error(
                    ref($_) . ': ' . $_->error . ', dump: ' . Data::Dumper::Dumper( $_->field_hash ) );
            } else {
                $self->logger->error( ref($_) . ': ' . $_ );
            }
        } else {
            $self->logger->error("Swedbank Payments Plugin: $_");
        }
    };

    return ( $error, $order_id, $transaction_id, $paymentorder_id, $redirect_url );
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
    my $patron = Koha::Patrons->find($borrowernumber);
    $patron = $patron->unblessed if $patron;

    my $language = $self->get_language();
    $template->param(
        koha_version => $self->_get_koha_version(),
        LANG         => $language,
        PLUGIN_DIR   => $self->bundle_path,
    );

    my $order_id = $cgi->param('order_id');

    try {
        my $table = $self->get_qualified_table_name('transactions');
        my $dbh   = C4::Context->dbh;
        my $sth   = $dbh->prepare(
            "SELECT transaction_id, swedbank_paymentorder_id, payee_reference, amount FROM $table WHERE borrowernumber = ? AND order_id = ?"
        );
        $sth->execute( $borrowernumber, $order_id );
        my ( $transaction_id, $paymentorder_id, $payee_reference, $amount ) = $sth->fetchrow_array();

        if ( !$transaction_id or !$paymentorder_id ) {
            Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::Transaction::NotFound->throw(
                error_code      => 'TRANSACTION_NOT_FOUND',
                patron          => $patron,
                order_id        => $order_id,
                transaction_id  => $transaction_id,
                paymentorder_id => $paymentorder_id,
            );
        }

        my ( $success, $error_code ) = $self->process_transaction($order_id);

        if ( !$success ) {
            Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::Transaction->throw(
                error_code      => $error_code || 'unknown_error',
                patron          => $patron,
                order_id        => $order_id,
                transaction_id  => $transaction_id,
                paymentorder_id => $paymentorder_id,
            );
        }

        $sth = $dbh->prepare("SELECT accountline_id, status FROM $table WHERE borrowernumber = ? AND order_id = ?");
        $sth->execute( $borrowernumber, $order_id );
        my ( $accountline_id, $status ) = $sth->fetchrow_array();

        if ( $status eq $transaction_status->{CANCELLED} ) {
            Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::Transaction::Cancelled->throw(
                error_code      => 'cancelled_payment',
                patron          => $patron,
                order_id        => $order_id,
                transaction_id  => $transaction_id,
                paymentorder_id => $paymentorder_id,
            );
        }

        my $line = Koha::Account::Lines->find( { accountlines_id => $accountline_id } );
        unless ($line) {
            Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::Transaction->throw(
                error_code      => $error_code || 'unknown_error',
                error           => 'Accountlines entry not found',
                patron          => $patron,
                order_id        => $order_id,
                transaction_id  => $transaction_id,
                paymentorder_id => $paymentorder_id,
            );
        }
        my $transaction_value  = $line->amount;
        my $transaction_amount = sprintf "%.2f", $transaction_value;
        $transaction_amount =~ s/^-//g;

        my $local_currency = $self->get_currency;

        if ( defined($transaction_value) ) {
            $template->param(
                patron        => $patron,
                message       => 'valid_payment',
                currency      => $local_currency,
                message_value => $transaction_amount
            );
        } else {
            $template->param(
                patron  => $patron,
                message => 'no_amount'
            );
        }
    } catch {
        my $patron;
        if ( blessed $_ ) {
            if (   $_->isa('Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::Transaction')
                || $_->isa('Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError') )
            {
                $patron = $_->can('patron') ? $_->patron->unblessed : undef;
                $template->param( message => $_->error_code, order_id => $order_id, patron => $patron );
                $self->logger->error(
                    ref($_) . ': ' . $_->error . ', dump: ' . Data::Dumper::Dumper( $_->field_hash ) );
            } else {
                $template->param( message => 'unknown_error', order_id => $order_id );
                $self->logger->error( ref($_) . ': ' . $_ );
            }
        } else {
            $template->param( message => 'unknown_error', order_id => $order_id );
            $self->logger->error("Swedbank Payments Plugin: $_");
        }
    };

    $self->output_html( $template->output() );
}

sub process_transaction {
    my ( $self, $order_id ) = @_;

    my $table = $self->get_qualified_table_name('transactions');

    my $schema = Koha::Database->new->schema;
    try {
        $schema->txn_do(
            sub {
                my $dbh = C4::Context->dbh;
                my $sth = $dbh->prepare(
                    "SELECT transaction_id, swedbank_paymentorder_id, payee_reference, amount FROM $table WHERE order_id = ?"
                );
                $sth->execute($order_id);
                my ( $transaction_id, $paymentorder_id, $payee_reference, $amount ) = $sth->fetchrow_array();

                # Check payment status
                my $ua = LWP::UserAgent->new;

                my $host        = $self->get_host;
                my $url         = "$host" . "$paymentorder_id" . '?$expand=orderItems,payments,currentPayment';
                my @req_headers = $self->get_headers;

                my $res = $ua->get( $url, @req_headers );
                my $capture_url;
                my $paid = 0;
                if ( $res->is_success && $res->code == 200 ) {
                    my $res_json;

                    # Validate JSON input
                    $res_json = eval { from_json( $res->decoded_content ); };
                    if ($@) {
                        Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MalformedJSON->throw(
                            error_code => 'PAYMENT_ORDER_GET_FAILED_MALFORMED_RESPONSE_JSON',
                            error      => 'Malformed JSON from payment order get response',
                            content    => $res->decoded_content,
                            order_id   => $order_id,
                        );
                    }

                    unless ( $res_json->{paymentOrder} ) {
                        Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty->throw(
                            error_code => 'PAYMENT_ORDER_GET_FAILED_RESPONSE_PAYMENTORDER_MISSING',
                            error      => 'Response is missing a required property',
                            content    => $res->decoded_content,
                            order_id   => $order_id,
                            property   => 'paymentOrder'
                        );
                    }

                    unless ( $res_json->{operations} ) {
                        Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty->throw(
                            error_code => 'PAYMENT_ORDER_GET_FAILED_RESPONSE_OPERATIONS_MISSING',
                            error      => 'Response is missing a required property',
                            content    => $res->decoded_content,
                            order_id   => $order_id,
                            property   => 'operations'
                        );
                    }

                    # Get capture URL
                    my $operations = $res_json->{operations};
                    foreach my $op (@$operations) {
                        if ( $op->{rel} eq 'capture' ) {
                            $capture_url = $op->{href};
                        }
                    }

                    if ($capture_url) {

                        # Make sure "orderItems" exists in response JSON
                        if (   !$res_json->{paymentOrder}->{orderItems}
                            or !$res_json->{paymentOrder}->{orderItems}->{orderItemList} )
                        {
                            Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty->throw(
                                error_code => 'PAYMENT_ORDER_GET_FAILED_RESPONSE_ORDERITEMLIST_MISSING',
                                error      => 'Response is missing a required property',
                                content    => $res->decoded_content,
                                order_id   => $order_id,
                                property   => 'paymentOrder.orderItems.orderItemList'
                            );
                        } else {

                            # Start capture
                            my $paymentorder    = $res_json->{paymentOrder};
                            my @cap_req_headers = $self->get_headers;
                            my $cap_req_json    = {
                                "transaction" => {
                                    "description"    => "Capturing the authorized payment",
                                    "amount"         => $paymentorder->{amount},
                                    "vatAmount"      => $paymentorder->{vatAmount},
                                    "payeeReference" => $payee_reference . 'C',
                                    "orderItems"     => $paymentorder->{orderItems}->{orderItemList},
                                }
                            };
                            my $cap_res =
                                $ua->post( $capture_url, 'Content' => encode_json $cap_req_json, @cap_req_headers );
                            if ( $cap_res->is_success && $cap_res->code == 200 ) {
                                my $cap_res_json;

                                # Validate JSON input
                                $cap_res_json = eval { from_json( $cap_res->decoded_content ); };
                                if ($@) {
                                    Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MalformedJSON->throw(
                                        error_code => 'PAYMENT_CAPTURE_FAILED_MALFORMED_RESPONSE_JSON',
                                        error      => 'Malformed JSON from payment capture response',
                                        content    => $res->decoded_content,
                                        order_id   => $order_id,
                                    );
                                }

                                # Make sure "paymentOrder.status" exists in response JSON
                                if (   !exists $cap_res_json->{paymentOrder}
                                    or !exists $cap_res_json->{paymentOrder}->{status} )
                                {
                                    Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty
                                        ->throw(
                                        error_code => 'PAYMENT_CAPTURE_FAILED_CAPTURE_PAYMENTORDER_STATUS_MISSING',
                                        error      => 'Response is missing a required property',
                                        content    => $res->decoded_content,
                                        order_id   => $order_id,
                                        property   => 'paymentOrder.status'
                                        );
                                }

                                if ( lc( $cap_res_json->{paymentOrder}->{status} ) ne 'paid' ) {
                                    Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::NotCompleted->throw(
                                        error_code => 'PAYMENT_CAPTURE_FAILED_STATUS_NOT_PAID',
                                        error      => 'Payment status is not completed!',
                                        status     => $cap_res_json->{paymentOrder}->{status},
                                        content    => $res->decoded_content,
                                        order_id   => $order_id,
                                    );
                                }

                                $res = $ua->get( $url, @req_headers );
                                if ( $res->is_success && $res->code == 200 ) {

                                    # Validate JSON input
                                    $res_json = eval { from_json( $res->decoded_content ); };
                                    if ($@) {
                                        Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MalformedJSON
                                            ->throw(
                                            error_code => 'PAYMENT_ORDER_GET_FAILED_MALFORMED_RESPONSE_JSON',
                                            error      => 'Malformed JSON from payment order get response',
                                            content    => $res->decoded_content,
                                            order_id   => $order_id,
                                            );
                                    }

                                    $self->logger->info(
                                        "SWEDBANKPAY $order_id: Payment captured $table.order_id: $order_id, $table.paymentorder_id: $paymentorder_id"
                                    );
                                } else {
                                    Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError->throw(
                                        error_code => 'PAYMENT_ORDER_CAPTURE_NOT_SUCCESS',
                                        error      => 'Payment order capture was not successful',
                                        code       => $res->code,
                                        content    => $res->decoded_content,
                                        order_id   => $order_id,
                                    );
                                }
                            }
                        }
                    }

                    # Get paid URL
                    Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty->throw(
                        error_code => 'PAYMENT_ORDER_MISSING_PAID_URL',
                        error      => 'Response is missing a required property',
                        content    => $res->decoded_content,
                        order_id   => $order_id,
                        property   => 'paymentOrder.paid.id'
                    ) unless exists $res_json->{paymentOrder}->{paid}->{id};
                    my $paid_url = $res_json->{paymentOrder}->{paid}->{id};

                    if ($paid_url) {
                        my @paid_req_headers = $self->get_headers;
                        my $paid_res         = $ua->get( "$host" . $paid_url, @paid_req_headers );
                        if ( $paid_res->is_success && $paid_res->code == 200 ) {
                            my $paid_res_json;

                            # Validate JSON input
                            $paid_res_json = eval { from_json( $paid_res->decoded_content ); };
                            if ($@) {
                                Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MalformedJSON->throw(
                                    error_code => 'PAYMENT_PAID_FAILED_MALFORMED_RESPONSE_JSON',
                                    error      => 'Malformed JSON from payment order get response',
                                    content    => $res->decoded_content,
                                    order_id   => $order_id,
                                );
                            }

                            my $local_currency = $self->get_currency;
                            my $decimals       = decimal_precision($local_currency);

                            # ISO4217
                            if ( $decimals > 0 ) {
                                $amount = $amount * 10**$decimals;
                            }

                            if ( exists $paid_res_json->{paid}->{amount}
                                && $paid_res_json->{paid}->{amount} == $amount )
                            {
                                $paid = 1;
                                $self->add_payment_to_koha($order_id);
                                $self->logger->info(
                                    "SWEDBANKPAY $order_id: Payment paid, paymentorder_id: $paymentorder_id");
                            } else {
                                Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty->throw(
                                    error_code => 'PAYMENT_ORDER_MISSING_STATUS',
                                    error      => 'Response is missing a required property',
                                    content    => $res->decoded_content,
                                    order_id   => $order_id,
                                    property   => 'paymentOrder.status'
                                ) unless exists $res_json->{paymentOrder}->{status};
                                if ( lc( $res_json->{paymentOrder}->{status} ) ne 'paid' ) {
                                    my $paid_amount = $paid_res_json->{paid}->{amount} || '';
                                    $amount ||= 0;
                                    Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::PaymentError->throw(
                                        error_code => 'cancelled_payment',
                                        error      => 'Payment status is not paid',
                                        content    => "Payment amount '$paid_amount' != '$amount'",
                                        order_id   => $order_id,
                                        status     => $res_json->{paymentOrder}->{status},
                                    );
                                }
                                Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::PaymentError->throw(
                                    error_code => 'PAYMENT_PAID_FAILED_PAID_NOT_EXIST_IN_RESPONSE',
                                    error      => 'Property does not exist in response',
                                    content    => $res->decoded_content,
                                    order_id   => $order_id,
                                    property   => 'paid'
                                ) unless $paid_res_json->{paid};
                                Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::PaymentError->throw(
                                    error_code => 'PAYMENT_PAID_FAILED_PAID_AMOUNT_NOT_EQUAL_TO_TOTAL',
                                    error      => 'Payment paid amount does not equal to total amount',
                                    content => "Payment amount '" . $paid_res_json->{paid}->{amount} . "' != '$amount'",
                                    order_id => $order_id,
                                    status   => $res_json->{paymentOrder}->{status},
                                );

                            }
                        } else {
                            Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::PaymentError->throw(
                                error_code => 'PAYMENT_PAID_FAILED',
                                error      => 'Payment was failed',
                                content    => $paid_res->decoded_content,
                                order_id   => $order_id,
                            );
                        }
                    } else {
                        Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError->throw(
                            error_code => 'PAYMENT_PAID_MISSING_PAID_URL',
                            error      => 'Paid URL missing from response',
                            content    => $res->decoded_content,
                            order_id   => $order_id,
                        );
                    }

                    # Payment was failed
                    unless ($paid) {
                        $sth = $dbh->prepare("UPDATE $table SET status = ? WHERE order_id = ?");
                        $sth->execute( $transaction_status->{CANCELLED}, $order_id );
                    }
                } else {
                    Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError->throw(
                        error_code => 'PAYMENT_ORDER_GET_FAILED',
                        error      => 'Malformed JSON from payment order get response',
                        content    => $res->decoded_content,
                        order_id   => $order_id,
                    );
                }

            }
        );
    } catch {
        if ( blessed $_ ) {
            if ( $_->can('rethrow') ) {
                $_->rethrow;
            } else {
                die $_;
            }
        } else {
            die $_;
        }
    };

    return 1;
}

sub add_payment_to_koha {
    my ( $self, $order_id ) = @_;

    my $table              = $self->get_qualified_table_name('transactions');
    my $table_accountlines = $self->get_qualified_table_name('accountlines');
    my $dbh                = C4::Context->dbh;
    my $sth = $dbh->prepare("SELECT transaction_id, borrowernumber, amount, status FROM $table WHERE order_id = ?");
    $sth->execute($order_id);
    my ( $transaction_id, $borrowernumber, $amount, $status ) = $sth->fetchrow_array();
    if ( $status eq $transaction_status->{COMPLETED} ) {
        my $patron = Koha::Patrons->find($borrowernumber);
        Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::Transaction::AlreadyPaid->throw(
            error          => 'Payment is already paid',
            error_code     => 'already_paid',
            order_id       => $order_id,
            patron         => $patron ? $patron->unblessed : undef,
            transaction_id => $transaction_id,
        );
    }

    my $local_currency  = $self->get_currency;
    my $currency        = code2currency( $local_currency, LOCALE_CURR_ALPHA );
    my $currency_number = currency2code( $currency, LOCALE_CURR_NUMERIC );
    my $decimals        = decimal_precision($local_currency);

    $sth = $dbh->prepare("SELECT accountline_id FROM `$table_accountlines` WHERE transaction_id = ?");
    $sth->execute($transaction_id);

    my @accountline_ids;
    while ( my ($accline_id) = $sth->fetchrow_array ) {
        push @accountline_ids, $accline_id;
    }
    my $patron = Koha::Patrons->find($borrowernumber);
    my $lines  = Koha::Account::Lines->search(
        {
            accountlines_id   => { 'in' => \@accountline_ids },
            amountoutstanding => 0,
        }
    )->as_list;
    my $account        = Koha::Account->new( { patron_id => $borrowernumber } );
    my $accountline_id = $account->pay(
        {
            amount     => $amount,
            note       => 'Swedbank Pay Payment',
            library_id => $patron->branchcode,
            lines      => $lines,                   # Arrayref of Koha::Account::Line objects to pay
        }
    );

    # Support older Koha versions
    if ( ref($accountline_id) eq 'HASH' and exists $accountline_id->{payment_id} ) {
        $accountline_id = $accountline_id->{payment_id};
    }

    # Link payment to swedbank_pay_transactions
    $sth = $dbh->prepare("UPDATE $table SET accountline_id = ?, status = ? WHERE order_id = ?");
    $sth->execute( $accountline_id, $transaction_status->{COMPLETED}, $order_id );

    # Renew any items as required
    for my $line ( @{$lines} ) {
        next unless $line->itemnumber;
        my $item = Koha::Items->find( { itemnumber => $line->itemnumber } );

        # Renew if required
        if ( $self->_version_check('19.11.00') ) {
            if (   $line->debit_type_code eq "OVERDUE"
                && $line->status ne "UNRETURNED" )
            {
                if ( C4::Circulation::CheckIfIssuedToPatron( $line->borrowernumber, $item->biblionumber ) ) {
                    my ( $renew_ok, $error ) =
                        C4::Circulation::CanBookBeRenewed( $line->borrowernumber, $line->itemnumber, 0 );
                    if ($renew_ok) {
                        C4::Circulation::AddRenewal( $line->borrowernumber, $line->itemnumber );
                    }
                }
            }
        } else {
            if ( defined( $line->accounttype )
                && $line->accounttype eq "FU" )
            {
                if ( C4::Circulation::CheckIfIssuedToPatron( $line->borrowernumber, $item->biblionumber ) ) {
                    my ( $can, $error ) =
                        C4::Circulation::CanBookBeRenewed( $line->borrowernumber, $line->itemnumber, 0 );
                    if ($can) {

                        # Fix paid for fine before renewal to prevent
                        # call to _CalculateAndUpdateFine if
                        # CalculateFinesOnReturn is set.
                        C4::Circulation::_FixOverduesOnReturn( $line->borrowernumber, $line->itemnumber );

                        # Renew the item
                        my $datedue = C4::Circulation::AddRenewal( $line->borrowernumber, $line->itemnumber );
                    }
                }
            }
        }
    }
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
        my $currency = $self->retrieve_data('SwedbankCurrency') || 'SEK';
        $template->param(
            enable_opac_payments        => $self->retrieve_data('enable_opac_payments'),
            SwedbankPayMerchantToken    => $self->retrieve_data('SwedbankPayMerchantToken'),
            SwedbankPayKohaInstanceName => $self->retrieve_data('SwedbankPayKohaInstanceName'),
            SwedbankPayPayeeID          => $self->retrieve_data('SwedbankPayPayeeID'),
            SwedbankPayPayeeName        => $self->retrieve_data('SwedbankPayPayeeName'),
            SwedbankPayTosUrl           => $self->retrieve_data('SwedbankPayTosUrl'),
            SwedbankCurrency            => $currency,
            testMode                    => $self->retrieve_data('testMode'),
        );

        $self->output_html( $template->output() );
    } else {
        my $store_error_code;
        unless ( $cgi->param('SwedbankPayKohaInstanceName') ) {
            $store_error_code = 'EMPTY_KOHA_INSTANCE_NAME';
        }
        if ( length( $cgi->param('SwedbankPayKohaInstanceName') ) > 20 ) {
            $store_error_code = 'KOHA_INSTANCE_NAME_TOO_LONG';
        }

        if ($store_error_code) {
            my $template = $self->get_template( { file => 'configure.tt' } );

            my $currency = $self->retrieve_data('SwedbankCurrency') || 'SEK';
            $template->param(
                enable_opac_payments        => $self->retrieve_data('enable_opac_payments'),
                SwedbankPayKohaInstanceName => $self->retrieve_data('SwedbankPayKohaInstanceName'),
                SwedbankPayMerchantToken    => $self->retrieve_data('SwedbankPayMerchantToken'),
                SwedbankPayPayeeID          => $self->retrieve_data('SwedbankPayPayeeID'),
                SwedbankPayPayeeName        => $self->retrieve_data('SwedbankPayPayeeName'),
                SwedbankPayTosUrl           => $self->retrieve_data('SwedbankPayTosUrl'),
                SwedbankCurrency            => $self->retrieve_data('SwedbankCurrency'),
                testMode                    => $currency,
                error                       => $store_error_code,
            );

            return $self->output_html( $template->output() );

        }
        my $currency = $cgi->param('SwedbankCurrency') || 'SEK';
        $self->store_data(
            {
                enable_opac_payments        => scalar $cgi->param('enable_opac_payments'),
                SwedbankPayMerchantToken    => scalar $cgi->param('SwedbankPayMerchantToken'),
                SwedbankPayKohaInstanceName => scalar $cgi->param('SwedbankPayKohaInstanceName'),
                SwedbankPayPayeeID          => scalar $cgi->param('SwedbankPayPayeeID'),
                SwedbankPayPayeeName        => scalar $cgi->param('SwedbankPayPayeeName'),
                SwedbankPayTosUrl           => scalar $cgi->param('SwedbankPayTosUrl'),
                SwedbankCurrency            => $currency,
                testMode                    => scalar $cgi->param('testMode'),
            }
        );
        $self->go_home();
    }
}

sub install() {
    my ( $self, $args ) = @_;

    my $table              = $self->get_qualified_table_name('transactions');
    my $table_accountlines = $self->get_qualified_table_name('accountlines');

    my $transaction_status_list    = join( ",", map "'$_'", values(%$transaction_status) );
    my $transaction_status_default = "'" . $transaction_status->{PENDING} . "'";

    # Set database name as default instance name
    $self->store_data(
        {
            SwedbankPayKohaInstanceName => substr( C4::Context->config('database'), 0, 20 ),
        }
    );

    C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS `$table` (
            `transaction_id` INT( 11 ) NOT NULL AUTO_INCREMENT,
            `accountline_id` INT( 11 ),
            `borrowernumber` INT( 11 ),
            `order_id` VARCHAR( 50 ),
            `payee_reference` VARCHAR( 30 ) UNIQUE,
            `swedbank_paymentorder_id` VARCHAR( 255 ),
            `amount` decimal(28,6),
            `status` ENUM($transaction_status_list) DEFAULT $transaction_status_default,
            `updated` TIMESTAMP,
            PRIMARY KEY (`transaction_id`),
            CONSTRAINT `swed_main_ibfk_accountline_id` FOREIGN KEY (`accountline_id`) REFERENCES `accountlines` (`accountlines_id`) ON DELETE SET NULL ON UPDATE CASCADE,
            CONSTRAINT `swed_main_ibfk_borrowernumber` FOREIGN KEY (`borrowernumber`) REFERENCES `borrowers` (`borrowernumber`) ON DELETE SET NULL ON UPDATE CASCADE
        ) ENGINE = INNODB;
    " );

    C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS `${table_accountlines}` (
            `transaction_id` INT( 11 ) NOT NULL AUTO_INCREMENT,
            `accountline_id` INT( 11 ),
            PRIMARY KEY (`transaction_id`, `accountline_id`),
            CONSTRAINT `swed_tx_ibfk_transaction_id` FOREIGN KEY (`transaction_id`) REFERENCES `${table}` (`transaction_id`) ON DELETE CASCADE ON UPDATE CASCADE,
            CONSTRAINT `swed_tx_ibfk_accountline_id` FOREIGN KEY (`accountline_id`) REFERENCES `accountlines` (`accountlines_id`) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE = INNODB;
    " );

    return 1;
}

sub get_headers {
    my ($self) = @_;

    my $content_type = 'application/json;version=3.1';
    my $auth_token   = $self->retrieve_data('SwedbankPayMerchantToken');
    my @req_headers  = (
        "Content-Type"  => $content_type,
        "Accept"        => 'application/problem+json; q=1.0, application/json; q=0.9',
        "Authorization" => "Bearer $auth_token",
    );
}

sub get_host {
    my ($self) = @_;

    return $self->retrieve_data('testMode')
        ? 'https://api.externalintegration.payex.com'
        : 'https://api.payex.com';
}

sub logger {
    my ($self) = @_;

    return $self->{logger};
}

sub upgrade {
    my ( $self, $args ) = @_;

    $self->_db_upgrade_1;

    my $dt = Koha::DateUtils::dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

sub uninstall {
    my ( $self, $args ) = @_;

    my $table              = $self->get_qualified_table_name('transactions');
    my $table_accountlines = $self->get_qualified_table_name('accountlines');

    C4::Context->dbh->do("DROP TABLE $table");
    C4::Context->dbh->do("DROP TABLE $table_accountlines");

    return 1;
}

sub get_currency {
    my ($self)          = @_;
    my $active_currency = Koha::Acquisition::Currencies->get_active;
    my $local_currency  = $self->retrieve_data('SwedbankCurrency');
    if ($local_currency) {
        return $local_currency;
    } elsif ($active_currency) {
        $local_currency = $active_currency->isocode;
        $local_currency = $active_currency->currency unless defined $local_currency;
    } else {
        $local_currency = 'SEK';
    }
    return $local_currency;
}

sub get_language {
    my ($self) = @_;
    my $language = C4::Languages::getlanguage( $self->{'cgi'} ) || "sv-SE";
    $language = 'en-US' if $language eq 'en';    # convert en to en-US
                                                 # TODO: remove when PLUGIN_DIR gets automatically passed into template

    return $language;
}

sub _db_upgrade_1 {
    my ($self) = @_;

    return if $self->SUPER::_version_compare( $self->get_metadata->{version}, '3.1.0' ) == 1;

    my $dbh = C4::Context->dbh;

    my $old_table          = $self->get_qualified_table_name('swedbank_pay_transactions');
    my $table              = $self->get_qualified_table_name('transactions');
    my $table_accountlines = $self->get_qualified_table_name('accountlines');

    try { $dbh->do("RENAME TABLE `${old_table}_ac` TO `$table_accountlines`;") } catch { };
    try { $dbh->do("RENAME TABLE `$old_table` TO `$table`;") } catch                   { };
    $dbh->do( "
        CREATE TABLE IF NOT EXISTS `$table_accountlines` (
            `transaction_id` INT( 11 ) NOT NULL AUTO_INCREMENT,
            `accountline_id` INT( 11 ),
            PRIMARY KEY (`transaction_id`, `accountline_id`),
            CONSTRAINT `swed_tx_ibfk_transaction_id` FOREIGN KEY (`transaction_id`) REFERENCES `${table}` (`transaction_id`) ON DELETE CASCADE ON UPDATE CASCADE,
            CONSTRAINT `swed_tx_ibfk_accountline_id` FOREIGN KEY (`accountline_id`) REFERENCES `accountlines` (`accountlines_id`) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE = INNODB;
    " );

    try {
        $dbh->do(
            "ALTER TABLE ${table} ADD CONSTRAINT `swed_main_ibfk_borrowernumber` FOREIGN KEY (`borrowernumber`) REFERENCES `borrowers` (`borrowernumber`) ON DELETE SET NULL ON UPDATE CASCADE;"
        );
        $dbh->do(
            "ALTER TABLE ${table} ADD CONSTRAINT `swed_main_ibfk_accountline_id` FOREIGN KEY (`accountline_id`) REFERENCES `accountlines` (`accountlines_id`) ON DELETE SET NULL ON UPDATE CASCADE;"
        );
    } catch {
    };

    try {
        my $sth = $dbh->prepare("SELECT transaction_id, accountlines_ids FROM `$table`");
        $sth->execute;
        while ( my ( $transaction_id, $accountlines_ids ) = $sth->fetchrow_array ) {
            next unless $accountlines_ids;

            my @accountlines = split( ' ', $accountlines_ids );
            foreach my $accountline_id (@accountlines) {
                $dbh->do("INSERT IGNORE INTO `$table_accountlines` (transaction_id, accountline_id) VALUES (?, ?);");
            }
        }
    } catch {
    };

    try {
        $dbh->do("ALTER TABLE ${table} DROP accountlines_ids;");
    } catch {
    };
}

1;
