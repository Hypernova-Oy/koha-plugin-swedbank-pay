#!/usr/bin/perl
  
# Copyright 2015 PTFS Europe
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use CGI qw( -utf8 );

use C4::Context;
use C4::Circulation;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;
use Koha::Account::Line;
use Koha::Patrons;
use Koha::Plugin::Com::imCode::SwedbankPay;

use XML::LibXML;
use Locale::Currency;
use Locale::Currency::Format;

my $paymentHandler = Koha::Plugin::Com::imCode::SwedbankPay->new;
my $input = new CGI;
my $order_id = $input->url_param('order_id');

if ( $order_id ) {
    my $table = $paymentHandler->get_qualified_table_name('swedbank_pay_transactions');
    my $dbh   = C4::Context->dbh;
    my $sth   = $dbh->prepare(
        "SELECT borrowernumber FROM $table WHERE order_id = ?");
    $sth->execute($order_id);
    my ($borrowernumber, $accountlines_string, $amount) = $sth->fetchrow_array();
    
    unless ( $borrowernumber ) {
        return print $input->header( -status => '404 Not Found');
    }

    $paymentHandler->process_transaction( $order_id );
    print $input->header( -status => '200 OK');
}
