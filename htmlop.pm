# -*-perl-*-
# htmlop.pl version 0.1.16: Do operations on html documents.
#
# Original source from Bj�rn Borud, without it I would not have atempted
# this. In this incarnation it bears no resemblance to Bj�rns code.
# - Nicolai Langfeldt 18/11/95.
# 
# htmlop.pl does operations on html files, possebly many at a time.
# Operations:
# - Absolitify urls
# - Relativify urls
# - Gather list of urls
# - Callback with url
# - Canonify document w.r.t. SGML.
#
# Authors:
# - Nicolai Langfeldt (janl@ifi.uio.no)
# - Chris Szurgot (szurgot@itribe.net)
#
# Changes:
# janl    18/11/95 - Initial version
# szurgot 09/02/96 - Code in htmlop'process to remove <BASE> Tag if we are 
#                    returning the form. An unchanged base destroys local 
#                    fragments.
# janl    22/02/96 - Added URLSUB functions.  <BASE> will only be removed from
#		     the returned doc, never from the origninal doc.
# janl    16/05/96 - Removed I* options and added single NODOC option/modifier
#		     to replace them.
# janl	  09/09/96 - Added URLPROC and NREL opcodes, for a better URL
#		     processing model. -> 0.1.7
# janl    24/09/96 - Various cosmetics, no longer inserting a !SGML tag,
#		     only !DOCTYPE and HTML tags. -> 0.1.8
# janl    11/10/96 - URLs in HTML 3.2 tags are now found.
# janl     6/11/96 - Added netscape SCRIPT tag.
# janl    20/11/96 - 'BORDER' is different from 'BORDER=0' -> 0.1.10
# janl    06/11/96 - Added userdata argument to URLPROC.
#   			Added SAVEURLS and USESAVED opcodes. -> 0.1.11
# janl    11/04/97 - Changed to URI::URL and got into strict harness
# janl	  13/04/97 - Fixed comment processing, extended it to processing
#			directives. Bug reported by Chris Johnson. -> 0.1.12
# janl    08/04/97 - Made ISMAP into ISMAP=, bad! -> 0.1.13
# janl	  23/05/97 - Treating <script> and <style> as verbatim -> 0.1.14
# janl	  06/06/97 - Canonify: <!SGML tag confused it and !DOCTYPE was mangled
#			-> 0.1.15
# janl	  30/07/97 - Now supporting <BASE> tag.
#		   - Added TAGCALLBACK opcode -> 0.1.16

package htmlop;

use URI::URL;

use strict;
# Global variables
use vars qw($ABS $REL $LIST $CANON $URLSUB $NODOC $URLPROC $NREL);
use vars qw($SAVEURL $USESAVED $TAGCALLBACK $debug);

# These are for the smartrel routines
my $url_origin;
my $doc_top;
my $doc_top_re;
my $choped_url_or;

# HTML operation codes for process_html.  The first argument is the
# html document to do operations on.  It will not be changed.  If
# NODOC is not passed a new document edited as specified will be
# returned.  No more than one document will be returned by one
# invocation of htmlop.

$ABS = 1;			# Absolutify urls. Arg: Origin, The
                                # ABS function absolutifies URLS,
                                # assuming they are relative to the
                                # argument.
				# If a <BASE> tag is found the origin
				# given by it will be used instead of
				# the arguemnt given.

$REL = 2;			# Relativize all urls. Arg: Origin.
                                # The REL function simply removes the
                                # argument string from any urls
                                # matching it.  For this reason the
                                # origin string is interprated as a
                                # RE, which may have unexpected
                                # results, unless RE specials are
                                # escaped, which they should be.

$LIST = 3;			# List all urls, Ret: urls

$CANON = 4;			# See that missing opening (and
                                # ending) SGML tags are injected.

$URLSUB = 5;			# Do regular expression substitution
                                # on urls.  Arg: RE, substitute.

$NODOC = 6;			# Do not return a rebuilt document.
                                # Saves memory, and time

# NOTE: I SUSPECT URLPROC IS BROKEN IF A BASE TAG APPEARS IN THE TEXT.
# THE URL PROCESSOR NEEDS TO BE PASSED htmlop::process' IDEA OF WHAT THE
# BASE URL IS.

$URLPROC = 7;			# Apply function on urls (process
                                # urls).  Arg: Pointer to function to
				# apply, userdata.  The function will
				# be passed the url, modified by any
				# previous operations and the
				# userdata.  The function must return
				# the new url.

$NREL = 8;			# New relativisation function, works
                                # much better than the old one. Arg:
                                # Origin, Top.

$SAVEURL = 9;			# Save urls in tag with modified name.
				# Arg: attribute prefix.
				# Example: <a href=foo> becomes
				# <a href=foo w3mir-href=foo> if no other
				# processing of the url is done.

$USESAVED = 10;			# Use saved urls. Arg: attribute prefix

$TAGCALLBACK = 11;		# Procedure to call for each Tag.
				# Args: procedure, userdata (one item)

				# Args to procedure: userdata, Base
				# URL, tag name, reference to array of
				# URL attributes, reference to hash of
				# all attributes.  The base url is
				# derived from the one used in ABS or
				# the BASE tag.

$debug=0;			# Debugging level in this package

# process_html returns a array.  The first component of the array is
# the new html document. The rest of the array is the urls.  If a
# document is not to be returned a empty string is returned. If a url
# list is not to be returned a empty array is returned.

# HERE BE DRAGONS:

# Where to find URLs in various tags.  The second compoent is a array
# reference.

my(%urls) = (
	A	=> [ 'HREF' ] ,
	IMG	=> [ 'SRC' ,'LOWSRC' ,'USEMAP' ] ,
	EMBED	=> [ 'SRC' ],
	FRAME	=> [ 'SRC' ],
	BODY	=> [ 'BACKGROUND' ],
	AREA	=> [ 'HREF' ],
	LINK	=> [ 'HREF' ],
	APPLET	=> [ 'CODE' ,'CODEBASE'], # This probably dosn't work too well
	INPUT	=> [ 'SRC' ],
	MAP	=> [ 'HREF' ],
	SCRIPT	=> [ 'SRC' ],
	);

# Tags that enclose bits we want to leave absolutely alone because they
# are not very like HTML, or some such.

# The material between the start and end tags is copied with no
# processing at all.  The end tag is left to be processed.
# The endtag match is case insensitive.
my(%verbatim) = (
        SCRIPT	=> quotemeta('</SCRIPT>'),	# Embeded scripts
	STYLE	=> quotemeta('</STYLE>'),	# Embeded stylesheet
	);

# These are the functions that pick the HTML to pieces.  It will not
# work esp. good on a random SGML document since the HTML application
# of SGML has simpler quoting than it might.

sub gettoken {
  # Get one token from the argument, removing it from the argument.
  # BUG: There should be whitespace at the end of the examined string.
  my($c,$token,$rest);
  
  # Skip whitespace and newlines
  return '' unless defined(@_) && defined($_[0]);
  $_[0] =~ s/^[\n\s]*//;
  
  return '' if ($_[0] eq '');
  
  $c = substr($_[0],0,1);
  substr($_[0],0,1)='';
  
  if ($c eq '"') {		# Quoted material
    ($token,$rest)=split('"',$_[0],2);
    $_[0]=$rest;
  } elsif ($c eq '=') {
    $token='=';
  } else {			# Non quoted material
    $_[0] =~ m/[=\s\n]/;
    $_[0] = $&.$';
    $token=$c.$`;
  }
  #    print "Token: '$token'\t\tRest: '",$_[0],"'\n";
  return $token;
}


sub tagtoken {
  # Pick the tag to pieces (also knonw as tokens). Return an
  # associative array of attributes.  The attribute-names are changed
  # to uppercase.  The attribute-values are left as is.
  my($tok,$lasttok,%tokens);
  # Append a space, gettoken needs it - silly? Yes! 
  # Change it to test on boundrary things rather than ...?
  $_[0].=' ';

  $lasttok='';
  while (1) {
    last if (($tok=uc &gettoken($_[0])) eq '');

    if ($tok eq '=') {
#      print STDERR " -bad html-" if ($lasttok eq '');
      $tokens{$lasttok}.=&gettoken($_[0]);
#      print STDERR "STORED: $lasttok = ",$tokens{$lasttok},"\n";
    } else {
      $tokens{$tok}=undef;
      $lasttok=$tok;
    }
  }
  return %tokens;
}


sub gettag {
  # Pick out the following things from the remaining html doc:
  # Everything leading up to the first tag.  The first tag, and its contents.
  # Modify @_ directly to reduce number of copies of possebly huge
  # documents kept in memory at once.
  # Return the body, the tag name, and the attributes (associative array)
  my(%attr,$tagn,$tagc,$body,$tag);
  
  unless ($_[0] =~ s/([^<]*)\<([^>]*)>//) {
    $body=$_[0];
    $_[0]='';
    return ($body,'',());
  }
  $body=$1;
  $tag=$2;
  
  #print "BODY: $body\n";
  #print "COMPLETE TAG: $tag\n";
  
  # Examine tag contents
  if ($tag =~ /^([!?]--)/ || $tag =~ /^(!\w+)/) {
    # Comment or processing dicective, handle specially
    $tagn=$&;
    $tagc=$';
    return ($body,$tagn,("$tagc",undef));
  }

  # Everything else
  ($tagn,$tagc) = split(/[\s\n]+/,$tag,2);
  $tagn="\U$tagn";

  return ($body,$tagn,()) if !defined($tagc);
  
  return ($body,$tagn,&tagtoken($tagc));
}


# This is meant for general consumption:

sub process {
  # Process a html file.  Into one end you put a html file.  Out
  # of the other end you get something dependent on the operations
  # you specified.
  # I cannot gobble my arguments. I need to examine them several times.
  
  my($arg,$doc,$i,$retdoc,$canon,$newdoc,@urllist,$Q,$cont);
  my($origin,$baseurl);
  
  $origin=$baseurl='';

  $retdoc=$canon=0;
  
  # Get the document from the argument list
  $doc=shift(@_);
  
  $retdoc=1;
  $i=0;
  # Argument checking
  while (defined($arg=$_[$i++])) {
    if (! ($arg =~ /^\d+$/)) {
      print STDERR "ERROR IN HTMLOP::process:\n";
      print STDERR "Args: ",join(',',@_),"\n";
      print STDERR "ARG: $arg is not a opcode.\n";
      exit(1);
    }
    if ($arg == $ABS) {
      $baseurl=$origin=$_[$i++];
    } elsif ($arg == $REL || $arg == $SAVEURL || $arg == $USESAVED) {
      $i++; # Skip one arg
    } elsif ($arg == $URLSUB || $arg == $NREL || $arg == $URLPROC ||
	     $arg == $TAGCALLBACK ) {
      $i += 2; # Skip two args
    } elsif ($arg == $LIST) { 
      # do nothing
    } elsif ($arg == $CANON) {
      $canon=1;
    } elsif ($arg == $NODOC) {
      $retdoc=0;
    } else {
      die "htmlop: Incorrect invocation of html_process\n";
    }
  }
  
  my($endhtml)=0;	# Have we seen </html>?
  my($SGML)=1;		# 1: !DOCTYPE not seen, 2: !DOCTYPE seen, -1: it's OK

  # These are used to store the tag components
  my($textpart);
  my($tagname);
  my(%attrval);

  my($wholetag);	# The whole tag, put together again
  my($moretag);		# TMP storage of tag attributes
  my($attr);		# Looping thru attributes, misnomer.
  my($RE);
  my($subst);
  my($prefix);
  my($fun);		# Function to apply to url
  my($verbatim)='';

  # Welcome to the machine

  $newdoc='';
  while ($doc ne '') {
    ($textpart,$tagname,%attrval)=&gettag($doc);
    
    # Process the tag
    { # Need a way to get out of this, last is my friend
      # 'Canonize'
      if ($canon) {
	$endhtml=1 if ($tagname eq '/HTML');
	if ($SGML!=-1 && $canon && $tagname ne '!--' && $tagname ne '!SGML') {
	  $wholetag=$tagname;
	  $moretag=join('',keys %attrval);
	  $wholetag.=' '.$moretag if ($moretag ne '');
	  if ($SGML==1) {
	    $SGML=2;
	    if ($tagname eq '!DOCTYPE') {
	      $tagname=$wholetag;
	      %attrval=();
	      last;
	    }

	    # We have no idea what DTD this doc follows so we put in
	    # something kinda non-comitting
	    $newdoc.='<!DOCTYPE HTML PUBLIC "html.dtd">'."\n";
	  }
	  if ($SGML==2) {
	    $SGML=-1;
	    if ($tagname eq 'HTML') {
	      $tagname=$wholetag;
	      %attrval=();
	      last;
	    }
	    $newdoc.='<HTML>'."\n";
	  }
	}			# sgml!=-1
      }				#canon

      # Tack on text part before I bail out, if wanted
      $newdoc.=$textpart if $retdoc;

      if ($tagname eq 'BASE') {
	if (defined($attrval{'HREF'})) {
	  if ($origin) {
	    $baseurl=(url($attrval{'HREF'})->abs($origin,1))->as_string;
	  } else {
	    $baseurl=$attrval{'HREF'};
	  }
	  print STDERR "\nBase tag: $baseurl\n" if $debug;
	}
	next;  # Get rid of base tags
      }

      # URL processing
      $i=0;
      while (defined($arg=$_[$i])) {
	if (! ($arg =~ /^\d+$/)) {
	  print STDERR "Args: ",join(',',@_),"\n";
	  print STDERR "ARG: $arg ($i) is not a opcode.\n";
	  exit(1);
	}
	$i++;
	if ($arg == $ABS) {
	  $origin=$baseurl || $_[$i++];
	  $i++;
	  # Want it to be a URL object
	  $origin=url $origin unless ref $origin;
	  print STDERR 'ABS: ',$origin->as_string,"\n" if $debug;
	  next unless defined($urls{$tagname});
	  foreach $attr (@{$urls{$tagname}}) {
	    $attrval{$attr}=
	      (url($attrval{$attr})->abs($origin,1))->as_string
		if defined($attrval{$attr});
	  }
	} elsif ($arg == $REL) {
	  $origin=$_[$i++];
	  # Want it to be a string
	  $origin=$origin->as_string if ref $origin;
	  print STDERR 'REL: ',$origin,"\n" if $debug;
	  next unless defined($urls{$tagname});
	  foreach $attr (@{$urls{$tagname}}) {
	    $attrval{$attr} =~ s/^$origin//
	      if defined($attrval{$attr});
	  }
	} elsif ($arg == $URLSUB) {
	  $RE=$_[$i++];
	  $subst=$_[$i++];
	  warn "URLSUB: $RE -> $subst\n" if $debug;
	  next unless defined($urls{$tagname});
	  foreach $attr (@{$urls{$tagname}}) {
	    $attrval{$attr} =~ s/$RE/$subst/
	      if defined($attrval{$attr});
	  }
	} elsif ($arg == $LIST) {
	  warn "LIST;\n" if $debug;
	  next unless exists($urls{$tagname});
	  foreach $attr (@{$urls{$tagname}}) {
	    push(@urllist,$attrval{$attr}) if defined($attrval{$attr});
	  }
	} elsif ($arg == $SAVEURL) {
	  warn "SAVEURL;\n" if $debug;
	  $prefix=$_[$i++];
	  next unless exists($urls{$tagname});
	  foreach $attr (@{$urls{$tagname}}) {
	    $attrval{"$prefix$attr"}=$attrval{$attr}
	      if defined($attrval{$attr});
	  }
	} elsif ($arg == $USESAVED) {
	  warn "USESAVED;\n" if $debug;
	  $prefix=$_[$i++];
	  next unless exists($urls{$tagname});
	  foreach $attr (@{$urls{$tagname}}) {
	    $attrval{$attr}=$attrval{"$prefix$attr"}
	      if (defined($attrval{"$prefix$attr"}));
	    # bug compatability, drop in sometime after w3mir 1.0
	    $attrval{$attr}=$attrval{"$prefix-$attr"}
	      if (defined($attrval{"$prefix-$attr"}));
	  }
	} elsif ($arg == $NODOC) {
	  warn "NODOC;\n" if $debug;
	} elsif ($arg == $CANON) {
	  warn "CANON;\n" if $debug;
	} elsif ($arg == $URLPROC || $arg == $NREL) {
	  # Apply a function to all urls.
	  # NREL = Special case of $URLPROC, apply internal function.
	  if ($arg == $URLPROC) {
	    warn "URLPROC;\n" if $debug;
	    $fun=$_[$i++];
	    $arg=$_[$i++];
	  } else {
	    $fun=\&smartrel;
	    $arg=undef;
	    $url_origin=$_[$i++];
	    $doc_top=$_[$i++];
	    $doc_top_re=quotemeta $doc_top;
	    ($choped_url_or=$url_origin) =~ s/^$doc_top_re//;
	    warn "NREL $url_origin $doc_top\n" if $debug;
	  }

	  next unless (defined($urls{$tagname}));

	  foreach $attr (@{$urls{$tagname}}) {
	    $attrval{$attr}=&$fun($attrval{$attr},$arg)
	      if defined($attrval{$attr});
	  }
	} elsif ($arg == $TAGCALLBACK) {
	  $fun=$_[$i++];
	  $arg=$_[$i++];
	  &$fun($arg,$baseurl, $tagname, 
		(defined($urls{$tagname})? $urls{$tagname}: undef),
		\%attrval);
	} else {
	  print STDERR "Internal error. opcode: $arg, i: $i, args: ",
	  join(',',@_),"\n";
	}
      }
      last;
    }
    # That ends URL processing

    # Was this a verbatim leadin tag?
    # If yes, atempt to fish out text between here and the end tag,
    # (minimal match) and substitute it with nothing.  The end tag is kept
    $verbatim=$1 
      if defined($verbatim{$tagname}) &&
	($doc =~ s/^(.*)($verbatim{$tagname})/$2/is);
    
    # Tack on the tag, if wanted.
    if ($retdoc) {
      if ($tagname) {
	$newdoc.='<'.$tagname;
	foreach $attr (keys %attrval) {
	  $newdoc.=' '.$attr;
	  if (defined($cont=$attrval{$attr})) {
	    $Q='';
	    $Q='"' if ($cont =~ m/[^\w\d]/);
	    $newdoc.='='.$Q.$cont.$Q;
	  }
	}
	$newdoc.='>'.$verbatim;
	$verbatim='';
      }
    }
    print "NEW: $newdoc\n" if $debug > 2;
  }
  $newdoc.="</HTML>\n" if ($canon && !$endhtml);
  $newdoc =~ s/\<BASE.*\>//ig if ($canon);
  return ($newdoc,@urllist);
}


sub smartrel {
  # 'smart' relativisation function, uses .. to refer to things up to
  # $doc_top level.  Outside that scope it stays absolute.
  #
  # Example to clear mind:
  # url_origin: http://www.math.uio.no/doc/linux/
  # doc_top:    http://www.math.uio.no/
  # url:        http://www.math.uio.no/doc/mail/top.html
  # return:     ../mail/top.html
  #
  
  my($url_o)=@_;

  return if (!(defined($url_o) && $url_o));
  
  $url_o=url $url_o unless ref $url_o;

#  print STDERR "\nsmartrel: $url_o->as_string\n",
#                 "    from: $url_origin\n",
#                 "  within: $doc_top\n";
  
  # Check if within scope of our doc
  $url_o = $url_o->rel($url_origin)
    if $url_o->as_string =~ m/^$doc_top_re/;

  return $url_o->as_string;
}


sub smart_setup {
  # Setup routine for smartrel.

  ($url_origin,$doc_top) = @_;

  $url_origin=$url_origin->as_string if ref $url_origin;
  $doc_top=$doc_top->as_string if ref $doc_top;

  $doc_top_re=quotemeta $doc_top;

  ($choped_url_or=$url_origin) =~ s/^$doc_top_re//;
}

1;

__END__
  
# Some testing code

sub test
($doc_top_re=$doc_top='http://www.math.uio.no/') =~ s/(\W)/\\$1/g;

($choped_url_or=$url_origin='http://www.math.uio.no/doc/') =~ 
  s/^$doc_top_re//;

$url='http://www.math.uio.no/doc/top.html';

print "Relativizing: $url ->\n  ",&smartrel($url),"\n";
