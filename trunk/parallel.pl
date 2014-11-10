#!/usr/bin/env perl

# Copyright (C) 2007,2008,2009,2010,2011,2012,2013,2014 Ole Tange and
# Free Software Foundation, Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, see <http://www.gnu.org/licenses/>
# or write to the Free Software Foundation, Inc., 51 Franklin St,
# Fifth Floor, Boston, MA 02110-1301 USA

# open3 used in Job::start
use IPC::Open3;
# &WNOHANG used in reaper
use POSIX qw(:sys_wait_h setsid ceil :errno_h);
# gensym used in Job::start
use Symbol qw(gensym);
# tempfile used in Job::start
use File::Temp qw(tempfile tempdir);
# mkpath used in openresultsfile
use File::Path;
# GetOptions used in get_options_from_array
use Getopt::Long;
# Used to ensure code quality
use strict;
use File::Basename;

if(not $ENV{SHELL}) {
    # $ENV{SHELL} is sometimes not set on Mac OS X and Windows
    ::warning("\$SHELL not set. Using /bin/sh.\n");
    $ENV{SHELL} = "/bin/sh";
}
if(not $ENV{HOME}) {
    # $ENV{HOME} is sometimes not set if called from PHP
    ::warning("\$HOME not set. Using /tmp\n");
    $ENV{HOME} = "/tmp";
}

save_stdin_stdout_stderr();
save_original_signal_handler();
parse_options();
::debug("init", "Open file descriptors: ", join(" ",keys %Global::fd), "\n");
my $number_of_args;
if($Global::max_number_of_args) {
    $number_of_args=$Global::max_number_of_args;
} elsif ($opt::X or $opt::m or $opt::xargs) {
    $number_of_args = undef;
} else {
    $number_of_args = 1;
}

my @command;
@command = @ARGV;

my @fhlist;
if($opt::pipepart) {
    @fhlist = map { open_or_exit($_) } "/dev/null";
} else {
    @fhlist = map { open_or_exit($_) } @opt::a;
    if(not @fhlist and not $opt::pipe) {
	@fhlist = (*STDIN);
    }
}
if($opt::skip_first_line) {
    # Skip the first line for the first file handle
    my $fh = $fhlist[0];
    <$fh>;
}
if($opt::header and not $opt::pipe) {
    my $fh = $fhlist[0];
    # split with colsep or \t
    # $header force $colsep = \t if undef?
    my $delimiter = $opt::colsep;
    $delimiter ||= "\$";
    my $id = 1;
    for my $fh (@fhlist) {
	my $line = <$fh>;
	chomp($line);
	::debug("init", "Delimiter: '$delimiter'");
	for my $s (split /$delimiter/o, $line) {
	    ::debug("init", "Colname: '$s'");
	    # Replace {colname} with {2}
	    # TODO accept configurable short hands
	    # TODO how to deal with headers in {=...=}
	    for(@command) {
	      s:\{$s(|/|//|\.|/\.)\}:\{$id$1\}:g;
	    }
	    $Global::input_source_header{$id} = $s;
	    $id++;
	}
    }
} else {
    my $id = 1;
    for my $fh (@fhlist) {
	$Global::input_source_header{$id} = $id;
	$id++;
    }
}

if($opt::filter_hosts and (@opt::sshlogin or @opt::sshloginfile)) {
    # Parallel check all hosts are up. Remove hosts that are down
    filter_hosts();
}

if($opt::nonall or $opt::onall) {
    onall(@command);
    wait_and_exit(min(undef_as_zero($Global::exitstatus),254));
}

# TODO --transfer foo/./bar --cleanup
# multiple --transfer and --basefile with different /./

$Global::JobQueue = JobQueue->new(
    \@command,\@fhlist,$Global::ContextReplace,$number_of_args,\@Global::ret_files);

if($opt::eta or $opt::bar) {
    # Count the number of jobs before starting any
    $Global::JobQueue->total_jobs();
}
if($opt::pipepart) {
    $Global::JobQueue->{'commandlinequeue'}->unget(
	map { pipe_part_files($_) } @opt::a);
}
for my $sshlogin (values %Global::host) {
    $sshlogin->max_jobs_running();
}

init_run_jobs();
my $sem;
if($Global::semaphore) {
    $sem = acquire_semaphore();
}
$SIG{TERM} = \&start_no_new_jobs;

start_more_jobs();
if(not $opt::pipepart) {
    if($opt::pipe) {
	spreadstdin();
    }
}
::debug("init", "Start draining\n");
drain_job_queue();
::debug("init", "Done draining\n");
reaper();
::debug("init", "Done reaping\n");
if($opt::pipe and @opt::a) {
    for my $job (@Global::tee_jobs) {
	unlink $job->fh(2,"name");
	$job->set_fh(2,"name","");
	$job->print();
	unlink $job->fh(1,"name");
    }
}
::debug("init", "Cleaning\n");
cleanup();
if($Global::semaphore) {
    $sem->release();
}
for(keys %Global::sshmaster) {
    kill "TERM", $_;
}
::debug("init", "Halt\n");
if($opt::halt_on_error) {
    wait_and_exit($Global::halt_on_error_exitstatus);
} else {
    wait_and_exit(min(undef_as_zero($Global::exitstatus),254));
}

sub __PIPE_MODE__ {}

sub pipe_part_files {
    # Input:
    #   $file = the file to read
    # Returns:
    #   @commands to run to pipe the blocks of the file to the command given
    my ($file) = @_;
    my $buf = "";
    open(my $fh, "<", $file) || die;
    my $header = find_header(\$buf,$fh);
    # find positions
    my @pos = find_split_positions($file,$opt::blocksize,length $header);
    # unshift job with cat_partial
    my @cmdlines;
    for(my $i=0; $i<$#pos; $i++) {
	my $cmd = $Global::JobQueue->{'commandlinequeue'}->get();
	$cmd->{'replaced'} = 
	    cat_partial($file, 0, length($header), $pos[$i], $pos[$i+1]) . "|" .
	    "(".$cmd->{'replaced'}.")";
	::debug("init", "Unget ", $cmd->{'replaced'}, "\n");
	push(@cmdlines, $cmd);
    }
    return @cmdlines;
}

sub find_header {
    my ($buf_ref, $fh) = @_;
    my $header = "";
    if($opt::header) {
	if($opt::header eq ":") { $opt::header = "(.*\n)"; }
	# Number = number of lines
	$opt::header =~ s/^(\d+)$/"(.*\n)"x$1/e;
	while(read($fh,substr($$buf_ref,length $$buf_ref,0),$opt::blocksize)) {
	    if($$buf_ref=~s/^($opt::header)//) {
		$header = $1; 
		last;
	    }
	}
    }
    return $header;
}

sub find_split_positions {
    # Input:
    #   $file = the file to read
    #   $block = (minimal) --block-size of each chunk
    #   $headerlen = length of header to be skipped
    # Uses:
    #   $opt::recstart
    #   $opt::recend
    # Returns:
    #   @positions of block start/end
    my($file, $block, $headerlen) = @_;
    my $size = -s $file;
    # The optimal dd blocksize for mint, redhat, solaris, openbsd = 2^17..2^20
    # The optimal dd blocksize for freebsd = 2^15..2^17
    my $dd_block_size = 131072; # 2^17
    my @pos;
    my ($recstart,$recend) = recstartrecend();
    my $recendrecstart = $recend.$recstart;
    open (my $fh, "<", $file) || die;
    push(@pos,$headerlen);
    for(my $pos = $block+$headerlen; $pos < $size; $pos += $block) {
	my $buf;
	seek($fh, $pos, 0) || die;
	while(read($fh,substr($buf,length $buf,0),$dd_block_size)) {
	    if($opt::regexp) {
		# If match /$recend$recstart/ => Record position
		if($buf =~ /(.*$recend)$recstart/os) {
		    my $i = length($1);
		    push(@pos,$pos+$i);
		    # Start looking for next record _after_ this match
		    $pos += $i;
		    last;
		}
	    } else {
		# If match $recend$recstart => Record position
		my $i = index($buf,$recendrecstart);
		if($i != -1) {
		    push(@pos,$pos+$i);
		    # Start looking for next record _after_ this match
		    $pos += $i;
		    last;
		}
	    }
	}
    }
    push(@pos,$size);
    close $fh;
    return @pos;
}

sub cat_partial {
    # Input:
    #   $file = the file to read
    #   ($start, $end, [$start2, $end2, ...]) = start byte, end byte
    # Returns:
    #   Efficient perl command to copy $start..$end, $start2..$end2, ... to stdout
    my($file, @start_end) = @_;
    my($start, $i);
    # Convert start_end to start_len
    my @start_len = map { if(++$i % 2) { $start = $_; } else { $_-$start } } @start_end;
    return "<". shell_quote_scalar($file) .
	q{ perl -e 'while(@ARGV) { sysseek(STDIN,shift,0) || die; $left = shift; while($read = sysread(STDIN,$buf, ($left > 32768 ? 32768 : $left))){ $left -= $read; syswrite(STDOUT,$buf); } }' } .
	" @start_len";
}

sub spreadstdin {
    # read a record
    # Spawn a job and print the record to it.
    my $buf = "";
    my ($recstart,$recend) = recstartrecend();
    my $recendrecstart = $recend.$recstart;
    my $chunk_number = 1;
    my $one_time_through;
    my $blocksize = $opt::blocksize;
    my $in = *STDIN;
    my $header = find_header(\$buf,$in);
    while(1) {
      my $anything_written = 0;
      if(not read($in,substr($buf,length $buf,0),$blocksize)) {
	  # End-of-file
	  $chunk_number != 1 and last;
	  # Force the while-loop once if everything was read by header reading
	  $one_time_through++ and last;
      }
      if($opt::r) {
	  # Remove empty lines
	  $buf=~s/^\s*\n//gm;
	  if(length $buf == 0) {
	      next;
	  }
      }
      if($Global::max_lines and not $Global::max_number_of_args) {
	  # Read n-line records 
	  my $n_lines = $buf=~tr/\n/\n/;
	  my $last_newline_pos = rindex($buf,"\n");
	  while($n_lines % $Global::max_lines) {
	      $n_lines--;
	      $last_newline_pos = rindex($buf,"\n",$last_newline_pos-1);
	  }
	  # Chop at $last_newline_pos as that is where n-line record ends
	  $anything_written +=
	      write_record_to_pipe($chunk_number++,\$header,\$buf,
				   $recstart,$recend,$last_newline_pos+1);
	  substr($buf,0,$last_newline_pos+1) = "";
      } elsif($opt::regexp) {
	  if($Global::max_number_of_args) {
	      # -N => (start..*?end){n}
	      # -L -N => (start..*?end){n*l}
	      my $read_n_lines = $Global::max_number_of_args * ($Global::max_lines || 1);
	      while($buf =~ s/((?:$recstart.*?$recend){$read_n_lines})($recstart.*)$/$2/os) {
		  # Copy to modifiable variable
		  my $b = $1;
		  $anything_written +=
		      write_record_to_pipe($chunk_number++,\$header,\$b,
					   $recstart,$recend,length $1);
	      }
	  } else {
	      # Find the last recend-recstart in $buf
	      if($buf =~ s/(.*$recend)($recstart.*?)$/$2/os) {
		  # Copy to modifiable variable
		  my $b = $1;
		  $anything_written +=
		      write_record_to_pipe($chunk_number++,\$header,\$b,
					   $recstart,$recend,length $1);
	      }
	  }
      } else {
	  if($Global::max_number_of_args) {
	      # -N => (start..*?end){n}
	      my $i = 0;
	      my $read_n_lines = $Global::max_number_of_args * ($Global::max_lines || 1);
	      while(($i = nindex(\$buf,$recendrecstart,$read_n_lines)) != -1) {
		  $i += length $recend; # find the actual splitting location
		  $anything_written +=
		      write_record_to_pipe($chunk_number++,\$header,\$buf,
					   $recstart,$recend,$i);
		  substr($buf,0,$i) = "";
	      }
	  } else {
	      # Find the last recend-recstart in $buf
	      my $i = rindex($buf,$recendrecstart);
	      if($i != -1) {
		  $i += length $recend; # find the actual splitting location
		  $anything_written +=
		      write_record_to_pipe($chunk_number++,\$header,\$buf,
					   $recstart,$recend,$i);
		  substr($buf,0,$i) = "";
	      }
	  }
      }
      if(not $anything_written and not eof($in)) {
	  # Nothing was written - maybe the block size < record size?
	  # Increase blocksize exponentially
	  my $old_blocksize = $blocksize;
	  $blocksize = ceil($blocksize * 1.3 + 1);
	  ::warning("A record was longer than $old_blocksize. " .
		    "Increasing to --blocksize $blocksize\n");
      }
    }
    # If there is anything left in the buffer write it
    substr($buf,0,0) = "";
    write_record_to_pipe($chunk_number++,\$header,\$buf,$recstart,$recend,length $buf);

    ::debug("init", "Done reading input\n");
    $Global::start_no_new_jobs ||= 1;
    if($opt::roundrobin) {
	for my $job (values %Global::running) {
	    close $job->fh(0,"w");
	}
	my %incomplete_jobs = %Global::running;
	my $sleep = 1;
	while(keys %incomplete_jobs) {
	    my $something_written = 0;
	    for my $pid (keys %incomplete_jobs) {
		my $job = $incomplete_jobs{$pid};
		if($job->stdin_buffer_length()) {
		    $something_written += $job->non_block_write();
		} else {
		    delete $incomplete_jobs{$pid}
		}
	    }
	    if($something_written) {
		$sleep = $sleep/2+0.001;
	    }
	    $sleep = ::reap_usleep($sleep);
	}
    }
}

sub recstartrecend {
    # Uses:
    #   $opt::recstart
    #   $opt::recend
    # Returns:
    #   $recstart,$recend with default values and regexp conversion
    my($recstart,$recend);
    if(defined($opt::recstart) and defined($opt::recend)) {
	# If both --recstart and --recend is given then both must match
	$recstart = $opt::recstart;
	$recend = $opt::recend;
    } elsif(defined($opt::recstart)) {
	# If --recstart is given it must match start of record
	$recstart = $opt::recstart;
	$recend = "";
    } elsif(defined($opt::recend)) {
	# If --recend is given then it must match end of record
	$recstart = "";
	$recend = $opt::recend;
    }

    if($opt::regexp) {
	# If $recstart/$recend contains '|' this should only apply to the regexp
	$recstart = "(?:".$recstart.")";
	$recend = "(?:".$recend.")";
    } else {
	# $recstart/$recend = printf strings (\n)
	$recstart =~ s/\\([0rnt\'\"\\])/"qq|\\$1|"/gee;
	$recend =~ s/\\([0rnt\'\"\\])/"qq|\\$1|"/gee;
    }
    return ($recstart,$recend);
}

sub nindex {
    # See if string is in buffer N times
    # Returns:
    #   the position where the Nth copy is found
    my ($buf_ref, $str, $n) = @_;
    my $i = 0;
    for(1..$n) {
	$i = index($$buf_ref,$str,$i+1);
	if($i == -1) { last }
    }
    return $i;
}

sub round_robin_write {
    my ($header_ref,$block_ref,$recstart,$recend,$endpos) = @_;
    my $something_written = 0;
    my $block_passed = 0;
    while(not $block_passed) {
	while(my ($pid,$job) = each %Global::running) {
	    if($job->stdin_buffer_length() > 0) {
		$something_written += $job->non_block_write();
	    } else {
		$job->set_stdin_buffer($header_ref,$block_ref,$endpos,$recstart,$recend);
		$block_passed = 1;
		$job->set_virgin(0);
		$something_written += $job->non_block_write();
		last;
	    }
	}
    }

    # http://docstore.mik.ua/orelly/perl/cookbook/ch07_15.htm
    start_more_jobs();
    return $something_written;
}


sub write_record_to_pipe {
    # Fork then
    # Write record from pos 0 .. $endpos to pipe
    my ($chunk_number,$header_ref,$record_ref,$recstart,$recend,$endpos) = @_;
    if($endpos == 0) { return 0; }
    if(vec($Global::job_already_run,$chunk_number,1)) { return 1; }
    if($opt::roundrobin) {
	return round_robin_write($header_ref,$record_ref,$recstart,$recend,$endpos);
    }
    # If no virgin found, backoff
    my $sleep = 0.0001; # 0.01 ms - better performance on highend
    while(not @Global::virgin_jobs) {
	::debug("pipe", "No virgin jobs");
	$sleep = ::reap_usleep($sleep);
	# Jobs may not be started because of loadavg
	# or too little time between each ssh login.
	start_more_jobs();
    }
    my $job = shift @Global::virgin_jobs;
    # Job is no longer virgin
    $job->set_virgin(0);
    if(fork()) {
	# Skip
    } else {
	# Chop of at $endpos as we do not know how many rec_sep will
	# be removed.
	substr($$record_ref,$endpos,length $$record_ref) = "";
	# Remove rec_sep
	if($opt::remove_rec_sep) {
	    Job::remove_rec_sep($record_ref,$recstart,$recend);
	}
	$job->write($header_ref);
	$job->write($record_ref);
	close $job->fh(0,"w");
	exit(0);
    }
    close $job->fh(0,"w");
    return 1;
}

sub __SEM_MODE__ {}

sub acquire_semaphore {
    # Acquires semaphore. If needed: spawns to the background
    # Returns:
    #   The semaphore to be released when jobs is complete
    $Global::host{':'} = SSHLogin->new(":");
    my $sem = Semaphore->new($Semaphore::name,$Global::host{':'}->max_jobs_running());
    $sem->acquire();
    if($Semaphore::fg) {
	# skip
    } else {
	# If run in the background, the PID will change
	# therefore release and re-acquire the semaphore
	$sem->release();
	if(fork()) {
	    exit(0);
	} else {
	    # child
	    # Get a semaphore for this pid
	    ::die_bug("Can't start a new session: $!") if setsid() == -1;
	    $sem = Semaphore->new($Semaphore::name,$Global::host{':'}->max_jobs_running());
	    $sem->acquire();
	}
    }
    return $sem;
}

sub __PARSE_OPTIONS__ {}

sub options_hash {
    # Returns a hash of the GetOptions config
    return
	("debug|D=s" => \$opt::D,
	 "xargs" => \$opt::xargs,
	 "m" => \$opt::m,
	 "X" => \$opt::X,
	 "v" => \@opt::v,
	 "joblog=s" => \$opt::joblog,
	 "results|result|res=s" => \$opt::results,
	 "resume" => \$opt::resume,
	 "resume-failed|resumefailed" => \$opt::resume_failed,
	 "silent" => \$opt::silent,
	 #"silent-error|silenterror" => \$opt::silent_error,
	 "keep-order|keeporder|k" => \$opt::keeporder,
	 "group" => \$opt::group,
	 "g" => \$opt::retired,
	 "ungroup|u" => \$opt::u,
	 "linebuffer|linebuffered|line-buffer|line-buffered" => \$opt::linebuffer,
	 "tmux" => \$opt::tmux,
	 "null|0" => \$opt::0,
	 "quote|q" => \$opt::q,
	 # Replacement strings
	 "parens=s" => \$opt::parens,
	 "rpl=s" => \@opt::rpl,
	 "I=s" => \$opt::I,
	 "extensionreplace|er=s" => \$opt::U,
	 "U=s" => \$opt::retired,
	 "basenamereplace|bnr=s" => \$opt::basenamereplace,
	 "dirnamereplace|dnr=s" => \$opt::dirnamereplace,
	 "basenameextensionreplace|bner=s" => \$opt::basenameextensionreplace,
	 "seqreplace=s" => \$opt::seqreplace,
	 "slotreplace=s" => \$opt::slotreplace,
	 "jobs|j=s" => \$opt::jobs,
	 "delay=f" => \$opt::delay,
	 "sshdelay=f" => \$opt::sshdelay,
	 "load=s" => \$opt::load,
	 "noswap" => \$opt::noswap,
	 "max-line-length-allowed" => \$opt::max_line_length_allowed,
	 "number-of-cpus" => \$opt::number_of_cpus,
	 "number-of-cores" => \$opt::number_of_cores,
	 "use-cpus-instead-of-cores" => \$opt::use_cpus_instead_of_cores,
	 "shellquote|shell_quote|shell-quote" => \$opt::shellquote,
	 "nice=i" => \$opt::nice,
	 "timeout=s" => \$opt::timeout,
	 "tag" => \$opt::tag,
	 "tagstring|tag-string=s" => \$opt::tagstring,
	 "onall" => \$opt::onall,
	 "nonall" => \$opt::nonall,
	 "filter-hosts|filterhosts|filter-host" => \$opt::filter_hosts,
	 "sshlogin|S=s" => \@opt::sshlogin,
	 "sshloginfile|slf=s" => \@opt::sshloginfile,
	 "controlmaster|M" => \$opt::controlmaster,
	 "return=s" => \@opt::return,
	 "trc=s" => \@opt::trc,
	 "transfer" => \$opt::transfer,
	 "cleanup" => \$opt::cleanup,
	 "basefile|bf=s" => \@opt::basefile,
	 "B=s" => \$opt::retired,
	 "ctrlc|ctrl-c" => \$opt::ctrlc,
	 "noctrlc|no-ctrlc|no-ctrl-c" => \$opt::noctrlc,
	 "workdir|work-dir|wd=s" => \$opt::workdir,
	 "W=s" => \$opt::retired,
	 "tmpdir=s" => \$opt::tmpdir,
	 "tempdir=s" => \$opt::tmpdir,
	 "use-compress-program|compress-program=s" => \$opt::compress_program,
	 "use-decompress-program|decompress-program=s" => \$opt::decompress_program,
	 "compress" => \$opt::compress,
	 "tty" => \$opt::tty,
	 "T" => \$opt::retired,
	 "halt-on-error|halt=s" => \$opt::halt_on_error,
	 "H=i" => \$opt::retired,
	 "retries=i" => \$opt::retries,
	 "dry-run|dryrun" => \$opt::dryrun,
	 "progress" => \$opt::progress,
	 "eta" => \$opt::eta,
	 "bar" => \$opt::bar,
	 "arg-sep|argsep=s" => \$opt::arg_sep,
	 "arg-file-sep|argfilesep=s" => \$opt::arg_file_sep,
	 "trim=s" => \$opt::trim,
	 "env=s" => \@opt::env,
	 "recordenv|record-env" => \$opt::record_env,
	 "plain" => \$opt::plain,
	 "profile|J=s" => \@opt::profile,
	 "pipe|spreadstdin" => \$opt::pipe,
	 "robin|round-robin|roundrobin" => \$opt::roundrobin,
	 "recstart=s" => \$opt::recstart,
	 "recend=s" => \$opt::recend,
	 "regexp|regex" => \$opt::regexp,
	 "remove-rec-sep|removerecsep|rrs" => \$opt::remove_rec_sep,
	 "files|output-as-files|outputasfiles" => \$opt::files,
	 "block|block-size|blocksize=s" => \$opt::blocksize,
	 "tollef" => \$opt::retired,
	 "gnu" => \$opt::gnu,
	 "xapply" => \$opt::xapply,
	 "bibtex" => \$opt::bibtex,
	 "nn|nonotice|no-notice" => \$opt::no_notice,
	 # xargs-compatibility - implemented, man, testsuite
	 "max-procs|P=s" => \$opt::jobs,
	 "delimiter|d=s" => \$opt::d,
	 "max-chars|s=i" => \$opt::max_chars,
	 "arg-file|a=s" => \@opt::a,
	 "no-run-if-empty|r" => \$opt::r,
	 "replace|i:s" => \$opt::i,
	 "E=s" => \$opt::E,
	 "eof|e:s" => \$opt::E,
	 "max-args|n=i" => \$opt::max_args,
	 "max-replace-args|N=i" => \$opt::max_replace_args,
	 "colsep|col-sep|C=s" => \$opt::colsep,
	 "help|h" => \$opt::help,
	 "L=f" => \$opt::L,
	 "max-lines|l:f" => \$opt::max_lines,
	 "interactive|p" => \$opt::p,
	 "verbose|t" => \$opt::verbose,
	 "version|V" => \$opt::version,
	 "minversion|min-version=i" => \$opt::minversion,
	 "show-limits|showlimits" => \$opt::show_limits,
	 "exit|x" => \$opt::x,
	 # Semaphore
	 "semaphore" => \$opt::semaphore,
	 "semaphoretimeout=i" => \$opt::semaphoretimeout,
	 "semaphorename|id=s" => \$opt::semaphorename,
	 "fg" => \$opt::fg,
	 "bg" => \$opt::bg,
	 "wait" => \$opt::wait,
	 # Shebang #!/usr/bin/parallel --shebang
	 "shebang|hashbang" => \$opt::shebang,
	 "internal-pipe-means-argfiles" => \$opt::internal_pipe_means_argfiles,
	 "Y" => \$opt::retired,
         "skip-first-line" => \$opt::skip_first_line,
	 "header=s" => \$opt::header,
	 "cat" => \$opt::cat,
	 "fifo" => \$opt::fifo,
	 "pipepart|pipe-part" => \$opt::pipepart,
	);
}

sub get_options_from_array {
    # Run GetOptions on @array
    # Returns:
    #   true if parsing worked
    #   false if parsing failed
    #   @array is changed
    my ($array_ref, @keep_only) = @_;
    # A bit of shuffling of @ARGV needed as GetOptionsFromArray is not
    # supported everywhere
    my @save_argv;
    my $this_is_ARGV = (\@::ARGV == $array_ref);
    if(not $this_is_ARGV) {
	@save_argv = @::ARGV;
	@::ARGV = @{$array_ref};
    }
    # If @keep_only set: Ignore all values except @keep_only
    my %options = options_hash();
    if(@keep_only) {
	my (%keep,@dummy);
	@keep{@keep_only} = @keep_only;
	for my $k (grep { not $keep{$_} } keys %options) {
	    # Store the value of the option in @dummy
	    $options{$k} = \@dummy;
	}
    }
    my $retval = GetOptions(%options);
    if(not $this_is_ARGV) {
	@{$array_ref} = @::ARGV;
	@::ARGV = @save_argv;
    }
    return $retval;
}

sub parse_options {
    # Returns: N/A
    # Defaults:
    $Global::version = 20140722;
    $Global::progname = 'parallel';
    $Global::infinity = 2**31;
    $Global::debug = 0;
    $Global::verbose = 0;
    $Global::grouped = 1;
    $Global::keeporder = 0;
    $Global::quoting = 0;
    # Read only table with default --rpl values
    %Global::replace =
	(
	 '{}'   => '',
	 '{#}'  => '$_=$job->seq()',
	 '{%}'  => '$_=$job->slot()',
	 '{/}'  => 's:.*/::',
	 '{//}' => '$Global::use{"File::Basename"} ||= eval "use File::Basename; 1;"; $_ = dirname($_);',
	 '{/.}' => 's:.*/::; s:\.[^/.]+$::;',
	 '{.}'  => 's:\.[^/.]+$::',
	);
    # Modifiable copy of %Global::replace
    %Global::rpl = %Global::replace;
    $Global::parens = "{==}";
    $/="\n";
    $Global::ignore_empty = 0;
    $Global::interactive = 0;
    $Global::stderr_verbose = 0;
    $Global::default_simultaneous_sshlogins = 9;
    $Global::exitstatus = 0;
    $Global::halt_on_error_exitstatus = 0;
    $Global::arg_sep = ":::";
    $Global::arg_file_sep = "::::";
    $Global::trim = 'n';
    $Global::max_jobs_running = 0;
    $Global::job_already_run = '';

    @ARGV=read_options();

    if(@opt::v) { $Global::verbose = $#opt::v+1; } # Convert -v -v to v=2
    $Global::debug = $opt::D;
    if(defined $opt::X) { $Global::ContextReplace = 1; }
    if(defined $opt::silent) { $Global::verbose = 0; }
    if(defined $opt::keeporder) { $Global::keeporder = 1; }
    if(defined $opt::group) { $Global::grouped = 1; }
    if(defined $opt::u) { $Global::grouped = 0; }
    if(defined $opt::0) { $/ = "\0"; }
    if(defined $opt::d) { my $e="sprintf \"$opt::d\""; $/ = eval $e; }
    if(defined $opt::p) { $Global::interactive = $opt::p; }
    if(defined $opt::q) { $Global::quoting = 1; }
    if(defined $opt::r) { $Global::ignore_empty = 1; }
    if(defined $opt::verbose) { $Global::stderr_verbose = 1; }
    # Deal with --rpl
    sub rpl {
	# Modify %Global::rpl
	# Replace $old with $new
	my ($old,$new) =  @_;
	if($old ne $new) {
	    $Global::rpl{$new} = $Global::rpl{$old};
	    delete $Global::rpl{$old};
	}
    }
    if(defined $opt::parens) { $Global::parens = $opt::parens; }
    my $parenslen = 0.5*length $Global::parens;
    $Global::parensleft = substr($Global::parens,0,$parenslen);
    $Global::parensright = substr($Global::parens,$parenslen);
    if(defined $opt::I) { rpl('{}',$opt::I); }
    if(defined $opt::U) { rpl('{.}',$opt::U); }
    if(defined $opt::i and $opt::i) { rpl('{}',$opt::i); }
    if(defined $opt::basenamereplace) { rpl('{/}',$opt::basenamereplace); }
    if(defined $opt::dirnamereplace) { rpl('{//}',$opt::dirnamereplace); }
    if(defined $opt::seqreplace) { rpl('{#}',$opt::seqreplace); }
    if(defined $opt::slotreplace) { rpl('{%}',$opt::slotreplace); }
    if(defined $opt::basenameextensionreplace) {
       rpl('{/.}',$opt::basenameextensionreplace);
    }
    for(@opt::rpl) {
	# Create $Global::rpl entries for --rpl options
	# E.g: "{..} s:\.[^.]+$:;s:\.[^.]+$:;"
	my ($shorthand,$long) = split/ /,$_,2;
	$Global::rpl{$shorthand} = $long;
    }	
    if(defined $opt::E) { $Global::end_of_file_string = $opt::E; }
    if(defined $opt::max_args) { $Global::max_number_of_args = $opt::max_args; }
    if(defined $opt::timeout) { $Global::timeoutq = TimeoutQueue->new($opt::timeout); }
    if(defined $opt::tmpdir) { $ENV{'TMPDIR'} = $opt::tmpdir; }
    if(defined $opt::help) { die_usage(); }
    if(defined $opt::colsep) { $Global::trim = 'lr'; }
    if(defined $opt::header) { $opt::colsep = defined $opt::colsep ? $opt::colsep : "\t"; }
    if(defined $opt::trim) { $Global::trim = $opt::trim; }
    if(defined $opt::arg_sep) { $Global::arg_sep = $opt::arg_sep; }
    if(defined $opt::arg_file_sep) { $Global::arg_file_sep = $opt::arg_file_sep; }
    if(defined $opt::number_of_cpus) { print SSHLogin::no_of_cpus(),"\n"; wait_and_exit(0); }
    if(defined $opt::number_of_cores) {
        print SSHLogin::no_of_cores(),"\n"; wait_and_exit(0);
    }
    if(defined $opt::max_line_length_allowed) {
        print Limits::Command::real_max_length(),"\n"; wait_and_exit(0);
    }
    if(defined $opt::version) { version(); wait_and_exit(0); }
    if(defined $opt::bibtex) { bibtex(); wait_and_exit(0); }
    if(defined $opt::record_env) { record_env(); wait_and_exit(0); }
    if(defined $opt::show_limits) { show_limits(); }
    if(@opt::sshlogin) { @Global::sshlogin = @opt::sshlogin; }
    if(@opt::sshloginfile) { read_sshloginfiles(@opt::sshloginfile); }
    if(@opt::return) { push @Global::ret_files, @opt::return; }
    if(not defined $opt::recstart and
       not defined $opt::recend) { $opt::recend = "\n"; }
    if(not defined $opt::blocksize) { $opt::blocksize = "1M"; }
    $opt::blocksize = multiply_binary_prefix($opt::blocksize);
    if(defined $opt::semaphore) { $Global::semaphore = 1; }
    if(defined $opt::semaphoretimeout) { $Global::semaphore = 1; }
    if(defined $opt::semaphorename) { $Global::semaphore = 1; }
    if(defined $opt::fg) { $Global::semaphore = 1; }
    if(defined $opt::bg) { $Global::semaphore = 1; }
    if(defined $opt::wait) { $Global::semaphore = 1; }
    if(defined $opt::halt_on_error and $opt::halt_on_error=~/%/) { $opt::halt_on_error /= 100; }
    if(defined $opt::timeout and $opt::timeout !~ /^\d+(\.\d+)?%?$/) {
	::error("--timeout must be seconds or percentage\n");
	wait_and_exit(255);
    }
    if(defined $opt::minversion) {
	print $Global::version,"\n";
	if($Global::version < $opt::minversion) {
	    wait_and_exit(255);
	} else {
	    wait_and_exit(0);
	}
    }
    if(not defined $opt::delay) {
	# Set --delay to --sshdelay if not set
	$opt::delay = $opt::sshdelay;
    }
    if($opt::compress_program) {
	$opt::compress = 1;
	$opt::decompress_program ||= $opt::compress_program." -dc";
    }
    if($opt::compress) {
	my ($compress, $decompress) = find_compression_program();
	$opt::compress_program ||= $compress;
	$opt::decompress_program ||= $decompress;
    }
    if(defined $opt::nonall) {
	# Append a dummy empty argument
	push @ARGV, $Global::arg_sep, "";
    }
    if(defined $opt::tty) {
        # Defaults for --tty: -j1 -u
        # Can be overridden with -jXXX -g
        if(not defined $opt::jobs) {
            $opt::jobs = 1;
        }
        if(not defined $opt::group) {
            $Global::grouped = 0;
        }
    }
    if(@opt::trc) {
        push @Global::ret_files, @opt::trc;
        $opt::transfer = 1;
        $opt::cleanup = 1;
    }
    if(defined $opt::max_lines) {
	if($opt::max_lines eq "-0") {
	    # -l -0 (swallowed -0)
	    $opt::max_lines = 1;
	    $opt::0 = 1;
	    $/ = "\0";
	} elsif ($opt::max_lines == 0) {
	    # If not given (or if 0 is given) => 1
	    $opt::max_lines = 1;
	}
	$Global::max_lines = $opt::max_lines;
	if(not $opt::pipe) {
	    # --pipe -L means length of record - not max_number_of_args
	    $Global::max_number_of_args ||= $Global::max_lines;
	}
    }

    # Read more than one arg at a time (-L, -N)
    if(defined $opt::L) {
	$Global::max_lines = $opt::L;
	if(not $opt::pipe) {
	    # --pipe -L means length of record - not max_number_of_args
	    $Global::max_number_of_args ||= $Global::max_lines;
	}
    }
    if(defined $opt::max_replace_args) {
	$Global::max_number_of_args = $opt::max_replace_args;
	$Global::ContextReplace = 1;
    }
    if((defined $opt::L or defined $opt::max_replace_args)
       and
       not ($opt::xargs or $opt::m)) {
	$Global::ContextReplace = 1;
    }
    if(defined $opt::tag and not defined $opt::tagstring) {
	$opt::tagstring = "\257<\257>"; # Default = {}
    }
    if(defined $opt::pipepart and
       (defined $opt::L or defined $opt::max_lines
	or defined $opt::max_replace_args)) {
	::error("--pipepart is incompatible with --max-replace-args, ",
		"--max-lines, and -L.\n");
	wait_and_exit(255);
    }
    if(grep /^$Global::arg_sep$|^$Global::arg_file_sep$/o, @ARGV) {
        # Deal with ::: and ::::
        @ARGV=read_args_from_command_line();
    }

    # Semaphore defaults
    # Must be done before computing number of processes and max_line_length
    # because when running as a semaphore GNU Parallel does not read args
    $Global::semaphore ||= ($0 =~ m:(^|/)sem$:); # called as 'sem'
    if($Global::semaphore) {
        # A semaphore does not take input from neither stdin nor file
        @opt::a = ("/dev/null");
        push(@Global::unget_argv, [Arg->new("")]);
        $Semaphore::timeout = $opt::semaphoretimeout || 0;
        if(defined $opt::semaphorename) {
            $Semaphore::name = $opt::semaphorename;
        } else {
            $Semaphore::name = `tty`;
            chomp $Semaphore::name;
        }
        $Semaphore::fg = $opt::fg;
        $Semaphore::wait = $opt::wait;
        $Global::default_simultaneous_sshlogins = 1;
        if(not defined $opt::jobs) {
            $opt::jobs = 1;
        }
	if($Global::interactive and $opt::bg) {
	    ::error("Jobs running in the ".
		    "background cannot be interactive.\n");
            ::wait_and_exit(255);
	}
    }
    if(defined $opt::eta) {
        $opt::progress = $opt::eta;
    }
    if(defined $opt::bar) {
        $opt::progress = $opt::bar;
    }
    if(defined $opt::retired) {
	    ::error("-g has been retired. Use --group.\n");
	    ::error("-B has been retired. Use --bf.\n");
	    ::error("-T has been retired. Use --tty.\n");
	    ::error("-U has been retired. Use --er.\n");
	    ::error("-W has been retired. Use --wd.\n");
	    ::error("-Y has been retired. Use --shebang.\n");
	    ::error("-H has been retired. Use --halt.\n");
	    ::error("--tollef has been retired. Use -u -q --arg-sep -- and --load for -l.\n");
            ::wait_and_exit(255);
    }
    citation_notice();

    parse_sshlogin();
    parse_env_var();

    if(remote_hosts() and ($opt::X or $opt::m or $opt::xargs)) {
        # As we do not know the max line length on the remote machine
        # long commands generated by xargs may fail
        # If opt_N is set, it is probably safe
        ::warning("Using -X or -m with --sshlogin may fail.\n");
    }

    if(not defined $opt::jobs) {
        $opt::jobs = "100%";
    }
    open_joblog();
}

sub env_quote {
    my $v = $_[0];
    $v =~ s/([\\])/\\$1/g;
    $v =~ s/([\[\] \#\'\&\<\>\(\)\;\{\}\t\"\$\`\*\174\!\?\~])/\\$1/g;
    $v =~ s/\n/"\n"/g;
    return $v;
}

sub record_env {
    # Record current %ENV-keys in ~/.parallel/ignored_vars
    # Returns: N/A
    my $ignore_filename = $ENV{'HOME'} . "/.parallel/ignored_vars";
    if(open(my $vars_fh, ">", $ignore_filename)) {
	print $vars_fh map { $_,"\n" } keys %ENV;
    } else {
	::error("Cannot write to $ignore_filename\n");
	::wait_and_exit(255);
    }
}

sub parse_env_var {
    # Parse --env and set $Global::envvar
    # Returns: N/A
    $Global::envvar = "";
    $Global::envwarn = "";
    my @vars = ();
    for my $varstring (@opt::env) {
        # Split up --env VAR1,VAR2
	push @vars, split /,/, $varstring;
    }
    if(grep { /^_$/ } @vars) {
	# Include all vars that are not in a clean environment
	if(open(my $vars_fh, "<", $ENV{'HOME'} . "/.parallel/ignored_vars")) {
	    my @ignore = <$vars_fh>;
	    chomp @ignore;
	    my %ignore;
	    @ignore{@ignore} = @ignore;
	    close $vars_fh;
	    push @vars, grep { not defined $ignore{$_} } keys %ENV;
	    @vars = grep { not /^_$/ } @vars;
	} else {
	    ::error("Run '$Global::progname --record-env' in a clean environment first.\n");
	    ::wait_and_exit(255);
	}
    }
    # Keep only defined variables
    @vars = grep { defined($ENV{$_}) } @vars;
    my @qcsh = map { my $a=$_; "setenv $a " . env_quote($ENV{$a})  } @vars;
    my @qbash = map { my $a=$_; "export $a=" . env_quote($ENV{$a}) } @vars;
    my @bash_functions = grep { substr($ENV{$_},0,4) eq "() {" } @vars;
    if(@bash_functions) {
	# Functions are not supported for all shells
	if($ENV{'SHELL'} !~ m:/(bash|rbash|zsh|rzsh|dash|ksh):) {
	    ::warning("Shell functions may not be supported in $ENV{'SHELL'}\n");
	}
    }
    push @qbash, map { my $a=$_; "eval $a\"\$$a\"" } @bash_functions;

    # Check if any variables contain \n
    if(grep /\n/, @ENV{@vars}) {
	# \n is bad for csh and will cause it to fail.
	$Global::envwarn .= ::shell_quote_scalar(q{echo $SHELL | egrep "/t?csh" > /dev/null && echo CSH/TCSH DO NOT SUPPORT newlines IN VARIABLES/FUNCTIONS && exec false;}."\n");
    }

    # Create lines like:
    # echo $SHELL | grep "/t\\{0,1\\}csh" >/dev/null && setenv V1 val1 && setenv V2 val2 || export V1=val1 && export V2=val2 ; echo "$V1$V2"
    if(@vars) {
	$Global::envvar .= 
	    join"", 
	    (q{echo $SHELL | grep "/t\\{0,1\\}csh" > /dev/null && }
	     . join(" && ", @qcsh)
	     . q{ || }
	     . join(" && ", @qbash)
	     .q{;});
    }
    $Global::envvarlen = length $Global::envvar;
}

sub open_joblog {
    my $append = 0;
    if(($opt::resume or $opt::resume_failed)
       and
       not ($opt::joblog or $opt::results)) {
        ::error("--resume and --resume-failed require --joblog or --results.\n");
	::wait_and_exit(255);
    }
    if($opt::joblog) {
	if($opt::resume || $opt::resume_failed) {
	    if(open(my $joblog_fh, "<", $opt::joblog)) {
		# Read the joblog
		$append = <$joblog_fh>; # If there is a header: Open as append later
		my $joblog_regexp;
		if($opt::resume_failed) {
		    # Make a regexp that only matches commands with exit+signal=0
		    # 4 host 1360490623.067 3.445 1023 1222 0 0 command
		    $joblog_regexp='^(\d+)(?:\t[^\t]+){5}\t0\t0\t';
		} else {
		    # Just match the job number
		    $joblog_regexp='^(\d+)';
		}			
		while(<$joblog_fh>) {
		    if(/$joblog_regexp/o) {
			# This is 30% faster than set_job_already_run($1);
			vec($Global::job_already_run,($1||0),1) = 1;
		    } elsif(not /\d+\s+[^\s]+\s+([0-9.]+\s+){6}/) {
			::error("Format of '$opt::joblog' is wrong: $_");
			::wait_and_exit(255);
		    }
		}
		close $joblog_fh;
	    }
	}
	if($append) {
	    # Append to joblog
	    if(not open($Global::joblog, ">>", $opt::joblog)) {
		::error("Cannot append to --joblog $opt::joblog.\n");
		::wait_and_exit(255);
	    }
	} else {
	    if($opt::joblog eq "-") {
		# Use STDOUT as joblog
		$Global::joblog = $Global::fd{1};
	    } elsif(not open($Global::joblog, ">", $opt::joblog)) {
		# Overwrite the joblog
		::error("Cannot write to --joblog $opt::joblog.\n");
		::wait_and_exit(255);
	    }
	    print $Global::joblog
		join("\t", "Seq", "Host", "Starttime", "JobRuntime",
		     "Send", "Receive", "Exitval", "Signal", "Command"
		). "\n";
	}
    }
}

sub find_compression_program {
    # Find a fast compression program
    # Returns:
    #   $compress_program = compress program with options
    #   $decompress_program = decompress program with options

    # Search for these. Sorted by speed
    my @prg = qw(lzop pigz gzip pbzip2 plzip bzip2 lzma lzip xz);
    for my $p (@prg) {
	if(which($p)) {
	    return ("$p -c -1","$p -dc");
	}
    }
    # Fall back to cat
    return ("cat","cat");
}

sub which {
    # Input:
    #   $program = program to find the path to
    # Returns:
    #   $full_path = full path to $program. undef if not found
    my $program = $_[0];
    
    return (grep { -e $_."/".$program } split(":",$ENV{'PATH'}))[0];
}

sub read_options {
    # Read options from command line, profile and $PARALLEL
    # Returns:
    #   @ARGV_no_opt = @ARGV without --options
    # This must be done first as this may exec myself
    if(defined $ARGV[0] and ($ARGV[0] =~ /^--shebang/ or
			     $ARGV[0] =~ /^--shebang-?wrap/ or
			     $ARGV[0] =~ /^--hashbang/)) {
        # Program is called from #! line in script
	# remove --shebang-wrap if it is set
        $opt::shebang_wrap = ($ARGV[0] =~ s/^--shebang-?wrap *//);
	# remove --shebang if it is set
	$opt::shebang = ($ARGV[0] =~ s/^--shebang *//);
	# remove --hashbang if it is set
        $opt::shebang .= ($ARGV[0] =~ s/^--hashbang *//);
	if($opt::shebang) {
	    my $argfile = shell_quote_scalar(pop @ARGV);
	    # exec myself to split $ARGV[0] into separate fields
	    exec "$0 --skip-first-line -a $argfile @ARGV";
	}
	if($opt::shebang_wrap) {
            my @options;
	    my @parser;
	    if ($^O eq 'freebsd') {
		# FreeBSD's #! puts different values in @ARGV than Linux' does.
		my @nooptions = @ARGV;
		get_options_from_array(\@nooptions);
		while($#ARGV > $#nooptions) {
		    push @options, shift @ARGV;
		}
		while(@ARGV and $ARGV[0] ne ":::") {
		    push @parser, shift @ARGV;
		}
		if(@ARGV and $ARGV[0] eq ":::") {
		    shift @ARGV;
		}
	    } else {
		@options = shift @ARGV;
	    }
	    my $script = shell_quote_scalar(shift @ARGV);
	    # exec myself to split $ARGV[0] into separate fields
	    exec "$0 --internal-pipe-means-argfiles @options @parser $script ::: @ARGV";
	}
    }

    Getopt::Long::Configure("bundling","require_order");
    my @ARGV_copy = @ARGV;
    # Check if there is a --profile to set @opt::profile
    get_options_from_array(\@ARGV_copy,"profile|J=s","plain") || die_usage();
    my @ARGV_profile = ();
    my @ARGV_env = ();
    if(not $opt::plain) {
	# Add options from .parallel/config and other profiles
	my @config_profiles = (
	    "/etc/parallel/config",
	    $ENV{'HOME'}."/.parallel/config",
	    $ENV{'HOME'}."/.parallelrc");
	my @profiles = @config_profiles;
	if(@opt::profile) {
	    # --profile overrides default profiles
	    @profiles = ();
	    for my $profile (@opt::profile) {
		if(-r $profile) {
		    push @profiles, $profile;
		} else {
		    push @profiles, $ENV{'HOME'}."/.parallel/".$profile;
		}
	    }
	}
	for my $profile (@profiles) {
	    if(-r $profile) {
		open (my $in_fh, "<", $profile) || ::die_bug("read-profile: $profile");
		while(<$in_fh>) {
		    /^\s*\#/ and next;
		    chomp;
		    push @ARGV_profile, shell_unquote(split/(?<![\\])\s/, $_);
		}
		close $in_fh;
	    } else {
		if(grep /^$profile$/, @config_profiles) {
		    # config file is not required to exist
		} else {
		    ::error("$profile not readable.\n");
		    wait_and_exit(255);
		}
	    }
	}
	# Add options from shell variable $PARALLEL
	if($ENV{'PARALLEL'}) {
	    # Split options on space, but ignore empty options
	    @ARGV_env = grep { /./ } shell_unquote(split/(?<![\\])\s/, $ENV{'PARALLEL'});
	}
    }
    Getopt::Long::Configure("bundling","require_order");
    get_options_from_array(\@ARGV_profile) || die_usage();
    get_options_from_array(\@ARGV_env) || die_usage();
    get_options_from_array(\@ARGV) || die_usage();

    # Prepend non-options to @ARGV (such as commands like 'nice')
    unshift @ARGV, @ARGV_profile, @ARGV_env;
    return @ARGV;
}

sub read_args_from_command_line {
    # Arguments given on the command line after:
    #   ::: ($Global::arg_sep)
    #   :::: ($Global::arg_file_sep)
    # Removes the arguments from @ARGV and:
    # - puts filenames into -a
    # - puts arguments into files and add the files to -a
    # Input:
    #   @::ARGV = command option ::: arg arg arg :::: argfiles
    # Returns:
    #   @argv_no_argsep = @::ARGV without ::: and :::: and following args
    my @new_argv = ();
    for(my $arg = shift @ARGV; @ARGV; $arg = shift @ARGV) {
        if($arg eq $Global::arg_sep
	   or
	   $arg eq $Global::arg_file_sep) {
	    my $group = $arg; # This group of arguments is args or argfiles
	    my @group;
	    while(defined ($arg = shift @ARGV)) {
		if($arg eq $Global::arg_sep
		   or
		   $arg eq $Global::arg_file_sep) {
		    # exit while loop if finding new separator
		    last;
		} else {
		    # If not hitting ::: or ::::
		    # Append it to the group
		    push @group, $arg;
		}
	    }

	    if($group eq $Global::arg_file_sep
	       or ($opt::internal_pipe_means_argfiles and $opt::pipe)
		) {
		# Group of file names on the command line.
		# Append args into -a
		push @opt::a, @group;
	    } elsif($group eq $Global::arg_sep) {
		# Group of arguments on the command line.
		# Put them into a file.
		# Create argfile
		my ($outfh,$name) = ::tempfile(SUFFIX => ".arg");
		unlink($name);
		# Put args into argfile
		print $outfh map { $_,$/ } @group;
		seek $outfh, 0, 0;
		# Append filehandle to -a
		push @opt::a, $outfh;
	    } else {
		::die_bug("Unknown command line group: $group");
	    }
	    if(defined($arg)) {
		# $arg is ::: or ::::
		redo;
	    } else {
		# $arg is undef -> @ARGV empty
		last;
	    }
	}
	push @new_argv, $arg;
    }
    # Output: @ARGV = command to run with options
    return @new_argv;
}

sub cleanup {
    # Returns: N/A
    if(@opt::basefile) { cleanup_basefile(); }
}

sub __QUOTING_ARGUMENTS_FOR_SHELL__ {}

sub shell_quote {
    my @strings = (@_);
    for my $a (@strings) {
        $a =~ s/([\002-\011\013-\032\\\#\?\`\(\)\{\}\[\]\*\>\<\~\|\; \"\!\$\&\'\202-\377])/\\$1/g;
        $a =~ s/[\n]/'\n'/g; # filenames with '\n' is quoted using \'
    }
    return wantarray ? @strings : "@strings";
}

sub shell_quote_empty {
    # Inputs:
    #   @strings = strings to be quoted
    # Returns:
    #   @quoted_strings = empty strings quoted as ''.
    my @strings = shell_quote(@_);
    for my $a (@strings) {
	if($a eq "") {
	    $a = "''";
	}
    }
    return wantarray ? @strings : "@strings";
}

sub shell_quote_scalar {
    # Quote the string so shell will not expand any special chars
    # Inputs:
    #   $string = string to be quoted
    # Returns:
    #   $shell_quoted = string quoted with \ as needed by the shell
    my $a = $_[0];
    if(defined $a) {
	$a =~ s/([\002-\011\013-\032\\\#\?\`\(\)\{\}\[\]\*\>\<\~\|\; \"\!\$\&\'\202-\377])/\\$1/g;
	$a =~ s/[\n]/'\n'/g; # filenames with '\n' is quoted using \'
    }
    return $a;
}

sub shell_quote_file {
    # Quote the string so shell will not expand any special chars and prepend ./ if needed
    # Input:
    #   $filename = filename to be shell quoted
    # Returns:
    #   $quoted_filename = filename quoted with \ as needed by the shell and ./ if needed
    my $a = shell_quote_scalar(shift);
    if(defined $a) {
	if($a =~ m:^/: or $a =~ m:^\./:) {
	    # /abs/path or ./rel/path => skip
	} else {
	    # rel/path => ./rel/path
	    $a = "./".$a;
	}
    }
    return $a;
}

sub maybe_quote {
    # If $Global::quoting is set then quote the string so shell will not expand any special chars
    # Else do not quote
    # Inputs:
    #   $string = string to be quoted
    # Returns:
    #   $maybe_quoted_string = $string quoted if needed
    if($Global::quoting) {
	return shell_quote_scalar(@_);
    } else {
	return "@_";
    }
}

sub maybe_unquote {
    # If $Global::quoting then unquote the string as shell would
    # Else do not unquote
    # Inputs:
    #   $maybe_quoted_string = string to be maybe unquoted
    # Returns:
    #   $string = $maybe_quoted_string unquoted if needed
    if($Global::quoting) {
	return shell_unquote(@_);
    } else {
	return "@_";
    }
}

sub shell_unquote {
    # Unquote strings from shell_quote
    # Inputs:
    #   @strings = strings to be unquoted
    # Returns:
    #   @unquoted_strings = @strings with shell quoting removed
    my @strings = (@_);
    my $arg;
    for my $arg (@strings) {
        if(not defined $arg) {
            $arg = "";
        }
	# filenames with '\n' is quoted using \'\n\'
        $arg =~ s/'\n'/\n/g;
	# Non-printables
        $arg =~ s/\\([\002-\011\013-\032])/$1/g;
	# Shell special chars
        $arg =~ s/\\([\#\?\`\(\)\{\}\*\>\<\~\|\; \"\!\$\&\'])/$1/g;
	# Backslash
        $arg =~ s/\\\\/\\/g;
    }
    return wantarray ? @strings : "@strings";
}

sub __FILEHANDLES__ {}


sub save_stdin_stdout_stderr {
    # Remember the original STDIN, STDOUT and STDERR
    # and file descriptors opened by the shell (e.g. 3>/tmp/foo)
    # Returns: N/A

    # Find file descriptors that are already opened (by the shell)
    for my $fdno (1..61) { 
	# /dev/fd/62 and above are used by bash for <(cmd)
	my $fh;
	if(open($fh,">&=",$fdno)) {
	    $Global::fd{$fdno}=$fh;
	}
    }
    open $Global::original_stderr, ">&", "STDERR" or
	::die_bug("Can't dup STDERR: $!");
    open $Global::original_stdin, "<&", "STDIN" or
	::die_bug("Can't dup STDIN: $!");
}

sub enough_file_handles {
    # Check that we have enough filehandles available for starting
    # another job
    # Returns:
    #   1 if ungrouped (thus not needing extra filehandles)
    #   0 if too few filehandles
    #   1 if enough filehandles
    if($Global::grouped) {
        my %fh;
        my $enough_filehandles = 1;
  	# perl uses 7 filehandles for something?
        # open3 uses 2 extra filehandles temporarily
        # We need a filehandle for each redirected file descriptor 
	# (normally just STDOUT and STDERR)
	for my $i (1..(7+2+keys %Global::fd)) {
            $enough_filehandles &&= open($fh{$i}, "<", "/dev/null");
        }
        for (values %fh) { close $_; }
        return $enough_filehandles;
    } else {
	# Ungrouped does not need extra file handles
	return 1;
    }
}

sub open_or_exit {
    # Open a file name or exit if the file cannot be opened
    # Inputs:
    #   $file = filehandle or filename to open
    # Returns:
    #   $fh = file handle to read-opened file
    my $file = shift;
    if($file eq "-") {
	$Global::stdin_in_opt_a = 1;
	return ($Global::original_stdin || *STDIN);
    }
    if(ref $file eq "GLOB") {
	# This is an open filehandle
	return $file;
    }
    my $fh = gensym;
    if(not open($fh, "<", $file)) {
        ::error("Cannot open input file `$file': No such file or directory.\n");
        wait_and_exit(255);
    }
    return $fh;
}

sub __RUNNING_THE_JOBS_AND_PRINTING_PROGRESS__ {}

# Variable structure:
#
#    $Global::running{$pid} = Pointer to Job-object
#    @Global::virgin_jobs = Pointer to Job-object that have received no input
#    $Global::host{$sshlogin} = Pointer to SSHLogin-object
#    $Global::total_running = total number of running jobs
#    $Global::total_started = total jobs started

sub init_run_jobs {
    $Global::total_running = 0;
    $Global::total_started = 0;
    $Global::tty_taken = 0;
    $SIG{USR1} = \&list_running_jobs;
    $SIG{USR2} = \&toggle_progress;
    if(@opt::basefile) { setup_basefile(); }
}

sub start_more_jobs {
    # Run start_another_job() but only if:
    #   * not $Global::start_no_new_jobs set
    #   * not JobQueue is empty
    #   * not load on server is too high
    #   * not server swapping
    #   * not too short time since last remote login
    # Returns:
    #   $jobs_started = number of jobs started
    my $jobs_started = 0;
    my $jobs_started_this_round = 0;
    if($Global::start_no_new_jobs) {
	return $jobs_started;
    }
    if($Global::max_procs_file) {
	# --jobs filename
	my $mtime = (stat($Global::max_procs_file))[9];
	if($mtime > $Global::max_procs_file_last_mod) {
	    # file changed: Force re-computing max_jobs_running
	    $Global::max_procs_file_last_mod = $mtime;
	    for my $sshlogin (values %Global::host) {
		$sshlogin->set_max_jobs_running(undef);
	    }
	}
    }
    do {
	$jobs_started_this_round = 0;
	# This will start 1 job on each --sshlogin (if possible)
	# thus distribute the jobs on the --sshlogins round robin
	for my $sshlogin (values %Global::host) {
	    if($Global::JobQueue->empty() and not $opt::pipe) {
		# No more jobs in the queue
		last;
	    }
	    debug("run", "Running jobs before on ", $sshlogin->string(), ": ",
		  $sshlogin->jobs_running(), "\n");
	    if ($sshlogin->jobs_running() < $sshlogin->max_jobs_running()) {
		if($opt::load and $sshlogin->loadavg_too_high()) {
		    # The load is too high or unknown
		    next;
		}
		if($opt::noswap and $sshlogin->swapping()) {
		    # The server is swapping
		    next;
		}
		if($sshlogin->too_fast_remote_login()) {
		    # It has been too short since 
		    next;
		}
		if($opt::delay and $opt::delay > ::now() - $Global::newest_starttime) {
		    # It has been too short since last start
		    next;
		}
		debug("run", $sshlogin->string(), " has ", $sshlogin->jobs_running(),
		      " out of ", $sshlogin->max_jobs_running(),
		      " jobs running. Start another.\n");
		if(start_another_job($sshlogin) == 0) {
		    # No more jobs to start on this $sshlogin
		    debug("run","No jobs started on ", $sshlogin->string(), "\n");
		    next;
		}
		$sshlogin->inc_jobs_running();
		$sshlogin->set_last_login_at(::now());
		$jobs_started++;
		$jobs_started_this_round++;
	    }
	    debug("run","Running jobs after on ", $sshlogin->string(), ": ",
		  $sshlogin->jobs_running(), " of ",
		  $sshlogin->max_jobs_running(), "\n");
	}
    } while($jobs_started_this_round);

    return $jobs_started;
}

sub start_another_job {
    # If there are enough filehandles
    #   and JobQueue not empty
    #   and not $job is in joblog
    # Then grab a job from Global::JobQueue,
    #   start it at sshlogin
    #   mark it as virgin_job
    # Inputs:
    #   $sshlogin = the SSHLogin to start the job on
    # Returns:
    #   1 if another jobs was started
    #   0 otherwise
    my $sshlogin = shift;
    # Do we have enough file handles to start another job?
    if(enough_file_handles()) {
        if($Global::JobQueue->empty() and not $opt::pipe) {
            # No more commands to run
	    debug("start", "Not starting: JobQueue empty\n");
	    return 0;
        } else {
            my $job;
	    # Skip jobs already in job log
	    # Skip jobs already in results
            do {
		$job = get_job_with_sshlogin($sshlogin);
		if(not defined $job) {
		    # No command available for that sshlogin
		    debug("start", "Not starting: no jobs available for ",
			  $sshlogin->string(), "\n");
		    return 0;
		}
	    } while ($job->is_already_in_joblog()
		     or
		     ($opt::results and $opt::resume and $job->is_already_in_results()));
	    debug("start", "Command to run on '", $job->sshlogin()->string(), "': '",
		  $job->replaced(),"'\n");
            if($job->start()) {
		if($opt::pipe) {
		    push(@Global::virgin_jobs,$job);
		}
                debug("start", "Started as seq ", $job->seq(),
		      " pid:", $job->pid(), "\n");
                return 1;
            } else {
                # Not enough processes to run the job.
		# Put it back on the queue.
		$Global::JobQueue->unget($job);
		# Count down the number of jobs to run for this SSHLogin.
		my $max = $sshlogin->max_jobs_running();
		if($max > 1) { $max--; } else {
		    ::error("No more processes: cannot run a single job. Something is wrong.\n");
		    ::wait_and_exit(255);
		}
		$sshlogin->set_max_jobs_running($max);
		# Sleep up to 300 ms to give other processes time to die
		::usleep(rand()*300);
		::warning("No more processes: ",
			  "Decreasing number of running jobs to $max. ",
			  "Raising ulimit -u or /etc/security/limits.conf may help.\n");
		return 0;
            }
        }
    } else {
        # No more file handles
	$Global::no_more_file_handles_warned++ or
	    ::warning("No more file handles. ",
		      "Raising ulimit -n or /etc/security/limits.conf may help.\n");
        return 0;
    }
}

sub init_progress {
    # Returns:
    #   list of computers for progress output
    $|=1;
    if($opt::bar) {
	return("","");
    }
    my %progress = progress();
    return ("\nComputers / CPU cores / Max jobs to run\n",
            $progress{'workerlist'});
}

sub drain_job_queue {
    # Returns: N/A
    $Private::first_completed ||= time;
    if($opt::progress) {
        print $Global::original_stderr init_progress();
    }
    my $last_header="";
    my $sleep = 0.2;
    do {
        while($Global::total_running > 0) {
            debug($Global::total_running, "==", scalar
		  keys %Global::running," slots: ", $Global::max_jobs_running);
	    if($opt::pipe) {
		# When using --pipe sometimes file handles are not closed properly
		for my $job (values %Global::running) {
		    close $job->fh(0,"w");
		}
	    }
            if($opt::progress) {
                my %progress = progress();
                if($last_header ne $progress{'header'}) {
                    print $Global::original_stderr "\n", $progress{'header'}, "\n";
                    $last_header = $progress{'header'};
                }
                print $Global::original_stderr "\r",$progress{'status'};
		flush $Global::original_stderr;
            }
	    if($Global::total_running < $Global::max_jobs_running
	       and not $Global::JobQueue->empty()) {
		# These jobs may not be started because of loadavg
		# or too little time between each ssh login.
		if(start_more_jobs() > 0) {
		    # Exponential back-on if jobs were started
		    $sleep = $sleep/2+0.001;
		}
	    }
            # Sometimes SIGCHLD is not registered, so force reaper
	    $sleep = ::reap_usleep($sleep);
        }
        if(not $Global::JobQueue->empty()) {
	    # These jobs may not be started:
	    # * because there the --filter-hosts has removed all
	    if(not %Global::host) {
		::error("There are no hosts left to run on.\n");
		::wait_and_exit(255);
	    }
	    # * because of loadavg
	    # * because of too little time between each ssh login.
            start_more_jobs();
	    $sleep = ::reap_usleep($sleep);
        }
    } while ($Global::total_running > 0
	     or
	     not $Global::start_no_new_jobs and not $Global::JobQueue->empty());
    if($opt::progress) {
	my %progress = progress();
	print $Global::original_stderr "\r", $progress{'status'}, "\n";
	flush $Global::original_stderr;
    }
}

sub toggle_progress {
    # Turn on/off progress view
    # Returns: N/A
    $opt::progress = not $opt::progress;
    if($opt::progress) {
        print $Global::original_stderr init_progress();
    }
}

sub progress {
    # Returns:
    #   list of workers
    #   header that will fit on the screen
    #   status message that will fit on the screen
    my $termcols = terminal_columns();
    my @workers = sort keys %Global::host;
    my %sshlogin = map { $_ eq ":" ? ($_=>"local") : ($_=>$_) } @workers;
    my $workerno = 1;
    my %workerno = map { ($_=>$workerno++) } @workers;
    my $workerlist = "";
    for my $w (@workers) {
        $workerlist .=
        $workerno{$w}.":".$sshlogin{$w} ." / ".
            ($Global::host{$w}->ncpus() || "-")." / ".
            $Global::host{$w}->max_jobs_running()."\n";
    }
    my $eta = "";
    my ($status,$header)=("","");
    if($opt::eta or $opt::bar) {
        my $completed = 0;
        for(@workers) { $completed += $Global::host{$_}->jobs_completed() }
        if($completed) {
	    my $total = $Global::JobQueue->total_jobs();
	    my $left = $total - $completed;
	    my $pctcomplete = $completed / $total;
	    my $timepassed = (time - $Private::first_completed);
	    my $avgtime = $timepassed / $completed;
	    $Private::smoothed_avg_time ||= $avgtime;
	    # Smooth the eta so it does not jump wildly
	    $Private::smoothed_avg_time = (1 - $pctcomplete) *
		$Private::smoothed_avg_time + $pctcomplete * $avgtime;
	    my $this_eta;
	    $Private::last_time ||= $timepassed;
	    if($timepassed != $Private::last_time
	       or not defined $Private::last_eta) {
		$Private::last_time = $timepassed;
		$this_eta = $left * $Private::smoothed_avg_time;
		$Private::last_eta = $this_eta;
	    } else {
		$this_eta = $Private::last_eta;
	    }
	    $eta = sprintf("ETA: %ds Left: %d AVG: %.2fs  ", $this_eta, $left, $avgtime);
	    if($opt::bar) {
		my $arg = $Global::newest_job ? 
		    $Global::newest_job->{'commandline'}->replace_placeholders(["\257<\257>"],0,0) : "";
		my $bar_text = sprintf("%d%% %d:%d=%ds %s", 
				  $pctcomplete*100, $completed, $left, $this_eta, $arg);
		my $rev = '[7m';
		my $reset = '[0m';
		my $terminal_width = terminal_columns();
		my $s = sprintf("%-${terminal_width}s",
				substr($bar_text,0,$terminal_width));
		my $width = int($terminal_width * $pctcomplete);
		$s =~ s/^(.{$width})/$1$reset/;
		$s = "\r#   ".int($this_eta)." sec $arg" . "\r". $pctcomplete*100 # Prefix with zenity header
		    . "\r" . $rev . $s . $reset;  
		$status = $s;
	    }
        }
    }
    if($opt::bar) {
	return ("workerlist" => "", "header" => "", "status" => $status);
    }
    $status = "x"x($termcols+1);
    if(length $status > $termcols) {
        # sshlogin1:XX/XX/XX%/XX.Xs sshlogin2:XX/XX/XX%/XX.Xs sshlogin3:XX/XX/XX%/XX.Xs
        $header = "Computer:jobs running/jobs completed/%of started jobs/Average seconds to complete";
        $status = $eta .
            join(" ",map
                 {
                     if($Global::total_started) {
                         my $completed = ($Global::host{$_}->jobs_completed()||0);
                         my $running = $Global::host{$_}->jobs_running();
                         my $time = $completed ? (time-$^T)/($completed) : "0";
                         sprintf("%s:%d/%d/%d%%/%.1fs ",
                                 $sshlogin{$_}, $running, $completed,
                                 ($running+$completed)*100
                                 / $Global::total_started, $time);
                     }
                 } @workers);
    }
    if(length $status > $termcols) {
        # 1:XX/XX/XX%/XX.Xs 2:XX/XX/XX%/XX.Xs 3:XX/XX/XX%/XX.Xs 4:XX/XX/XX%/XX.Xs
        $header = "Computer:jobs running/jobs completed/%of started jobs";
        $status = $eta .
            join(" ",map
                 {
                     my $completed = ($Global::host{$_}->jobs_completed()||0);
                     my $running = $Global::host{$_}->jobs_running();
                     my $time = $completed ? (time-$^T)/($completed) : "0";
                     sprintf("%s:%d/%d/%d%%/%.1fs ",
                             $workerno{$_}, $running, $completed,
                             ($running+$completed)*100
                             / $Global::total_started, $time);
                 } @workers);
    }
    if(length $status > $termcols) {
        # sshlogin1:XX/XX/XX% sshlogin2:XX/XX/XX% sshlogin3:XX/XX/XX%
        $header = "Computer:jobs running/jobs completed/%of started jobs";
        $status = $eta .
            join(" ",map
                 { sprintf("%s:%d/%d/%d%%",
                           $sshlogin{$_},
                           $Global::host{$_}->jobs_running(),
                           ($Global::host{$_}->jobs_completed()||0),
                           ($Global::host{$_}->jobs_running()+
                            ($Global::host{$_}->jobs_completed()||0))*100
                           / $Global::total_started) }
                 @workers);
    }
    if(length $status > $termcols) {
        # 1:XX/XX/XX% 2:XX/XX/XX% 3:XX/XX/XX% 4:XX/XX/XX% 5:XX/XX/XX% 6:XX/XX/XX%
        $header = "Computer:jobs running/jobs completed/%of started jobs";
        $status = $eta .
            join(" ",map
                 { sprintf("%s:%d/%d/%d%%",
                           $workerno{$_},
                           $Global::host{$_}->jobs_running(),
                           ($Global::host{$_}->jobs_completed()||0),
                           ($Global::host{$_}->jobs_running()+
                            ($Global::host{$_}->jobs_completed()||0))*100
                           / $Global::total_started) }
                 @workers);
    }
    if(length $status > $termcols) {
        # sshlogin1:XX/XX/XX% sshlogin2:XX/XX/XX% sshlogin3:XX/XX sshlogin4:XX/XX
        $header = "Computer:jobs running/jobs completed";
        $status = $eta .
            join(" ",map
                       { sprintf("%s:%d/%d",
                                 $sshlogin{$_}, $Global::host{$_}->jobs_running(),
                                 ($Global::host{$_}->jobs_completed()||0)) }
                       @workers);
    }
    if(length $status > $termcols) {
        # sshlogin1:XX/XX sshlogin2:XX/XX sshlogin3:XX/XX sshlogin4:XX/XX
        $header = "Computer:jobs running/jobs completed";
        $status = $eta .
            join(" ",map
                       { sprintf("%s:%d/%d",
                                 $sshlogin{$_}, $Global::host{$_}->jobs_running(),
                                 ($Global::host{$_}->jobs_completed()||0)) }
                       @workers);
    }
    if(length $status > $termcols) {
        # 1:XX/XX 2:XX/XX 3:XX/XX 4:XX/XX 5:XX/XX 6:XX/XX
        $header = "Computer:jobs running/jobs completed";
        $status = $eta .
            join(" ",map
                       { sprintf("%s:%d/%d",
                                 $workerno{$_}, $Global::host{$_}->jobs_running(),
                                 ($Global::host{$_}->jobs_completed()||0)) }
                       @workers);
    }
    if(length $status > $termcols) {
        # sshlogin1:XX sshlogin2:XX sshlogin3:XX sshlogin4:XX sshlogin5:XX
        $header = "Computer:jobs completed";
        $status = $eta .
            join(" ",map
                       { sprintf("%s:%d",
                                 $sshlogin{$_},
                                 ($Global::host{$_}->jobs_completed()||0)) }
                       @workers);
    }
    if(length $status > $termcols) {
        # 1:XX 2:XX 3:XX 4:XX 5:XX 6:XX
        $header = "Computer:jobs completed";
        $status = $eta .
            join(" ",map
                       { sprintf("%s:%d",
                                 $workerno{$_},
                                 ($Global::host{$_}->jobs_completed()||0)) }
                       @workers);
    }
    return ("workerlist" => $workerlist, "header" => $header, "status" => $status);
}

sub terminal_columns {
    # Get the number of columns of the display
    # Returns:
    #   number of columns of the screen
    if(not $Private::columns) {
        $Private::columns = $ENV{'COLUMNS'};
        if(not $Private::columns) {
            my $resize = qx{ resize 2>/dev/null };
            $resize =~ /COLUMNS=(\d+);/ and do { $Private::columns = $1; };
        }
        $Private::columns ||= 80;
    }
    return $Private::columns;
}

sub get_job_with_sshlogin {
    # Returns:
    #   next job object for $sshlogin if any available
    my $sshlogin = shift;

    my $job = $Global::JobQueue->get();
    if(not defined $job) {
        # No more jobs
	::debug("start", "No more jobs: JobQueue empty\n");
        return undef;
    }

    my $clean_command = $job->replaced();
    if($clean_command =~ /^\s*$/) {
        # Do not run empty lines
        if(not $Global::JobQueue->empty()) {
            return get_job_with_sshlogin($sshlogin);
        } else {
            return undef;
        }
    }
    $job->set_sshlogin($sshlogin);
    if($opt::retries and $clean_command and
       $job->failed_here()) {
        # This command with these args failed for this sshlogin
        my ($no_of_failed_sshlogins,$min_failures) = $job->min_failed();
        if($no_of_failed_sshlogins == keys %Global::host and
           $job->failed_here() == $min_failures) {
            # It failed the same or more times on another host:
            # run it on this host
        } else {
            # If it failed fewer times on another host:
            # Find another job to run
            my $nextjob;
            if(not $Global::JobQueue->empty()) {
		# This can potentially recurse for all args
                no warnings 'recursion';
                $nextjob = get_job_with_sshlogin($sshlogin);
            }
            # Push the command back on the queue
            $Global::JobQueue->unget($job);
            return $nextjob;
        }
    }
    return $job;
}

sub __REMOTE_SSH__ {}

sub read_sshloginfiles {
    # Returns: N/A
    for my $s (@_) {
	read_sshloginfile($s);
    }
}

sub read_sshloginfile {
    # Returns: N/A
    my $file = shift;
    my $close = 1;
    my $in_fh;
    if($file eq "..") {
        $file = $ENV{'HOME'}."/.parallel/sshloginfile";
    }
    if($file eq ".") {
        $file = "/etc/parallel/sshloginfile";
    }
    if($file eq "-") {
	$in_fh = *STDIN;
	$close = 0;
    } else {
	if(not open($in_fh, "<", $file)) {
	    # Try the filename
	    if(not open($in_fh, "<", $ENV{'HOME'}."/.parallel/".$file)) {
		# Try prepending ~/.parallel
		::error("Cannot open $file.\n");
		::wait_and_exit(255);
	    }
	}
    }
    while(<$in_fh>) {
        chomp;
        /^\s*#/ and next;
        /^\s*$/ and next;
        push @Global::sshlogin, $_;
    }
    if($close) {
	close $in_fh;
    }
}

sub parse_sshlogin {
    # Returns: N/A
    my @login;
    if(not @Global::sshlogin) { @Global::sshlogin = (":"); }
    for my $sshlogin (@Global::sshlogin) {
        # Split up -S sshlogin,sshlogin
        for my $s (split /,/, $sshlogin) {
            if ($s eq ".." or $s eq "-") {
                read_sshloginfile($s);
            } else {
                push (@login, $s);
            }
        }
    }
    $Global::minimal_command_line_length = 8_000_000;
    for my $sshlogin_string (@login) {
        my $sshlogin = SSHLogin->new($sshlogin_string);
	if($sshlogin_string eq ":") {
	    $sshlogin->set_maxlength(Limits::Command::max_length());
	} else {
	    # If all chars needs to be quoted, every other character will be \
	    $sshlogin->set_maxlength(Limits::Command::max_length()/2);
	}
	$Global::minimal_command_line_length =
	    ::min($Global::minimal_command_line_length, $sshlogin->maxlength());
        $Global::host{$sshlogin->string()} = $sshlogin;
    }


    debug("start", "sshlogin: ", my_dump(%Global::host),"\n");
    if($opt::transfer or @opt::return or $opt::cleanup or @opt::basefile) {
        if(not remote_hosts()) {
            # There are no remote hosts
            if(@opt::trc) {
		::warning("--trc ignored as there are no remote --sshlogin.\n");
            } elsif (defined $opt::transfer) {
		::warning("--transfer ignored as there are no remote --sshlogin.\n");
            } elsif (@opt::return) {
                ::warning("--return ignored as there are no remote --sshlogin.\n");
            } elsif (defined $opt::cleanup) {
		::warning("--cleanup ignored as there are no remote --sshlogin.\n");
            } elsif (@opt::basefile) {
                ::warning("--basefile ignored as there are no remote --sshlogin.\n");
            }
        }
    }
}

sub remote_hosts {
    # Return sshlogins that are not ':'
    # Returns:
    #   list of sshlogins with ':' removed
    return grep !/^:$/, keys %Global::host;
}

sub setup_basefile {
    # Transfer basefiles to each $sshlogin
    # This needs to be done before first jobs on $sshlogin is run
    # Returns: N/A
    my $cmd = "";
    my $rsync_destdir;
    my $workdir;
    for my $sshlogin (values %Global::host) {
      if($sshlogin->string() eq ":") { next }
      for my $file (@opt::basefile) {
	if($file !~ m:^/: and $opt::workdir eq "...") {
	  ::error("Work dir '...' will not work with relative basefiles\n");
	  ::wait_and_exit(255);
	}
	$workdir ||= Job->new("")->workdir();
	$cmd .= $sshlogin->rsync_transfer_cmd($file,$workdir) . "&";
      }
    }
    $cmd .= "wait;";
    debug("init", "basesetup: $cmd\n");
    print `$cmd`;
}

sub cleanup_basefile {
    # Remove the basefiles transferred
    # Returns: N/A
    my $cmd="";
    my $workdir = Job->new("")->workdir();
    for my $sshlogin (values %Global::host) {
        if($sshlogin->string() eq ":") { next }
        for my $file (@opt::basefile) {
	  $cmd .= $sshlogin->cleanup_cmd($file,$workdir)."&";
        }
    }
    $cmd .= "wait;";
    debug("init", "basecleanup: $cmd\n");
    print `$cmd`;
}

sub filter_hosts {
    my(@cores, @cpus, @maxline, @echo);
    while (my ($host, $sshlogin) = each %Global::host) {
	if($host eq ":") { next }
	# The 'true' is used to get the $host out later
	my $sshcmd = "true $host;" . $sshlogin->sshcommand()." ".$sshlogin->serverlogin();
	push(@cores, $host."\t".$sshcmd." ".$Global::envvar." parallel --number-of-cores\n");
	push(@cpus, $host."\t".$sshcmd." ".$Global::envvar." parallel --number-of-cpus\n");
	push(@maxline, $host."\t".$sshcmd." ".$Global::envvar." parallel --max-line-length-allowed\n");
	# 'echo' is used to get the best possible value for an ssh login time
	push(@echo, $host."\t".$sshcmd." echo\n");
    }
    my ($fh, $tmpfile) = ::tempfile(SUFFIX => ".ssh");
    print $fh @cores, @cpus, @maxline, @echo;
    close $fh;
    # --timeout 5: Setting up an SSH connection and running a simple
    #              command should never take > 5 sec.
    # --delay 0.1: If multiple sshlogins use the same proxy the delay
    #              will make it less likely to overload the ssh daemon.
    # --retries 3: If the ssh daemon it overloaded, try 3 times
    # -s 16000: Half of the max line on UnixWare
    my $cmd = "cat $tmpfile | $0 -j0 --timeout 5 -s 16000 --joblog - --plain --delay 0.1 --retries 3 --tag --tagstring {1} --colsep '\t' -k eval {2} 2>/dev/null";
    ::debug("init", $cmd, "\n");
    open(my $host_fh, "-|", $cmd) || ::die_bug("parallel host check: $cmd");
    my (%ncores, %ncpus, %time_to_login, %maxlen, %echo, @down_hosts);
    while(<$host_fh>) {
	chomp;
	my @col = split /\t/, $_;
	if(defined $col[6]) {
	    # This is a line from --joblog
	    # seq host time spent sent received exit signal command
	    # 2 : 1372607672.654 0.675 0 0 0 0 eval true\ m\;ssh\ m\ parallel\ --number-of-cores
	    if($col[0] eq "Seq" and $col[1] eq "Host" and
		    $col[2] eq "Starttime") {
		# Header => skip
		next;
	    }
	    # Get server from: eval true server\;
	    $col[8] =~ /eval true..([^;]+).;/ or ::die_bug("col8 does not contain host: $col[8]");
	    my $host = $1;
	    $host =~ s/\\//g;
	    $Global::host{$host} or next;
	    if($col[6] eq "255" or $col[7] eq "15") {
		# exit == 255 or signal == 15: ssh failed
		# Remove sshlogin
		::debug("init", "--filtered $host\n");
		push(@down_hosts, $host);
		@down_hosts = uniq(@down_hosts);
	    } elsif($col[6] eq "127") {
		# signal == 127: parallel not installed remote
		# Set ncpus and ncores = 1
		::warning("Could not figure out ",
			  "number of cpus on $host. Using 1.\n");
		$ncores{$host} = 1;
		$ncpus{$host} = 1;
		$maxlen{$host} = Limits::Command::max_length();
	    } elsif($col[0] =~ /^\d+$/ and $Global::host{$host}) {
		# Remember how log it took to log in
		# 2 : 1372607672.654 0.675 0 0 0 0 eval true\ m\;ssh\ m\ echo
		$time_to_login{$host} = ::min($time_to_login{$host},$col[3]);
	    } else {
		::die_bug("host check unmatched long jobline: $_");
	    }
	} elsif($Global::host{$col[0]}) {
	    # This output from --number-of-cores, --number-of-cpus,
	    # --max-line-length-allowed
	    # ncores: server       8
	    # ncpus:  server       2
	    # maxlen: server       131071
	    if(not $ncores{$col[0]}) {
		$ncores{$col[0]} = $col[1];
	    } elsif(not $ncpus{$col[0]}) {
		$ncpus{$col[0]} = $col[1];
	    } elsif(not $maxlen{$col[0]}) {
		$maxlen{$col[0]} = $col[1];
	    } elsif(not $echo{$col[0]}) {
		$echo{$col[0]} = $col[1];
	    } elsif(m/perl: warning:|LANGUAGE =|LC_ALL =|LANG =|are supported and installed/) {
		# Skip these:
		# perl: warning: Setting locale failed.
		# perl: warning: Please check that your locale settings:
		#         LANGUAGE = (unset),
		#         LC_ALL = (unset),
		#         LANG = "en_US.UTF-8"
		#     are supported and installed on your system.
		# perl: warning: Falling back to the standard locale ("C").
	    } else {
		::die_bug("host check too many col0: $_");
	    }
	} else {
	    ::die_bug("host check unmatched short jobline ($col[0]): $_");
	}
    }
    close $host_fh;
    $Global::debug or unlink $tmpfile;
    delete @Global::host{@down_hosts};
    @down_hosts and ::warning("Removed @down_hosts\n");
    $Global::minimal_command_line_length = 8_000_000;
    while (my ($sshlogin, $obj) = each %Global::host) {
	if($sshlogin eq ":") { next }
	$ncpus{$sshlogin} or ::die_bug("ncpus missing: ".$obj->serverlogin());
	$ncores{$sshlogin} or ::die_bug("ncores missing: ".$obj->serverlogin());
	$time_to_login{$sshlogin} or ::die_bug("time_to_login missing: ".$obj->serverlogin());
	$maxlen{$sshlogin} or ::die_bug("maxlen missing: ".$obj->serverlogin());
	if($opt::use_cpus_instead_of_cores) {
	    $obj->set_ncpus($ncpus{$sshlogin});
	} else {
	    $obj->set_ncpus($ncores{$sshlogin});
	}
	$obj->set_time_to_login($time_to_login{$sshlogin});
        $obj->set_maxlength($maxlen{$sshlogin});
	$Global::minimal_command_line_length =
	    ::min($Global::minimal_command_line_length,
		  int($maxlen{$sshlogin}/2));
	::debug("init", "Timing from -S:$sshlogin ncpus:",$ncpus{$sshlogin},
		" ncores:", $ncores{$sshlogin},
		" time_to_login:", $time_to_login{$sshlogin},
		" maxlen:", $maxlen{$sshlogin},
		" min_max_len:", $Global::minimal_command_line_length,"\n");
    }
}

sub onall {
    sub tmp_joblog {
	my $joblog = shift;
	if(not defined $joblog) {
	    return undef;
	}
	my ($fh, $tmpfile) = ::tempfile(SUFFIX => ".log");
	close $fh;
	return $tmpfile;
    }
    my @command = @_;
    if($Global::quoting) {   
       @command = shell_quote_empty(@command);
    }

    # Copy all @fhlist into tempfiles
    my @argfiles = ();
    for my $fh (@fhlist) {
	my ($outfh, $name) = ::tempfile(SUFFIX => ".all", UNLINK => 1);
	print $outfh (<$fh>);
	close $outfh;
	push @argfiles, $name;
    }
    if(@opt::basefile) { setup_basefile(); }
    # for each sshlogin do:
    # parallel -S $sshlogin $command :::: @argfiles
    #
    # Pass some of the options to the sub-parallels, not all of them as
    # -P should only go to the first, and -S should not be copied at all.
    my $options =
	join(" ",
	     ((defined $opt::jobs) ? "-P $opt::jobs" : ""),
	     ((defined $opt::u) ? "-u" : ""),
	     ((defined $opt::group) ? "-g" : ""),
	     ((defined $opt::keeporder) ? "--keeporder" : ""),
	     ((defined $opt::D) ? "-D $opt::D" : ""),
	     ((defined $opt::plain) ? "--plain" : ""),
	     ((defined $opt::max_chars) ? "--max-chars ".$opt::max_chars : ""),
	);
    my $suboptions =
	join(" ",
	     ((defined $opt::u) ? "-u" : ""),
	     ((defined $opt::group) ? "-g" : ""),
	     ((defined $opt::files) ? "--files" : ""),
	     ((defined $opt::keeporder) ? "--keeporder" : ""),
	     ((defined $opt::colsep) ? "--colsep ".shell_quote($opt::colsep) : ""),
	     ((@opt::v) ? "-vv" : ""),
	     ((defined $opt::D) ? "-D $opt::D" : ""),
	     ((defined $opt::timeout) ? "--timeout ".$opt::timeout : ""),
	     ((defined $opt::plain) ? "--plain" : ""),
	     ((defined $opt::retries) ? "--retries ".$opt::retries : ""),
	     ((defined $opt::max_chars) ? "--max-chars ".$opt::max_chars : ""),
	     ((defined $opt::arg_sep) ? "--arg-sep ".$opt::arg_sep : ""),
	     ((defined $opt::arg_file_sep) ? "--arg-file-sep ".$opt::arg_file_sep : ""),
	     (@opt::env ? map { "--env ".::shell_quote_scalar($_) } @opt::env : ""),
	);
    ::debug("init", "| $0 $options\n");
    open(my $parallel_fh, "|-", "$0 --no-notice -j0 $options") ||
	::die_bug("This does not run GNU Parallel: $0 $options");
    my @joblogs;
    for my $host (sort keys %Global::host) {
	my $sshlogin = $Global::host{$host};
	my $joblog = tmp_joblog($opt::joblog);
	if($joblog) {
	    push @joblogs, $joblog;
	    $joblog = "--joblog $joblog";
	}
	my $quad = $opt::arg_file_sep || "::::";
	::debug("init", "$0 $suboptions -j1 $joblog ",
	    ((defined $opt::tag) ?
	     "--tagstring ".shell_quote_scalar($sshlogin->string()) : ""),
	     " -S ", shell_quote_scalar($sshlogin->string())," ",
	     join(" ",shell_quote(@command))," $quad @argfiles\n");
	print $parallel_fh "$0 $suboptions -j1 $joblog ",
	    ((defined $opt::tag) ?
	     "--tagstring ".shell_quote_scalar($sshlogin->string()) : ""),
	     " -S ", shell_quote_scalar($sshlogin->string())," ",
	     join(" ",shell_quote(@command))," $quad @argfiles\n";
    }
    close $parallel_fh;
    $Global::exitstatus = $? >> 8;
    debug("init", "--onall exitvalue ", $?);
    if(@opt::basefile) { cleanup_basefile(); }
    $Global::debug or unlink(@argfiles);
    my %seen;
    for my $joblog (@joblogs) {
	# Append to $joblog
	open(my $fh, "<", $joblog) || ::die_bug("Cannot open tmp joblog $joblog");
	# Skip first line (header);
	<$fh>;
	print $Global::joblog (<$fh>);
	close $fh;
	unlink($joblog);
    }
}

sub __SIGNAL_HANDLING__ {}

sub save_original_signal_handler {
    # Remember the original signal handler
    # Returns: N/A
    $SIG{TERM} ||= sub { exit 0; }; # $SIG{TERM} is not set on Mac OS X
    $SIG{INT} = sub { if($opt::tmux) { qx { tmux kill-session -t p$$ }; } 
		      unlink keys %Global::unlink; exit -1  };
    $SIG{TERM} = sub { if($opt::tmux) { qx { tmux kill-session -t p$$ }; } 
		      unlink keys %Global::unlink; exit -1  };
    %Global::original_sig = %SIG;
    $SIG{TERM} = sub {}; # Dummy until jobs really start
}

sub list_running_jobs {
    # Returns: N/A
    for my $v (values %Global::running) {
        print $Global::original_stderr "$Global::progname: ",$v->replaced(),"\n";
    }
}

sub start_no_new_jobs {
    # Returns: N/A
    $SIG{TERM} = $Global::original_sig{TERM};
    print $Global::original_stderr
        ("$Global::progname: SIGTERM received. No new jobs will be started.\n",
         "$Global::progname: Waiting for these ", scalar(keys %Global::running),
         " jobs to finish. Send SIGTERM again to stop now.\n");
    list_running_jobs();
    $Global::start_no_new_jobs ||= 1;
}

sub reaper {
    # A job finished.
    # Print the output.
    # Start another job
    # Returns: N/A
    my $stiff;
    my $children_reaped = 0;
    debug("run", "Reaper ");
    while (($stiff = waitpid(-1, &WNOHANG)) > 0) {
	$children_reaped++;
        if($Global::sshmaster{$stiff}) {
            # This is one of the ssh -M: ignore
            next;
        }
        my $job = $Global::running{$stiff};
	# '-a <(seq 10)' will give us a pid not in %Global::running
        $job or next;
        $job->set_exitstatus($? >> 8);
        $job->set_exitsignal($? & 127);
        debug("run", "died (", $job->exitstatus(), "): ", $job->seq());
        $job->set_endtime(::now());
        if($stiff == $Global::tty_taken) {
            # The process that died had the tty => release it
            $Global::tty_taken = 0;
        }

        if(not $job->should_be_retried()) {
	    # The job is done
	    # Free the jobslot
	    push @Global::slots, $job->slot();
	    if($opt::timeout) {
		# Update average runtime for timeout
		$Global::timeoutq->update_delta_time($job->runtime());
	    }
            # Force printing now if the job failed and we are going to exit
            my $print_now = ($opt::halt_on_error and $opt::halt_on_error == 2
			     and $job->exitstatus());
            if($Global::keeporder and not $print_now) {
                $Private::print_later{$job->seq()} = $job;
                $Private::job_end_sequence ||= 1;
                debug("run", "Looking for: $Private::job_end_sequence ",
                      "Current: ", $job->seq(), "\n");
		for(my $j = $Private::print_later{$Private::job_end_sequence};
		    $j or vec($Global::job_already_run,$Private::job_end_sequence,1);
                    $Private::job_end_sequence++,
		    $j = $Private::print_later{$Private::job_end_sequence}) {
                    debug("run", "Found job end $Private::job_end_sequence");
                    if($j) { 
			$j->print();
			delete $Private::print_later{$Private::job_end_sequence};
		    }
		}		    
            } else {
                $job->print();
            }
            if($job->exitstatus()) {
                # The jobs had a exit status <> 0, so error
                $Global::exitstatus++;
		$Global::total_failed++;
                if($opt::halt_on_error) {
                    if($opt::halt_on_error == 1
			or
		       ($opt::halt_on_error < 1 and $Global::total_failed > 3 
			and
			$Global::total_failed / $Global::total_started > $opt::halt_on_error)) {
                        # If halt on error == 1 or --halt 10%
			# we should gracefully exit
                        print $Global::original_stderr
                            ("$Global::progname: Starting no more jobs. ",
                             "Waiting for ", scalar(keys %Global::running),
                             " jobs to finish. This job failed:\n",
                             $job->replaced(),"\n");
                        $Global::start_no_new_jobs ||= 1;
                        $Global::halt_on_error_exitstatus = $job->exitstatus();
                    } elsif($opt::halt_on_error == 2) {
                        # If halt on error == 2 we should exit immediately
                        print $Global::original_stderr
                            ("$Global::progname: This job failed:\n",
                             $job->replaced(),"\n");
                        exit ($job->exitstatus());
                    }
                }
            }
        }
        my $sshlogin = $job->sshlogin();
        $sshlogin->dec_jobs_running();
        $sshlogin->inc_jobs_completed();
        $Global::total_running--;
        delete $Global::running{$stiff};
	start_more_jobs();
    }
    debug("run", "done ");
    return $children_reaped;
}

sub __USAGE__ {}

sub wait_and_exit {
    # If we do not wait, we sometimes get segfault
    # Returns: N/A
    my $error = shift;
    if($error) {
	# Kill all without printing
	for my $job (values %Global::running) {
	    $job->kill("TERM");
	    $job->kill("TERM");
	}
    }
    for (keys %Global::unkilled_children) {
        kill 9, $_;
        waitpid($_,0);
        delete $Global::unkilled_children{$_};
    }
    wait();
    exit($error);
}

sub die_usage {
    # Returns: N/A
    usage();
    wait_and_exit(255);
}

sub usage {
    # Returns: N/A
    print join
	("\n",
	 "Usage:",
	 "$Global::progname [options] [command [arguments]] < list_of_arguments",
	 "$Global::progname [options] [command [arguments]] (::: arguments|:::: argfile(s))...",
	 "cat ... | $Global::progname --pipe [options] [command [arguments]]",
	 "",
	 "-j n           Run n jobs in parallel",
	 "-k             Keep same order",
	 "-X             Multiple arguments with context replace",
	 "--colsep regexp         Split input on regexp for positional replacements",
	 "{} {.} {/} {/.} {#} {%} Replacement strings",
	 "{3} {3.} {3/} {3/.}     Positional replacement strings",
	 "",
	 "-S sshlogin    Example: foo\@server.example.com",
	 "--slf ..       Use ~/.parallel/sshloginfile as the list of sshlogins",
	 "--trc {}.bar   Shorthand for --transfer --return {}.bar --cleanup",
	 "--onall        Run the given command with argument on all sshlogins",
	 "--nonall       Run the given command with no arguments on all sshlogins",
	 "",
	 "--pipe         Split stdin (standard input) to multiple jobs.",
	 "--recend str   Record end separator for --pipe.",
	 "--recstart str Record start separator for --pipe.",
	 "",
	 "See 'man $Global::progname' for details",
	 "",
	 "When using programs that use GNU Parallel to process data for publication please cite:",
	 "",
	 "O. Tange (2011): GNU Parallel - The Command-Line Power Tool,",
	 ";login: The USENIX Magazine, February 2011:42-47.",
	 "");
}


sub citation_notice {
    # if --no-notice or --plain: do nothing
    # if stderr redirected: do nothing
    # if ~/.parallel/will-cite: do nothing
    # else: print citation notice to stderr
    if($opt::no_notice
       or
       $opt::plain
       or
       not -t $Global::original_stderr
       or
       -e $ENV{'HOME'}."/.parallel/will-cite") {
	# skip
    } else {
	print $Global::original_stderr 
	    ("When using programs that use GNU Parallel to process data for publication please cite:\n",
	     "\n",
	     "  O. Tange (2011): GNU Parallel - The Command-Line Power Tool,\n",
	     "  ;login: The USENIX Magazine, February 2011:42-47.\n",
	     "\n",
	     "This helps funding further development; and it won't cost you a cent.\n",
	     "\n",
	     "To silence this citation notice run 'parallel --bibtex' once or use '--no-notice'.\n\n",
	    );
	flush $Global::original_stderr;
    }
}


sub warning {
    my @w = @_;
    my $fh = $Global::original_stderr || *STDERR;
    my $prog = $Global::progname || "parallel";
    print $fh $prog, ": Warning: ", @w;
}


sub error {
    my @w = @_;
    my $fh = $Global::original_stderr || *STDERR;
    my $prog = $Global::progname || "parallel";
    print $fh $prog, ": Error: ", @w;
}


sub die_bug {
    my $bugid = shift;
    print STDERR
	("$Global::progname: This should not happen. You have found a bug.\n",
	 "Please contact <parallel\@gnu.org> and include:\n",
	 "* The version number: $Global::version\n",
	 "* The bugid: $bugid\n",
	 "* The command line being run\n",
	 "* The files being read (put the files on a webserver if they are big)\n",
	 "\n",
	 "If you get the error on smaller/fewer files, please include those instead.\n");
    ::wait_and_exit(255);
}

sub version {
    # Returns: N/A
    if($opt::tollef and not $opt::gnu) {
	print "WARNING: YOU ARE USING --tollef. IF THINGS ARE ACTING WEIRD USE --gnu.\n";
    }
    print join("\n",
               "GNU $Global::progname $Global::version",
               "Copyright (C) 2007,2008,2009,2010,2011,2012,2013,2014 Ole Tange and Free Software Foundation, Inc.",
               "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>",
               "This is free software: you are free to change and redistribute it.",
               "GNU $Global::progname comes with no warranty.",
               "",
               "Web site: http://www.gnu.org/software/${Global::progname}\n",
	       "When using programs that use GNU Parallel to process data for publication please cite:\n",
	       "O. Tange (2011): GNU Parallel - The Command-Line Power Tool, ",
	       ";login: The USENIX Magazine, February 2011:42-47.\n",
        );
}

sub bibtex {
    # Returns: N/A
    if($opt::tollef and not $opt::gnu) {
	print "WARNING: YOU ARE USING --tollef. IF THINGS ARE ACTING WEIRD USE --gnu.\n";
    }
    print join("\n",
	       "When using programs that use GNU Parallel to process data for publication please cite:",
	       "",
               "\@article{Tange2011a,",
	       " title = {GNU Parallel - The Command-Line Power Tool},",
	       " author = {O. Tange},",
	       " address = {Frederiksberg, Denmark},",
	       " journal = {;login: The USENIX Magazine},",
	       " month = {Feb},",
	       " number = {1},",
	       " volume = {36},",
	       " url = {http://www.gnu.org/s/parallel},",
	       " year = {2011},",
	       " pages = {42-47}",
	       "}",
	       "",
	       "(Feel free to use \\nocite{Tange2011a})",
	       "",
	       "This helps funding further development.",
	       ""
        );
    while(not -e $ENV{'HOME'}."/.parallel/will-cite") {
	print "\nType: 'will cite' and press enter.\n> ";
	my $input = <STDIN>;
	if($input =~ /will cite/i) {
	    mkdir $ENV{'HOME'}."/.parallel";
	    open (my $fh, ">", $ENV{'HOME'}."/.parallel/will-cite") 
		|| ::die_bug("Cannot write: ".$ENV{'HOME'}."/.parallel/will-cite");
	    close $fh;
	    print "\nThank you for your support. It is much appreciated. The citation\n",
	    "notice is now silenced.\n";
	}
    }
}

sub show_limits {
    # Returns: N/A
    print("Maximal size of command: ",Limits::Command::real_max_length(),"\n",
          "Maximal used size of command: ",Limits::Command::max_length(),"\n",
          "\n",
          "Execution of  will continue now, and it will try to read its input\n",
          "and run commands; if this is not what you wanted to happen, please\n",
          "press CTRL-D or CTRL-C\n");
}

sub __GENERIC_COMMON_FUNCTION__ {}

sub uniq {
    # Remove duplicates and return unique values
    return keys %{{ map { $_ => 1 } @_ }};
}

sub min {
    # Returns:
    #   Minimum value of array
    my $min;
    for (@_) {
        # Skip undefs
        defined $_ or next;
        defined $min or do { $min = $_; next; }; # Set $_ to the first non-undef
        $min = ($min < $_) ? $min : $_;
    }
    return $min;
}

sub max {
    # Returns:
    #   Maximum value of array
    my $max;
    for (@_) {
        # Skip undefs
        defined $_ or next;
        defined $max or do { $max = $_; next; }; # Set $_ to the first non-undef
        $max = ($max > $_) ? $max : $_;
    }
    return $max;
}

sub sum {
    # Returns:
    #   Sum of values of array
    my @args = @_;
    my $sum = 0;
    for (@args) {
        # Skip undefs
        $_ and do { $sum += $_; }
    }
    return $sum;
}

sub undef_as_zero {
    my $a = shift;
    return $a ? $a : 0;
}

sub undef_as_empty {
    my $a = shift;
    return $a ? $a : "";
}

sub hostname {
    if(not $Private::hostname) {
        my $hostname = `hostname`;
        chomp($hostname);
        $Private::hostname = $hostname || "nohostname";
    }
    return $Private::hostname;
}

sub reap_usleep {
    # Reap dead children.
    # If no dead children: Sleep specified amount with exponential backoff
    # Returns:
    #   $ms/2+0.001 if children reaped
    #   $ms*1.1 if no children reaped
    my $ms = shift;
    if(reaper()) {
	# Sleep exponentially shorter (1/2^n) if a job finished
	return $ms/2+0.001;
    } else {
	if($opt::timeout) {
	    $Global::timeoutq->process_timeouts();
	}
	usleep($ms);
	Job::exit_if_disk_full();
	if($opt::linebuffer) {
	    for my $job (values %Global::running) {
		$job->print();
	    }
	}
	# Sleep exponentially longer (1.1^n) if a job did not finish
	# though at most 1000 ms.
	return (($ms < 1000) ? ($ms * 1.1) : ($ms));
    }
}

sub usleep {
    # Sleep this many milliseconds.
    my $secs = shift;
    ::debug(int($secs),"ms ");
    select(undef, undef, undef, $secs/1000);
}

sub now {
    # Returns time since epoch as in seconds with 3 decimals

    if(not $Global::use{"Time::HiRes"}) {
	if(eval "use Time::HiRes qw ( time );") {
	    eval "sub TimeHiRestime { return Time::HiRes::time };";
	} else {
	    eval "sub TimeHiRestime { return time() };";
	}
	$Global::use{"Time::HiRes"} = 1;
    }

    return (int(TimeHiRestime()*1000))/1000;
}

sub multiply_binary_prefix {
    # Evalualte numbers with binary prefix
    # Ki=2^10, Mi=2^20, Gi=2^30, Ti=2^40, Pi=2^50, Ei=2^70, Zi=2^80, Yi=2^80
    # ki=2^10, mi=2^20, gi=2^30, ti=2^40, pi=2^50, ei=2^70, zi=2^80, yi=2^80
    # K =2^10, M =2^20, G =2^30, T =2^40, P =2^50, E =2^70, Z =2^80, Y =2^80
    # k =10^3, m =10^6, g =10^9, t=10^12, p=10^15, e=10^18, z=10^21, y=10^24
    # 13G = 13*1024*1024*1024 = 13958643712
    my $s = shift;
    $s =~ s/ki/*1024/gi;
    $s =~ s/mi/*1024*1024/gi;
    $s =~ s/gi/*1024*1024*1024/gi;
    $s =~ s/ti/*1024*1024*1024*1024/gi;
    $s =~ s/pi/*1024*1024*1024*1024*1024/gi;
    $s =~ s/ei/*1024*1024*1024*1024*1024*1024/gi;
    $s =~ s/zi/*1024*1024*1024*1024*1024*1024*1024/gi;
    $s =~ s/yi/*1024*1024*1024*1024*1024*1024*1024*1024/gi;
    $s =~ s/xi/*1024*1024*1024*1024*1024*1024*1024*1024*1024/gi;

    $s =~ s/K/*1024/g;
    $s =~ s/M/*1024*1024/g;
    $s =~ s/G/*1024*1024*1024/g;
    $s =~ s/T/*1024*1024*1024*1024/g;
    $s =~ s/P/*1024*1024*1024*1024*1024/g;
    $s =~ s/E/*1024*1024*1024*1024*1024*1024/g;
    $s =~ s/Z/*1024*1024*1024*1024*1024*1024*1024/g;
    $s =~ s/Y/*1024*1024*1024*1024*1024*1024*1024*1024/g;
    $s =~ s/X/*1024*1024*1024*1024*1024*1024*1024*1024*1024/g;

    $s =~ s/k/*1000/g;
    $s =~ s/m/*1000*1000/g;
    $s =~ s/g/*1000*1000*1000/g;
    $s =~ s/t/*1000*1000*1000*1000/g;
    $s =~ s/p/*1000*1000*1000*1000*1000/g;
    $s =~ s/e/*1000*1000*1000*1000*1000*1000/g;
    $s =~ s/z/*1000*1000*1000*1000*1000*1000*1000/g;
    $s =~ s/y/*1000*1000*1000*1000*1000*1000*1000*1000/g;
    $s =~ s/x/*1000*1000*1000*1000*1000*1000*1000*1000*1000/g;

    $s = eval $s;
    ::debug($s);
    return $s;
}

sub __DEBUGGING__ {}

sub debug {
    # Returns: N/A
    $Global::debug or return;
    @_ = grep { defined $_ ? $_ : "" } @_;
    if($Global::debug eq "all" or $Global::debug eq $_[0]) {
	if($Global::fd{1}) {
	    # Original stdout was saved
	    my $stdout = $Global::fd{1};
	    print $stdout @_[1..$#_];
	} else {
	    print @_[1..$#_];
	}
    }
}

sub my_memory_usage {
    # Returns:
    #   memory usage if found
    #   0 otherwise
    use strict;
    use FileHandle;

    my $pid = $$;
    if(-e "/proc/$pid/stat") {
        my $fh = FileHandle->new("</proc/$pid/stat");

        my $data = <$fh>;
        chomp $data;
        $fh->close;

        my @procinfo = split(/\s+/,$data);

        return undef_as_zero($procinfo[22]);
    } else {
        return 0;
    }
}

sub my_size {
    # Returns:
    #   size of object if Devel::Size is installed
    #   -1 otherwise
    my @size_this = (@_);
    eval "use Devel::Size qw(size total_size)";
    if ($@) {
        return -1;
    } else {
        return total_size(@_);
    }
}

sub my_dump {
    # Returns:
    #   ascii expression of object if Data::Dump(er) is installed
    #   error code otherwise
    my @dump_this = (@_);
    eval "use Data::Dump qw(dump);";
    if ($@) {
        # Data::Dump not installed
        eval "use Data::Dumper;";
        if ($@) {
            my $err =  "Neither Data::Dump nor Data::Dumper is installed\n".
                "Not dumping output\n";
            print $Global::original_stderr $err;
            return $err;
        } else {
            return Dumper(@dump_this);
        }
    } else {
	# Create a dummy Data::Dump:dump as Hans Schou sometimes has
	# it undefined
	eval "sub Data::Dump:dump {}";
        eval "use Data::Dump qw(dump);";
        return (Data::Dump::dump(@dump_this));
    }
}

sub my_croak {
    eval "use Carp; 1";
    $Carp::Verbose = 1;
    croak(@_);
}

sub my_carp {
    eval "use Carp; 1";
    $Carp::Verbose = 1;
    carp(@_);
}

sub __OBJECT_ORIENTED_PARTS__ {}

package SSHLogin;

sub new {
    my $class = shift;
    my $sshlogin_string = shift;
    my $ncpus;
    if($sshlogin_string =~ s:^(\d+)/:: and $1) {
        # Override default autodetected ncpus unless zero or missing
        $ncpus = $1;
    }
    my $string = $sshlogin_string;
    my @unget = ();
    my $no_slash_string = $string;
    $no_slash_string =~ s/[^-a-z0-9:]/_/gi;
    return bless {
        'string' => $string,
        'jobs_running' => 0,
        'jobs_completed' => 0,
        'maxlength' => undef,
        'max_jobs_running' => undef,
        'ncpus' => $ncpus,
        'sshcommand' => undef,
        'serverlogin' => undef,
        'control_path_dir' => undef,
        'control_path' => undef,
	'time_to_login' => undef,
	'last_login_at' => undef,
        'loadavg_file' => $ENV{'HOME'} . "/.parallel/tmp/loadavg-" .
            $no_slash_string,
        'loadavg' => undef,
	'last_loadavg_update' => 0,
        'swap_activity_file' => $ENV{'HOME'} . "/.parallel/tmp/swap_activity-" .
            $no_slash_string,
        'swap_activity' => undef,
    }, ref($class) || $class;
}

sub DESTROY {
    my $self = shift;
    # Remove temporary files if they are created.
    unlink $self->{'loadavg_file'};
    unlink $self->{'swap_activity_file'};
}

sub string {
    my $self = shift;
    return $self->{'string'};
}

sub jobs_running {
    my $self = shift;

    return ($self->{'jobs_running'} || "0");
}

sub inc_jobs_running {
    my $self = shift;
    $self->{'jobs_running'}++;
}

sub dec_jobs_running {
    my $self = shift;
    $self->{'jobs_running'}--;
}

#sub set_jobs_running {
#    my $self = shift;
#    $self->{'jobs_running'} = shift;
#}

sub set_maxlength {
    my $self = shift;
    $self->{'maxlength'} = shift;
}

sub maxlength {
    my $self = shift;
    return $self->{'maxlength'};
}

sub jobs_completed {
    my $self = shift;
    return $self->{'jobs_completed'};
}

sub inc_jobs_completed {
    my $self = shift;
    $self->{'jobs_completed'}++;
}

sub set_max_jobs_running {
    my $self = shift;
    if(defined $self->{'max_jobs_running'}) {
        $Global::max_jobs_running -= $self->{'max_jobs_running'};
    }
    $self->{'max_jobs_running'} = shift;
    if(defined $self->{'max_jobs_running'}) {
        # max_jobs_running could be resat if -j is a changed file
        $Global::max_jobs_running += $self->{'max_jobs_running'};
    }
}

sub swapping {
    my $self = shift;
    my $swapping = $self->swap_activity();
    return (not defined $swapping or $swapping)
}

sub swap_activity {
    # If the currently known swap activity is too old:
    #   Recompute a new one in the background
    # Returns:
    #   last swap activity computed
    my $self = shift;
    # Should we update the swap_activity file?
    my $update_swap_activity_file = 0;
    if(-r $self->{'swap_activity_file'}) {
        open(my $swap_fh, "<", $self->{'swap_activity_file'}) || ::die_bug("swap_activity_file-r");
        my $swap_out = <$swap_fh>;
        close $swap_fh;
        if($swap_out =~ /^(\d+)$/) {
            $self->{'swap_activity'} = $1;
            ::debug("swap", "New swap_activity: ", $self->{'swap_activity'});
        }
        ::debug("swap", "Last update: ", $self->{'last_swap_activity_update'});
        if(time - $self->{'last_swap_activity_update'} > 10) {
            # last swap activity update was started 10 seconds ago
            ::debug("swap", "Older than 10 sec: ", $self->{'swap_activity_file'});
            $update_swap_activity_file = 1;
        }
    } else {
        ::debug("swap", "No swap_activity file: ", $self->{'swap_activity_file'});
        $self->{'swap_activity'} = undef;
        $update_swap_activity_file = 1;
    }
    if($update_swap_activity_file) {
        ::debug("swap", "Updating swap_activity file ", $self->{'swap_activity_file'});
        $self->{'last_swap_activity_update'} = time;
        -e $ENV{'HOME'}."/.parallel" or mkdir $ENV{'HOME'}."/.parallel";
        -e $ENV{'HOME'}."/.parallel/tmp" or mkdir $ENV{'HOME'}."/.parallel/tmp";
        my $swap_activity;
	$swap_activity = swapactivityscript();
        if($self->{'string'} ne ":") {
            $swap_activity = $self->sshcommand() . " " . $self->serverlogin() . " " .
		::shell_quote_scalar($swap_activity);
        }
        # Run swap_activity measuring.
        # As the command can take long to run if run remote
        # save it to a tmp file before moving it to the correct file
        my $file = $self->{'swap_activity_file'};
        my ($dummy_fh, $tmpfile) = ::tempfile(SUFFIX => ".swp");
	::debug("swap", "\n", $swap_activity, "\n");
        qx{ ($swap_activity > $tmpfile && mv $tmpfile $file || rm $tmpfile) & };
    }
    return $self->{'swap_activity'};
}

{
    my $script;

    sub swapactivityscript {
	# Returns:
	#   shellscript for detecting swap activity
	#
	# arguments for vmstat are OS dependant
	# swap_in and swap_out are in different columns depending on OS
	#
	if(not $script) {
	    my %vmstat = (
		# linux: $7*$8
		# $ vmstat 1 2
		# procs -----------memory---------- ---swap-- -----io---- -system-- ----cpu----
		#  r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa
		#  5  0  51208 1701096 198012 18857888    0    0    37   153   28   19 56 11 33  1
		#  3  0  51208 1701288 198012 18857972    0    0     0     0 3638 10412 15  3 82  0
		'linux' => ['vmstat 1 2 | tail -n1', '$7*$8'],
		
		# solaris: $6*$7
		# $ vmstat -S 1 2
		#  kthr      memory            page            disk          faults      cpu
		#  r b w   swap  free  si  so pi po fr de sr s3 s4 -- --   in   sy   cs us sy id
		#  0 0 0 4628952 3208408 0  0  3  1  1  0  0 -0  2  0  0  263  613  246  1  2 97
		#  0 0 0 4552504 3166360 0  0  0  0  0  0  0  0  0  0  0  246  213  240  1  1 98
		'solaris' => ['vmstat -S 1 2 | tail -1', '$6*$7'],
		
		# darwin (macosx): $21*$22
		# $ vm_stat -c 2 1
		# Mach Virtual Memory Statistics: (page size of 4096 bytes)
		#     free   active   specul inactive throttle    wired  prgable   faults     copy    0fill reactive   purged file-backed anonymous cmprssed cmprssor  dcomprs   comprs  pageins  pageout  swapins swapouts
		#   346306   829050    74871   606027        0   240231    90367  544858K 62343596  270837K    14178   415070      570102    939846      356      370      116      922  4019813        4        0        0 
		#   345740   830383    74875   606031        0   239234    90369     2696      359      553        0        0      570110    941179      356      370        0        0        0        0        0        0 
		'darwin' => ['vm_stat -c 2 1 | tail -n1', '$21*$22'],
		
		# ultrix: $12*$13
		# $ vmstat -S 1 2
		#  procs      faults    cpu      memory              page             disk  
		#  r b w   in  sy  cs us sy id  avm  fre  si so  pi  po  fr  de  sr s0 
		#  1 0 0    4  23   2  3  0 97 7743 217k   0  0   0   0   0   0   0  0
		#  1 0 0    6  40   8  0  1 99 7743 217k   0  0   3   0   0   0   0  0
		'ultrix' => ['vmstat -S 1 2 | tail -1', '$12*$13'],
		
		# aix: $6*$7
		# $ vmstat 1 2
		# System configuration: lcpu=1 mem=2048MB
		# 
		# kthr    memory              page              faults        cpu    
		# ----- ----------- ------------------------ ------------ -----------
		#  r  b   avm   fre  re  pi  po  fr   sr  cy  in   sy  cs us sy id wa
		#  0  0 333933 241803   0   0   0   0    0   0  10  143  90  0  0 99  0
		#  0  0 334125 241569   0   0   0   0    0   0  37 5368 184  0  9 86  5
		'aix' => ['vmstat 1 2 | tail -n1', '$6*$7'],
		
		# freebsd: $8*$9
		# $ vmstat -H 1 2
		#  procs      memory      page                    disks     faults         cpu
		#  r b w     avm    fre   flt  re  pi  po    fr  sr ad0 ad1   in   sy   cs us sy id
		#  1 0 0  596716   19560    32   0   0   0    33   8   0   0   11  220  277  0  0 99
		#  0 0 0  596716   19560     2   0   0   0     0   0   0   0   11  144  263  0  1 99
		'freebsd' => ['vmstat -H 1 2 | tail -n1', '$8*$9'],
		
		# mirbsd: $8*$9
		# $ vmstat 1 2
		#  procs   memory        page                    disks     traps         cpu
		#  r b w    avm    fre   flt  re  pi  po  fr  sr wd0 cd0  int   sys   cs us sy id
		#  0 0 0  25776 164968    34   0   0   0   0   0   0   0  230   259   38  4  0 96
		#  0 0 0  25776 164968    24   0   0   0   0   0   0   0  237   275   37  0  0 100
		'mirbsd' => ['vmstat 1 2 | tail -n1', '$8*$9'],
		
		# netbsd: $7*$8
		# $ vmstat 1 2
		#  procs    memory      page                       disks   faults      cpu
		#  r b      avm    fre  flt  re  pi   po   fr   sr w0 w1   in   sy  cs us sy id
		#  0 0   138452   6012   54   0   0    0    1    2  3  0    4  100  23  0  0 100
		#  0 0   138456   6008    1   0   0    0    0    0  0  0    7   26  19  0 0 100
		'netbsd' => ['vmstat 1 2 | tail -n1', '$7*$8'],
		
		# openbsd: $8*$9
		# $ vmstat 1 2
		#  procs    memory       page                    disks    traps          cpu
		#  r b w    avm     fre  flt  re  pi  po  fr  sr wd0 wd1  int   sys   cs us sy id
		#  0 0 0  76596  109944   73   0   0   0   0   0   0   1    5   259   22  0  1 99
		#  0 0 0  76604  109936   24   0   0   0   0   0   0   0    7   114   20  0  1 99
		'openbsd' => ['vmstat 1 2 | tail -n1', '$8*$9'],
		
		# hpux: $8*$9
		# $ vmstat 1 2
		#          procs           memory                   page                              faults       cpu
		#     r     b     w      avm    free   re   at    pi   po    fr   de    sr     in     sy    cs  us sy id
		#     1     0     0   247211  216476    4    1     0    0     0    0     0    102  73005    54   6 11 83
		#     1     0     0   247211  216421   43    9     0    0     0    0     0    144   1675    96  25269512791222387000 25269512791222387000 105
		'hpux' => ['vmstat 1 2 | tail -n1', '$8*$9'],
		
		# dec_osf (tru64): $11*$12
		# $ vmstat  1 2
		# Virtual Memory Statistics: (pagesize = 8192)
		#   procs      memory        pages                            intr       cpu
		#   r   w   u  act free wire fault  cow zero react  pin pout  in  sy  cs us sy id
		#   3 181  36  51K 1895 8696  348M  59M 122M   259  79M    0   5 218 302  4  1 94
		#   3 181  36  51K 1893 8696     3   15   21     0   28    0   4  81 321  1  1 98
		'dec_osf' => ['vmstat 1 2 | tail -n1', '$11*$12'],
		
		# gnu (hurd): $7*$8
		# $ vmstat -k 1 2
		# (pagesize: 4, size: 512288, swap size: 894972)
		#   free   actv  inact  wired   zeroed  react    pgins   pgouts  pfaults  cowpfs hrat    caobj  cache swfree
		# 371940  30844  89228  20276   298348      0    48192    19016   756105   99808  98%      876  20628 894972
		# 371940  30844  89228  20276       +0     +0       +0       +0      +42      +2  98%      876  20628 894972
		'gnu' => ['vmstat -k 1 2 | tail -n1', '$7*$8'],
		
		# -nto (qnx has no swap)
		#-irix
		#-svr5 (scosysv)
		);
	    my $perlscript = "";
	    for my $os (keys %vmstat) {
		#q[ { vmstat 1 2 2> /dev/null || vmstat -c 1 2; } | ].
		#   q[ awk 'NR!=4{next} NF==17||NF==16{print $7*$8} NF==22{print $21*$22} {exit}' ];
		$vmstat{$os}[1] =~ s/\$/\\\\\\\$/g; # $ => \\\$
		$perlscript .= 'if($^O eq "'.$os.'") { print `'.$vmstat{$os}[0].' | awk "{print ' . 
		    $vmstat{$os}[1] . '}"` }';
	    }
	    $perlscript = "perl -e " . ::shell_quote_scalar($perlscript);
	    $script = $Global::envvar. " " .$perlscript;
	}
	return $script;
    }
}

sub too_fast_remote_login {
    my $self = shift;
    if($self->{'last_login_at'} and $self->{'time_to_login'}) {
	# sshd normally allows 10 simultaneous logins
	# A login takes time_to_login
	# So time_to_login/5 should be safe
	# If now <= last_login + time_to_login/5: Then it is too soon.
	my $too_fast = (::now() <= $self->{'last_login_at'}
			+ $self->{'time_to_login'}/5);
	::debug("run", "Too fast? $too_fast ");
	return $too_fast;
    } else {
	# No logins so far (or time_to_login not computed): it is not too fast
	return 0;
    }
}

sub last_login_at {
    my $self = shift;
    return $self->{'last_login_at'};
}

sub set_last_login_at {
    my $self = shift;
    $self->{'last_login_at'} = shift;
}

sub loadavg_too_high {
    my $self = shift;
    my $loadavg = $self->loadavg();
    return (not defined $loadavg or
            $loadavg > $self->max_loadavg());
}

sub loadavg {
    # If the currently know loadavg is too old:
    #   Recompute a new one in the background
    # The load average is computed as the number of processes waiting for disk
    # or CPU right now. So it is the server load this instant and not averaged over
    # several minutes. This is needed so GNU Parallel will at most start one job
    # that will push the load over the limit.
    #
    # Returns:
    #   $last_loadavg = last load average computed (undef if none)
    my $self = shift;
    # Should we update the loadavg file?
    my $update_loadavg_file = 0;
    if(open(my $load_fh, "<", $self->{'loadavg_file'})) {
	local $/ = undef;
        my $load_out = <$load_fh>;
        close $load_fh;
	my $load =()= ($load_out=~/(^[DR]....[^\[])/gm);
        if($load > 0) {
	    # load is overestimated by 1
            $self->{'loadavg'} = $load - 1;
            ::debug("load", "New loadavg: ", $self->{'loadavg'});
        } else {
	    ::die_bug("loadavg_invalid_content: $load_out");
	}
        ::debug("load", "Last update: ", $self->{'last_loadavg_update'});
        if(time - $self->{'last_loadavg_update'} > 10) {
            # last loadavg was started 10 seconds ago
            ::debug("load", time - $self->{'last_loadavg_update'}, " secs old: ",
		    $self->{'loadavg_file'});
            $update_loadavg_file = 1;
        }
    } else {
        ::debug("load", "No loadavg file: ", $self->{'loadavg_file'});
        $self->{'loadavg'} = undef;
        $update_loadavg_file = 1;
    }
    if($update_loadavg_file) {
        ::debug("load", "Updating loadavg file", $self->{'loadavg_file'}, "\n");
        $self->{'last_loadavg_update'} = time;
        -e $ENV{'HOME'}."/.parallel" or mkdir $ENV{'HOME'}."/.parallel";
        -e $ENV{'HOME'}."/.parallel/tmp" or mkdir $ENV{'HOME'}."/.parallel/tmp";
        my $cmd = "";
        if($self->{'string'} ne ":") {
	    $cmd = $self->sshcommand() . " " . $self->serverlogin() . " ";
	}
	$cmd .= "ps ax -o state,command";
        # As the command can take long to run if run remote
        # save it to a tmp file before moving it to the correct file
        my $file = $self->{'loadavg_file'};
        my ($dummy_fh, $tmpfile) = ::tempfile(SUFFIX => ".loa");
        qx{ ($cmd > $tmpfile && mv $tmpfile $file || rm $tmpfile) & };
    }
    return $self->{'loadavg'};
}

sub max_loadavg {
    my $self = shift;
    # If --load is a file it might be changed
    if($Global::max_load_file) {
	my $mtime = (stat($Global::max_load_file))[9];
	if($mtime > $Global::max_load_file_last_mod) {
	    $Global::max_load_file_last_mod = $mtime;
	    for my $sshlogin (values %Global::host) {
		$sshlogin->set_max_loadavg(undef);
	    }
	}
    }
    if(not defined $self->{'max_loadavg'}) {
        $self->{'max_loadavg'} =
            $self->compute_max_loadavg($opt::load);
    }
    ::debug("load", "max_loadavg: ", $self->string(), " ", $self->{'max_loadavg'});
    return $self->{'max_loadavg'};
}

sub set_max_loadavg {
    my $self = shift;
    $self->{'max_loadavg'} = shift;
}

sub compute_max_loadavg {
    # Parse the max loadaverage that the user asked for using --load
    # Returns:
    #   max loadaverage
    my $self = shift;
    my $loadspec = shift;
    my $load;
    if(defined $loadspec) {
        if($loadspec =~ /^\+(\d+)$/) {
            # E.g. --load +2
            my $j = $1;
            $load =
                $self->ncpus() + $j;
        } elsif ($loadspec =~ /^-(\d+)$/) {
            # E.g. --load -2
            my $j = $1;
            $load =
                $self->ncpus() - $j;
        } elsif ($loadspec =~ /^(\d+)\%$/) {
            my $j = $1;
            $load =
                $self->ncpus() * $j / 100;
        } elsif ($loadspec =~ /^(\d+(\.\d+)?)$/) {
            $load = $1;
        } elsif (-f $loadspec) {
            $Global::max_load_file = $loadspec;
            $Global::max_load_file_last_mod = (stat($Global::max_load_file))[9];
            if(open(my $in_fh, "<", $Global::max_load_file)) {
                my $opt_load_file = join("",<$in_fh>);
                close $in_fh;
                $load = $self->compute_max_loadavg($opt_load_file);
            } else {
                print $Global::original_stderr "Cannot open $loadspec\n";
                ::wait_and_exit(255);
            }
        } else {
            print $Global::original_stderr "Parsing of --load failed\n";
            ::die_usage();
        }
        if($load < 0.01) {
            $load = 0.01;
        }
    }
    return $load;
}

sub time_to_login {
    my $self = shift;
    return $self->{'time_to_login'};
}

sub set_time_to_login {
    my $self = shift;
    $self->{'time_to_login'} = shift;
}

sub max_jobs_running {
    my $self = shift;
    if(not defined $self->{'max_jobs_running'}) {
        my $nproc = $self->compute_number_of_processes($opt::jobs);
        $self->set_max_jobs_running($nproc);
    }
    return $self->{'max_jobs_running'};
}

sub compute_number_of_processes {
    # Number of processes wanted and limited by system resources
    # Returns:
    #   Number of processes
    my $self = shift;
    my $opt_P = shift;
    my $wanted_processes = $self->user_requested_processes($opt_P);
    if(not defined $wanted_processes) {
        $wanted_processes = $Global::default_simultaneous_sshlogins;
    }
    ::debug("load", "Wanted procs: $wanted_processes\n");
    my $system_limit =
        $self->processes_available_by_system_limit($wanted_processes);
    ::debug("load", "Limited to procs: $system_limit\n");
    return $system_limit;
}

sub processes_available_by_system_limit {
    # If the wanted number of processes is bigger than the system limits:
    # Limit them to the system limits
    # Limits are: File handles, number of input lines, processes,
    # and taking > 1 second to spawn 10 extra processes
    # Returns:
    #   Number of processes
    my $self = shift;
    my $wanted_processes = shift;

    my $system_limit = 0;
    my @jobs = ();
    my $job;
    my @args = ();
    my $arg;
    my $more_filehandles = 1;
    my $max_system_proc_reached = 0;
    my $slow_spawining_warning_printed = 0;
    my $time = time;
    my %fh;
    my @children;

    # Reserve filehandles
    # perl uses 7 filehandles for something?
    # parallel uses 1 for memory_usage
    # parallel uses 4 for ?
    for my $i (1..12) {
        open($fh{"init-$i"}, "<", "/dev/null");
    }

    for(1..2) {
        # System process limit
        my $child;
        if($child = fork()) {
            push (@children,$child);
            $Global::unkilled_children{$child} = 1;
        } elsif(defined $child) {
            # The child takes one process slot
            # It will be killed later
            $SIG{TERM} = $Global::original_sig{TERM};
            sleep 10000000;
            exit(0);
        } else {
            $max_system_proc_reached = 1;
        }
    }
    my $count_jobs_already_read = $Global::JobQueue->next_seq();
    my $wait_time_for_getting_args = 0;
    my $start_time = time;
    while(1) {
        $system_limit >= $wanted_processes and last;
        not $more_filehandles and last;
        $max_system_proc_reached and last;
	my $before_getting_arg = time;
        if($Global::semaphore or $opt::pipe) {
	    # Skip: No need to get args
        } elsif(defined $opt::retries and $count_jobs_already_read) {
            # For retries we may need to run all jobs on this sshlogin
            # so include the already read jobs for this sshlogin
            $count_jobs_already_read--;
        } else {
            if($opt::X or $opt::m) {
                # The arguments may have to be re-spread over several jobslots
                # So pessimistically only read one arg per jobslot
                # instead of a full commandline
                if($Global::JobQueue->{'commandlinequeue'}->{'arg_queue'}->empty()) {
		    if($Global::JobQueue->empty()) {
			last;
		    } else {
			($job) = $Global::JobQueue->get();
			push(@jobs, $job);
		    }
		} else {
		    ($arg) = $Global::JobQueue->{'commandlinequeue'}->{'arg_queue'}->get();
		    push(@args, $arg);
		}
            } else {
                # If there are no more command lines, then we have a process
                # per command line, so no need to go further
                $Global::JobQueue->empty() and last;
                ($job) = $Global::JobQueue->get();
                push(@jobs, $job);
	    }
        }
	$wait_time_for_getting_args += time - $before_getting_arg;
        $system_limit++;

        # Every simultaneous process uses 2 filehandles when grouping
        # Every simultaneous process uses 2 filehandles when compressing
        $more_filehandles = open($fh{$system_limit*10}, "<", "/dev/null")
            && open($fh{$system_limit*10+2}, "<", "/dev/null")
            && open($fh{$system_limit*10+3}, "<", "/dev/null")
            && open($fh{$system_limit*10+4}, "<", "/dev/null");

        # System process limit
        my $child;
        if($child = fork()) {
            push (@children,$child);
            $Global::unkilled_children{$child} = 1;
        } elsif(defined $child) {
            # The child takes one process slot
            # It will be killed later
            $SIG{TERM} = $Global::original_sig{TERM};
            sleep 10000000;
            exit(0);
        } else {
            $max_system_proc_reached = 1;
        }
	my $forktime = time - $time - $wait_time_for_getting_args;
        ::debug("run", "Time to fork $system_limit procs: $wait_time_for_getting_args ",
		$forktime,
		" (processes so far: ", $system_limit,")\n");
        if($system_limit > 10 and
	   $forktime > 1 and
	   $forktime > $system_limit * 0.01
	   and not $slow_spawining_warning_printed) {
            # It took more than 0.01 second to fork a processes on avg.
            # Give the user a warning. He can press Ctrl-C if this
            # sucks.
            print $Global::original_stderr
                ("parallel: Warning: Starting $system_limit processes took > $forktime sec.\n",
                 "Consider adjusting -j. Press CTRL-C to stop.\n");
            $slow_spawining_warning_printed = 1;
        }
    }
    # Cleanup: Close the files
    for (values %fh) { close $_ }
    # Cleanup: Kill the children
    for my $pid (@children) {
        kill 9, $pid;
        waitpid($pid,0);
        delete $Global::unkilled_children{$pid};
    }
    # Cleanup: Unget the command_lines or the @args
    $Global::JobQueue->{'commandlinequeue'}->{'arg_queue'}->unget(@args);
    $Global::JobQueue->unget(@jobs);
    if($system_limit < $wanted_processes) {
	# The system_limit is less than the wanted_processes
	if($system_limit < 1 and not $Global::JobQueue->empty()) {
	    ::warning("Cannot spawn any jobs. Raising ulimit -u or /etc/security/limits.conf may help.\n");
	    ::wait_and_exit(255);
	}
	if(not $more_filehandles) {
	    ::warning("Only enough file handles to run ", $system_limit, " jobs in parallel.\n",
		      "Raising ulimit -n or /etc/security/limits.conf may help.\n");
	}
	if($max_system_proc_reached) {
	    ::warning("Only enough available processes to run ", $system_limit,
		      " jobs in parallel. Raising ulimit -u or /etc/security/limits.conf may help.\n");
	}
    }
    if($] == 5.008008 and $system_limit > 1000) {
	# https://savannah.gnu.org/bugs/?36942
	$system_limit = 1000;
    }
    if($Global::JobQueue->empty()) {
	$system_limit ||= 1;
    }
    if($self->string() ne ":" and
       $system_limit > $Global::default_simultaneous_sshlogins) {
        $system_limit =
            $self->simultaneous_sshlogin_limit($system_limit);
    }
    return $system_limit;
}

sub simultaneous_sshlogin_limit {
    # Test by logging in wanted number of times simultaneously
    # Returns:
    #   min($wanted_processes,$working_simultaneous_ssh_logins-1)
    my $self = shift;
    my $wanted_processes = shift;
    if($self->{'time_to_login'}) {
	return $wanted_processes;
    }

    # Try twice because it guesses wrong sometimes
    # Choose the minimal
    my $ssh_limit =
        ::min($self->simultaneous_sshlogin($wanted_processes),
	      $self->simultaneous_sshlogin($wanted_processes));
    if($ssh_limit < $wanted_processes) {
        my $serverlogin = $self->serverlogin();
        ::warning("ssh to $serverlogin only allows ",
		  "for $ssh_limit simultaneous logins.\n",
		  "You may raise this by changing ",
		  "/etc/ssh/sshd_config:MaxStartups and MaxSessions on $serverlogin.\n",
		  "Using only ",$ssh_limit-1," connections ",
		  "to avoid race conditions.\n");
    }
    # Race condition can cause problem if using all sshs.
    if($ssh_limit > 1) { $ssh_limit -= 1; }
    return $ssh_limit;
}

sub simultaneous_sshlogin {
    # Using $sshlogin try to see if we can do $wanted_processes
    # simultaneous logins
    # (ssh host echo simultaneouslogin & ssh host echo simultaneouslogin & ...)|grep simul|wc -l
    # Returns:
    #   Number of succesful logins
    my $self = shift;
    my $wanted_processes = shift;
    my $sshcmd = $self->sshcommand();
    my $serverlogin = $self->serverlogin();
    my $sshdelay = $opt::sshdelay ? "sleep $opt::sshdelay;" : "";
    my $cmd = "$sshdelay$sshcmd $serverlogin echo simultaneouslogin </dev/null 2>&1 &"x$wanted_processes;
    ::debug("init", "Trying $wanted_processes logins at $serverlogin\n");
    open (my $simul_fh, "-|", "($cmd)|grep simultaneouslogin | wc -l") or
	::die_bug("simultaneouslogin");
    my $ssh_limit = <$simul_fh>;
    close $simul_fh;
    chomp $ssh_limit;
    return $ssh_limit;
}

sub set_ncpus {
    my $self = shift;
    $self->{'ncpus'} = shift;
}

sub user_requested_processes {
    # Parse the number of processes that the user asked for using -j
    # Returns:
    #   the number of processes to run on this sshlogin
    my $self = shift;
    my $opt_P = shift;
    my $processes;
    if(defined $opt_P) {
        if($opt_P =~ /^\+(\d+)$/) {
            # E.g. -P +2
            my $j = $1;
            $processes =
                $self->ncpus() + $j;
        } elsif ($opt_P =~ /^-(\d+)$/) {
            # E.g. -P -2
            my $j = $1;
            $processes =
                $self->ncpus() - $j;
        } elsif ($opt_P =~ /^(\d+)\%$/) {
            my $j = $1;
            $processes =
                $self->ncpus() * $j / 100;
        } elsif ($opt_P =~ /^(\d+)$/) {
            $processes = $1;
            if($processes == 0) {
                # -P 0 = infinity (or at least close)
                $processes = $Global::infinity;
            }
        } elsif (-f $opt_P) {
            $Global::max_procs_file = $opt_P;
            $Global::max_procs_file_last_mod = (stat($Global::max_procs_file))[9];
            if(open(my $in_fh, "<", $Global::max_procs_file)) {
                my $opt_P_file = join("",<$in_fh>);
                close $in_fh;
                $processes = $self->user_requested_processes($opt_P_file);
            } else {
                ::error("Cannot open $opt_P.\n");
                ::wait_and_exit(255);
            }
        } else {
            ::error("Parsing of --jobs/-j/--max-procs/-P failed.\n");
            ::die_usage();
        }
        if($processes < 1) {
            $processes = 1;
        }
    }
    return $processes;
}

sub ncpus {
    my $self = shift;
    if(not defined $self->{'ncpus'}) {
        my $sshcmd = $self->sshcommand();
        my $serverlogin = $self->serverlogin();
        if($serverlogin eq ":") {
            if($opt::use_cpus_instead_of_cores) {
                $self->{'ncpus'} = no_of_cpus();
            } else {
                $self->{'ncpus'} = no_of_cores();
            }
        } else {
            my $ncpu;
            if($opt::use_cpus_instead_of_cores) {
                $ncpu = qx(echo|$sshcmd $serverlogin $Global::envvar parallel --number-of-cpus);
            } else {
                $ncpu = qx(echo|$sshcmd $serverlogin $Global::envvar parallel --number-of-cores);
            }
	    chomp $ncpu;
            if($ncpu =~ /^\s*[0-9]+\s*$/s) {
                $self->{'ncpus'} = $ncpu;
            } else {
                ::warning("Could not figure out ",
			  "number of cpus on $serverlogin ($ncpu). Using 1.\n");
                $self->{'ncpus'} = 1;
            }
        }
    }
    return $self->{'ncpus'};
}

sub no_of_cpus {
    # Returns:
    #   Number of physical CPUs
    local $/="\n"; # If delimiter is set, then $/ will be wrong
    my $no_of_cpus;
    if ($^O eq 'linux') {
        $no_of_cpus = no_of_cpus_gnu_linux() || no_of_cores_gnu_linux();
    } elsif ($^O eq 'freebsd') {
        $no_of_cpus = no_of_cpus_freebsd();
    } elsif ($^O eq 'netbsd') {
        $no_of_cpus = no_of_cpus_netbsd();
    } elsif ($^O eq 'openbsd') {
        $no_of_cpus = no_of_cpus_openbsd();
    } elsif ($^O eq 'gnu') {
        $no_of_cpus = no_of_cpus_hurd();
    } elsif ($^O eq 'darwin') {
	$no_of_cpus = no_of_cpus_darwin();
    } elsif ($^O eq 'solaris') {
        $no_of_cpus = no_of_cpus_solaris();
    } elsif ($^O eq 'aix') {
        $no_of_cpus = no_of_cpus_aix();
    } elsif ($^O eq 'hpux') {
        $no_of_cpus = no_of_cpus_hpux();
    } elsif ($^O eq 'nto') {
        $no_of_cpus = no_of_cpus_qnx();
    } elsif ($^O eq 'svr5') {
        $no_of_cpus = no_of_cpus_openserver();
    } elsif ($^O eq 'irix') {
        $no_of_cpus = no_of_cpus_irix();
    } elsif ($^O eq 'dec_osf') {
        $no_of_cpus = no_of_cpus_tru64();
    } else {
	$no_of_cpus = (no_of_cpus_gnu_linux()
		       || no_of_cpus_freebsd()
		       || no_of_cpus_netbsd()
		       || no_of_cpus_openbsd()
		       || no_of_cpus_hurd()
		       || no_of_cpus_darwin()
		       || no_of_cpus_solaris()
		       || no_of_cpus_aix()
		       || no_of_cpus_hpux()
		       || no_of_cpus_qnx()
		       || no_of_cpus_openserver()
		       || no_of_cpus_irix()
		       || no_of_cpus_tru64()
			# Number of cores is better than no guess for #CPUs
		       || nproc()
	    );
    }
    if($no_of_cpus) {
	chomp $no_of_cpus;
        return $no_of_cpus;
    } else {
        ::warning("Cannot figure out number of cpus. Using 1.\n");
        return 1;
    }
}

sub no_of_cores {
    # Returns:
    #   Number of CPU cores
    local $/="\n"; # If delimiter is set, then $/ will be wrong
    my $no_of_cores;
    if ($^O eq 'linux') {
	$no_of_cores = no_of_cores_gnu_linux();
    } elsif ($^O eq 'freebsd') {
        $no_of_cores = no_of_cores_freebsd();
    } elsif ($^O eq 'netbsd') {
        $no_of_cores = no_of_cores_netbsd();
    } elsif ($^O eq 'openbsd') {
        $no_of_cores = no_of_cores_openbsd();
    } elsif ($^O eq 'gnu') {
        $no_of_cores = no_of_cores_hurd();
    } elsif ($^O eq 'darwin') {
	$no_of_cores = no_of_cores_darwin();
    } elsif ($^O eq 'solaris') {
	$no_of_cores = no_of_cores_solaris();
    } elsif ($^O eq 'aix') {
        $no_of_cores = no_of_cores_aix();
    } elsif ($^O eq 'hpux') {
        $no_of_cores = no_of_cores_hpux();
    } elsif ($^O eq 'nto') {
        $no_of_cores = no_of_cores_qnx();
    } elsif ($^O eq 'svr5') {
        $no_of_cores = no_of_cores_openserver();
    } elsif ($^O eq 'irix') {
        $no_of_cores = no_of_cores_irix();
    } elsif ($^O eq 'dec_osf') {
        $no_of_cores = no_of_cores_tru64();
    } else {
	$no_of_cores = (no_of_cores_gnu_linux()
			|| no_of_cores_freebsd()
			|| no_of_cores_netbsd()
			|| no_of_cores_openbsd()
			|| no_of_cores_hurd()
			|| no_of_cores_darwin()
			|| no_of_cores_solaris()
			|| no_of_cores_aix()
			|| no_of_cores_hpux()
			|| no_of_cores_qnx()
			|| no_of_cores_openserver()
			|| no_of_cores_irix()
			|| no_of_cores_tru64()
			|| nproc()
	    );
    }
    if($no_of_cores) {
	chomp $no_of_cores;
        return $no_of_cores;
    } else {
        ::warning("Cannot figure out number of CPU cores. Using 1.\n");
        return 1;
    }
}

sub nproc {
    # Returns:
    #   Number of cores using `nproc`
    my $no_of_cores = `nproc 2>/dev/null`;
    return $no_of_cores;
}    

sub no_of_cpus_gnu_linux {
    # Returns:
    #   Number of physical CPUs on GNU/Linux
    #   undef if not GNU/Linux
    my $no_of_cpus;
    my $no_of_cores;
    if(-e "/proc/cpuinfo") {
        $no_of_cpus = 0;
        $no_of_cores = 0;
        my %seen;
        open(my $in_fh, "<", "/proc/cpuinfo") || return undef;
        while(<$in_fh>) {
            if(/^physical id.*[:](.*)/ and not $seen{$1}++) {
                $no_of_cpus++;
            }
            /^processor.*[:]/i and $no_of_cores++;
        }
        close $in_fh;
    }
    return ($no_of_cpus||$no_of_cores);
}

sub no_of_cores_gnu_linux {
    # Returns:
    #   Number of CPU cores on GNU/Linux
    #   undef if not GNU/Linux
    my $no_of_cores;
    if(-e "/proc/cpuinfo") {
        $no_of_cores = 0;
        open(my $in_fh, "<", "/proc/cpuinfo") || return undef;
        while(<$in_fh>) {
            /^processor.*[:]/i and $no_of_cores++;
        }
        close $in_fh;
    }
    return $no_of_cores;
}

sub no_of_cpus_freebsd {
    # Returns:
    #   Number of physical CPUs on FreeBSD
    #   undef if not FreeBSD
    my $no_of_cpus =
	(`sysctl -a dev.cpu 2>/dev/null | grep \%parent | awk '{ print \$2 }' | uniq | wc -l | awk '{ print \$1 }'`
	 or
	 `sysctl hw.ncpu 2>/dev/null | awk '{ print \$2 }'`);
    chomp $no_of_cpus;
    return $no_of_cpus;
}

sub no_of_cores_freebsd {
    # Returns:
    #   Number of CPU cores on FreeBSD
    #   undef if not FreeBSD
    my $no_of_cores =
	(`sysctl hw.ncpu 2>/dev/null | awk '{ print \$2 }'`
	 or
	 `sysctl -a hw  2>/dev/null | grep [^a-z]logicalcpu[^a-z] | awk '{ print \$2 }'`);
    chomp $no_of_cores;
    return $no_of_cores;
}

sub no_of_cpus_netbsd {
    # Returns:
    #   Number of physical CPUs on NetBSD
    #   undef if not NetBSD
    my $no_of_cpus = `sysctl -n hw.ncpu 2>/dev/null`;
    chomp $no_of_cpus;
    return $no_of_cpus;
}

sub no_of_cores_netbsd {
    # Returns:
    #   Number of CPU cores on NetBSD
    #   undef if not NetBSD
    my $no_of_cores = `sysctl -n hw.ncpu 2>/dev/null`;
    chomp $no_of_cores;
    return $no_of_cores;
}

sub no_of_cpus_openbsd {
    # Returns:
    #   Number of physical CPUs on OpenBSD
    #   undef if not OpenBSD
    my $no_of_cpus = `sysctl -n hw.ncpu 2>/dev/null`;
    chomp $no_of_cpus;
    return $no_of_cpus;
}

sub no_of_cores_openbsd {
    # Returns:
    #   Number of CPU cores on OpenBSD
    #   undef if not OpenBSD
    my $no_of_cores = `sysctl -n hw.ncpu 2>/dev/null`;
    chomp $no_of_cores;
    return $no_of_cores;
}

sub no_of_cpus_hurd {
    # Returns:
    #   Number of physical CPUs on HURD
    #   undef if not HURD
    my $no_of_cpus = `nproc`;
    chomp $no_of_cpus;
    return $no_of_cpus;
}

sub no_of_cores_hurd {
    # Returns:
    #   Number of physical CPUs on HURD
    #   undef if not HURD
    my $no_of_cores = `nproc`;
    chomp $no_of_cores;
    return $no_of_cores;
}

sub no_of_cpus_darwin {
    # Returns:
    #   Number of physical CPUs on Mac Darwin
    #   undef if not Mac Darwin
    my $no_of_cpus =
	(`sysctl -n hw.physicalcpu 2>/dev/null`
	 or
	 `sysctl -a hw 2>/dev/null | grep [^a-z]physicalcpu[^a-z] | awk '{ print \$2 }'`);
    return $no_of_cpus;
}

sub no_of_cores_darwin {
    # Returns:
    #   Number of CPU cores on Mac Darwin
    #   undef if not Mac Darwin
    my $no_of_cores =
	(`sysctl -n hw.logicalcpu 2>/dev/null`
	 or
	 `sysctl -a hw  2>/dev/null | grep [^a-z]logicalcpu[^a-z] | awk '{ print \$2 }'`);
    return $no_of_cores;
}

sub no_of_cpus_solaris {
    # Returns:
    #   Number of physical CPUs on Solaris
    #   undef if not Solaris
    if(-x "/usr/sbin/psrinfo") {
        my @psrinfo = `/usr/sbin/psrinfo`;
        if($#psrinfo >= 0) {
            return $#psrinfo +1;
        }
    }
    if(-x "/usr/sbin/prtconf") {
        my @prtconf = `/usr/sbin/prtconf | grep cpu..instance`;
        if($#prtconf >= 0) {
            return $#prtconf +1;
        }
    }
    return undef;
}

sub no_of_cores_solaris {
    # Returns:
    #   Number of CPU cores on Solaris
    #   undef if not Solaris
    if(-x "/usr/sbin/psrinfo") {
        my @psrinfo = `/usr/sbin/psrinfo`;
        if($#psrinfo >= 0) {
            return $#psrinfo +1;
        }
    }
    if(-x "/usr/sbin/prtconf") {
        my @prtconf = `/usr/sbin/prtconf | grep cpu..instance`;
        if($#prtconf >= 0) {
            return $#prtconf +1;
        }
    }
    return undef;
}

sub no_of_cpus_aix {
    # Returns:
    #   Number of physical CPUs on AIX
    #   undef if not AIX
    my $no_of_cpus = 0;
    if(-x "/usr/sbin/lscfg") {
	open(my $in_fh, "-|", "/usr/sbin/lscfg -vs |grep proc | wc -l|tr -d ' '")
	    || return undef;
	$no_of_cpus = <$in_fh>;
	chomp ($no_of_cpus);
	close $in_fh;
    }
    return $no_of_cpus;
}

sub no_of_cores_aix {
    # Returns:
    #   Number of CPU cores on AIX
    #   undef if not AIX
    my $no_of_cores;
    if(-x "/usr/bin/vmstat") {
	open(my $in_fh, "-|", "/usr/bin/vmstat 1 1") || return undef;
	while(<$in_fh>) {
	    /lcpu=([0-9]*) / and $no_of_cores = $1;
	}
	close $in_fh;
    }
    return $no_of_cores;
}

sub no_of_cpus_hpux {
    # Returns:
    #   Number of physical CPUs on HP-UX
    #   undef if not HP-UX
    my $no_of_cpus =
        (`/usr/bin/mpsched -s 2>&1 | grep 'Locality Domain Count' | awk '{ print \$4 }'`);
    return $no_of_cpus;
}

sub no_of_cores_hpux {
    # Returns:
    #   Number of CPU cores on HP-UX
    #   undef if not HP-UX
    my $no_of_cores =
        (`/usr/bin/mpsched -s 2>&1 | grep 'Processor Count' | awk '{ print \$4 }'`);
    return $no_of_cores;
}

sub no_of_cpus_qnx {
    # Returns:
    #   Number of physical CPUs on QNX
    #   undef if not QNX
    # BUG: It is now known how to calculate this.
    my $no_of_cpus = 0;
    return $no_of_cpus;
}

sub no_of_cores_qnx {
    # Returns:
    #   Number of CPU cores on QNX
    #   undef if not QNX
    # BUG: It is now known how to calculate this.
    my $no_of_cores = 0;
    return $no_of_cores;
}

sub no_of_cpus_openserver {
    # Returns:
    #   Number of physical CPUs on SCO OpenServer
    #   undef if not SCO OpenServer
    my $no_of_cpus = 0;
    if(-x "/usr/sbin/psrinfo") {
        my @psrinfo = `/usr/sbin/psrinfo`;
        if($#psrinfo >= 0) {
            return $#psrinfo +1;
        }
    }
    return $no_of_cpus;
}

sub no_of_cores_openserver {
    # Returns:
    #   Number of CPU cores on SCO OpenServer
    #   undef if not SCO OpenServer
    my $no_of_cores = 0;
    if(-x "/usr/sbin/psrinfo") {
        my @psrinfo = `/usr/sbin/psrinfo`;
        if($#psrinfo >= 0) {
            return $#psrinfo +1;
        }
    }
    return $no_of_cores;
}

sub no_of_cpus_irix {
    # Returns:
    #   Number of physical CPUs on IRIX
    #   undef if not IRIX
    my $no_of_cpus =
        (`hinv | grep HZ | grep Processor | awk '{print \$1}'`);
    return $no_of_cpus;
}

sub no_of_cores_irix {
    # Returns:
    #   Number of CPU cores on IRIX
    #   undef if not IRIX
    my $no_of_cores = 
        (`hinv | grep HZ | grep Processor | awk '{print \$1}'`);
    return $no_of_cores;
}

sub no_of_cpus_tru64 {
    # Returns:
    #   Number of physical CPUs on Tru64
    #   undef if not Tru64
    my $no_of_cpus =
        (`sizer -pr`);
    return $no_of_cpus;
}

sub no_of_cores_tru64 {
    # Returns:
    #   Number of CPU cores on Tru64
    #   undef if not Tru64
    my $no_of_cores = 
        (`sizer -pr`);
    return $no_of_cores;
}

sub sshcommand {
    my $self = shift;
    if (not defined $self->{'sshcommand'}) {
        $self->sshcommand_of_sshlogin();
    }
    return $self->{'sshcommand'};
}

sub serverlogin {
    my $self = shift;
    if (not defined $self->{'serverlogin'}) {
        $self->sshcommand_of_sshlogin();
    }
    return $self->{'serverlogin'};
}

sub sshcommand_of_sshlogin {
    # 'server' -> ('ssh -S /tmp/parallel-ssh-RANDOM/host-','server')
    # 'user@server' -> ('ssh','user@server')
    # 'myssh user@server' -> ('myssh','user@server')
    # 'myssh -l user server' -> ('myssh -l user','server')
    # '/usr/bin/myssh -l user server' -> ('/usr/bin/myssh -l user','server')
    # Returns:
    #   sshcommand - defaults to 'ssh'
    #   login@host
    my $self = shift;
    my ($sshcmd, $serverlogin);
    if($self->{'string'} =~ /(.+) (\S+)$/) {
        # Own ssh command
        $sshcmd = $1; $serverlogin = $2;
    } else {
        # Normal ssh
        if($opt::controlmaster) {
            # Use control_path to make ssh faster
            my $control_path = $self->control_path_dir()."/ssh-%r@%h:%p";
            $sshcmd = "ssh -S ".$control_path;
            $serverlogin = $self->{'string'};
            if(not $self->{'control_path'}{$control_path}++) {
                # Master is not running for this control_path
                # Start it
                my $pid = fork();
                if($pid) {
                    $Global::sshmaster{$pid} ||= 1;
                } else {
		    $SIG{'TERM'} = undef;
                    # Ignore the 'foo' being printed
                    open(STDOUT,">","/dev/null");
                    # OpenSSH_3.6.1p2 gives 'tcgetattr: Invalid argument' with -tt
                    # STDERR >/dev/null to ignore "process_mux_new_session: tcgetattr: Invalid argument"
                    open(STDERR,">","/dev/null");
                    open(STDIN,"<","/dev/null");
                    # Run a sleep that outputs data, so it will discover if the ssh connection closes.
                    my $sleep = ::shell_quote_scalar('$|=1;while(1){sleep 1;print "foo\n"}');
                    my @master = ("ssh", "-tt", "-MTS", $control_path, $serverlogin, "perl", "-e", $sleep);
                    exec(@master);
                }
            }
        } else {
            $sshcmd = "ssh"; $serverlogin = $self->{'string'};
        }
    }
    $self->{'sshcommand'} = $sshcmd;
    $self->{'serverlogin'} = $serverlogin;
}

sub control_path_dir {
    # Returns:
    #   path to directory
    my $self = shift;
    if(not defined $self->{'control_path_dir'}) {
        -e $ENV{'HOME'}."/.parallel" or mkdir $ENV{'HOME'}."/.parallel";
        -e $ENV{'HOME'}."/.parallel/tmp" or mkdir $ENV{'HOME'}."/.parallel/tmp";
        $self->{'control_path_dir'} =
	    File::Temp::tempdir($ENV{'HOME'}
				. "/.parallel/tmp/control_path_dir-XXXX",
				CLEANUP => 1);
    }
    return $self->{'control_path_dir'};
}


sub rsync_transfer_cmd {
  # Command to run to transfer a file
  # Input:
  #   $file = filename of file to transfer
  #   $workdir = destination dir
  # Returns:
  #   $cmd = rsync command to run to transfer $file ("" if unreadable)
  my $self = shift;
  my $file = shift;
  my $workdir = shift;
  if(not -r $file) {
    ::warning($file, " is not readable and will not be transferred.\n");
    return "true";
  }
  my $rsync_destdir;
  if($file =~ m:^/:) {
    # rsync /foo/bar /
    $rsync_destdir = "/";
  } else {
    $rsync_destdir = ::shell_quote_file($workdir);
  }
  $file = ::shell_quote_file($file);
  my $sshcmd = $self->sshcommand();
  my $rsync_opt = "-rlDzR -e" . ::shell_quote_scalar($sshcmd);
  my $serverlogin = $self->serverlogin();
  # Make dir if it does not exist
  return "( $sshcmd $serverlogin mkdir -p $rsync_destdir;" .
    "rsync $rsync_opt $file $serverlogin:$rsync_destdir )";
}

sub cleanup_cmd {
  # Command to run to remove the remote file
  # Input:
  #   $file = filename to remove
  #   $workdir = destination dir
  # Returns:
  #   $cmd = ssh command to run to remove $file and empty parent dirs
  my $self = shift;
  my $file = shift;
  my $workdir = shift;
  my $f = $file;
  if($f =~ m:/\./:) {
      # foo/bar/./baz/quux => workdir/baz/quux
      # /foo/bar/./baz/quux => workdir/baz/quux
      $f =~ s:.*/\./:$workdir/:;
  } elsif($f =~ m:^[^/]:) {
      # foo/bar => workdir/foo/bar
      $f = $workdir."/".$f;
  }
  my @subdirs = split m:/:, ::dirname($f);
  my @rmdir;
  my $dir = "";
  for(@subdirs) {
    $dir .= $_."/";
    unshift @rmdir, ::shell_quote_file($dir);
  }
  my $rmdir = @rmdir ? "rmdir @rmdir 2>/dev/null;" : "";
  if(defined $opt::workdir and $opt::workdir eq "...") {
    $rmdir .= "rm -rf " . ::shell_quote_file($workdir).';';
  }

  $f = ::shell_quote_file($f);
  my $sshcmd = $self->sshcommand();
  my $serverlogin = $self->serverlogin();
  return "$sshcmd $serverlogin ".::shell_quote_scalar("(rm -f $f; $rmdir)");
}

package JobQueue;

sub new {
    my $class = shift;
    my $commandref = shift;
    my $read_from = shift;
    my $context_replace = shift;
    my $max_number_of_args = shift;
    my $return_files = shift;
    my $commandlinequeue = CommandLineQueue->new
	($commandref, $read_from, $context_replace, $max_number_of_args,
	 $return_files);
    my @unget = ();
    return bless {
        'unget' => \@unget,
        'commandlinequeue' => $commandlinequeue,
        'total_jobs' => undef,
    }, ref($class) || $class;
}

sub get {
    my $self = shift;

    if(@{$self->{'unget'}}) {
        my $job = shift @{$self->{'unget'}};
        return ($job);
    } else {
        my $commandline = $self->{'commandlinequeue'}->get();
        if(defined $commandline) {
            my $job = Job->new($commandline);
            return $job;
        } else {
            return undef;
        }
    }
}

sub unget {
    my $self = shift;
    unshift @{$self->{'unget'}}, @_;
}

sub empty {
    my $self = shift;
    my $empty = (not @{$self->{'unget'}})
	&& $self->{'commandlinequeue'}->empty();
    ::debug("run", "JobQueue->empty $empty ");
    return $empty;
}

sub total_jobs {
    my $self = shift;
    if(not defined $self->{'total_jobs'}) {
        my $job;
        my @queue;
        while($job = $self->get()) {
            push @queue, $job;
        }
        $self->unget(@queue);
        $self->{'total_jobs'} = $#queue+1;
    }
    return $self->{'total_jobs'};
}

sub next_seq {
    my $self = shift;

    return $self->{'commandlinequeue'}->seq();
}

sub quote_args {
    my $self = shift;
    return $self->{'commandlinequeue'}->quote_args();
}


package Job;

sub new {
    my $class = shift;
    my $commandlineref = shift;
    return bless {
        'commandline' => $commandlineref, # CommandLine object
        'workdir' => undef, # --workdir
        'stdin' => undef, # filehandle for stdin (used for --pipe)
	# filename for writing stdout to (used for --files)
        'remaining' => "", # remaining data not sent to stdin (used for --pipe)
	'datawritten' => 0, # amount of data sent via stdin (used for --pipe)
        'transfersize' => 0, # size of files using --transfer
        'returnsize' => 0, # size of files using --return
        'pid' => undef,
        # hash of { SSHLogins => number of times the command failed there }
        'failed' => undef,
        'sshlogin' => undef,
        # The commandline wrapped with rsync and ssh
        'sshlogin_wrap' => undef,
        'exitstatus' => undef,
        'exitsignal' => undef,
	# Timestamp for timeout if any
	'timeout' => undef,
	'virgin' => 1,
    }, ref($class) || $class;
}

sub replaced {
    my $self = shift;
    $self->{'commandline'} or ::die_bug("commandline empty");
    return $self->{'commandline'}->replaced();
}

sub seq {
    my $self = shift;
    return $self->{'commandline'}->seq();
}

sub slot {
    my $self = shift;
    return $self->{'commandline'}->slot();
}

{
    my($cattail);

    sub cattail {
	# Returns:
	#   $cattail = perl program for: cattail "decompress program" writerpid [file_to_decompress or stdin] [file_to_unlink]
	if(not $cattail) {
	    $cattail = q{
		# cat followed by tail.
		# If $writerpid dead: finish after this round
		use Fcntl;
		
		$|=1;
		
		my ($cmd, $writerpid, $read_file, $unlink_file) = @ARGV;
		if($read_file) {
		    open(IN,"<",$read_file) || die("cattail: Cannot open $read_file");
		} else {
		    *IN = *STDIN;
		}
		
		my $flags;
		fcntl(IN, F_GETFL, $flags) || die $!; # Get the current flags on the filehandle
		$flags |= O_NONBLOCK; # Add non-blocking to the flags
		fcntl(IN, F_SETFL, $flags) || die $!; # Set the flags on the filehandle
		open(OUT,"|-",$cmd) || die("cattail: Cannot run $cmd");
		
		while(1) {
		    # clear EOF
		    seek(IN,0,1);
		    my $writer_running = kill 0, $writerpid;
		    $read = sysread(IN,$buf,32768);
		    if($read) {
			# We can unlink the file now: The writer has written something
			-e $unlink_file and unlink $unlink_file;
			# Blocking print
			while($buf) {
			    my $bytes_written = syswrite(OUT,$buf);
			    # syswrite may be interrupted by SIGHUP
			    substr($buf,0,$bytes_written) = "";
			}
			# Something printed: Wait less next time
			$sleep /= 2;
		    } else {
			if(eof(IN) and not $writer_running) {
			    # Writer dead: There will never be more to read => exit
			    exit;
			}
			# TODO This could probably be done more efficiently using select(2)
			# Nothing read: Wait longer before next read
			# Up to 30 milliseconds
			$sleep = ($sleep < 30) ? ($sleep * 1.001 + 0.01) : ($sleep);
			usleep($sleep);
		    }
		}
		
		sub usleep {
		    # Sleep this many milliseconds.
		    my $secs = shift;
		    select(undef, undef, undef, $secs/1000);
		}
	    };
	    $cattail =~ s/#.*//mg;
	    $cattail =~ s/\s+/ /g;
	}
	return $cattail;
    }
}

sub openoutputfiles {
    # Open files for STDOUT and STDERR
    # Set file handles in $self->fh
    my $self = shift;
    my ($outfhw, $errfhw, $outname, $errname);
    if($opt::results) {
	my $args_as_dirname = $self->{'commandline'}->args_as_dirname();
	# Output in: prefix/name1/val1/name2/val2/stdout
	my $dir = $opt::results."/".$args_as_dirname;
	if(eval{ File::Path::mkpath($dir); }) {
	    # OK
	} else {
	    # mkpath failed: Argument probably too long.
	    # Set $Global::max_file_length, which will keep the individual
	    # dir names shorter than the max length
	    max_file_name_length($opt::results);
	    $args_as_dirname = $self->{'commandline'}->args_as_dirname();
	    # prefix/name1/val1/name2/val2/
	    $dir = $opt::results."/".$args_as_dirname;
	    File::Path::mkpath($dir);
	}
	# prefix/name1/val1/name2/val2/stdout
	$outname = "$dir/stdout";
	if(not open($outfhw, "+>", $outname)) {
	    ::error("Cannot write to `$outname'.\n");
	    ::wait_and_exit(255);
	}
	# prefix/name1/val1/name2/val2/stderr
	$errname = "$dir/stderr";
	if(not open($errfhw, "+>", $errname)) {
	    ::error("Cannot write to `$errname'.\n");
	    ::wait_and_exit(255);
	}
	$self->set_fh(1,"unlink","");
	$self->set_fh(2,"unlink","");
    } elsif($Global::grouped) {
	# To group we create temporary files for STDOUT and STDERR
	# To avoid the cleanup unlink the files immediately (but keep them open)
	if(@Global::tee_jobs) {
	    # files must be removed when the tee is done
	} elsif($opt::files) {
	    ($outfhw, $outname) = ::tempfile(SUFFIX => ".par");
	    ($errfhw, $errname) = ::tempfile(SUFFIX => ".par");
	    # --files => only remove stderr
	    $self->set_fh(1,"unlink","");
	    $self->set_fh(2,"unlink",$errname);
	} else {
	    ($outfhw, $outname) = ::tempfile(SUFFIX => ".par");
	    ($errfhw, $errname) = ::tempfile(SUFFIX => ".par");
	    $self->set_fh(1,"unlink",$outname);
	    $self->set_fh(2,"unlink",$errname);
	}
    } else {
	# --ungroup
	open($outfhw,">&",$Global::fd{1}) || die;
	open($errfhw,">&",$Global::fd{2}) || die;
	# File name must be empty as it will otherwise be printed
	$outname = "";
	$errname = "";
	$self->set_fh(1,"unlink",$outname);
	$self->set_fh(2,"unlink",$errname);
    }
    # Set writing FD
    $self->set_fh(1,'w',$outfhw);
    $self->set_fh(2,'w',$errfhw);
    $self->set_fh(1,'name',$outname);
    $self->set_fh(2,'name',$errname);
    if($opt::compress) {
	# Send stdout to stdin for $opt::compress_program(1)
	# Send stderr to stdin for $opt::compress_program(2)
	# cattail get pid:  $pid = $self->fh($fdno,'rpid');
	my $cattail = cattail();
	for my $fdno (1,2) {
	    my $wpid = open(my $fdw,"|-","$opt::compress_program >>".
			    $self->fh($fdno,'name')) || die $?;
	    $self->set_fh($fdno,'w',$fdw);
	    $self->set_fh($fdno,'wpid',$wpid);
	    my $rpid = open(my $fdr, "-|", "perl", "-e", $cattail, 
			    $opt::decompress_program, $wpid,
			    $self->fh($fdno,'name'),$self->fh($fdno,'unlink')) || die $?;
	    $self->set_fh($fdno,'r',$fdr);
	    $self->set_fh($fdno,'rpid',$rpid);
	}
    } elsif($Global::grouped) {
	# Set reading FD if using --group (--ungroup does not need)
	for my $fdno (1,2) {
	    # Re-open the file for reading
	    # so fdw can be closed seperately
	    # and fdr can be seeked seperately (for --line-buffer)
	    open(my $fdr,"<", $self->fh($fdno,'name')) || 
		::die_bug("fdr: Cannot open ".$self->fh($fdno,'name'));
	    $self->set_fh($fdno,'r',$fdr);
            # Unlink if required
	    $Global::debug or unlink $self->fh($fdno,"unlink");
	}
    }
    if($opt::linebuffer) {
	# Set non-blocking when using --linebuffer
	$Global::use{"Fcntl"} ||= eval "use Fcntl qw(:DEFAULT :flock); 1;";
	for my $fdno (1,2) {
	    my $fdr = $self->fh($fdno,'r');
	    my $flags;
	    fcntl($fdr, &F_GETFL, $flags) || die $!; # Get the current flags on the filehandle
	    $flags |= &O_NONBLOCK; # Add non-blocking to the flags
	    fcntl($fdr, &F_SETFL, $flags) || die $!; # Set the flags on the filehandle
	}
    }
}

sub max_file_name_length {
    # Figure out the max length of a subdir
    # TODO and the max total length
    # Ext4 = 255,130816
    my $testdir = shift;

    my $upper = 8_000_000;
    my $len = 8;
    my $dir="x"x$len;
    do {
	rmdir($testdir."/".$dir);
	$len *= 16;
	$dir="x"x$len;
    } while (mkdir $testdir."/".$dir);
    # Then search for the actual max length between $len/16 and $len
    my $min = $len/16;
    my $max = $len;
    while($max-$min > 5) {
	# If we are within 5 chars of the exact value:
	# it is not worth the extra time to find the exact value
	my $test = int(($min+$max)/2);
	$dir="x"x$test;
	if(mkdir $testdir."/".$dir) {
	    rmdir($testdir."/".$dir);
	    $min = $test;
	} else {
	    $max = $test;
	}
    }
    $Global::max_file_length = $min;
    return $min;
}

sub set_fh {
    # Set file handle
    my ($self, $fd_no, $key, $fh) = @_;
    $self->{'fd'}{$fd_no,$key} = $fh;
}

sub fh {
    # Get file handle
    my ($self, $fd_no, $key) = @_;
    return $self->{'fd'}{$fd_no,$key};
}

sub write {
    my $self = shift;
    my $remaining_ref = shift;
    my $stdin_fh = $self->fh(0,"w");
    syswrite($stdin_fh,$$remaining_ref);
}

sub set_stdin_buffer {
    my $self = shift;
    my ($header_ref,$block_ref,$endpos,$recstart,$recend) = @_;
    $self->{'stdin_buffer'} = ($self->virgin() ? $$header_ref : "").substr($$block_ref,0,$endpos);
    if($opt::remove_rec_sep) {
	remove_rec_sep(\$self->{'stdin_buffer'},$recstart,$recend);
    }
    $self->{'stdin_buffer_length'} = length $self->{'stdin_buffer'};
    $self->{'stdin_buffer_pos'} = 0;
}

sub stdin_buffer_length {
    my $self = shift;
    return $self->{'stdin_buffer_length'};
}

sub remove_rec_sep {
    my ($block_ref,$recstart,$recend) = @_;
    # Remove record separator
    $$block_ref =~ s/$recend$recstart//gos;
    $$block_ref =~ s/^$recstart//os;
    $$block_ref =~ s/$recend$//os;
}

sub non_block_write {
    my $self = shift;
    my $something_written = 0;
    use POSIX qw(:errno_h);
#    use Fcntl;
#    my $flags = '';
    for my $buf (substr($self->{'stdin_buffer'},$self->{'stdin_buffer_pos'})) {
	my $in = $self->fh(0,"w");
#	fcntl($in, F_GETFL, $flags)
#	    or die "Couldn't get flags for HANDLE : $!\n";
#	$flags |= O_NONBLOCK;
#	fcntl($in, F_SETFL, $flags)
#	    or die "Couldn't set flags for HANDLE: $!\n";
	my $rv = syswrite($in, $buf);
	if (!defined($rv) && $! == EAGAIN) {
	    # would block
	    $something_written = 0;
	} elsif ($self->{'stdin_buffer_pos'}+$rv != $self->{'stdin_buffer_length'}) {
	    # incomplete write
	    # Remove the written part
	    $self->{'stdin_buffer_pos'} += $rv;
	    $something_written = $rv;
	} else {
	    # successfully wrote everything
	    my $a="";
	    $self->set_stdin_buffer(\$a,\$a,"","");
	    $something_written = $rv;
	}
    }

    ::debug("pipe", "Non-block: ", $something_written);
    return $something_written;
}


sub virgin {
    my $self = shift;
    return $self->{'virgin'};
}

sub set_virgin {
    my $self = shift;
    $self->{'virgin'} = shift;
}

sub pid {
    my $self = shift;
    return $self->{'pid'};
}

sub set_pid {
    my $self = shift;
    $self->{'pid'} = shift;
}

sub starttime {
    # Returns:
    #   UNIX-timestamp this job started
    my $self = shift;
    return sprintf("%.3f",$self->{'starttime'});
}

sub set_starttime {
    my $self = shift;
    my $starttime = shift || ::now();
    $self->{'starttime'} = $starttime;
}

sub runtime {
    # Returns:
    #   Run time in seconds
    my $self = shift;
    return sprintf("%.3f",int(($self->endtime() - $self->starttime())*1000)/1000);
}

sub endtime {
    # Returns:
    #   UNIX-timestamp this job ended
    #   0 if not ended yet
    my $self = shift;
    return ($self->{'endtime'} || 0);
}

sub set_endtime {
    my $self = shift;
    my $endtime = shift;
    $self->{'endtime'} = $endtime;
}

sub timedout {
    my $self = shift;
    my $delta_time = shift;
    return time > $self->{'starttime'} + $delta_time;
}

sub kill {
    # kill the jobs
    my $self = shift;
    my @signals = @_;
    my @family_pids = $self->family_pids();
    # Record this jobs as failed
    $self->set_exitstatus(-1);
    # Send two TERMs to give time to clean up
    ::debug("run", "Kill seq ", $self->seq(), "\n");
    my @send_signals = @signals || ("TERM", "TERM", "KILL");
    for my $signal (@send_signals) {
	my $alive = 0;
	for my $pid (@family_pids) {
	    if(kill 0, $pid) {
		# The job still running
		kill $signal, $pid;
		$alive = 1;
	    }
	}
	# If a signal was given as input, do not do the sleep below
	@signals and next;

	if($signal eq "TERM" and $alive) {
	    # Wait up to 200 ms between TERMs - but only if any pids are alive
	    my $sleep = 1;
	    for (my $sleepsum = 0; kill 0, $family_pids[0] and $sleepsum < 200;
		 $sleepsum += $sleep) {
		$sleep = ::reap_usleep($sleep);
	    }
	}
    }
}

{
    my %pid_parentpid_cmd;

    sub family_pids {
	# Find the pids with this->pid as (grand)*parent
	my $self = shift;
	my $pid = $self->pid();

       	%pid_parentpid_cmd or %pid_parentpid_cmd = 
	    (
	     'aix' => q( ps -ef | awk '{print $2" "$3}' ),
	     'cygwin' => q( ps -ef | awk '{print $2" "$3}' ),
	     'dec_osf' => q( ps -ef | awk '{print $2" "$3}' ),
	     'darwin' => q( ps -o pid,ppid -ax ),
	     'dragonfly' => q( ps -o pid,ppid -ax ),
	     'freebsd' => q( ps -o pid,ppid -ax ),
	     'gnu' => q( ps -ef | awk '{print $2" "$3}' ),
	     'hpux' => q( ps -ef | awk '{print $2" "$3}' ),
	     'linux' => q( ps -ef | awk '{print $2" "$3}' ),
	     'mirbsd' => q( ps -o pid,ppid -ax ),
	     'netbsd' => q( ps -o pid,ppid -ax ),
	     'nto' => q( ps -ef | awk '{print $2" "$3}' ),
	     'openbsd' => q( ps -o pid,ppid -ax ),
	     'solaris' => q( ps -ef | awk '{print $2" "$3}' ),
	     'svr5' => q( ps -ef | awk '{print $2" "$3}' ),
	    );
	$pid_parentpid_cmd{$^O} or ::die_bug("pid_parentpid_cmd for $^O missing");

	my (@pidtable,%children_of,@pids);
	# Table with pid parentpid
	@pidtable = `$pid_parentpid_cmd{$^O}`;
	for (@pidtable) {
	    /(\S+)\s+(\S+)/ or ::die_bug("pidtable format");
	    push @{$children_of{$2}}, $1;
	}
	my @more = ($pid);
	# While more (grand)*children
	while(@more) {
	    my @m;
	    push @pids, @more;
	    for my $parent (@more) {
		if($children_of{$parent}) {
		    # add the children of this parent
		    push @m, @{$children_of{$parent}};
		}
	    }
	    @more = @m;
	}

	return (@pids);
    }
}

sub failed {
    # return number of times failed for this $sshlogin
    my $self = shift;
    my $sshlogin = shift;
    return $self->{'failed'}{$sshlogin};
}

sub failed_here {
    # return number of times failed for the current $sshlogin
    my $self = shift;
    return $self->{'failed'}{$self->sshlogin()};
}

sub add_failed {
    # increase the number of times failed for this $sshlogin
    my $self = shift;
    my $sshlogin = shift;
    $self->{'failed'}{$sshlogin}++;
}

sub add_failed_here {
    # increase the number of times failed for the current $sshlogin
    my $self = shift;
    $self->{'failed'}{$self->sshlogin()}++;
}

sub reset_failed {
    # increase the number of times failed for this $sshlogin
    my $self = shift;
    my $sshlogin = shift;
    delete $self->{'failed'}{$sshlogin};
}

sub reset_failed_here {
    # increase the number of times failed for this $sshlogin
    my $self = shift;
    delete $self->{'failed'}{$self->sshlogin()};
}

sub min_failed {
    # Returns:
    #   the number of sshlogins this command has failed on
    #   the minimal number of times this command has failed
    my $self = shift;
    my $min_failures =
	::min(map { $self->{'failed'}{$_} }
		keys %{$self->{'failed'}});
    my $number_of_sshlogins_failed_on = scalar keys %{$self->{'failed'}};
    return ($number_of_sshlogins_failed_on,$min_failures);
}

sub total_failed {
    # Returns:
    #   the number of times this command has failed
    my $self = shift;
    my $total_failures = 0;
    for (values %{$self->{'failed'}}) {
	$total_failures += $_;
    }
    return ($total_failures);
}

sub set_sshlogin {
    my $self = shift;
    my $sshlogin = shift;
    $self->{'sshlogin'} = $sshlogin;
    delete $self->{'sshlogin_wrap'}; # If sshlogin is changed the wrap is wrong
}

sub sshlogin {
    my $self = shift;
    return $self->{'sshlogin'};
}

sub sshlogin_wrap {
    # Wrap the command with the commands needed to run remotely
    my $self = shift;
    if(not defined $self->{'sshlogin_wrap'}) {
	my $sshlogin = $self->sshlogin();
	my $sshcmd = $sshlogin->sshcommand();
	my $serverlogin = $sshlogin->serverlogin();
	my $next_command_line = $Global::envvar.$self->replaced();
	my ($pre,$post,$cleanup)=("","","");
	if($serverlogin eq ":") {
	    $self->{'sshlogin_wrap'} = $next_command_line;
	} else {
	    # --transfer
	    $pre .= $self->sshtransfer();
	    # --return
	    $post .= $self->sshreturn();
	    # --cleanup
	    $post .= $self->sshcleanup();
	    if($post) {
		# We need to save the exit status of the job
		$post = '_EXIT_status=$?; ' . $post . ' exit $_EXIT_status;';
	    }
	    # If the remote login shell is (t)csh then use 'setenv'
	    # otherwise use 'export'
	    # We cannot use parse_env_var(), as PARALLEL_SEQ changes
	    # for each command
	    my $parallel_env =
		($Global::envwarn
		 . q{ 'eval `echo $SHELL | grep "/t\\{0,1\\}csh" > /dev/null }
		 . q{ && echo setenv PARALLEL_SEQ '$PARALLEL_SEQ'\; }
		 . q{ setenv PARALLEL_PID '$PARALLEL_PID' }
		 . q{ || echo PARALLEL_SEQ='$PARALLEL_SEQ'\;export PARALLEL_SEQ\; }
		 . q{ PARALLEL_PID='$PARALLEL_PID'\;export PARALLEL_PID` ;' });
	    my $remote_pre = "";
	    my $ssh_options = "";
	    if($opt::pipe and $opt::ctrlc
	       or
	       not $opt::pipe and not $opt::noctrlc) {
		# TODO Determine if this is needed
		# Propagating CTRL-C to kill remote jobs requires
		# remote jobs to be run with a terminal.
		$ssh_options = "-tt -oLogLevel=quiet";
#		$ssh_options = "";
		# tty - check if we have a tty.
		# stty:
		#   -onlcr - make output 8-bit clean
		#   isig - pass CTRL-C as signal
		#   -echo - do not echo input
		$remote_pre .= ::shell_quote_scalar('tty >/dev/null && stty isig -onlcr -echo;');
	    }
	    if($opt::workdir) {
		my $wd = ::shell_quote_file($self->workdir());
		$remote_pre .= ::shell_quote_scalar("mkdir -p ") . $wd .
		    ::shell_quote_scalar("; cd ") . $wd . 
		    # exit 255 (instead of exec false) would be the correct thing,
		    # but that fails on tcsh
		    ::shell_quote_scalar(qq{ || exec false;});
	    }
	    # This script is to solve the problem of
	    # * not mixing STDERR and STDOUT
	    # * terminating with ctrl-c
	    # It works on Linux but not Solaris
	    my $signal_script = "perl -e '".
	    q{
		use IO::Poll; 
		$SIG{CHLD} = sub {exit ($?&127 ? 128+($?&127) : 1+$?>>8)}; 
		$p = IO::Poll->new; 
		$p->mask(STDOUT, POLLHUP); 
		$pid=fork; unless($pid) {setpgrp; exec $ENV{SHELL}, "-c", @ARGV; die "exec: $!\n"} 
		$p->poll; 
		kill SIGHUP, -${pid} unless $done; 
		wait; exit ($?&127 ? 128+($?&127) : 1+$?>>8) 
            } . "' ";
	    $signal_script =~ s/\s+/ /g;

	    $self->{'sshlogin_wrap'} =
		($pre
		 . "$sshcmd $ssh_options $serverlogin $parallel_env "
		 . $remote_pre
#		 . ::shell_quote_scalar($signal_script . ::shell_quote_scalar($next_command_line))
		 . ::shell_quote_scalar($next_command_line)
		 . ";" 
		 . $post);
	}
    }
    return $self->{'sshlogin_wrap'};
}

sub transfer {
    # Files to transfer
    # Returns:
    #   @transfer - File names of files to transfer
    my $self = shift;
    my @transfer = ();
    $self->{'transfersize'} = 0;
    if($opt::transfer) {
	for my $record (@{$self->{'commandline'}{'arg_list'}}) {
	    # Merge arguments from records into args
	    for my $arg (@$record) {
		CORE::push @transfer, $arg->orig();
		# filesize
		if(-e $arg->orig()) {
		    $self->{'transfersize'} += (stat($arg->orig()))[7];
		}
	    }
	}
    }
    return @transfer;
}

sub transfersize {
    my $self = shift;
    return $self->{'transfersize'};
}

sub sshtransfer {
  # Returns for each transfer file:
  #   rsync $file remote:$workdir
    my $self = shift;
    my @pre;
    my $sshlogin = $self->sshlogin();
    my $workdir = $self->workdir();
    for my $file ($self->transfer()) {
      push @pre, $sshlogin->rsync_transfer_cmd($file,$workdir).";";
    }
    return join("",@pre);
}

sub return {
    # Files to return
    # Non-quoted and with {...} substituted
    # Returns:
    #   @non_quoted_filenames
    my $self = shift;
    return $self->{'commandline'}->
	replace_placeholders($self->{'commandline'}{'return_files'},0,0);
}

sub returnsize {
    # This is called after the job has finished
    # Returns:
    #   $number_of_bytes transferred in return
    my $self = shift;
    for my $file ($self->return()) {
	if(-e $file) {
	    $self->{'returnsize'} += (stat($file))[7];
	}
    }
    return $self->{'returnsize'};
}

sub sshreturn {
    # Returns for each return-file:
    #   rsync remote:$workdir/$file .
    my $self = shift;
    my $sshlogin = $self->sshlogin();
    my $sshcmd = $sshlogin->sshcommand();
    my $serverlogin = $sshlogin->serverlogin();
    my $rsync_opt = "-rlDzR -e".::shell_quote_scalar($sshcmd);
    my $pre = "";
    for my $file ($self->return()) {
	$file =~ s:^\./::g; # Remove ./ if any
	my $relpath = ($file !~ m:^/:); # Is the path relative?
	my $cd = "";
	my $wd = "";
	if($relpath) {
	    #   rsync -avR /foo/./bar/baz.c remote:/tmp/
	    # == (on old systems)
	    #   rsync -avR --rsync-path="cd /foo; rsync" remote:bar/baz.c /tmp/
	    $wd = ::shell_quote_file($self->workdir()."/");
	}
	# Only load File::Basename if actually needed
	$Global::use{"File::Basename"} ||= eval "use File::Basename; 1;";
	# dir/./file means relative to dir, so remove dir on remote 
	$file =~ m:(.*)/\./:;
	my $basedir = $1 ? ::shell_quote_file($1."/") : "";
	my $nobasedir = $file;
	$nobasedir =~ s:.*/\./::;
	$cd = ::shell_quote_file(::dirname($nobasedir));
	my $rsync_cd = '--rsync-path='.::shell_quote_scalar("cd $wd$cd; rsync");
	my $basename = ::shell_quote_scalar(::shell_quote_file(basename($file)));
	# --return
	#   mkdir -p /home/tange/dir/subdir/; 
        #   rsync -rlDzR --rsync-path="cd /home/tange/dir/subdir/; rsync" 
        #   server:file.gz /home/tange/dir/subdir/
	$pre .= "mkdir -p $basedir$cd; rsync $rsync_cd $rsync_opt $serverlogin:".
	     $basename . " ".$basedir.$cd.";";
    }
    return $pre;
}

sub sshcleanup {
    # Return the sshcommand needed to remove the file
    # Returns:
    #   ssh command needed to remove files from sshlogin
    my $self = shift;
    my $sshlogin = $self->sshlogin();
    my $sshcmd = $sshlogin->sshcommand();
    my $serverlogin = $sshlogin->serverlogin();
    my $workdir = $self->workdir();
    my $cleancmd = "";

    for my $file ($self->cleanup()) {
	my @subworkdirs = parentdirs_of($file);
	$cleancmd .= $sshlogin->cleanup_cmd($file,$workdir).";";
    }
    if(defined $opt::workdir and $opt::workdir eq "...") {
	$cleancmd .= "$sshcmd $serverlogin rm -rf " . ::shell_quote_scalar($workdir).';';
    }
    return $cleancmd;
}

sub cleanup {
    # Returns:
    #   Files to remove at cleanup
    my $self = shift;
    if($opt::cleanup) {
	my @transfer = $self->transfer();
	my @return = $self->return();
	return (@transfer,@return);
    } else {
	return ();
    }
}

sub workdir {
    # Returns:
    #   the workdir on a remote machine
    my $self = shift;
    if(not defined $self->{'workdir'}) {
	my $workdir;
	if(defined $opt::workdir) {
	    if($opt::workdir eq ".") {
		# . means current dir
		my $home = $ENV{'HOME'};
		eval 'use Cwd';
		my $cwd = cwd();
		$workdir = $cwd;
		if($home) {
		    # If homedir exists: remove the homedir from
		    # workdir if cwd starts with homedir
		    # E.g. /home/foo/my/dir => my/dir
		    # E.g. /tmp/my/dir => /tmp/my/dir
		    my ($home_dev, $home_ino) = (stat($home))[0,1];
		    my $parent = "";
		    my @dir_parts = split(m:/:,$cwd);
		    my $part;
		    while(defined ($part = shift @dir_parts)) {
			$part eq "" and next;
			$parent .= "/".$part;
			my ($parent_dev, $parent_ino) = (stat($parent))[0,1];
			if($parent_dev == $home_dev and $parent_ino == $home_ino) {
			    # dev and ino is the same: We found the homedir.
			    $workdir = join("/",@dir_parts);
			    last;
			}
		    }
		}
		if($workdir eq "") {
		    $workdir = ".";
		}
	    } elsif($opt::workdir eq "...") {
		$workdir = ".parallel/tmp/" . ::hostname() . "-" . $$
		    . "-" . $self->seq();
	    } else {
		$workdir = $opt::workdir;
		# Rsync treats /./ special. We dont want that
		$workdir =~ s:/\./:/:g; # Remove /./
		$workdir =~ s:/+$::; # Remove ending / if any
		$workdir =~ s:^\./::g; # Remove starting ./ if any
	    }
	} else {
	    $workdir = ".";
	}
	$self->{'workdir'} = ::shell_quote_scalar($workdir);
    }
    return $self->{'workdir'};
}

sub parentdirs_of {
    # Return:
    #   all parentdirs except . of this dir or file - sorted desc by length
    my $d = shift;
    my @parents = ();
    while($d =~ s:/[^/]+$::) {
	if($d ne ".") {
	    push @parents, $d;
	}
    }
    return @parents;
}

sub start {
    # Setup STDOUT and STDERR for a job and start it.
    # Returns:
    #   job-object or undef if job not to run
    my $job = shift;
    # Get the shell command to be executed (possibly with ssh infront).
    my $command = $job->sshlogin_wrap();

    if($Global::interactive or $Global::stderr_verbose) {
	if($Global::interactive) {
	    print $Global::original_stderr "$command ?...";
	    open(my $tty_fh, "<", "/dev/tty") || ::die_bug("interactive-tty");
	    my $answer = <$tty_fh>;
	    close $tty_fh;
	    my $run_yes = ($answer =~ /^\s*y/i);
	    if (not $run_yes) {
		$command = "true"; # Run the command 'true'
	    }
	} else {
	    print $Global::original_stderr "$command\n";
	}
    }

    my $pid;
    $job->openoutputfiles();
    my($stdout_fh,$stderr_fh) = ($job->fh(1,"w"),$job->fh(2,"w"));
    local (*IN,*OUT,*ERR);
    open OUT, '>&', $stdout_fh or ::die_bug("Can't redirect STDOUT: $!");
    open ERR, '>&', $stderr_fh or ::die_bug("Can't dup STDOUT: $!");

    if(($opt::dryrun or $Global::verbose) and not $Global::grouped) {
	if($Global::verbose <= 1) {
	    print $stdout_fh $job->replaced(),"\n";
	} else {
	    # Verbose level > 1: Print the rsync and stuff
	    print $stdout_fh $command,"\n";
	}
    }
    if($opt::dryrun) {
	$command = "true";
    }
    $ENV{'PARALLEL_SEQ'} = $job->seq();
    $ENV{'PARALLEL_PID'} = $$;
    ::debug("run", $Global::total_running, " processes . Starting (",
	    $job->seq(), "): $command\n");
    if($opt::pipe) {
	my ($stdin_fh);
	# Wrap command with end-of-file detector, 
	# so we do not spawn a program if there is no input.
	# Exit value:
	#   empty input = true
	#   some input = exit val from command
	# Bug:
	#   If the command does not read the first char, the temp file
	#   is not deleted.
        my ($dummy_fh, $tmpfile) = ::tempfile(SUFFIX => ".chr");
	$command = qq{
             sh -c 'dd bs=1 count=1 of=$tmpfile 2>/dev/null';
             test \! -s "$tmpfile" && rm -f "$tmpfile" && exec true;
             (cat $tmpfile; rm $tmpfile; cat - ) | } .
		 "($command);";
	if($opt::tmux) {
	    $command = $job->tmux_wrap($command);
	}

	# The eval is needed to catch exception from open3
	eval {
	    $pid = ::open3($stdin_fh, ">&OUT", ">&ERR", $ENV{SHELL}, "-c", $command) ||
		::die_bug("open3-pipe");
	    1;
	};
	$job->set_fh(0,"w",$stdin_fh);
    } elsif(@opt::a and not $Global::stdin_in_opt_a and $job->seq() == 1
	    and $job->sshlogin()->string() eq ":") {
	# Give STDIN to the first job if using -a (but only if running
	# locally - otherwise CTRL-C does not work for other jobs Bug#36585)
	*IN = *STDIN;
	# The eval is needed to catch exception from open3
	if($opt::tmux) {
	    $command = $job->tmux_wrap($command);
	}
	eval {
	    $pid = ::open3("<&IN", ">&OUT", ">&ERR", $ENV{SHELL}, "-c", $command) ||
		::die_bug("open3-a");
	    1;
	};
	# Re-open to avoid complaining
	open(STDIN, "<&", $Global::original_stdin)
	    or ::die_bug("dup-\$Global::original_stdin: $!");
    } elsif ($opt::tty and not $Global::tty_taken and -c "/dev/tty" and
	     open(my $devtty_fh, "<", "/dev/tty")) {
	# Give /dev/tty to the command if no one else is using it
	*IN = $devtty_fh;
	# The eval is needed to catch exception from open3
	if($opt::tmux) {
	    $command = $job->tmux_wrap($command);
	}
	eval {
	    $pid = ::open3("<&IN", ">&OUT", ">&ERR", $ENV{SHELL}, "-c", $command) ||
		::die_bug("open3-/dev/tty");
	    $Global::tty_taken = $pid;
	    close $devtty_fh;
	    1;
	};
    } else {
	if($opt::tmux) {
	    $command = $job->tmux_wrap($command);
	}
	eval {
	    $pid = ::open3(::gensym, ">&OUT", ">&ERR", $ENV{SHELL}, "-c", $command) ||
		::die_bug("open3-gensym");
	    1;
	};
    }
    if($pid) {
	# A job was started
	$Global::total_running++;
	$Global::total_started++;
	$job->set_pid($pid);
	$job->set_starttime();
	$Global::running{$job->pid()} = $job;
	if($opt::timeout) {
	    $Global::timeoutq->insert($job);
	}
	$Global::newest_job = $job;
	$Global::newest_starttime = ::now();
	return $job;
    } else {
	# No more processes
	::debug("run", "Cannot spawn more jobs.\n");
	return undef;
    }
}

sub tmux_wrap {
    # Wrap command with tmux for session pPID
    # Input:
    #   $actual_command = the actual command being run (incl ssh wrap)
    my $self = shift;
    my $actual_command = shift;
    # Temporary file name. Used for fifo to communicate exit val
    my ($fh, $tmpfile) = ::tempfile(SUFFIX => ".tmx");
    $Global::unlink{$tmpfile}=1;
    close $fh;
    unlink $tmpfile;
    my $visual_command = $self->replaced();
    my $title = ::undef_as_empty($self->{'commandline'}->replace_placeholders(["\257<\257>"],0,0))."";
    # ascii 194-224 annoys tmux
    $title =~ s/[\011-\016;\302-\340]//g;

    my $tmux;
    if($Global::total_running == 0) {
	$tmux = "tmux new-session -s p$$ -d -n ".
	    ::shell_quote_scalar($title);
	print $Global::original_stderr "See output with: tmux attach -t p$$\n";
    } else {
	$tmux = "tmux new-window -t p$$ -n ".::shell_quote_scalar($title);
    }
    return "mkfifo $tmpfile; $tmux ".
	# Run in tmux
	::shell_quote_scalar("(".$actual_command.');(echo $?$status;echo 255) >'.$tmpfile.";".
			     "echo ".::shell_quote_scalar($visual_command).";".
			     "echo \007Job finished at: `date`;sleep 10").
			     # Run outside tmux
			     ";  exit `perl -ne '1..1 and print' $tmpfile;rm $tmpfile` ";
}

sub is_already_in_results {
    # Do we already have results for this job?
    # Returns:
    #   $job_already_run = bool whether there is output for this or not
    my $job = $_[0];
    my $args_as_dirname = $job->{'commandline'}->args_as_dirname();
    # prefix/name1/val1/name2/val2/
    my $dir = $opt::results."/".$args_as_dirname;
    ::debug("run", "Test $dir/stdout", -e "$dir/stdout", "\n");
    return -e "$dir/stdout";
}

sub is_already_in_joblog {
    my $job = shift;
    return vec($Global::job_already_run,$job->seq(),1);
}

sub set_job_in_joblog {
    my $job = shift;
    vec($Global::job_already_run,$job->seq(),1) = 1;
}

sub should_be_retried {
    # Should this job be retried?
    # Returns
    #   0 - do not retry
    #   1 - job queued for retry
    my $self = shift;
    if (not $opt::retries) {
	return 0;
    }
    if(not $self->exitstatus()) {
	# Completed with success. If there is a recorded failure: forget it
	$self->reset_failed_here();
	return 0
    } else {
	# The job failed. Should it be retried?
	$self->add_failed_here();
	if($self->total_failed() == $opt::retries) {
	    # This has been retried enough
	    return 0;
	} else {
	    # This command should be retried
	    $self->set_endtime(undef);
	    $Global::JobQueue->unget($self);
	    ::debug("run", "Retry ", $self->seq(), "\n");
	    return 1;
	}
    }
}

sub print {
    # Print the output of the jobs
    # Returns: N/A

    my $self = shift;
    ::debug("print", ">>joboutput ", $self->replaced(), "\n");
    if($opt::dryrun) {
	# Nothing was printed to this job:
	# cleanup tmp files if --files was set
	unlink $self->fh(1,"name");
    }
    if($opt::pipe and $self->virgin()) {
	# Skip --joblog, --dryrun, --verbose
    } else {
	if($Global::joblog) { $self->print_joblog() }

	# Printing is only relevant for grouped output.
	$Global::grouped or return;
	# Check for disk full
	exit_if_disk_full();
	my $command = $self->sshlogin_wrap();
	
	if(($opt::dryrun or $Global::verbose) and $Global::grouped
	   and
	   not $self->{'verbose_printed'}) {
	    $self->{'verbose_printed'}++;
	    if($Global::verbose <= 1) {
		print STDOUT $self->replaced(),"\n";
	    } else {
		# Verbose level > 1: Print the rsync and stuff
		print STDOUT $command,"\n";
	    }
	    # If STDOUT and STDERR are merged,
	    # we want the command to be printed first
	    # so flush to avoid STDOUT being buffered
	    flush STDOUT;
	}
    }
    for my $fdno (sort { $a <=> $b } keys %Global::fd) {
	# Sort by file descriptor numerically: 1,2,3,..,9,10,11
	$fdno == 0 and next;
	my $out_fd = $Global::fd{$fdno};
	my $in_fh = $self->fh($fdno,"r");
	if(not $in_fh) {
	    if(not $Job::file_descriptor_warning_printed{$fdno}++) {
		# ::warning("File descriptor $fdno not defined\n");
	    }
	    next;
	}
	::debug("print", "File descriptor $fdno (", $self->fh($fdno,"name"), "):");
	if($opt::files) {
	    # If --compress: $in_fh must be closed first.
	    close $self->fh($fdno,"w");
	    close $in_fh;
	    if($opt::pipe and $self->virgin()) {
		# Nothing was printed to this job:                                                                                           # cleanup unused tmp files if --files was set
		for my $fdno (1,2) {
		    unlink $self->fh($fdno,"name");
		    unlink $self->fh($fdno,"unlink");
		}
	    } elsif($fdno == 1 and $self->fh($fdno,"name")) {
		print $out_fd $self->fh($fdno,"name"),"\n";
	    }
	} elsif($opt::linebuffer) {
	    # Line buffered print out
	    my $partial = \$self->{'partial_line',$fdno};
	    if(defined $self->{'exitstatus'}) {
		# If the job is dead: close printing fh. Needed for --compress
		close $self->fh($fdno,"w");
		if($opt::compress && $opt::linebuffer) {
		    # Blocked reading in final round
		    $Global::use{"Fcntl"} ||= eval "use Fcntl qw(:DEFAULT :flock); 1;";
		    for my $fdno (1,2) {
			my $fdr = $self->fh($fdno,'r');
			my $flags;
			fcntl($fdr, &F_GETFL, $flags) || die $!; # Get the current flags on the filehandle
			$flags &= ~&O_NONBLOCK; # Remove non-blocking to the flags
			fcntl($fdr, &F_SETFL, $flags) || die $!; # Set the flags on the filehandle
		    }
		}
	    }
	    # This seek will clear EOF
	    seek $in_fh, tell($in_fh), 0;
	    # The read is non-blocking: The $in_fh is set to non-blocking.
	    # 32768 --tag = 5.1s
	    # 327680 --tag = 4.4s
	    # 1024000 --tag = 4.4s
	    # 3276800 --tag = 4.3s
	    # 32768000 --tag = 4.7s
	    # 10240000 --tag = 4.3s
	    while(read($in_fh,substr($$partial,length $$partial),3276800)) {
		# Append to $$partial
		# Find the last \n
		my $i = rindex($$partial,"\n");
		if($i != -1) {
		    # One or more complete lines were found
		    if($fdno == 2 and not $self->{'printed_first_line',$fdno}++) {
			# OpenSSH_3.6.1p2 gives 'tcgetattr: Invalid argument' with -tt
			# This is a crappy way of ignoring it.
			$$partial =~ s/^(client_process_control: )?tcgetattr: Invalid argument\n//;
			# Length of partial line has changed: Find the last \n again
			$i = rindex($$partial,"\n");
		    }
		    if($opt::tag or defined $opt::tagstring) {
			# Replace ^ with $tag within the full line
			my $tag = $self->tag();
			substr($$partial,0,$i+1) =~ s/^/$tag/gm;
			# Length of partial line has changed: Find the last \n again
			$i = rindex($$partial,"\n");
		    }
		    # Print up to and including the last \n
		    print $out_fd substr($$partial,0,$i+1);
		    # Remove the printed part
		    substr($$partial,0,$i+1)="";
		}
	    }
	    if(defined $self->{'exitstatus'}) {
		# If the job is dead: print the remaining partial line
		# read remaining
		if($$partial and ($opt::tag or defined $opt::tagstring)) {
		    my $tag = $self->tag();
		    $$partial =~ s/^/$tag/gm;
		}
		print $out_fd $$partial;
		# Release the memory
		$$partial = undef;
		if($self->fh($fdno,"rpid") and CORE::kill 0, $self->fh($fdno,"rpid")) {
		    # decompress still running
		} else {
		    # decompress done: close fh
		    close $in_fh;
		}
	    }
	} else {
	    my $buf;
	    close $self->fh($fdno,"w");
	    seek $in_fh, 0, 0;
	    # $in_fh is now ready for reading at position 0
	    if($opt::tag or defined $opt::tagstring) {
		my $tag = $self->tag();
		if($fdno == 2) {
		    # OpenSSH_3.6.1p2 gives 'tcgetattr: Invalid argument' with -tt
		    # This is a crappy way of ignoring it.
		    while(<$in_fh>) {
			if(/^(client_process_control: )?tcgetattr: Invalid argument\n/) {
			    # Skip
			} else {
			    print $out_fd $tag,$_;
			}
			# At most run the loop once
			last;
		    }
		}
		while(<$in_fh>) {
		    print $out_fd $tag,$_;
		}
	    } else {
		my $buf;
		if($fdno == 2) {
		    # OpenSSH_3.6.1p2 gives 'tcgetattr: Invalid argument' with -tt
		    # This is a crappy way of ignoring it.
		    sysread($in_fh,$buf,1_000);
		    $buf =~ s/^(client_process_control: )?tcgetattr: Invalid argument\n//;
		    print $out_fd $buf;
		}
		while(sysread($in_fh,$buf,32768)) {
		    print $out_fd $buf;
		}
	    }
	    close $in_fh;   
	}
	flush $out_fd;
    }
    ::debug("print", "<<joboutput @command\n");
}

sub print_joblog {
    my $self = shift;
    my $cmd;
    if($Global::verbose <= 1) {
	$cmd = $self->replaced();
    } else {
	# Verbose level > 1: Print the rsync and stuff
	$cmd = "@command";
    }
    print $Global::joblog
	join("\t", $self->seq(), $self->sshlogin()->string(),
	     $self->starttime(), sprintf("%10.3f",$self->runtime()),
	     $self->transfersize(), $self->returnsize(),
	     $self->exitstatus(), $self->exitsignal(), $cmd
	). "\n";
    flush $Global::joblog;
    $self->set_job_in_joblog();
}

sub tag {
    my $self = shift;
    if(not defined $self->{'tag'}) {
	$self->{'tag'} = $self->{'commandline'}->
	    replace_placeholders([$opt::tagstring],0,0)."\t";
    }
    return $self->{'tag'};
}

sub exitstatus {
    my $self = shift;
    return $self->{'exitstatus'};
}

sub set_exitstatus {
    my $self = shift;
    my $exitstatus = shift;
    if($exitstatus) {
	# Overwrite status if non-zero
	$self->{'exitstatus'} = $exitstatus;
    } else {
	# Set status but do not overwrite
	# Status may have been set by --timeout
	$self->{'exitstatus'} ||= $exitstatus;
    }
}

sub exitsignal {
    my $self = shift;
    return $self->{'exitsignal'};
}

sub set_exitsignal {
    my $self = shift;
    my $exitsignal = shift;
    $self->{'exitsignal'} = $exitsignal;
}

{
    my ($disk_full_fh,$error_printed);
    sub exit_if_disk_full {
	# Checks if $TMPDIR is full by writing 8kb to a tmpfile
	# If the disk is full: Exit immediately.
	# Returns:
	#   N/A
	if(not $disk_full_fh) {
	    $disk_full_fh = ::tempfile();
	}
	my $pos = tell $disk_full_fh;
	print $disk_full_fh "x"x8193;
	if(not $disk_full_fh
	   or
	   tell $disk_full_fh == $pos) {
	    ::error("Output is incomplete. Cannot append to buffer file in \$TMPDIR. Is the disk full?\n");
	    ::error("Change \$TMPDIR with --tmpdir or use --compress.\n");
	    ::wait_and_exit(255);
	}
	truncate $disk_full_fh, $pos;
    }
}


package CommandLine;

sub new {
    my $class = shift;
    my $seq = shift;
    my $commandref = shift;
    $commandref || die;
    my $arg_queue = shift;
    my $context_replace = shift;
    my $max_number_of_args = shift; # for -N and normal (-n1)
    my $return_files = shift;
    my $replacecount_ref = shift;
    my $len_ref = shift;
    my %replacecount = %$replacecount_ref;
    my %len = %$len_ref;
    for (keys %$replacecount_ref) {
	# Total length of this replacement string {} replaced with all args
	$len{$_} = 0;
    }
    return bless {
	'command' => $commandref,
	'seq' => $seq,
	'len' => \%len,
	'arg_list' => [],
	'arg_queue' => $arg_queue,
	'max_number_of_args' => $max_number_of_args,
	'replacecount' => \%replacecount,
	'context_replace' => $context_replace,
	'return_files' => $return_files,
	'replaced' => undef,
    }, ref($class) || $class;
}

sub seq {
    my $self = shift;
    return $self->{'seq'};
}

sub slot {
    my $self = shift;
    if(not $self->{'slot'}) {
	if(not @Global::slots) {
	    # $Global::max_slot_number will typically be $Global::max_jobs_running
	    push @Global::slots, ++$Global::max_slot_number;
	}
	$self->{'slot'} = shift @Global::slots;
    }
    return $self->{'slot'};
}

sub populate {
    # Add arguments from arg_queue until the number of arguments or
    # max line length is reached
    # Returns: N/A
    my $self = shift;
    my $next_arg;
    my $max_len = $Global::minimal_command_line_length || Limits::Command::max_length();
    
    if($opt::cat or $opt::fifo) {
	# Get a tempfile name
	my($outfh,$name) = ::tempfile(SUFFIX => ".pip");
	close $outfh;
	# Unlink is needed if: ssh otheruser@localhost
	unlink $name;
	$Global::JobQueue->{'commandlinequeue'}->{'arg_queue'}->unget([Arg->new($name)]);
    }

    while (not $self->{'arg_queue'}->empty()) {
	$next_arg = $self->{'arg_queue'}->get();
	if(not defined $next_arg) {
	    next;
	}
	$self->push($next_arg);
	if($self->len() >= $max_len) {
	    # Command length is now > max_length
	    # If there are arguments: remove the last
	    # If there are no arguments: Error
	    # TODO stuff about -x opt_x
	    if($self->number_of_args() > 1) {
		# There is something to work on
		$self->{'arg_queue'}->unget($self->pop());
		last;
	    } else {
		my $args = join(" ", map { $_->orig() } @$next_arg);
		::error("Command line too long (", 
			$self->len(), " >= ",
			Limits::Command::max_length(),
			") at number ",
			$self->{'arg_queue'}->arg_number(),
			": ".
			(substr($args,0,50))."...\n");
		$self->{'arg_queue'}->unget($self->pop());
		::wait_and_exit(255);
	    }
	}

	if(defined $self->{'max_number_of_args'}) {
	    if($self->number_of_args() >= $self->{'max_number_of_args'}) {
		last;
	    }
	}
    }
    if(($opt::m or $opt::X) and not $CommandLine::already_spread
       and $self->{'arg_queue'}->empty() and $Global::max_jobs_running) {
	# -m or -X and EOF => Spread the arguments over all jobslots
	# (unless they are already spread)
	$CommandLine::already_spread ||= 1;
	if($self->number_of_args() > 1) {
	    $self->{'max_number_of_args'} =
		::ceil($self->number_of_args()/$Global::max_jobs_running);
	    $Global::JobQueue->{'commandlinequeue'}->{'max_number_of_args'} =
		$self->{'max_number_of_args'};
	    $self->{'arg_queue'}->unget($self->pop_all());
	    while($self->number_of_args() < $self->{'max_number_of_args'}) {
		$self->push($self->{'arg_queue'}->get());
	    }
	}
    }
}

sub push {
    # Add one or more records as arguments
    # Returns: N/A
    my $self = shift;
    my $record = shift;
    push @{$self->{'arg_list'}}, $record;
    my $arg_no = ($self->number_of_args()-1) * ($#$record+1);

    my $quote_arg = $Global::noquote ? 0 : not $Global::quoting;
    my $rep;
    for my $arg (@$record) {
	$arg_no++;
	if(defined $arg) {
	    for my $perlexpr (keys %{$self->{'replacecount'}}) {
		$rep = $arg->replace($perlexpr,$quote_arg,$self);
		$self->{'len'}{$perlexpr} += length $rep;
		::debug("length", "Length: ", length $rep, 
			"(", $perlexpr, "=>", $rep, ")\n");
	    }
	}
    }
}

sub pop {
    # Remove last argument
    # Returns:
    #   the last record
    my $self = shift;
    my $record = pop @{$self->{'arg_list'}};
    my $quote_arg = $Global::noquote ? 0 : not $Global::quoting;
    for my $arg (@$record) {
	if(defined $arg) {
	    for my $perlexpr (keys %{$self->{'replacecount'}}) {
		$self->{'len'}{$perlexpr} -=
		    length $arg->replace($perlexpr,$quote_arg,$self);
	    }
	}
    }
    return $record;
}

sub pop_all {
    # Remove all arguments and zeros the length of replacement strings
    # Returns:
    #   all records
    my $self = shift;
    my @popped = @{$self->{'arg_list'}};
    for my $replacement_string (keys %{$self->{'replacecount'}}) {
	$self->{'len'}{$replacement_string} = 0;
    }
    $self->{'arg_list'} = [];
    return @popped;
}

sub number_of_args {
    # The number of records
    # Returns:
    #   number of records
    my $self = shift;
    # Ftq rudef oaawuq ime dqxqmeqp az 2011-01-24 mzp ime iaz nk MQhmd
    # Mdzrvadp Nvmdymeaz az 2011-04-10. Ftue oaawuq dqxqmeqp az
    # 2013-08-18 ue m nuf tmdpqd me kag tmhq fa geq daf14. Bxqmeq
    # qymux oaawuq@fmzsq.pw itqz kag dqmp ftue.
    # 
    # U my ftq ymuzfmuzqd ar m buqoq ar rdqq earfimdq omxxqp SZG
    # Bmdmxxqx. Rdqq earfimdq sgmdmzfqqe kag mooqee fa ftq eagdoq
    # oapq, ngf U tmhq nqqz iazpqduzs tai ymzk mofgmxxk _dqmp_ ftq
    # eagdoq oapq.
    # 
    # Fa fqef ftue U bgf uz m oayyqzf fqxxuzs bqabxq fa qymux yq itqz
    # ftqk dqmp ftue. Ftq oayyqzf ime bgf uz m eqofuaz ar ftq oapq
    # ftmf za azq iagxp xaaw fa ruj ad uybdahq ftq earfimdq - ea ftq
    # eagdoq oapq qcguhmxqzf fa m pgefk oadzqd. Fa ymwq egdq ftq
    # oayyqzf iagxp zaf etai gb ur eayq azq vgef sdqbbqp ftdagst ftq
    # eagdoq oapq U daf13'qp ftq eagdoq oapq
    # tffb://qz.iuwubqpum.ads/iuwu/DAF13
    # 
    # 2.5 yazfte xmfqd U dqoquhqp mz qymux rday eayqazq ita zaf azxk
    # ymzmsqp fa ruzp ftq oayyqzf, ngf mxea ymzmsqp fa sgqee ftq oapq
    # tmp fa nq daf13'qp.
    # 
    # Ftue nduzse yq fa ftq oazoxgeuaz ftmf ftqdq _mdq_ bqabxq, ita
    # mdq zaf mrruxumfqp iuft ftq bdavqof, ftmf iuxx dqmp ftq eagdoq
    # oapq - ftagst uf ymk zaf tmbbqz hqdk arfqz.
    #
    # This is really the number of records
    return $#{$self->{'arg_list'}}+1;
}

sub number_of_recargs {
    # The number of args in records
    # Returns:
    #   number of args records
    my $self = shift;
    my $sum = 0;
    my $nrec = scalar @{$self->{'arg_list'}};
    if($nrec) {
	$sum = $nrec * (scalar @{$self->{'arg_list'}[0]});
    }
    return $sum;
}

sub args_as_string {
    # Returns:
    #  all unmodified arguments joined with ' ' (similar to {})
    my $self = shift;
    return (join " ", map { $_->orig() }
	    map { @$_ } @{$self->{'arg_list'}});
}

sub args_as_dirname {
    # Returns:
    #  all unmodified arguments joined with '/' (similar to {})
    #  \t \0 \\ and / are quoted as: \t \0 \\ \_
    # If $Global::max_file_length: Keep subdirs < $Global::max_file_length
    my $self = shift;
    my @res = ();

    for my $rec_ref (@{$self->{'arg_list'}}) {
	# If headers are used, sort by them.
	# Otherwise keep the order from the command line.
	my @header_indexes_sorted = header_indexes_sorted($#$rec_ref+1);
	for my $n (@header_indexes_sorted) {
	    CORE::push(@res,
		 $Global::input_source_header{$n},
		 map { my $s = $_;
		       #  \t \0 \\ and / are quoted as: \t \0 \\ \_
		       $s =~ s/\\/\\\\/g;
		       $s =~ s/\t/\\t/g;
		       $s =~ s/\0/\\0/g;
		       $s =~ s:/:\\_:g;
		       if($Global::max_file_length) {
			   # Keep each subdir shorter than the longest
			   # allowed file name
			   $s = substr($s,0,$Global::max_file_length);
		       }
		       $s; }
		 $rec_ref->[$n-1]->orig());
	}
    }
    return join "/", @res;
}

sub header_indexes_sorted {
    # Sort headers first by number then by name.
    # E.g.: 1a 1b 11a 11b
    # Returns:
    #  Indexes of %Global::input_source_header sorted
    my $max_col = shift;
    
    no warnings 'numeric';
    for my $col (1 .. $max_col) {
	# Make sure the header is defined. If it is not: use column number
	if(not defined $Global::input_source_header{$col}) {
	    $Global::input_source_header{$col} = $col;
	}
    }
    my @header_indexes_sorted = sort {
	# Sort headers numerically then asciibetically
	$Global::input_source_header{$a} <=> $Global::input_source_header{$b}
	or
	    $Global::input_source_header{$a} cmp $Global::input_source_header{$b}
    } 1 .. $max_col;
    return @header_indexes_sorted;
}

sub len {
    # The length of the command line with args substituted
    my $self = shift;
    my $len = 0;
    # Add length of the original command with no args
    # Length of command w/ all replacement args removed
    $len += $self->{'len'}{'noncontext'} + @{$self->{'command'}} -1;
    ::debug("length", "noncontext + command: $len\n");
    my $recargs = $self->number_of_recargs();
    if($self->{'context_replace'}) {
	# Context is duplicated for each arg
	$len += $recargs * $self->{'len'}{'context'};
	for my $replstring (keys %{$self->{'replacecount'}}) {
	    # If the replacements string is more than once: mulitply its length
	    $len += $self->{'len'}{$replstring} *
		$self->{'replacecount'}{$replstring};
	    ::debug("length", $replstring, " ", $self->{'len'}{$replstring}, "*",
		    $self->{'replacecount'}{$replstring}, "\n");
	}
	# echo 11 22 33 44 55 66 77 88 99 1010
	# echo 1 2 3 4 5 6 7 8 9 10 1 2 3 4 5 6 7 8 9 10
	# 5 +  ctxgrp*arg
	::debug("length", "Ctxgrp: ", $self->{'len'}{'contextgroups'},
		" Groups: ", $self->{'len'}{'noncontextgroups'}, "\n");
	# Add space between context groups
	$len += ($recargs-1) * ($self->{'len'}{'contextgroups'});
    } else {
	# Each replacement string may occur several times
	# Add the length for each time
	$len += 1*$self->{'len'}{'context'};
	::debug("length", "context+noncontext + command: $len\n");
	for my $replstring (keys %{$self->{'replacecount'}}) {
	    # (space between regargs + length of replacement)
	    # * number this replacement is used
	    $len += ($recargs -1 + $self->{'len'}{$replstring}) *
		$self->{'replacecount'}{$replstring};
	}
    }
    if($opt::nice) {
	# Pessimistic length if --nice is set
	# Worse than worst case: every char needs to be quoted with \
	$len *= 2;
    }
    if($Global::quoting) {
	# Pessimistic length if -q is set
	# Worse than worst case: every char needs to be quoted with \
	$len *= 2;
    }
    if($opt::shellquote) {
	# Pessimistic length if --shellquote is set
	# Worse than worst case: every char needs to be quoted with \ twice
	$len *= 4;
    }
    # If we are using --env, add the prefix for that, too.
    $len += $Global::envvarlen;

    return $len;
}

sub replaced {
    my $self = shift;
    if(not defined $self->{'replaced'}) {
	# Don't quote arguments if the input is the full command line
	my $quote_arg = $Global::noquote ? 0 : not $Global::quoting;
	my $cmdstring = $self->replace_placeholders($self->{'command'},$Global::quoting,$quote_arg);
	if (length($cmdstring) != $self->len()) {
	    ::debug("length", length $cmdstring, " != ", $self->len(), " ", $cmdstring, "\n");
	} else {
	    ::debug("length", length $cmdstring, " == ", $self->len(), " ", $cmdstring, "\n");
	}
	if($opt::cat) {
	    # Prepend 'cat > {};'
	    # Append '_EXIT=$?;(rm {};exit $_EXIT)'
	    $self->{'replaced'} = 
		$self->replace_placeholders(["cat > \257<\257>; ", $cmdstring, 
					    "; _EXIT=\$?; rm \257<\257>; exit \$_EXIT"],
					    0,0);
	} elsif($opt::fifo) {
	    # Prepend 'mkfifo {}; ('
	    # Append ') & _PID=$!; cat > {}; wait $_PID; _EXIT=$?;(rm {};exit $_EXIT)'
	    $self->{'replaced'} = 
		$self->replace_placeholders(["mkfifo \257<\257>; (",
					    $cmdstring,
					    ") & _PID=\$!; cat > \257<\257>; ", 
					    "wait \$_PID; _EXIT=\$?; ",
					    "rm \257<\257>; exit \$_EXIT"],
					    0,0);
	} else {
	    $self->{'replaced'} = $cmdstring;
	}
	if($self->{'replaced'} =~ /^\s*(-\S+)/) {
	    # Is this really a command in $PATH starting with '-'?
	    my $cmd = $1;
	    if(not ::which($cmd)) {
		::error("Command ($cmd) starts with '-'. Is this a wrong option?\n");
		::wait_and_exit(255);
	    }
	}
	if($opt::nice) {
	    # Prepend \nice -n19 $SHELL -c
	    # and quote
	    # \ before nice is needed to avoid tcsh's built-in
	    $self->{'replaced'} = '\nice' ." -n" . $opt::nice . " "
		. $ENV{SHELL}." -c "
		. ::shell_quote_scalar($self->{'replaced'});
	}
	if($opt::shellquote) {
	    # Prepend echo
	    # and quote twice
	    $self->{'replaced'} = "echo " .
		::shell_quote_scalar(::shell_quote_scalar($self->{'replaced'}));
	}
    }
    return $self->{'replaced'};
}

sub replace_placeholders {
    # Replace foo{}bar with fooargbar 
    # Input:
    #   target = foo{}bar
    #   quote = should this be quoted?
    # Returns: $target
    my $self = shift;
    my $targetref = shift;
    my $quote = shift;
    my $quote_arg = shift;
    my $context_replace = $self->{'context_replace'};
    my @target = @$targetref;
    ::debug("replace", "Replace @target\n");
    # -X = context replace
    # maybe multiple input sources
    # maybe --xapply
    # $self->{'arg_list'} = [ [Arg11, Arg12], [Arg21, Arg22], [Arg31, Arg32] ]
    if(not @target) {
	# @target is empty: Return empty array
	return @target;
    }
    # Fish out the words that have replacement strings in them
    my %word;
    for (@target) {
	my $tt = $_;
	::debug("replace", "Target: $tt");
	# a{1}b{}c{}d
	# a{=1 $_=$_ =}b{= $_=$_ =}c{= $_=$_ =}d
	# a\257<1 $_=$_ \257>b\257< $_=$_ \257>c\257< $_=$_ \257>d
	#    A B C => aAbA B CcA B Cd
	# -X A B C => aAbAcAd aAbBcBd aAbCcCd

	if($context_replace) {
	    while($tt =~ s/([^\s\257]*  # before {=
                     (?:
                      \257<       # {=
                      [^\257]*?   # The perl expression
                      \257>       # =}
                      [^\s\257]*  # after =}
                     )+)/ /x) {
		# $1 = pre \257 perlexpr \257 post
		$word{"$1"} ||= 1;
	    }
	} else {
	    while($tt =~ s/( (?: \257<([^\257]*?)\257>) )//x) {
		# $f = \257 perlexpr \257
		$word{$1} ||= 1;
	    }
	}
    }
    my @word = keys %word;
    my %replace;
    my @arg;
    for my $record (@{$self->{'arg_list'}}) {
	# Merge arg-objects from records into @arg for easy access
	# If $Global::quoting is set, quoting will be done later
	CORE::push @arg, @$record;
    }

    # Number of arguments - used for positional arguments
    my $n = $#_+1;
    # This is actually a CommandLine-object,
    # but it looks nice to be able to say {= $job->slot() =}
    my $job = $self;
    for my $word (@word) {
	# word = AB \257< perlexpr \257> CD \257< perlexpr \257> EF
	my $w = $word;
	::debug("replace", "Replacing in $w\n");

	# Replace positional arguments
	$w =~ s< ([^\s\257]*)  # before {=
                 \257<         # {=
                 (-?\d+)       # Position (eg. -2 or 3)
                 ([^\257]*?)   # The perl expression
                 \257>         # =}
                 ([^\s\257]*)  # after =}
               >
	   { $1. # Context (pre)
		 (
		 $arg[$2 > 0 ? $2-1 : $n+$2] ? # If defined: replace
		 $arg[$2 > 0 ? $2-1 : $n+$2]->replace($3,$quote_arg,$self)
		 : "")
		 .$4 }egx;# Context (post)
	::debug("replace", "Positional replaced $word with: $w\n");
	
	if($w !~ /\257/) {
	    # No more replacement strings in $w: No need to do more
	    CORE::push(@{$replace{$word}}, $w); 
	    next;
	}
	# for each arg:
	#   compute replacement for each string
	#   replace replacement strings with replacement in the word value
	#   push to replace word value
	::debug("replace", "Positional done: $w\n");
	for my $arg (@arg) {
	    my $val = $w;
	    my $number_of_replacements = 0;
	    for my $perlexpr (keys %{$self->{'replacecount'}}) {
		# Replace {= perl expr =} with value for each arg
		$number_of_replacements +=
		    $val =~ s{\257<\Q$perlexpr\E\257>}
		{$arg ? $arg->replace($perlexpr,$quote_arg,$self) : ""}eg;
	    }
	    my $ww = $word;
	    if($quote) {
		$ww = ::shell_quote_scalar($word);
		$val = ::shell_quote_scalar($val);
	    }
	    if($number_of_replacements) {
		CORE::push(@{$replace{$ww}}, $val);
	    }
	}
	if(not @arg) {
	    # No args: We can still have {%} or {#} as replacement string.
	    my $val = $w;
	    for my $perlexpr (keys %{$self->{'replacecount'}}) {
		# Replace {= perl expr =} with value for each arg
		$val =~ s/\257<\Q$perlexpr\E\257>/$_="";eval("$perlexpr");$_/eg;
	    }
	    my $ww = $word;
	    if($quote) {
		$val = ::shell_quote_scalar($val);
	    }
	    CORE::push(@{$replace{$ww}}, $val); 
	}
    }
    if($quote) {
	@target = ::shell_quote(@target);
    }

    ::debug("replace", "%replace=".(::my_dump(%replace))."\n");
    if(%replace) {
	# Substitute the replace strings with the replacement values
	# Must be sorted by length if a short word is a substring of a long word
	my $regexp = join('|', map { my $s = $_; $s =~ s/(\W)/\\$1/g; $s }
			  sort { length $b <=> length $a } keys %replace);
	for(@target) {
	    s/($regexp)/join(" ",@{$replace{$1}})/ge;
	}
    }
    ::debug("replace", "Return @target\n");
    return wantarray ? @target : "@target";
}


package CommandLineQueue;

sub new {
    my $class = shift;
    my $commandref = shift;
    my $read_from = shift;
    my $context_replace = shift;
    my $max_number_of_args = shift;
    my $return_files = shift;
    my @unget = ();
    my ($count,%replacecount,$posrpl,$perlexpr,%len);
    my @command = @$commandref;
    # Replace replacement strings with {= perl expr =}
    # Protect matching inside {= perl expr =}
    # by replacing {= and =} with \257< and \257>
    for(@command) {
	if(/\257/) {
	    ::error("Command cannot contain the character \257. Use a function for that.\n");
	    ::wait_and_exit(255);
	}
	s/\Q$Global::parensleft\E(.*?)\Q$Global::parensright\E/\257<$1\257>/gx;
    }
    for my $rpl (keys %Global::rpl) {
	# Replace the short hand string with the {= perl expr =} in $command and $opt::tagstring
	# Avoid replacing inside existing {= perl expr =}
	for(@command,@Global::ret_files) {
	    while(s/((^|\257>)[^\257]*?) # Don't replace after \257 unless \257>
                  \Q$rpl\E/$1\257<$Global::rpl{$rpl}\257>/xg) {
	    }
	}
	if(defined $opt::tagstring) {
	    for($opt::tagstring) {
		while(s/((^|\257>)[^\257]*?) # Don't replace after \257 unless \257>
                      \Q$rpl\E/$1\257<$Global::rpl{$rpl}\257>/x) {}
	    }
	}
	# Do the same for the positional replacement strings
	# A bit harder as we have to put in the position number
	$posrpl = $rpl;
	if($posrpl =~ s/^\{//) {
	    # Only do this if the shorthand start with {
	    for(@command,@Global::ret_files) {
		s/\{(-?\d+)\Q$posrpl\E/\257<$1 $Global::rpl{$rpl}\257>/g;
	    }
	    if(defined $opt::tagstring) {
		$opt::tagstring =~ s/\{(-?\d+)\Q$posrpl\E/\257<$1 $perlexpr\257>/g;
	    }
	}
    }
    my $sum = 0;
    while($sum == 0) {
	# Count how many times each replacement string is used
	my @cmd = @command;
	my $contextlen = 0;
	my $noncontextlen = 0;
	my $contextgroups = 0;
	for my $c (@cmd) {
	    while($c =~ s/ \257<([^\257]*?)\257> /\000/x) {
		# %replacecount = { "perlexpr" => number of times seen }
		# e.g { "$_++" => 2 }
		$replacecount{$1} ++;
		$sum++;
	    }
	    # Measure the length of the context around the {= perl expr =}
	    # Use that {=...=} has been replaced with \000 above
	    # So there is no need to deal with \257<
	    while($c =~ s/ (\S*\000\S*) //x) {
		my $w = $1;
		$w =~ s/\000//g; # Remove all \000's
		$contextlen += length($w);
		$contextgroups++;
	    }
	    # All {= perl expr =} have been removed: The rest is non-context
	    $noncontextlen += length $c; 
	}
	if($opt::tagstring) {
	    my $t = $opt::tagstring;
	    while($t =~ s/ \257<([^\257]*)\257> //x) {
		# %replacecount = { "perlexpr" => number of times seen }
		# e.g { "$_++" => 2 }
		# But for tagstring we just need to mark it as seen
		$replacecount{$1}||=1;
	    }
	}

	$len{'context'} = 0+$contextlen;
	$len{'noncontext'} = $noncontextlen;
	$len{'contextgroups'} = $contextgroups;
	$len{'noncontextgroups'} = @cmd-$contextgroups;
	::debug("length", "@command Context: ", $len{'context'},
		" Non: ", $len{'noncontext'}, " Ctxgrp: ", $len{'contextgroups'},
		" NonCtxGrp: ", $len{'noncontextgroups'}, "\n");
	if($sum == 0) {
	    # Default command = {}
	    # If not replacement string: append {}
	    if(not @command) {
		@command = ("\257<\257>");
		$Global::noquote = 1;
	    } elsif(($opt::pipe or $opt::pipepart)
		    and not $opt::fifo and not $opt::cat) {
		# With --pipe / --pipe-part you can have no replacement
		last;
	    } else {
		# Append {} to the command if there are no {...}'s and no {=...=}
		push @command, ("\257<\257>");
	    }
	}
    }

    return bless {
	'unget' => \@unget,
	'command' => \@command,
	'replacecount' => \%replacecount,
	'arg_queue' => RecordQueue->new($read_from,$opt::colsep),
	'context_replace' => $context_replace,
	'len' => \%len,
	'max_number_of_args' => $max_number_of_args,
	'size' => undef,
	'return_files' => $return_files,
	'seq' => 1,
    }, ref($class) || $class;
}

sub get {
    my $self = shift;
    if(@{$self->{'unget'}}) {
	my $cmd_line = shift @{$self->{'unget'}};
	return ($cmd_line);
    } else {
	my $cmd_line;
	$cmd_line = CommandLine->new($self->seq(),
				     $self->{'command'},
				     $self->{'arg_queue'},
				     $self->{'context_replace'},
				     $self->{'max_number_of_args'},
				     $self->{'return_files'},
				     $self->{'replacecount'},
				     $self->{'len'},
	    );
	$cmd_line->populate();
	::debug("init","cmd_line->number_of_args ",
		$cmd_line->number_of_args(), "\n");
	if($opt::pipe or $opt::pipepart) {
	    if($cmd_line->replaced() eq "") {
		# Empty command - pipe requires a command
		::error("--pipe must have a command to pipe into (e.g. 'cat').\n");
		::wait_and_exit(255);
	    }
	} else {
	    if($cmd_line->number_of_args() == 0) {
		# We did not get more args - maybe at EOF string?
		return undef;
	    } elsif($cmd_line->replaced() eq "") {
		# Empty command - get the next instead
		return $self->get();
	    }
	}
	$self->set_seq($self->seq()+1);
	return $cmd_line;
    }
}

sub unget {
    my $self = shift;
    unshift @{$self->{'unget'}}, @_;
}

sub empty {
    my $self = shift;
    my $empty = (not @{$self->{'unget'}}) && $self->{'arg_queue'}->empty();
    ::debug("run", "CommandLineQueue->empty $empty");
    return $empty;
}

sub seq {
    my $self = shift;
    return $self->{'seq'};
}

sub set_seq {
    my $self = shift;
    $self->{'seq'} = shift;
}

sub quote_args {
    my $self = shift;
    # If there is not command emulate |bash
    return $self->{'command'};
}

sub size {
    my $self = shift;
    if(not $self->{'size'}) {
	my @all_lines = ();
	while(not $self->{'arg_queue'}->empty()) {
	    push @all_lines, CommandLine->new($self->{'command'},
					      $self->{'arg_queue'},
					      $self->{'context_replace'},
					      $self->{'max_number_of_args'});
	}
	$self->{'size'} = @all_lines;
	$self->unget(@all_lines);
    }
    return $self->{'size'};
}


package Limits::Command;

# Maximal command line length (for -m and -X)
sub max_length {
    # Find the max_length of a command line and cache it
    # Returns:
    #   number of chars on the longest command line allowed
    if(not $Limits::Command::line_max_len) {
	# Disk cache of max command line length 
	my $len_cache = $ENV{'HOME'} . "/.parallel/tmp/linelen-" . ::hostname();
	my $cached_limit;
	if(-e $len_cache) {
	    open(my $fh, "<", $len_cache) || ::die_bug("Cannot read $len_cache");
	    $cached_limit = <$fh>;
	    close $fh;
	} else {
	    $cached_limit = real_max_length();
	    # If $HOME is write protected: Do not fail
	    mkdir($ENV{'HOME'} . "/.parallel");
	    mkdir($ENV{'HOME'} . "/.parallel/tmp");
	    open(my $fh, ">", $len_cache);
	    print $fh $cached_limit;
	    close $fh;
	}
	$Limits::Command::line_max_len = $cached_limit;
	if($opt::max_chars) {
	    if($opt::max_chars <= $cached_limit) {
		$Limits::Command::line_max_len = $opt::max_chars;
	    } else {
		::warning("Value for -s option ",
			  "should be < $cached_limit.\n");
	    }
	}
    }
    return $Limits::Command::line_max_len;
}

sub real_max_length {
    # Find the max_length of a command line
    # Returns:
    #   The maximal command line length
    # Use an upper bound of 8 MB if the shell allows for for infinite long lengths
    my $upper = 8_000_000;
    my $len = 8;
    do {
	if($len > $upper) { return $len };
	$len *= 16;
    } while (is_acceptable_command_line_length($len));
    # Then search for the actual max length between 0 and upper bound
    return binary_find_max_length(int($len/16),$len);
}

sub binary_find_max_length {
    # Given a lower and upper bound find the max_length of a command line
    # Returns:
    #   number of chars on the longest command line allowed
    my ($lower, $upper) = (@_);
    if($lower == $upper or $lower == $upper-1) { return $lower; }
    my $middle = int (($upper-$lower)/2 + $lower);
    ::debug("init", "Maxlen: $lower,$upper,$middle : ");
    if (is_acceptable_command_line_length($middle)) {
	return binary_find_max_length($middle,$upper);
    } else {
	return binary_find_max_length($lower,$middle);
    }
}

sub is_acceptable_command_line_length {
    # Test if a command line of this length can run
    # Returns:
    #   0 if the command line length is too long
    #   1 otherwise
    my $len = shift;

    local *STDERR;
    open (STDERR, ">", "/dev/null");
    system "true "."x"x$len;
    close STDERR;
    ::debug("init", "$len=$? ");
    return not $?;
}


package RecordQueue;

sub new {
    my $class = shift;
    my $fhs = shift;
    my $colsep = shift;
    my @unget = ();
    my $arg_sub_queue;
    if($colsep) {
	# Open one file with colsep
	$arg_sub_queue = RecordColQueue->new($fhs);
    } else {
	# Open one or more files if multiple -a
	$arg_sub_queue = MultifileQueue->new($fhs);
    }
    return bless {
	'unget' => \@unget,
	'arg_number' => 0,
	'arg_sub_queue' => $arg_sub_queue,
    }, ref($class) || $class;
}

sub get {
    # Returns:
    #   reference to array of Arg-objects
    my $self = shift;
    if(@{$self->{'unget'}}) {
	$self->{'arg_number'}++;
	return shift @{$self->{'unget'}};
    }
    my $ret = $self->{'arg_sub_queue'}->get();
    if(defined $Global::max_number_of_args
       and $Global::max_number_of_args == 0) {
	::debug("run", "Read 1 but return 0 args\n");
	return [Arg->new("")];
    } else {
	return $ret;
    }
}

sub unget {
    my $self = shift;
    ::debug("run", "RecordQueue-unget '@_'\n");
    $self->{'arg_number'} -= @_;
    unshift @{$self->{'unget'}}, @_;
}

sub empty {
    my $self = shift;
    my $empty = not @{$self->{'unget'}};
    $empty &&= $self->{'arg_sub_queue'}->empty();
    ::debug("run", "RecordQueue->empty $empty");
    return $empty;
}

sub arg_number {
    my $self = shift;
    return $self->{'arg_number'};
}


package RecordColQueue;

sub new {
    my $class = shift;
    my $fhs = shift;
    my @unget = ();
    my $arg_sub_queue = MultifileQueue->new($fhs);
    return bless {
	'unget' => \@unget,
	'arg_sub_queue' => $arg_sub_queue,
    }, ref($class) || $class;
}

sub get {
    # Returns:
    #   reference to array of Arg-objects
    my $self = shift;
    if(@{$self->{'unget'}}) {
	return shift @{$self->{'unget'}};
    }
    my $unget_ref=$self->{'unget'};
    if($self->{'arg_sub_queue'}->empty()) {
	return undef;
    }
    my $in_record = $self->{'arg_sub_queue'}->get();
    if(defined $in_record) {
	my @out_record = ();
	for my $arg (@$in_record) {
	    ::debug("run", "RecordColQueue::arg $arg\n");
	    my $line = $arg->orig();
	    ::debug("run", "line='$line'\n");
	    if($line ne "") {
		for my $s (split /$opt::colsep/o, $line, -1) {
		    push @out_record, Arg->new($s);
		}
	    } else {
		push @out_record, Arg->new("");
	    }
	}
	return \@out_record;
    } else {
	return undef;
    }
}

sub unget {
    my $self = shift;
    ::debug("run", "RecordColQueue-unget '@_'\n");
    unshift @{$self->{'unget'}}, @_;
}

sub empty {
    my $self = shift;
    my $empty = (not @{$self->{'unget'}} and $self->{'arg_sub_queue'}->empty());
    ::debug("run", "RecordColQueue->empty $empty");
    return $empty;
}


package MultifileQueue;

@Global::unget_argv=();

sub new {
    my $class = shift;
    my $fhs = shift;
    for my $fh (@$fhs) {
	if(-t $fh) {
	    ::warning("Input is read from the terminal. ".
		      "Only experts do this on purpose. ".
		      "Press CTRL-D to exit.\n");
	}
    }
    return bless {
	'unget' => \@Global::unget_argv,
	'fhs' => $fhs,
	'arg_matrix' => undef,
    }, ref($class) || $class;
}

sub get {
    my $self = shift;
    if($opt::xapply) {
	return $self->xapply_get();
    } else {
	return $self->nest_get();
    }
}

sub unget {
    my $self = shift;
    ::debug("run", "MultifileQueue-unget '@_'\n");
    unshift @{$self->{'unget'}}, @_;
}

sub empty {
    my $self = shift;
    my $empty = (not @Global::unget_argv
		 and not @{$self->{'unget'}});
    for my $fh (@{$self->{'fhs'}}) {
	$empty &&= eof($fh);
    }
    ::debug("run", "MultifileQueue->empty $empty");
    return $empty;
}

sub xapply_get {
    my $self = shift;
    if(@{$self->{'unget'}}) {
	return shift @{$self->{'unget'}};
    }
    my @record = ();
    my $prepend = undef;
    my $empty = 1;
    for my $fh (@{$self->{'fhs'}}) {
	my $arg = read_arg_from_fh($fh);
	if(defined $arg) {
	    # Record $arg for recycling at end of file
	    push @{$self->{'arg_matrix'}{$fh}}, $arg;
	    push @record, $arg;
	    $empty = 0;
	} else {
	    ::debug("run", "EOA ");
	    # End of file: Recycle arguments
	    push @{$self->{'arg_matrix'}{$fh}}, shift @{$self->{'arg_matrix'}{$fh}};
	    # return last @{$args->{'args'}{$fh}};
	    push @record, @{$self->{'arg_matrix'}{$fh}}[-1];
	}
    }
    if($empty) {
	return undef;
    } else {
	return \@record;
    }
}

sub nest_get {
    my $self = shift;
    if(@{$self->{'unget'}}) {
	return shift @{$self->{'unget'}};
    }
    my @record = ();
    my $prepend = undef;
    my $empty = 1;
    my $no_of_inputsources = $#{$self->{'fhs'}} + 1;
    if(not $self->{'arg_matrix'}) {
	# Initialize @arg_matrix with one arg from each file
	# read one line from each file
	my @first_arg_set;
	my $all_empty = 1;
	for (my $fhno = 0; $fhno < $no_of_inputsources ; $fhno++) {
	    my $arg = read_arg_from_fh($self->{'fhs'}[$fhno]);
	    if(defined $arg) {
		$all_empty = 0;
	    }
	    $self->{'arg_matrix'}[$fhno][0] = $arg || Arg->new("");
	    push @first_arg_set, $self->{'arg_matrix'}[$fhno][0];
	}
	if($all_empty) {
	    # All filehandles were at eof or eof-string
	    return undef;
	}
	return [@first_arg_set];
    }

    # Treat the case with one input source special.  For multiple
    # input sources we need to remember all previously read values to
    # generate all combinations. But for one input source we can
    # forget the value after first use.
    if($no_of_inputsources == 1) {
	my $arg = read_arg_from_fh($self->{'fhs'}[0]);
	if(defined($arg)) {
	    return [$arg];
	}
	return undef;
    }
    for (my $fhno = $no_of_inputsources - 1; $fhno >= 0; $fhno--) {
	if(eof($self->{'fhs'}[$fhno])) {
	    next;
	} else {
	    # read one
	    my $arg = read_arg_from_fh($self->{'fhs'}[$fhno]);
	    defined($arg) || next; # If we just read an EOF string: Treat this as EOF
	    my $len = $#{$self->{'arg_matrix'}[$fhno]} + 1;
	    $self->{'arg_matrix'}[$fhno][$len] = $arg;
	    # make all new combinations
	    my @combarg = ();
	    for (my $fhn = 0; $fhn < $no_of_inputsources; $fhn++) {
		push @combarg, [0, $#{$self->{'arg_matrix'}[$fhn]}];
	    }
	    $combarg[$fhno] = [$len,$len]; # Find only combinations with this new entry
	    # map combinations
	    # [ 1, 3, 7 ], [ 2, 4, 1 ]
	    # =>
	    # [ m[0][1], m[1][3], m[3][7] ], [ m[0][2], m[1][4], m[2][1] ]
	    my @mapped;
	    for my $c (expand_combinations(@combarg)) {
		my @a;
		for my $n (0 .. $no_of_inputsources - 1 ) {
		    push @a,  $self->{'arg_matrix'}[$n][$$c[$n]];
		}
		push @mapped, \@a;
	    }
	    # append the mapped to the ungotten arguments
	    push @{$self->{'unget'}}, @mapped;
	    # get the first
	    return shift @{$self->{'unget'}};
	}
    }
    # all are eof or at EOF string; return from the unget queue
    return shift @{$self->{'unget'}};
}

sub read_arg_from_fh {
    # Read one Arg from filehandle
    # Returns:
    #   Arg-object with one read line
    #   undef if end of file
    my $fh = shift;
    my $prepend = undef;
    my $arg;
    do {{
	if(eof($fh)) {
	    if(defined $prepend) {
		return Arg->new($prepend);
	    } else {
		return undef;
	    }
	}
	$arg = <$fh>;
	::debug("run", "read $arg\n");
	# Remove delimiter
	$arg =~ s:$/$::;
	if($Global::end_of_file_string and
	   $arg eq $Global::end_of_file_string) {
	    # Ignore the rest of input file
	    while (<$fh>) {}
	    ::debug("run", "EOF-string $arg\n");
	    if(defined $prepend) {
		return Arg->new($prepend);
	    } else {
		return undef;
	    }
	}
	if(defined $prepend) {
	    $arg = $prepend.$arg; # For line continuation
	    $prepend = undef; #undef;
	}
	if($Global::ignore_empty) {
	    if($arg =~ /^\s*$/) {
		redo; # Try the next line
	    }
	}
	if($Global::max_lines) {
	    if($arg =~ /\s$/) {
		# Trailing space => continued on next line
		$prepend = $arg;
		redo;
	    }
	}
    }} while (1 == 0); # Dummy loop {{}} for redo
    if(defined $arg) {
	return Arg->new($arg);
    } else {
	::die_bug("multiread arg undefined");
    }
}

sub expand_combinations {
    # Input:
    #   ([xmin,xmax], [ymin,ymax], ...)
    # Returns: ([x,y,...],[x,y,...])
    # where xmin <= x <= xmax and ymin <= y <= ymax
    my $minmax_ref = shift;
    my $xmin = $$minmax_ref[0];
    my $xmax = $$minmax_ref[1];
    my @p;
    if(@_) {
	# If there are more columns: Compute those recursively
	my @rest = expand_combinations(@_);
	for(my $x = $xmin; $x <= $xmax; $x++) {
	    push @p, map { [$x, @$_] } @rest;
	}
    } else {
	for(my $x = $xmin; $x <= $xmax; $x++) {
	    push @p, [$x];
	}
    }
    return @p;
}


package Arg;

sub new {
    my $class = shift;
    my $orig = shift;
    return bless {
	'orig' => $orig,
    }, ref($class) || $class;
}

sub replace {
    # Calculates the corresponding value for a given perl expression
    # Returns:
    #   The calculated string unquoted
    my $self = shift;
    my $perlexpr = shift; # E.g. $_=$_ or s/.gz//
    my $quote = (shift) ? 1 : 0; # should the string be quoted?
    # This is actually a CommandLine-object,
    # but it looks nice to be able to say {= $job->slot() =}
    my $job = shift;
    $perlexpr =~ s/^-?\d+ //; # Positional replace treated as normal replace
    if(not defined $self->{"rpl",0,$perlexpr}) {
	my $s;
	if($Global::trim eq "n") {
	    $s = $self->{'orig'};
	} else {
	    $s = trim_of($self->{'orig'});
	}
	local $_ = $s;
	::debug("replace", "eval ", $perlexpr, " ", $_, "\n");
	eval $perlexpr;
	$self->{"rpl",0,$perlexpr} = $_;
    }
    if(not defined $self->{"rpl",$quote,$perlexpr}) {
	$self->{"rpl",1,$perlexpr} = ::shell_quote_scalar($self->{"rpl",0,$perlexpr});
    }
    return $self->{"rpl",$quote,$perlexpr};
}

sub orig {
    my $self = shift;
    return $self->{'orig'};
}

sub trim_of {
    # Removes white space as specifed by --trim:
    # n = nothing
    # l = start
    # r = end
    # lr|rl = both
    # Returns:
    #   string with white space removed as needed
    my @strings = map { defined $_ ? $_ : "" } (@_);
    my $arg;
    if($Global::trim eq "n") {
	# skip
    } elsif($Global::trim eq "l") {
	for my $arg (@strings) { $arg =~ s/^\s+//; }
    } elsif($Global::trim eq "r") {
	for my $arg (@strings) { $arg =~ s/\s+$//; }
    } elsif($Global::trim eq "rl" or $Global::trim eq "lr") {
	for my $arg (@strings) { $arg =~ s/^\s+//; $arg =~ s/\s+$//; }
    } else {
	::error("--trim must be one of: r l rl lr.\n");
	::wait_and_exit(255);
    }
    return wantarray ? @strings : "@strings";
}


package TimeoutQueue;

sub new {
    my $class = shift;
    my $delta_time = shift;
    my ($pct);
    if($delta_time =~ /(\d+(\.\d+)?)%/) {
	# Timeout in percent
	$pct = $1/100;
	$delta_time = 1_000_000;
    }
    return bless {
	'queue' => [],
	'delta_time' => $delta_time,
	'pct' => $pct,
	'remedian_idx' => 0,
	'remedian_arr' => [],
	'remedian' => undef,
    }, ref($class) || $class;
}

sub delta_time {
    my $self = shift;
    return $self->{'delta_time'};
}

sub set_delta_time {
    my $self = shift;
    $self->{'delta_time'} = shift;
}

sub remedian {
    my $self = shift;
    return $self->{'remedian'};
}

sub set_remedian {
    # Set median of the last 999^3 (=997002999) values using Remedian 
    #
    # Rousseeuw, Peter J., and Gilbert W. Bassett Jr. "The remedian: A
    # robust averaging method for large data sets." Journal of the
    # American Statistical Association 85.409 (1990): 97-104.
    my $self = shift;
    my $val = shift;
    my $i = $self->{'remedian_idx'}++;
    my $rref = $self->{'remedian_arr'};
    $rref->[0][$i%999] = $val;
    $rref->[1][$i/999%999] = (sort @{$rref->[0]})[$#{$rref->[0]}/2];
    $rref->[2][$i/999/999%999] = (sort @{$rref->[1]})[$#{$rref->[1]}/2];
    $self->{'remedian'} = (sort @{$rref->[2]})[$#{$rref->[2]}/2];
}

sub update_delta_time {
    # Update delta_time based on runtime of finished job if timeout is
    # a percentage
    my $self = shift;
    my $runtime = shift;
    if($self->{'pct'}) {
	$self->set_remedian($runtime);
	$self->{'delta_time'} = $self->{'pct'} * $self->remedian();
	::debug("run", "Timeout: $self->{'delta_time'}s ");
    }
}

sub process_timeouts {
    # Check if there was a timeout
    my $self = shift;
    # $self->{'queue'} is sorted by start time
    while (@{$self->{'queue'}}) {
	my $job = $self->{'queue'}[0];
	if($job->endtime()) {
	    # Job already finished. No need to timeout the job
	    # This could be because of --keep-order
	    shift @{$self->{'queue'}};
	} elsif($job->timedout($self->{'delta_time'})) {
	    # Need to shift off queue before kill
	    # because kill calls usleep that calls process_timeouts
	    shift @{$self->{'queue'}};
	    $job->kill();
	} else {
	    # Because they are sorted by start time the rest are later
	    last;
	}
    }
}

sub insert {
    my $self = shift;
    my $in = shift;
    push @{$self->{'queue'}}, $in;
}


package Semaphore;

# This package provides a counting semaphore
#
# If a process dies without releasing the semaphore the next process
# that needs that entry will clean up dead semaphores
#
# The semaphores are stored in ~/.parallel/semaphores/id-<name> Each
# file in ~/.parallel/semaphores/id-<name>/ is the process ID of the
# process holding the entry. If the process dies, the entry can be
# taken by another process.

sub new {
    my $class = shift;
    my $id = shift;
    my $count = shift;
    $id=~s/([^-_a-z0-9])/unpack("H*",$1)/ige; # Convert non-word chars to hex
    $id="id-".$id; # To distinguish it from a process id
    my $parallel_dir = $ENV{'HOME'}."/.parallel";
    -d $parallel_dir or mkdir_or_die($parallel_dir);
    my $parallel_locks = $parallel_dir."/semaphores";
    -d $parallel_locks or mkdir_or_die($parallel_locks);
    my $lockdir = "$parallel_locks/$id";
    my $lockfile = $lockdir.".lock";
    if($count < 1) { ::die_bug("semaphore-count: $count"); }
    return bless {
	'lockfile' => $lockfile,
	'lockfh' => Symbol::gensym(),
	'lockdir' => $lockdir,
	'id' => $id,
	'idfile' => $lockdir."/".$id,
	'pid' => $$,
	'pidfile' => $lockdir."/".$$.'@'.::hostname(),
	'count' => $count + 1 # nlinks returns a link for the 'id-' as well
    }, ref($class) || $class;
}

sub acquire {
    my $self = shift;
    my $sleep = 1; # 1 ms
    my $start_time = time;
    while(1) {
	$self->atomic_link_if_count_less_than() and last;
	::debug("run", "Remove dead locks");
	my $lockdir = $self->{'lockdir'};
	for my $d (glob "$lockdir/*") {
	    ::debug("run", "Lock $d $lockdir\n");
	    $d =~ m:$lockdir/([0-9]+)\@([-\._a-z0-9]+)$:o or next;
	    my ($pid, $host) = ($1, $2);
	    if($host eq ::hostname()) {
		if(not kill 0, $1) {
		    ::debug("run", "Dead: $d");
		    unlink $d;
		} else {
		    ::debug("run", "Alive: $d");
		}
	    }
	}
	# try again
	$self->atomic_link_if_count_less_than() and last;
	# Retry slower and slower up to 1 second
	$sleep = ($sleep < 1000) ? ($sleep * 1.1) : ($sleep);
	# Random to avoid every sleeping job waking up at the same time
	::usleep(rand()*$sleep);
	if(defined($opt::timeout) and
	   $start_time + $opt::timeout > time) {
	    # Acquire the lock anyway
	    if(not -e $self->{'idfile'}) {
		open (my $fh, ">", $self->{'idfile'}) or
		    ::die_bug("timeout_write_idfile: $self->{'idfile'}");
		close $fh;
	    }
	    link $self->{'idfile'}, $self->{'pidfile'};
	    last;
	}
    }
    ::debug("run", "acquired $self->{'pid'}\n");
}

sub release {
    my $self = shift;
    unlink $self->{'pidfile'};
    if($self->nlinks() == 1) {
	# This is the last link, so atomic cleanup
	$self->lock();
	if($self->nlinks() == 1) {
	    unlink $self->{'idfile'};
	    rmdir $self->{'lockdir'};
	}
	$self->unlock();
    }
    ::debug("run", "released $self->{'pid'}\n");
}

sub atomic_link_if_count_less_than {
    # Link $file1 to $file2 if nlinks to $file1 < $count
    my $self = shift;
    my $retval = 0;
    $self->lock();
    ::debug($self->nlinks(), "<", $self->{'count'});
    if($self->nlinks() < $self->{'count'}) {
	-d $self->{'lockdir'} or mkdir_or_die($self->{'lockdir'});
	if(not -e $self->{'idfile'}) {
	    open (my $fh, ">", $self->{'idfile'}) or
		::die_bug("write_idfile: $self->{'idfile'}");
	    close $fh;
	}
	$retval = link $self->{'idfile'}, $self->{'pidfile'};
    }
    $self->unlock();
    ::debug("run", "atomic $retval");
    return $retval;
}

sub nlinks {
    my $self = shift;
    if(-e $self->{'idfile'}) {
	::debug("run", "nlinks", (stat(_))[3], "\n");
	return (stat(_))[3];
    } else {
	return 0;
    }
}

sub lock {
    my $self = shift;
    my $sleep = 100; # 100 ms
    my $total_sleep = 0;
    $Global::use{"Fcntl"} ||= eval "use Fcntl qw(:DEFAULT :flock); 1;";
    my $locked = 0;
    while(not $locked) {
	if(tell($self->{'lockfh'}) == -1) {
	    # File not open
	    open($self->{'lockfh'}, ">", $self->{'lockfile'})
		or ::debug("run", "Cannot open $self->{'lockfile'}");
	}
	if($self->{'lockfh'}) {
	    # File is open
	    chmod 0666, $self->{'lockfile'}; # assuming you want it a+rw
	    if(flock($self->{'lockfh'}, LOCK_EX()|LOCK_NB())) {
		# The file is locked: No need to retry
		$locked = 1;
		last;
	    } else {
		if ($! =~ m/Function not implemented/) {
		    ::warning("flock: $!");
		    ::warning("Will wait for a random while\n");
		    ::usleep(rand(5000));
		    # File cannot be locked: No need to retry
		    $locked = 2;
		    last;
		}
	    }
	}
	# Locking failed in first round
	# Sleep and try again
	$sleep = ($sleep < 1000) ? ($sleep * 1.1) : ($sleep);
	# Random to avoid every sleeping job waking up at the same time
	::usleep(rand()*$sleep);
	$total_sleep += $sleep;
	if($opt::semaphoretimeout) {
	    if($total_sleep/1000 > $opt::semaphoretimeout) {
		# Timeout: bail out
		::warning("Semaphore timed out. Ignoring timeout.");
		$locked = 3;
		last;
	    }
	} else {
	    if($total_sleep/1000 > 30) {
		::warning("Semaphore stuck for 30 seconds. Consider using --semaphoretimeout.");
	    }
	}
    }
    ::debug("run", "locked $self->{'lockfile'}");
}

sub unlock {
    my $self = shift;
    unlink $self->{'lockfile'};
    close $self->{'lockfh'};
    ::debug("run", "unlocked\n");
}

sub mkdir_or_die {
    # If dir is not writable: die
    my $dir = shift;
    my @dir_parts = split(m:/:,$dir);
    my ($ddir,$part);
    while(defined ($part = shift @dir_parts)) {
	$part eq "" and next;
	$ddir .= "/".$part;
	-d $ddir and next;
	mkdir $ddir;
    }
    if(not -w $dir) {
	::error("Cannot write to $dir: $!\n");
	::wait_and_exit(255);
    }
}

# Keep perl -w happy
$opt::x = $Semaphore::timeout = $Semaphore::wait = $Global::no_more_file_handles_warned =
$Job::file_descriptor_warning_printed = $Global::max_slot_number = 0;

