package t::lib::SwedbankPay::Util;

use Modern::Perl;

use t::lib::Mocks::Logger;
use t::lib::TestBuilder;

use C4::Templates;
use Koha::Account;
use Koha::Logger;

sub mock_logger {
    my $mocked_logger = t::lib::Mocks::Logger->new();
    Koha::Logger->get->mock(
        'context',
        sub {
            my ( $self, @context ) = @_;
            $self->{context} = \@context;
            return $self;
        }
    );
    return $mocked_logger;
}

sub create_test_data {
    my ($how_many_extra_accountlines) = @_;
    my $builder = t::lib::TestBuilder->new;
    $how_many_extra_accountlines ||= 0;
    my $amount       = 100;
    my $amount_cents = $amount * 100;
    my $sum_cents    = $amount_cents + $how_many_extra_accountlines * 100;
    my $accountline  = {
        amount      => $amount,
        description => 'test',
        type        => 'LOST',
        interface   => 'intranet',
    };

    my $patron   = $builder->build_object( { class => 'Koha::Patrons' } );
    my $password = 'test';
    $patron->set_password( { password => $password, skip_validation => 1 } );
    my $debit_line = Koha::Account->new( { patron_id => $patron->borrowernumber } )->add_debit($accountline);
    while ( $how_many_extra_accountlines > 0 ) {
        Koha::Account->new( { patron_id => $patron->borrowernumber } )->add_debit($accountline);
        $how_many_extra_accountlines--;
    }

    my $template = C4::Templates::gettemplate( 'opac-main.tt', 'opac' );
    return ( $patron, $amount, $amount_cents, $sum_cents, $debit_line, $template );
}

1;
