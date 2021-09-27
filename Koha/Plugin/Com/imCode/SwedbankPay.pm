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

    my $language = C4::Languages::getlanguage($self->{'cgi'}) || "sv-SE";
    $language = 'en-US' if $language eq 'en'; # convert en to en-US
    # TODO: remove when PLUGIN_DIR gets automatically passed into template
    $template->param(
        LANG => $language,
        PLUGIN_DIR => $self->bundle_path,
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
                "cancelUrl" => $complete_url,
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
    my $logger = Koha::Logger->get;

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my $language = C4::Languages::getlanguage($self->{'cgi'}) || "sv-SE";
    $language = 'en-US' if $language eq 'en'; # convert en to en-US
    # TODO: remove when PLUGIN_DIR gets automatically passed into template
    $template->param(
        LANG => $language,
        PLUGIN_DIR => $self->bundle_path,
    );

    my $order_id = $cgi->param('order_id');

    my $table = $self->get_qualified_table_name('swedbank_pay_transactions');
    my $dbh   = C4::Context->dbh;
    my $sth   = $dbh->prepare(
        "SELECT transaction_id, swedbank_paymentorder_id, payee_reference, amount FROM $table WHERE borrowernumber = ? AND order_id = ?");
    $sth->execute($borrowernumber, $order_id);
    my ($transaction_id, $paymentorder_id, $payee_reference, $amount) = $sth->fetchrow_array();

    if ( !$transaction_id or !$paymentorder_id ) {
        $template->param(
            borrower => scalar Koha::Patrons->find($borrowernumber),
            message  => 'TRANSACTION_NOT_FOUND'
        );
        $logger->warn( "SWEDBANKPAY $order_id: Transaction not found for borrowernumber: $borrowernumber, order_id: $order_id" );
        return $self->output_html( $template->output() );
    }

    my ( $success, $error_code ) = $self->process_transaction( $order_id );

    if ( !$success ) {
        $template->param(
            message => $error_code,
            order_id  => $order_id,
        );
        $logger->error( "SWEDBANKPAY $order_id: $error_code" );
    }

    $sth   = $dbh->prepare(
        "SELECT accountline_id, status FROM $table WHERE borrowernumber = ? AND order_id = ?");
    $sth->execute($borrowernumber, $order_id);
    my ($accountline_id, $status) = $sth->fetchrow_array();

    if ( $status eq $transaction_status->{CANCELLED} ) {
        $template->param(
            message => 'cancelled_payment',
            order_id  => $order_id,
        );
        return $self->output_html( $template->output() );
    }

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

sub process_transaction {
    my ( $self, $order_id ) = @_;

    my $logger = Koha::Logger->get;
    my $table = $self->get_qualified_table_name('swedbank_pay_transactions');
    my $dbh   = C4::Context->dbh;
    my $sth   = $dbh->prepare(
        "SELECT transaction_id, swedbank_paymentorder_id, payee_reference, amount FROM $table WHERE order_id = ?");
    $sth->execute( $order_id );
    my ($transaction_id, $paymentorder_id, $payee_reference, $amount) = $sth->fetchrow_array();

    # Check payment status
    my $ua = LWP::UserAgent->new;

    my $host =
      $self->retrieve_data('testMode')
      ? 'api.externalintegration.payex.com'
      : 'api.payex.com';
    my $url = "https://$host"."$paymentorder_id".'?$expand=orderItems,payments,currentPayment';

    my $content_type = 'application/json; charset=utf-8';
    my $auth_token = $self->retrieve_data('SwedbankPayMerchantToken');
    my @req_headers = (
        "Content-Type" => $content_type,
        "Accept" => 'application/problem+json; q=1.0, application/json; q=0.9',
        "Authorization" => "Bearer $auth_token",
    );

    my $res = $ua->get( $url, @req_headers );
    my $capture_url;
    my $paid = 0;
    my $error;
    if ( $res->is_success && $res->code == 200 ) {
        my $res_json;

        # Validate JSON input
        $res_json = eval { from_json( $res->decoded_content ); };
        if ( $@ ) {
            $error = 'PAYMENT_ORDER_GET_FAILED_MALFORMED_RESPONSE_JSON';
            $logger->error( "SWEDBANKPAY $order_id: Malformed response JSON: " . $res->decoded_content );
        }

        unless ( $res_json->{paymentOrder} ) {
            $error = 'PAYMENT_ORDER_GET_FAILED_RESPONSE_PAYMENTORDER_MISSING';
        }

        unless ( $res_json->{operations} ) {
            $error = 'PAYMENT_ORDER_GET_FAILED_RESPONSE_OPERATIONS_MISSING';
        }

        # Get create-paymentorder-capture URL
        my $operations = $res_json->{operations};
        foreach my $op ( @$operations ) {
            if ( $op->{rel} eq 'create-paymentorder-capture' ) {
                $capture_url = $op->{href};
            }
        };

        if ( $capture_url ) {
            # Make sure "orderItems" exists in response JSON
            if ( !$res_json->{paymentOrder}->{orderItems} or !$res_json->{paymentOrder}->{orderItems}->{orderItemList} ) {
                $error = 'PAYMENT_ORDER_GET_FAILED_RESPONSE_ORDERITEMLIST_MISSING';
            } else {
                # Start capture
                my $paymentorder = $res_json->{paymentOrder};
                my @cap_req_headers = (
                    "Content-Type" => $content_type,
                    "Accept" => 'application/problem+json; q=1.0, application/json; q=0.9',
                    "Authorization" => "Bearer $auth_token",
                );
                my $cap_req_json = {
                    "transaction" => {
                        "description" => "Capturing the authorized payment",
                        "amount" => $paymentorder->{amount},
                        "vatAmount" => $paymentorder->{vatAmount},
                        "payeeReference" => $payee_reference . 'C',
                        "orderItems" => $paymentorder->{orderItems}->{orderItemList},
                    }
                };
                my $cap_res = $ua->post( $capture_url, 'Content' => encode_json $cap_req_json, @cap_req_headers );
                if ( $cap_res->is_success && $cap_res->code == 200 ) {
                    my $cap_res_json;

                    # Validate JSON input
                    $cap_res_json = eval { from_json( $cap_res->decoded_content ); };
                    if ( $@ ) {
                        $error = 'PAYMENT_CAPTURE_FAILED_MALFORMED_RESPONSE_JSON';
                        $logger->error( "SWEDBANKPAY $order_id: Malformed response JSON: " . $cap_res->decoded_content );
                    }

                    # Make sure "capture.transaction" exists in response JSON
                    if ( !$cap_res_json->{capture} or !$cap_res_json->{capture}->{transaction} ) {
                        $error = 'PAYMENT_CAPTURE_FAILED_CAPTURE_TRANSACTION_MISSING';
                    }

                    if ( lc($cap_res_json->{capture}->{transaction}->{state}) ne 'completed' ) {
                        $error = 'PAYMENT_CAPTURE_FAILED_STATE_NOT_COMPLETED';
                    }

                    unless ( $error ) {
                        $logger->info( "SWEDBANKPAY $order_id: Payment captured $table.order_id: $order_id, $table.paymentorder_id: $paymentorder_id" );
                        $res = $ua->get( $url, @req_headers );
                        if ( $res->is_success && $res->code == 200 ) {
                            # Validate JSON input
                            $res_json = eval { from_json( $res->decoded_content ); };
                            if ( $@ ) {
                                $error = 'PAYMENT_ORDER_GET_FAILED_MALFORMED_RESPONSE_JSON';
                                $logger->error( "SWEDBANKPAY $order_id: Malformed response JSON: " . $res->decoded_content );
                            }
                        }
                    }
                } else {
                    $error = 'PAYMENT_CAPTURE_FAILED';
                    $logger->error( "SWEDBANKPAY $order_id: API error (" . $cap_res->code . '): ' . Data::Dumper::Dumper( $cap_res->decoded_content ) );
                }
            }
        }

        # Get paid-paymentorder URL
        my $paid_url;
        $operations = $res_json->{operations};
        foreach my $op ( @$operations ) {
            if ( $op->{rel} eq 'paid-paymentorder' ) {
                $paid_url = $op->{href};
            }
        };

        # Get failed-paymentorder URL
        my $failed_url;
        $operations = $res_json->{operations};
        foreach my $op ( @$operations ) {
            if ( $op->{rel} eq 'failed-paymentorder' ) {
                $failed_url = $op->{href};
            }
        };

        # Get aborted-paymentorder URL
        my $aborted_url;
        $operations = $res_json->{operations};
        foreach my $op ( @$operations ) {
            if ( $op->{rel} eq 'aborted-paymentorder' ) {
                $failed_url = $op->{href};
            }
        };

        # Payment was successful
        if ( $paid_url ) {
            my @paid_req_headers = (
                "Content-Type" => $content_type,
                "Accept" => 'application/problem+json; q=1.0, application/json; q=0.9',
                "Authorization" => "Bearer $auth_token",
            );
            my $paid_res = $ua->get( $paid_url, @paid_req_headers );
            if ( $paid_res->is_success && $paid_res->code == 200 ) {
                my $paid_res_json;

                # Validate JSON input
                $paid_res_json = eval { from_json( $paid_res->decoded_content ); };
                if ( $@ ) {
                    $error = 'PAYMENT_PAID_FAILED_MALFORMED_RESPONSE_JSON';
                    $logger->error( "SWEDBANKPAY $order_id: Malformed response JSON: " . $paid_res->decoded_content );
                }

                my $active_currency = Koha::Acquisition::Currencies->get_active;
                my $local_currency;
                if ($active_currency) {
                    $local_currency = $active_currency->isocode;
                    $local_currency = $active_currency->currency unless defined $local_currency;
                } else {
                    $local_currency = 'EUR';
                }
                my $decimals = decimal_precision($local_currency);

                # ISO4217
                if ($decimals > 0) {
                    $amount = $amount * 10**$decimals;
                }

                if ( $paid_res_json->{paid} and $paid_res_json->{paid}->{amount} == $amount) {
                    $paid = 1;
                    $logger->info( "SWEDBANKPAY $order_id: Payment paid $table.order_id: $order_id, $table.paymentorder_id: $paymentorder_id" );
                    $self->add_payment_to_koha( $order_id );
                }
            } else {
                $error = 'PAYMENT_PAID_FAILED';
                $logger->error( "SWEDBANKPAY $order_id: API error (" . $paid_res->code . '): ' . Data::Dumper::Dumper( $paid_res->decoded_content ) );
            }
        }

        # Payment was failed
        if ( ( $failed_url or $aborted_url ) and not $paid_url ) {
            $sth = $dbh->prepare(
                "UPDATE $table SET status = ? WHERE order_id = ?");
            $sth->execute( $transaction_status->{CANCELLED}, $order_id );
        }
    } else {
        $error = 'PAYMENT_ORDER_GET_FAILED';
        $logger->error( "SWEDBANKPAY $order_id: API error (" . $res->code . '): ' . Data::Dumper::Dumper( $res->decoded_content ) );
    }

    if ( $error ) {
        return ( 0, $error );
    } else {
        return ( 1, undef );
    }
}
sub add_payment_to_koha {
    my ( $self, $order_id ) = @_;

    my $table = $self->get_qualified_table_name('swedbank_pay_transactions');
    my $dbh   = C4::Context->dbh;
    my $sth   = $dbh->prepare(
        "SELECT borrowernumber, accountlines_ids, amount, status FROM $table WHERE order_id = ?");
    $sth->execute($order_id);
    my ($borrowernumber, $accountlines_string, $amount, $status) = $sth->fetchrow_array();
    if ( $status eq $transaction_status->{COMPLETED} ) {
        return; #already completed
    }

    my $active_currency = Koha::Acquisition::Currencies->get_active;
    my $local_currency;
    if ($active_currency) {
        $local_currency = $active_currency->isocode;
        $local_currency = $active_currency->currency unless defined $local_currency;
    } else {
        $local_currency = 'EUR';
    }
    my $currency = code2currency($local_currency, LOCALE_CURR_ALPHA);
    my $currency_number = currency2code($currency, LOCALE_CURR_NUMERIC);
    my $decimals = decimal_precision($local_currency);

    my @accountline_ids = split(' ', $accountlines_string);
    my $borrower = Koha::Patrons->find($borrowernumber);
    my $lines = Koha::Account::Lines->search(
        { accountlines_id => { 'in' => \@accountline_ids } } )->as_list;
    my $account = Koha::Account->new( { patron_id => $borrowernumber } );
    my $accountline_id = $account->pay(
        {
            amount     => $amount,
            note       => 'Swedbank Pay Payment',
            library_id => $borrower->branchcode,
            lines => $lines,    # Arrayref of Koha::Account::Line objects to pay
        }
    );

    # Support older Koha versions
    if ( ref($accountline_id) eq 'HASH' and exists $accountline_id->{payment_id} ) {
        $accountline_id = $accountline_id->{payment_id};
    }

    # Link payment to swedbank_pay_transactions
    $sth   = $dbh->prepare(
        "UPDATE $table SET accountline_id = ?, status = ? WHERE order_id = ?");
    $sth->execute( $accountline_id, $transaction_status->{COMPLETED}, $order_id );

	# Renew any items as required
    for my $line ( @{$lines} ) {
        next unless $line->itemnumber;
        my $item =
          Koha::Items->find( { itemnumber => $line->itemnumber } );

        # Renew if required
        if ( $self->_version_check('19.11.00') ) {
            if (   $line->debit_type_code eq "OVERDUE"
            && $line->status ne "UNRETURNED" )
            {
            if (
                C4::Circulation::CheckIfIssuedToPatron(
                $line->borrowernumber, $item->biblionumber
                )
              )
            {
                my ( $renew_ok, $error ) =
                  C4::Circulation::CanBookBeRenewed(
                $line->borrowernumber, $line->itemnumber, 0 );
                if ($renew_ok) {
                C4::Circulation::AddRenewal(
                    $line->borrowernumber, $line->itemnumber );
                }
            }
            }
        }
        else {
            if ( defined( $line->accounttype )
            && $line->accounttype eq "FU" )
            {
                if (
                    C4::Circulation::CheckIfIssuedToPatron(
                    $line->borrowernumber, $item->biblionumber
                    )
                  )
                {
                    my ( $can, $error ) =
                      C4::Circulation::CanBookBeRenewed(
                    $line->borrowernumber, $line->itemnumber, 0 );
                    if ($can) {

                    # Fix paid for fine before renewal to prevent
                    # call to _CalculateAndUpdateFine if
                    # CalculateFinesOnReturn is set.
                    C4::Circulation::_FixOverduesOnReturn(
                        $line->borrowernumber, $line->itemnumber );

                    # Renew the item
                    my $datedue =
                      C4::Circulation::AddRenewal(
                        $line->borrowernumber, $line->itemnumber );
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

