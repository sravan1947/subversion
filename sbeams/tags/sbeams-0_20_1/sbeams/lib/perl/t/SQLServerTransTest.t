#!/tools/bin/perl -w


use DBI;
use Test::More tests => 32;
use Test::Harness;
use strict;

close(STDERR);

$|++; # don't buffer output
my $numrows;
my $msg;
my $test = 'sbeams_test.dbo.testagain';
  
# Set up user agent and sbeams objects
my %dbh;
ok( $dbh{sqlserv} = dbConnect( 'sqlserv' ), 'Connect to SQL Server database' );
print "\n";

for my $db ( qw( sqlserv ) ) {
  print "Working on $db ( $dbh{$db}->{Driver}->{Name} )...\n";

  # Set up database, test inserts with autocommit ON
  ok( deleteRows( $db ), "Clean up database" );
  setNumrows( $db );
  ok( testInsert( $db ), 'Insert 3 rows' );
  ok( checkNumrows( $db, $numrows + 3 ), "Check number of rows: $msg" );

  # Test interrupted inserts with autocommit ON
  setNumrows( $db );
  ok( testInsert( $db ), 'Insert 3 rows' );
  ok( testInterrupt( $db ), 'Interrupt transaction' );
  ok( checkNumrows( $db, $numrows + 3 ), "Check number of rows: $msg" );
  print "\n";


  # Test ability to turn autocommit off
  ok( setAutoCommit( $db, 0 ), 'Set Autocommit OFF' );
  ok( checkCommitState( $db, 0 ), "Verify autocommit state - OFF" );
  
  # Test committed inserts with autocommit OFF
  setNumrows( $db );
  ok( testInsert( $db ), 'Insert 3 rows' );
  ok( testCommit( $db ), 'Commit transaction' );
  ok( checkNumrows( $db, $numrows + 3 ), "Check number of rows: $msg" );

  # Test rolled-back inserts with autocommit OFF
  setNumrows( $db );
  ok( testInsert( $db ), 'Insert 3 rows' );
  ok( testRollback( $db ), 'Rollback transaction' );
  ok( checkNumrows( $db, $numrows ), "Check number of rows: $msg" );

  # Test interrupted inserts with autocommit OFF
  setNumrows( $db );
  ok( testInsert( $db ), 'Insert 3 rows' );
  ok( testInterrupt( $db ), 'Interrupt transaction' );
  ok( checkNumrows( $db, $numrows ), "Check number of rows: $msg" );
  print "\n";


  # Test ability to set AutoCommit ON
  ok( setAutoCommit( $db, 1 ), 'Set Autocommit ON' );
  ok( checkCommitState( $db, 1 ), "Verify autocommit state - ON" );

  # Test begin with commit 
  setNumrows( $db );
  ok( testBegin( $db ), 'Set transaction beginning' );
  ok( testInsert( $db ), 'Insert 3 rows' );
  ok( testCommit( $db ), 'Commit transaction' );
  ok( checkNumrows( $db, $numrows + 3 ), "Check number of rows: $msg" );

  # Test begin with rollback 
  setNumrows( $db );
  ok( testBegin( $db ), 'Set transaction beginning' );
  ok( testInsert( $db ), 'Insert 3 rows' );
  ok( testRollback( $db ), 'Rollback transaction' );
  ok( checkNumrows( $db, $numrows ), "Check number of rows: $msg" );

  # Test begin with interrupt 
  setNumrows( $db );
  ok( testBegin( $db ), 'Set transaction beginning' );
  ok( testInsert( $db ), 'Insert 3 rows' );
  ok( testInterrupt( $db ), 'Rollback transaction' );
  ok( checkNumrows( $db, $numrows ), "Check number of rows: $msg" );

  print "\n\n";
}


END {
  breakdown();
} # End END

sub breakdown {
}

sub testInterrupt {
  my $db = shift;
  eval {
    undef( $dbh{$db} );
  }; 
  $dbh{$db} = dbConnect( $db );
  return ( defined $dbh{$db} ) ? 1 : 0;
}

sub checkCommitState {
  my $db = shift;
  my $state = shift;
  return ( $dbh{$db}->{AutoCommit} == $state ) ? 1 : 0;
}

sub checkNumrows {
  my $db = shift;
  my $num = shift;
#print "DB is $db, CNT is $num\n";
  my ( $cnt ) = $dbh{$db}->selectrow_array( <<"  END" );
  SELECT COUNT(*) FROM $test
  END
  $msg = ( $num == $cnt ) ? "Found $cnt as expected" : "Found $cnt, expected $num\n";
  return ( $num == $cnt ) ? 1 : 0;
}

sub testCommit {
  my $db = shift;
  $dbh{$db}->commit();
}

sub testBegin {
  my $db = shift;
  $dbh{$db}->begin_work();
}

sub testRollback {
  my $db = shift;
  $dbh{$db}->rollback();
}

sub testInsert {
  my $db = shift;
  my $sql = "INSERT INTO $test ( f_one, f_two ) VALUES ( ";
  my %strs = ( 1 => 'one', 2 => 'two', 3 => 'three' );
  my $status;
  for my $key ( keys( %strs) ) {
    $status = $dbh{$db}->do( $sql . $key . ", '$strs{$key}' )" );
  }
  return $status;
}

sub deleteRows {
  my $db = shift;
  $dbh{$db}->do( "DELETE FROM $test" );
}


sub setNumrows {
  my $db = shift;
  ( $numrows ) = $dbh{$db}->selectrow_array( <<"  END" );
  SELECT COUNT(*) FROM $test
  END
#  print "Found $numrows rows\n";
}

sub setAutoCommit {
  my $db = shift;
  my $commit = shift;
  my $result = ${dbh{$db}}->{AutoCommit} = $commit; 
  return ( $result == $commit ) ? 1 : 0;
}
  

sub dbConnect {
  my $db = shift;

  my $connect = ( $db eq 'mysql' ) ?  "DBI:mysql:host=pandora;database=dcampbel" :
#"DBI:mysql:host=mysql;database=test" :
                                     "DBI:Sybase:server=mssql;database=sbeams_test";
#                                     "DBI:Sybase:server=mssql;database=dcampbel";
  my $user = 'dcampbel';
#  my $user = ( $db eq 'mysql' ) ? 'guest' : 'user';
  my $pass = ( $db eq 'mysql' ) ? 'pass' : 'pass';
#  my $pass = ( $db eq 'mysql' ) ? 'pass' : 'pass';

  my $dbh = DBI->connect( $connect, $user, $pass, { RaiseError => 0, AutoCommit => 1 } ) || die;
  return $dbh;
}

#  $dbh->{AutoCommit} = 0;
