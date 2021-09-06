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
use Digest::MD5 qw(md5_hex);
use Locale::Currency;
use Locale::Currency::Format;

my $paymentHandler = Koha::Plugin::Com::imCode::SwedbankPay->new;
my $input = new CGI;
my $statuscode = $input->param('statuscode');

if ($statuscode and $statuscode == 2) {

    my $koha_transaction_id = $input->param('orderid');
    warn "orderid missing" and return unless ($koha_transaction_id);

    my $dibs_transaction_id = $input->param('transact');
    warn "transact missing" and return unless ($dibs_transaction_id);

    my $authkey = $input->param('authkey');
    warn "authkey missing" and return unless ($authkey);

    # We are getting the amount from the database and not from the parameters,
    # because this page says it can be returned:
    # https://tech.dibspayment.com/D2/Hosted/Output_parameters/Return_parameters
    # this page doesn't mention it:
    # https://tech.dibspayment.com/D2/Hosted/Output_parameters/Return_parameter_configuration
    # And even though it is selectable in the admin configuration (Integration -> return values)
    # it is never returned
    my $table = $paymentHandler->get_qualified_table_name('dibs_transactions');
    my $dbh   = C4::Context->dbh;
    my $sth   = $dbh->prepare(
        "SELECT borrowernumber, accountlines_ids, amount FROM $table WHERE transaction_id = ?");
    $sth->execute($koha_transaction_id);
    my ($borrowernumber, $accountlines_string, $amount) = $sth->fetchrow_array();

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

    # DIBS require "The smallest unit of an amount in the selected currency, following the ISO4217 standard." 
    $md5amount = $amount * 10**$decimals;

    my $md5string = "transact=$dibs_transaction_id&amount=$md5amount&currency=$currency_number";
    my $md51 = md5_hex($paymentHandler->retrieve_data('MD5k1') . $md5string);
    my $md5checksum = md5_hex($paymentHandler->retrieve_data('MD5k2') . $md51);

    warn "wrong authkey" and return unless ($authkey == $md5checksum);

    my @accountline_ids = split(' ', $accountlines_string);
    my $borrower = Koha::Patrons->find($borrowernumber);
    my $lines = Koha::Account::Lines->search(
        { accountlines_id => { 'in' => \@accountline_ids } } )->as_list;
    my $account = Koha::Account->new( { patron_id => $borrowernumber } );
    my $accountline_id = $account->pay(
        {   
            amount     => $amount,
            note       => 'DIBS Payment',                                                                 
            library_id => $borrower->branchcode,                                                         
            lines => $lines,    # Arrayref of Koha::Account::Line objects to pay                         
        }
    ); 

    # Link payment to dibs_transactions
    my $dbh   = C4::Context->dbh;
    my $sth   = $dbh->prepare(
        "UPDATE $table SET accountline_id = ? WHERE transaction_id = ?");
    $sth->execute( $accountline_id, $koha_transaction_id );
    
	# Renew any items as required
    for my $line ( @{$lines} ) {
        next unless $line->itemnumber;
        my $item =
          Koha::Items->find( { itemnumber => $line->itemnumber } );

        # Renew if required
        if ( $paymentHandler->_version_check('19.11.00') ) {
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



    print $input->header( -status => '200 OK');
}
