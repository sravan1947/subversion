package SBEAMS::Proteomics::Utilities;

###############################################################################
# Program     : SBEAMS::Proteomics::Utilities
# Author      : Eric Deutsch <edeutsch@systemsbiology.org>
# $Id$
#
# Description : This is part of the SBEAMS::Proteomics module which
#               defines many of the module-specific methods
#
###############################################################################


use strict;
use vars qw($sbeams
           );

use SBEAMS::Connection::DBConnector;
use SBEAMS::Connection::Settings;
use SBEAMS::Connection::TableInfo;

use SBEAMS::Proteomics::Settings;
use SBEAMS::Proteomics::TableInfo;


###############################################################################
# Constructor
###############################################################################
sub new {
    my $this = shift;
    my $class = ref($this) || $this;
    my $self = {};
    bless $self, $class;
    return($self);
}



###############################################################################
# readOutFile
###############################################################################
sub readOutFile { 
  my $self = shift;
  my %args = @_;


  #### Decode the argument list
  my $inputfile = $args{'inputfile'} || '';
  my $verbose = $args{'verbose'} || '';

  #### Define some variables
  my ($line,$last_part);
  my ($key,$value,$i,$matches,$tmp);

  #### Define a hash to hold header parameters
  my %parameters;
  my @column_titles;
  my $columns_line;


  #### Open the specified file
  unless ( open(INFILE, "$inputfile") ) {
    die("Cannot open input file $inputfile\n");
  }


  #### Find the filename in the file and parse it
  while ($line = <INFILE>) {
    $line =~ s/[\r\n]//g;
    if ($line =~ /\.out/) {
      $line =~ s/\.out//;
      $line =~ s/\s*\.\///;
      $line =~ s/\s*//g;
      $parameters{'file_root'} = $line;
      $line =~ /.+\.(\d+)\.(\d+)\.(\d)$/;
      $parameters{'start_scan'} = $1;
      $parameters{'end_scan'} = $2;
      $parameters{'assumed_charge'} = $3;
      last;
    }
  }


  #### Sometimes we rename the file from the original, so use the actual
  #### file name instead of the name that's in the contents of the file
  my $filepart = $inputfile;
  $filepart =~ s/^.*\///;
  $filepart =~ s/\.out//;
  $parameters{'file_root'} = $filepart;


  #### Initial hash defining search patterns and corresponding storage keys
  my (%ScanInfoPatternKey) = (
    "sample_mass_plus_H",'\(M\+H\)\+ mass = ([0-9.]+)',
#    "mass_error",' \~ ([0-9.]+) \(',
    "assumed_charge",'\(\+([0-9])\), fragment',
    "search_date",'(\d+\/\d+\/\d+, \d+:\d+ [AP]M)',
    "search_elapsed_hr",' (\d+) hr. ',
    "search_elapsed_min",' (\d+) min. ',
    "search_elapsed_sec",' (\d+) sec.',
    "search_host",'. on (.+)',
    "total_intensity",'total inten = ([0-9.]+)',
    "lowest_prelim_score",'lowest Sp = ([0-9.]+)',
    "matched_peptides",'\# matched peptides = ([0-9.]+)',
    "search_database",', # proteins = \d+, (.+)'
#    "Dmass1",'\(C\* \+([0-9.]+)\)',
#    "Dmass2",'\(M\@ \+([0-9.]+)\)',
#    "mass_C",' C=([0-9.]+)'
  );


  #### Initialize desired hash values to ""
  while ( ($key,$value) = each %ScanInfoPatternKey ) {
    $parameters{$key}="";
  }


  #### Process header portion of the input file, putting data in hash
  $matches = 0;
  while ($line = <INFILE>) {
    $line =~ s/[\r\n]//g;

    while ( ($key,$value) = each %ScanInfoPatternKey ) {
      if ($line =~ /$value/) {
        $parameters{$key}="$1";
        $matches++;
      }
    }

    last unless $line;

  }


  #### If a sufficient number of matches were't found, bail out.
  if ($matches < 8) {
    print "ERROR: Unable to parse header of $inputfile\n";
    while ( ($key,$value) = each %parameters ) {
      printf("%22s = %s\n",$key,$value);
    }
    return;
  }


  #### Do a little manual cleaning up
  $parameters{'search_date'} =~ s/,//g;
  $parameters{'search_elapsed_min'} = 0.0 +
    $parameters{'search_elapsed_hr'} * 60.0 +
    $parameters{'search_elapsed_min'} +
    $parameters{'search_elapsed_sec'} / 60.0;
  delete $parameters{'search_elapsed_hr'};
  delete $parameters{'search_elapsed_sec'};


  #### Print out the matched header values if verbose
  if ($verbose) {
    while ( ($key,$value) = each %parameters ) {
      printf("%22s = %s\n",$key,$value);
    }
  }


  #### Parse the header information
  while ($line = <INFILE>) {
    $line =~ s/[\r\n]//g;
    if ($line =~ /Rank\/Sp/) {
      $columns_line = $line;
      $line =~ s/^\s+//;
      @column_titles = split(/\s+/,$line);
    }

    last if ($line =~ /  -------  /);

  }


  print "\n",join(",",@column_titles),"\n\n" if ($verbose);


  #### Define data format
  my $format = "a5a8a11a8a8a8a8";

  #### And some other variables
  my @result;
  my $processed_flag;


  #### Create a list of standard, simple columns
  my (%simple_columns) = (
    "#","hit_index",
    "(M+H)+","hit_mass_plus_H",
    "deltCn","norm_corr_delta",
    "XCorr","cross_corr",
    "Sp","prelim_score"
  );


  #### Find the offset for "Reference".  Need this for later parsing
  my $start_pos = index ($columns_line,"Reference");

  #### Store the hash reference for each line in an array
  my @best_matches = ();
  my @values;


  #### Define a standard error string
  my $errstr = "ERROR: while parsing '$inputfile':\n      ";


  #### Parse the tabular data
  while ($line = <INFILE>) {
    $line =~ s/[\r\n]//g;
    last unless $line;


    #### If the line begins with 6 spaces and then stuff, assume it's a
    #### multiple protein match (special sequest format option)
    if ($line =~ /^      (\S+)/) {

      #### Extract the name of the protein as the first item after 6 spaces
      my $additional_protein = $1;
      #print "Found additional protein '$additional_protein'\n";

      #### If there hasn't already been at least one search_hit, die horribly
      die "ERROR: Found what was thought to be an 'additional_protein' ".
        "line before finding any search_hits!  This is fatal."
        unless (@best_matches);

      #### Get the handle of the previous best match
      my $previous_hit = $best_matches[-1];

      #### If there hasn't yet been an additional protein, create a container
      #### for all additional proteins
      unless ($previous_hit->{search_hit_proteins}) {
        my @search_hit_proteins;
        #### Put the in-line, top hit as the first item
        push(@search_hit_proteins,$previous_hit->{reference});
        $previous_hit->{search_hit_proteins} = \@search_hit_proteins;
      }

      #### Add this additional protein and skip to the next line
      push(@{$previous_hit->{search_hit_proteins}},$additional_protein);
      next;
    }


    #### Do a basic test of the line: skip if less than 8 columns
    @values = split(/\s+/,$line);
    if ($#values < 8) {
      print "WARNING: Skipping line (maybe duplicate references?):\n$line\n";
      next;
    }


    #### Unpack the first part and then append the Reference and Peptide,
    #### which seems to have a less-than-consistent format
    @result = unpack($format,$line);
    $last_part = substr($line,$start_pos,999);

    $last_part =~ /(.+) [A-Z-\@]\..+\.[A-Z-\@]$/;
    push(@result,$1);
    $last_part =~ /.+ ([A-Z-\@]\..+\.[A-Z-\@])$/;
    push(@result,$1);


    if ($verbose) {
      print "--------------------------------------------------------\n";
      print join("=",@result),"\n";
    }


    my %tmp_hash;

    #### Store the data in an array of hashes
    for ($i=0; $i<=$#column_titles; $i++) {
      $processed_flag = 0;


      #### Parse and store Rank/Sp
      if ($column_titles[$i] eq "Rank/Sp") {
        my @tmparr = split(/\//,$result[$i]);

        my $tmp = $tmparr[0];
        if ($tmp > 0 && $tmp < 100) {
          $tmp =~ s/ //g;
          $tmp_hash{'cross_corr_rank'} = $tmp;
        } else {
          print "$errstr Rank is out of range: $tmp\n";
        }

        my $tmp = $tmparr[1];
        if ($tmp > 0 && $tmp <= 500) {
          $tmp =~ s/ //g;
          $tmp_hash{'prelim_score_rank'} = $tmp;
        } else {
          print "$errstr Sp Rank is out of range: $tmp\n";
        }

        $processed_flag++;
      }


      #### Parse and store the standard, simple columns
      if ($simple_columns{$column_titles[$i]}) {

        my $tmp = $result[$i];
        if ( ($tmp > 0 && $tmp < 10000) ||
             ($tmp == 0 && $column_titles[$i] eq "deltCn") ||
             ($tmp == 0 && $column_titles[$i] eq "XCorr") ) {
          $tmp =~ s/ //g;
          $tmp_hash{$simple_columns{$column_titles[$i]}} = $tmp;
        } else {
          print "$errstr $column_titles[$i] is out of range: $tmp\n";
        }

        $processed_flag++;
      }


      #### Parse and store Ions
      if ($column_titles[$i] eq "Ions") {
        my @tmparr = split(/\//,$result[$i]);

        my $tmp = $tmparr[0];
        if ($tmp > 0 && $tmp < 1000) {
          $tmp =~ s/ //g;
          $tmp_hash{'identified_ions'} = $tmp;
        } else {
          print "$errstr identified_ions is out of range: $tmp\n";
        }

        my $tmp = $tmparr[1];
        if ($tmp > 0 && $tmp <= 1000) {
          $tmp =~ s/ //g;
          $tmp_hash{'total_ions'} = $tmp;
        } else {
          print "$errstr total_ions is out of range: $tmp\n";
        }

        $processed_flag++;
      }


      #### Parse and store Reference
      if ($column_titles[$i] eq "Reference") {
        my @tmparr = split(/\s+/,$result[$i]);

        my $tmp = $tmparr[0];
        if ($tmp) {
          $tmp =~ s/ //g;
          $tmp_hash{'reference'} = $tmp;
        } else {
          print "$errstr Reference is out of range: $tmp\n";
        }

        my $tmp = $tmparr[1];
        if ($tmp > 0 && $tmp <= 1000) {
          $tmp =~ s/[ \+]//g;
          $tmp_hash{'additional_proteins'} = $tmp;
        } else {
          $tmp_hash{'additional_proteins'} = 0;
        }

        $processed_flag++;
      }


      #### Parse and store Peptide
      if ($column_titles[$i] eq "Peptide") {

        my $tmp = $result[$i];
        if ($tmp) {
          $tmp =~ s/ //g;
          $tmp_hash{'peptide_string'} = $tmp;
          $tmp =~ s/[\*\@\#]//g;
          $tmp =~ /.*\.([A-Z-\@]+)\..*/;
          if ($1) {
            $tmp_hash{'peptide'} = $1;
          } else {
            print "$errstr Unable to parse peptide_string to peptide: $tmp\n";
          }

        } else {
          print "$errstr Peptide is out of range: $tmp\n";
        }

        $processed_flag++;
      }

      unless ($processed_flag) {
        print "$errstr Don't know what to do with column '$column_titles[$i]'\n";
      }


    } ## End for


    #### Add a few manual calculations
    $tmp_hash{'mass_delta'} =
      $parameters{'sample_mass_plus_H'} - $tmp_hash{'hit_mass_plus_H'};

    #### Remove a pesky trailing period
    $tmp_hash{'hit_index'} =~ s/\.//g;

    #### Print out the matched header values if verbose
    if ($verbose) {
      while ( ($key,$value) = each %tmp_hash ) {
        printf("%22s = %s\n",$key,$value);
      }
    }


    #### Store the hash of values in array
    push(@best_matches,\%tmp_hash);


  } ## End while


  close(INFILE);


  my %final_structure;
  $final_structure{'parameters'} = \%parameters;
  $final_structure{'matches'} = \@best_matches;

  return %final_structure;

}



###############################################################################
# readParamsFile
###############################################################################
sub readParamsFile { 
  my $self = shift;
  my %args = @_;

  #### Decode the argument list
  my $inputfile = $args{'inputfile'} || "";
  my $verbose = $args{'verbose'} || "";

  #### Define a few variables
  my ($line,$last_part);
  my ($key,$value,$i,$matches,$tmp);


  #### Define a hash to hold parameters from the file and also an array
  #### to have an ordered list of keys
  my %parameters;
  my @keys_in_order;


  #### Open the specified file
  if ( open(INFILE, "$inputfile") == 0 ) {
    die "\nCannot open input file $inputfile\n\n";
  }


  #### Read through the entire file, extracting key value pairs
  $matches = 0;
  while ($line = <INFILE>) {

    #### If the line isn't a comment line, then parse it
    unless ($line =~ /^\s*\#/) {

      #### Strip linefeeds and carriage returns
      $line =~ s/[\r\n]//g;

      #### Find key = value pattern
      $line =~ /\s*(\w+)\s*=\s*(.*)/;
      ($key,$value) = ($1,$2);

      #### If a suitable key was found then store the key value pair
      if ($key) {

        #### Strip off a possible trailing comment
        $value =~ s/\s*;.*$//;

        #print "$key = $value\n";
        $parameters{$key} = $value;
        push(@keys_in_order,$key);
      }

    }

  }


  #### Put parameters and data into a single structure and return
  my %finalhash;
  $finalhash{parameters} = \%parameters;
  $finalhash{keys_in_order} = \@keys_in_order;

  return \%finalhash;

}



###############################################################################
# readDtaFile
###############################################################################
sub readDtaFile { 
  my $self = shift;
  my %args = @_;

  #### Decode the argument list
  my $inputfile = $args{'inputfile'} || "";
  my $verbose = $args{'verbose'} || "";

  #### Define a few variables
  my $line;
  my @parsed_line;


  #### Define a hash to hold parameters from the file
  #### and a two dimensional array for the mass, intensity pairs
  my %parameters;
  my @mass_intensities;


  #### Parse information from the filename
  my $file_root = $inputfile;
  $file_root =~ s/.*\///;
  $file_root =~ /.+\.(\d+)\.(\d+)\.(\d).dta$/;
  $parameters{'start_scan'} = $1;
  $parameters{'end_scan'} = $2;
  $parameters{'assumed_charge'} = $3;
  $file_root =~ s/\.\d\.dta//;
  $parameters{'file_root'} = $file_root;


  #### Open the specified file
  if ( open(INFILE, "$inputfile") == 0 ) {
    die "\nCannot open input file $inputfile\n\n";
  }


  #### Read the header
  $line = <INFILE>;
  $line =~ s/[\r\n]//g;
  @parsed_line = split(/\s+/,$line);
  if ($#parsed_line != 1) {
    print "ERROR: Reading dta file '$inputfile'\n".
          "       Expected first line to have two columns.\n";
    return;
  }


  #### Stored results
  $parameters{sample_mass_plus_H} =  $parsed_line[0];
  $parameters{assumed_charge} =  $parsed_line[1];


  #### Read through the rest of the file, extracting mass, intensity pairs
  my $n_peaks = 0;
  while ($line = <INFILE>) {

    #### Strip linefeeds and carriage returns
    $line =~ s/[\r\n]//g;

    #### split into two values
    @parsed_line = split(/\s+/,$line);

    #### If we didn't get two values, then bail with error
    if ($#parsed_line != 1) {
      print "ERROR: Reading dta file '$inputfile'\n".
            "       Expected line $n_peaks to have two columns.\n";
      return;
    }


    #### Store the mass, intensity pair
    push(@mass_intensities,[@parsed_line]);


    $n_peaks++;

  }

  $parameters{n_peaks} =  $n_peaks;


  #### Put parameters and data into a single structure and return
  my %finalhash;
  $finalhash{parameters} = \%parameters;
  $finalhash{mass_intensities} = \@mass_intensities;

  return \%finalhash;


}



###############################################################################
# readSummaryFile
###############################################################################
sub readSummaryFile { 
  my $self = shift;
  my %args = @_;

  #### Decode the argument list
  my $inputfile = $args{'inputfile'} || "";
  my $verbose = $args{'verbose'} || "";

  #### Define a few variables
  my $line;
  my @parsed_line;


  #### Define a hash to hold pointers to the files with interesting information
  my %files;


  #### Open the specified file
  if ( open(INFILE, "$inputfile") == 0 ) {
    die "\nCannot open input file $inputfile\n\n";
  }


  while ($line = <INFILE>) {
    last if ($line =~ /------------/);
    last if ($line =~ /<HTML><BODY BGCOLOR="#FFFFFF"><PRE>/);
  }


  #### Initial hash defining search patterns and corresponding storage keys
  my (%ScanInfoPatternKey) = (
    "d0_first_scan",'LightFirstScan=(\d+)',
    "d0_last_scan",'LightLastScan=(\d+)',
    "d0_mass",'LightMass=([\d\.]+)',
    "d8_first_scan",'HeavyFirstScan=(\d+)',
    "d8_last_scan",'HeavyLastScan=(\d+)',
    "d8_mass",'HeavyMass=([\d\.]+)',
    "norm_flag",'bICATList1=([\d\.]+)',
    "mass_tolerance",'MassTol=([\d\.]+)'
  );



  my ($outfile,$matches,$key,$value);
  my $counter = 1;

  #### Read through the rest of the file, extracting information
  while ($line = <INFILE>) {

    #### Strip linefeeds and carriage returns
    $line =~ s/[\r\n]//g;

    #### Skip if we've reached the end
    last unless $line;

    #### Find the .outfile
    unless ($line =~ /showout_html5\?OutFile=(.+?\"\>)/) {
      print "ERROR: Unable to parse line: $line\n";
      next;
    }

    $outfile = $1;
    $outfile =~ /.+\/(.+\.out)/;
    $outfile = $1;

    unless ($outfile) {
      print "ERROR: Unable to parse line: $line\n";
      next;
    }


    #### Define a hash to hold parameters for each file,
    my %parameters;
    my $matches = 0;

    #### If there's probability information, extract it
    if ($line =~ /Prob=([\d\.]+)/) {
      $parameters{probability}="$1";
      $matches++;
    }


    #### If there's quantitation information, extract it
    if ($line =~ /LightFirstScan/) {

      #### Extract the data, putting into a hash
      while ( ($key,$value) = each %ScanInfoPatternKey ) {
        if ($line =~ /$value/) {
          $parameters{$key}="$1";
          $matches++;
        }
      }


      #### Extract the actual ratio
      $line =~ /\>\s*([\d\.]+)\:([\d\.]+)([\*]*)\</;
      unless ($outfile) {
        print "ERROR: Unable to extract light:heavy line: $line\n";
      }
      $parameters{d0_intensity} = $1;
      $parameters{d8_intensity} = $2;
      $parameters{manually_changed} = $3;

      #print "$counter:  $outfile  matches=$matches ".
      #  "light_first_scan = $parameters{light_first_scan}  ".
      #  "ratio=$1:$2\n";
      #$files{$outfile}=\%parameters;

    } else {
      #print "$counter:  $outfile\n";
    }

    $files{$outfile}=\%parameters if ($matches);

    $counter++;

  }


  #### Put data into a single structure and return
  my %finalhash;
  $finalhash{files} = \%files;


  return \%finalhash;


}



###############################################################################

1;

__END__
###############################################################################
###############################################################################
###############################################################################

=head1 NAME

SBEAMS::Proteomics::Utilities - Module-specific utilities

=head1 SYNOPSIS

  Used as part of this system

    use SBEAMS::Connection;
    use SBEAMS::Proteomics::Utilties;


=head1 DESCRIPTION

    This module is inherited by the SBEAMS::Proteomics module,
    although it can be used on its own.  Its main function 
    is to encapsulate common module-specific functionality.

=head1 METHODS

=item B<readOutFile()>

    Read a sequest .out file

=item B<readParamsFile()>

    Read a sequest.params file

=item B<readDtaFile()>

    Read a sequest .dta file

=item B<readSummaryFile()>

    Read a sequest .html summary file

=head1 AUTHOR

Eric Deutsch <edeutsch@systemsbiology.org>

=head1 SEE ALSO

perl(1).

=cut
