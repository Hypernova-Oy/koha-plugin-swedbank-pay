#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Test::Exception;
use Test::NoWarnings;
use Test::More tests => 5;
use Test::Mojo;
use Test::Warn;

use t::lib::TestBuilder;
use t::lib::Mocks;
use t::lib::Mocks::Logger;

use FindBin;
use lib "$FindBin::Bin/..";
use t::lib::SwedbankPay::Util;

use Koha::Account;
use Koha::Database;
use Koha::Patrons;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

my $logger = t::lib::SwedbankPay::Util::mock_logger();

use_ok('Koha::Plugin::Com::imCode::SwedbankPay');

my $swedbankpay = Koha::Plugin::Com::imCode::SwedbankPay->new;

my $mocked_swedbank = Test::MockModule->new("Koha::Plugin::Com::imCode::SwedbankPay");
my $mocked_lwp      = Test::MockModule->new("LWP::UserAgent");

subtest 'create_transaction() tests' => sub {

    plan tests => 12;

    $schema->storage->txn_begin;

    my $dbh = $schema->storage->dbh;

    my ( $patron, $amount, $amount_cents, $sum_cents, $debit_line, $template ) =
        t::lib::SwedbankPay::Util::create_test_data(4);

    my $accountlines = $schema->resultset('Accountline')->search( { borrowernumber => $patron->borrowernumber } );
    $mocked_lwp->mock(
        'post' => sub {
            my ( $self, @parameters ) = @_;
            warn $parameters[2];    # json
            die;
        }
    );

    warning_like {
        $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );
    }
           qr /"operation":"Purchase"/
        && qr/"currency":"SEK"/
        && qr/"amount":$sum_cents/
        && qr/"amount":$amount_cents/
        && qr/"unitPrice":$amount_cents/
        && qr/"vatPercent":0/
        && qr/"quantity":1/,
        'When creating a transaction to be sent to Swedbank, found expected parameters from request JSON';

    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                400, 'OK', HTTP::Headers->new, <<HERE
{"error":"test"}
HERE
            );
        }
    );

    $logger->clear();
    $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );
    $logger->error_like(
        qr/'error_code' => 'PAYMENT_ORDER_CREATE_FAILED'/,
        'Status != 201 handled'
    );

    $mocked_lwp->mock(
        'post' => sub {
            die "Unblessed exception";
        }
    );

    $logger->clear();
    $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );
    $logger->error_like(
        qr/Swedbank Payments Plugin: Unblessed exception/,
        'Unblessed exception handled'
    );

    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                201, 'OK', HTTP::Headers->new, <<HERE
{
  notvalidjson"
}
HERE
            );
        }
    );

    $logger->clear();
    $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );
    $logger->error_like(
        qr/'error_code' => 'PAYMENT_ORDER_CREATE_FAILED_MALFORMED_RESPONSE_JSON'/,
        'Malformed JSON exception'
    );

    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                201, 'OK', HTTP::Headers->new, <<HERE
{}
HERE
            );
        }
    );

    $logger->clear();
    $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );
    $logger->error_like(
        qr/'error_code' => 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_OPERATIONS_MISSING'/,
        'JSON missing property "operations" handled'
    );

    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                201, 'OK', HTTP::Headers->new, <<HERE
{"operations": []}
HERE
            );
        }
    );

    $logger->clear();
    $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );
    $logger->error_like(
        qr/'error_code' => 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_OPERATIONS_REDIRECT_URL_MISSING'/,
        'JSON missing property "redirect-checkout" handled'
    );

    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                201, 'OK', HTTP::Headers->new, <<HERE
{"operations": [{"rel":"redirect-checkout", "href": "test"}]}
HERE
            );
        }
    );

    $logger->clear();
    $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );
    $logger->error_like(
        qr/'error_code' => 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_PAYMENTORDER_MISSING'/,
        'JSON missing property "paymentOrder" handled'
    );

    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                201, 'OK', HTTP::Headers->new, <<HERE
{"operations": [{"rel":"redirect-checkout", "href": "test"}], "paymentOrder": {}}
HERE
            );
        }
    );

    $logger->clear();
    $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );
    $logger->error_like(
        qr/'error_code' => 'PAYMENT_ORDER_CREATE_FAILED_RESPONSE_PAYMENTORDER_ID_MISSING'/,
        'JSON missing property "paymentOrder.id" handled'
    );

    my $borrowernumber = $patron->borrowernumber;
    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                201, 'OK', HTTP::Headers->new, <<HERE
{"operations": [{"rel":"redirect-checkout", "href": "test"}], "paymentOrder": { "id": "$borrowernumber-paymentorder" }}
HERE
            );
        }
    );

    $logger->clear();
    my ( $error, $order_id, $transaction_id, $paymentorder_id, $redirect_url ) =
        $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );
    $logger->error_like(
        qr/^$/,
        'Successful response handled'
    );
    is( $error, undef, '$error is undef' );

    my $table = $swedbankpay->get_qualified_table_name('transactions');
    my $sth   = $dbh->prepare("SELECT * FROM $table WHERE transaction_id=?");
    $sth->execute($transaction_id);

    my $found    = 0;
    my $found_tx = {};
    while ( my $row = $sth->fetchrow_hashref ) {
        $found_tx = $row;
        $found++;
    }

    is( $found,                                1,                'Found correct transaction' );
    is( $found_tx->{swedbank_paymentorder_id}, $paymentorder_id, 'Found corrent paymentorder_id' );

    $logger->clear();
    $schema->storage->txn_rollback;
};

subtest 'process_transaction() tests' => sub {

    plan tests => 32;

    $schema->storage->txn_begin;

    my $dbh = $schema->storage->dbh;

    my $result;
    my ( $patron, $amount, $amount_cents, $sum_cents, $debit_line, $template ) =
        t::lib::SwedbankPay::Util::create_test_data(4);
    my $borrowernumber = $patron->borrowernumber;

    my $accountlines = $schema->resultset('Accountline')->search( { borrowernumber => $patron->borrowernumber } );
    my ( $error, $order_id, $transaction_id, $paymentorder_id, $redirect_url ) =
        $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{
  notvalidjson"
}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MalformedJSON', 'Malformed JSON exception handled';

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty', 'Missing property handled';
    is( $@->error_code, 'PAYMENT_ORDER_GET_FAILED_RESPONSE_PAYMENTORDER_MISSING', 'correct error_code' );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{}}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty', 'Missing property handled';
    is( $@->error_code, 'PAYMENT_ORDER_GET_FAILED_RESPONSE_OPERATIONS_MISSING', 'correct error_code' );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{}, "operations": [{"rel": "capture", "href": "test" }]}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty', 'Missing property handled';
    is( $@->error_code, 'PAYMENT_ORDER_GET_FAILED_RESPONSE_ORDERITEMLIST_MISSING', 'correct error_code' );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{"orderItems": {"orderItemList":[]}}, "operations": [{"rel": "capture", "href": "test" }]}
HERE
            );
        }
    );

    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{invalidjson"}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MalformedJSON', 'Malformed JSON exception handled';
    is( $@->error_code, 'PAYMENT_CAPTURE_FAILED_MALFORMED_RESPONSE_JSON', 'correct error_code' );

    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty', 'Malformed JSON exception handled';
    is( $@->error_code, 'PAYMENT_CAPTURE_FAILED_CAPTURE_PAYMENTORDER_STATUS_MISSING', 'correct error_code' );

    $mocked_lwp->mock(
        'post' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder": { "status": "test" }}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::NotCompleted', 'Payment order is not paid';
    is( $@->error_code, 'PAYMENT_CAPTURE_FAILED_STATUS_NOT_PAID', 'correct error_code' );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{"orderItems": {"orderItemList":[]}, "paid": { }}, "operations": []}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty', 'Missing property handled';
    is( $@->error_code, 'PAYMENT_ORDER_MISSING_PAID_URL', 'correct error_code' );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{"orderItems": {"orderItemList":[]}, "paid": { "id": "test" }}, "operations": []}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::MissingProperty', 'Missing property handled';
    is( $@->error_code, 'PAYMENT_ORDER_MISSING_STATUS', 'correct error_code' );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{"orderItems": {"orderItemList":[]}, "paid": { "id": "test" }, "status": "notpaid"}, "operations": []}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::PaymentError', 'Missing property handled';
    is( $@->error_code, 'cancelled_payment', 'correct error_code' );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{"orderItems": {"orderItemList":[]}, "paid": { "id": "test" }, "status": "paid", "amount": 1}, "operations": []}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError::PaymentError', 'Missing property handled';
    is( $@->error_code, 'PAYMENT_PAID_FAILED_PAID_AMOUNT_NOT_EQUAL_TO_TOTAL', 'correct error_code' );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                400, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{"orderItems": {"orderItemList":[]}, "paid": { "id": "test", "amount": 50000 }, "status": "paid"}, "operations": []}
HERE
            );
        }
    );

    throws_ok {
        $result = $swedbankpay->process_transaction($order_id);

    }
    'Koha::Plugin::Com::imCode::SwedbankPay::Exceptions::APIError', 'Status code != 200 handled';
    is( $@->error_code, 'PAYMENT_ORDER_GET_FAILED', 'correct error_code' );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{"orderItems": {"orderItemList":[]}, "paid": { "id": "test", "amount": 50000 }, "status": "paid"}, "operations": []}
HERE
            );
        }
    );

    $logger->clear();
    $result = $swedbankpay->process_transaction($order_id);
    $logger->info_like(
        qr/SWEDBANKPAY $order_id: Payment paid, paymentorder_id: $paymentorder_id/,
        'Logger logged payment as paid'
    );

    $accountlines = Koha::Account::Lines->search( { borrowernumber => $patron->borrowernumber } )->unblessed;
    is( scalar @$accountlines,        6,                      'Found six accountlines row' );
    is( $accountlines->[0]->{amount}, '100.000000',           'First was the lost item' );
    is( $accountlines->[1]->{amount}, '100.000000',           'Second was the second lost item' );
    is( $accountlines->[2]->{amount}, '100.000000',           'Second was the third lost item' );
    is( $accountlines->[3]->{amount}, '100.000000',           'Second was the fourth lost item' );
    is( $accountlines->[4]->{amount}, '100.000000',           'Second was the fifth lost item' );
    is( $accountlines->[5]->{amount}, '-500.000000',          'Sixth was the payment itself' );
    is( $accountlines->[5]->{note},   'Swedbank Pay Payment', 'Found correct payment note' );

    $schema->storage->txn_rollback;
};

subtest 'test float to int conversions' => sub {
    plan tests => 12;

    my @amount_list = (
        [ '155.00', '1.52', '-156.52' ],
        [ '0.6',    '0.2',  '-0.8' ],
    );
    foreach my $amounts (@amount_list) {

        $schema->storage->txn_begin;

        my $dbh = $schema->storage->dbh;

        my $result;
        my ( $patron, $amount, $amount_cents, $sum_cents, $debit_line, $template ) =
            t::lib::SwedbankPay::Util::create_test_data(4);
        my $borrowernumber = $patron->borrowernumber;

        $patron = $builder->build_object( { class => 'Koha::Patrons' } );
        my $debit_line1 = Koha::Account->new( { patron_id => $patron->borrowernumber } )->add_debit(
            {
                amount      => $amounts->[0],
                description => 'test1',
                type        => 'LOST',
                interface   => 'intranet',
            }
        );
        my $debit_line2 = Koha::Account->new( { patron_id => $patron->borrowernumber } )->add_debit(
            {
                amount      => $amounts->[1],
                description => 'test2',
                type        => 'LOST',
                interface   => 'intranet',
            }
        );

        $mocked_lwp->mock(
            'post' => sub {
                return HTTP::Response->new(
                    201, 'OK', HTTP::Headers->new, <<HERE
{"operations": [{"rel":"redirect-checkout", "href": "test"}], "paymentOrder": { "id": "$borrowernumber-paymentorder" }}
HERE
                );
            }
        );

        my $accountlines = $schema->resultset('Accountline')->search( { borrowernumber => $patron->borrowernumber } );
        my ( $error, $order_id, $transaction_id, $paymentorder_id, $redirect_url ) =
            $swedbankpay->create_transaction( $patron->borrowernumber, $accountlines, $template );

        $amount_cents = sprintf( "%.0f", sprintf( "%.2f", $amounts->[0] + $amounts->[1] ) * 100 );
        $mocked_lwp->mock(
            'get' => sub {
                return HTTP::Response->new(
                    200, 'OK', HTTP::Headers->new, <<HERE
{"paymentOrder":{"orderItems": {"orderItemList":[]}, "paid": { "id": "test", "amount": $amount_cents }, "status": "paid"}, "operations": []}
HERE
                );
            }
        );

        $logger->clear();
        $result = $swedbankpay->process_transaction($order_id);
        $logger->info_like(
            qr/SWEDBANKPAY $order_id: Payment paid, paymentorder_id: $paymentorder_id/,
            'Logger logged payment as paid'
        );

        $accountlines = Koha::Account::Lines->search( { borrowernumber => $patron->borrowernumber } )->unblessed;
        is( scalar @$accountlines, 3, 'Found three accountlines row' );
        is(
            $accountlines->[0]->{amount}, sprintf( "%.6f", $amounts->[0] ),
            'First was the lost item with amount ' . $amounts->[0]
        );
        is(
            $accountlines->[1]->{amount}, sprintf( "%.6f", $amounts->[1] ),
            'Second was the second lost item with amount ' . $amounts->[1]
        );
        is(
            $accountlines->[2]->{amount}, sprintf( "%.6f", $amounts->[2] ),
            'Third was the payment itself with amount ' . $amounts->[2]
        );
        is( $accountlines->[2]->{note}, 'Swedbank Pay Payment', 'Found correct payment note' );

        $schema->storage->txn_rollback;
    }
};
