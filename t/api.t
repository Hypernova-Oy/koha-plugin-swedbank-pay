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
use Test::More tests => 3;
use Test::Mojo;
use Test::Warn;

use t::lib::Mocks;
use t::lib::Mocks::Logger;
use t::lib::TestBuilder;

use FindBin;
use lib "$FindBin::Bin/..";
use t::lib::SwedbankPay::Util;

use Koha::Account;
use Koha::Database;
use Koha::Patrons;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

my $logger = t::lib::SwedbankPay::Util::mock_logger();

my $t = Test::Mojo->new('Koha::REST::V1');
t::lib::Mocks::mock_preference( 'RESTBasicAuth', 1 );

use_ok('Koha::Plugin::Com::imCode::SwedbankPay');

my $swedbankpay = Koha::Plugin::Com::imCode::SwedbankPay->new;

my $mocked_swedbank = Test::MockModule->new("Koha::Plugin::Com::imCode::SwedbankPay");
my $mocked_lwp      = Test::MockModule->new("LWP::UserAgent");

my $api_namespace = $swedbankpay->api_namespace;
my $api_url       = "/api/v1/contrib/$api_namespace";

subtest 'callback() tests' => sub {

    plan tests => 11;

    my $dbh = $schema->storage->dbh;
    $schema->storage->txn_begin;

    my ( $patron, $amount, $amount_cents, $sum_cents, $debit_line, $template ) =
        t::lib::SwedbankPay::Util::create_test_data();

    $t->post_ok( "$api_url/callback/nonexistent" => json => { not => "important" } )->status_is(200);
    $logger->error_like( qr/error_code' => 'TRANSACTION_NOT_FOUND'/, 'nonexistent transaction not found' );

    my $borrowernumber = $patron->borrowernumber;
    $amount = $debit_line->amount;
    my $table = $swedbankpay->get_qualified_table_name("transactions");
    $dbh->do(
        "INSERT INTO $table (borrowernumber, swedbank_paymentorder_id, order_id, amount) VALUES ($borrowernumber, '/psp/paymentorders/$borrowernumber', '$borrowernumber-test', '$amount');"
    );

    $mocked_lwp->mock(
        'get' => sub {
            return HTTP::Response->new(
                200, 'OK', HTTP::Headers->new, <<HERE
{
  "paymentOrder": {
    "status": "Paid",
    "paid": {
      "id": "1",
      "amount": $amount_cents
    }
  },
  "operations": []
}
HERE
            );
        }
    );

    $logger->clear();
    $t->post_ok( "$api_url/callback/$borrowernumber-test" => json => { not => "important" } )->status_is(200);
    $logger->error_is( '', 'No errors logged while receiving callback.' );
    $logger->warn_is( '', 'No warnigns logged while receiving callback.' );
    my $accountlines = Koha::Account::Lines->search( { borrowernumber => $patron->borrowernumber } )->unblessed;

    is( scalar @$accountlines,        2,                      'Found two accountlines row' );
    is( $accountlines->[0]->{amount}, '100.000000',           'First was the lost item' );
    is( $accountlines->[1]->{amount}, '-100.000000',          'Second was the payment' );
    is( $accountlines->[1]->{note},   'Swedbank Pay Payment', 'Found correct payment note' );

    $schema->storage->txn_rollback;
};
