=head1 NAME

Eval::Logic - Evaluate simple logical expressions from a string.

=head1 DESCRIPTION

With this module simple logical expressions from strings which  use logical
operators like and, or, not and the ternary operator can be evaluated.

This module was created because I wanted to be able to use a simple argument
validator which can be fully configured from YAML.  This module allows a
specification like "we require a_value and some_other_value, or a
a_third_option should be specified" to be expressed as a simple string
"(a_value && some_other_value) || a_third_option".

The module uses eval() and while it does take care to check for anything
other than a logical expression you should take a lot of care when
evaluating expressions from an untrusted source (in fact, I would not
recommend doing that at all).

=head1 SYNOPSIS

 $l = Eval::Logic->new ( '(a || b) && c' );
 $l->evaluate ( a => 1, b => 0, c => 1 ); 	# returns 1 for true
 $l->evaluate ( a => 1, b => 1, c => 0 );	# returns 0 for false
 $l->evaluate_if_true ( 'a', 'b' );		# an alternative for that second example
 $l->evaluate_if_false ( 'c' );			# and another alternative

=head1 METHODS

=cut

package Eval::Logic;

use strict;
use warnings;

use Carp;
use Symbol;
use utf8;

# Forbidden list if truth value names; these are Perl operators with regular
# names that cannot be overridden by using 'use subs'.
our @forbidden_tv_names = qw( or and not xor );

=head2 new (constructor)

 $l = Eval::Logic->new ( 'a && b' );
 
Create a new instance of Eval::Logic. Optionally an expression can be
specified which is immediately loaded in the object, see the expression
method for more information about the expression syntax.

=cut

sub new {
  my $class = shift;
  my $self = bless { undef_default => undef }, $class;
  $self->expression ( @_ ) if ( @_ );
  return $self;
}

=head2 expression

 $expression = $l->expression;
 $l->expression ( 'a && b' );
 
If called without an argument the current expression is returned, otherwise
the current expression in this object is replaced by whatever was specified. 
If multiple strings are specified they are combined in a single expression
that will require all individual expressions to be true.

An expression is a string in which the truth values are specified as simple
(bare) words which can contain letters, digits and underscores and which
must not begin with a digit.  In addition to this, the Perl logical
operators && (and), || (or), ! (not) can be used, as well as the ternary ?:
operator and parentheses. Whitespace is ignored.

The barewords TRUE and FALSE have a special meaning which you can probably
guess.

The method will croak if the expression provided is invalid.

=cut

sub expression {
  my $self = shift;
  if ( @_ ) {

    my $exp = @_ > 1 ? join ( ' && ', map { '(' . $_ . ')' } @_ ) : $_[0];

    my %tv;
    foreach my $v ( 
      split /			# split on anything that cannot be a truth value:
        (?:
          &&	|		# and operator,
          \|\|	|		# or operator,
          !	|		# not operator,
          \?	|		# the first part of the ternary operator,
          \:	|		# the second part of the ternary operator,
          \(	|		# opening parentheses,
          \)	|		# closing parentheses,
          \s			# any whitespace
        )+
      /x, $exp
    ) {
      if ( $v ) {
        next if (( $v eq 'TRUE' ) || ( $v eq 'FALSE' ));
        if ( grep { $v eq $_ } @forbidden_tv_names ) {
          croak "Invalid truth value in expression, named identical to Perl reserved word: '$v'";
        } elsif ( $v =~ /^[a-zA-Z_][a-zA-Z_0-9Ö]*$/ ) {
          $tv{$v} = undef;
        } else {
          croak "Syntax error or invalid truth value in expression: '$v'";
        }
      }
    }

    # Test the expression by evaluating it.
    $self->_eval ( $exp, %tv );
    
    # If we're here, the expression checked out.
    $self->{tv} = [ keys %tv ];
    $self->{exp} = $exp;
    
  } else {
    return $self->{exp};
  }
}

=head2 evaluate

 $outcome = $l->evaluate ( a => 1, b => 0 );
 
Evaluate the logic expression given the specified truth values. If no
default for undefined truth values is specified and some truth values are
not defined or not present, a warning is given.

The outcome is returned as 1 for true or 0 for false.

=cut

sub evaluate {
  my $self = shift;
  my %specified_tv = @_;
  
  croak 'TRUE or FALSE specified as a variable truth value' if (( exists $specified_tv{TRUE} ) || ( exists $specified_tv{FALSE} ));
  
  if ( defined $self->{exp} ) {
    my %tv;
    foreach my $v ( @{$self->{tv}} ) {
      if ( defined $specified_tv{$v} ) {
        $tv{$v} = $specified_tv{$v};
      } elsif ( defined $self->{undef_default} ) {
        $tv{$v} = $self->{undef_default};
      } else {
        carp (( exists $specified_tv{$v} ? 'Undefined' : 'Unspecified' ) . " truth value $v defaults to false" );
        $tv{$v} = 0;
      }
    }
    return $self->_eval ( $self->{exp}, %tv );
  } else {
    carp "No expression, returning false";
    return 0;
  }
}

=head2 evaluate_if_false

 $outcome = $l->evaluate_if_false ( 'a' );
 
Evaluate the logic expression given the specified values to be false, and
all other values to be true.  This is a shortcut to the evaluate method.

=cut

sub evaluate_if_false { shift->_eval_if ( 0, @_ ) }

=head2 evaluate_if_true

 $outcome = $l->evaluate_if_true ( 'b' );
 
Evaluate the logic expression given the specified values to be true, and all
other values to be false.  This is a shortcut to the evaluate method.

=cut

sub evaluate_if_true { shift->_eval_if ( 1, @_ ) }

=head2 truth_values

 @truth_values = $l->truth_values;
 
Return a list of all variable truth values which are present in the
currently loaded expression.

=cut

sub truth_values {
  my $self = shift;
  if ( defined $self->{exp} ) {
    return @{$self->{tv}};
  } else {
    carp "No expression, returning empty list";
    return ();
  }
}

=head2 undef_default

 $default = $l->undef_default;
 $l->undef_default ( $default );

Returns the current default for undefined truth values if specified without
an argument, or sets the default value to the specified argument.  If you
want undefined values to default to false you must explicitly call this
method with an argument that is defined and evaluates to false to suppress
warnings given about undefined values by the evaluate method.

=cut

sub undef_default {
  my $self = shift;
  if ( @_ ) {
    $self->{undef_default} = $_[0];
  } else {
    return $self->{undef_default};
  }
}
  
#
# The _eval method does the work: it creates a piece of Perl code and then
# evaluates it. It will get a bit dirty in here.
#

sub _eval {
  my $self = shift;
  my ( $exp, %tv ) = @_;
  
  # Make sure TRUE and FALSE always mean what they say.
  $tv{TRUE} = 1;
  $tv{FALSE} = 0;
  
  # Generate a piece of code in a 'scratch' package which we will clean
  # before using it.
  my $code = '';

  # To parse any error messages we count the number of lines added. 
  my $our_lines = 0;
  
  # Begin with the package declaration and declare the subroutine names
  # we're using to prevent them from calling core subroutines.
  $code .= 'package ' . __PACKAGE__ . "::Scratch;\n"; $our_lines++;
  $code .= 'use subs qw(' . join ( ' ', keys %tv ) . ");\n"; $our_lines++;

  # Generate a constant subroutine for every value.
  while ( my ( $name, $truth ) = each %tv ) {
    
    # For true we use 1, for false we use an empty list because that will
    # always evaluate to false, even in list context (think about stuff like
    # '(FALSE)' which must evaluate to false, and not to a list of one
    # element).
    
    $code .= 'sub ' . $name . '(){' . ( $truth ? '1' : '()' ) . "}\n";
    $our_lines++;
  }
  
  # Finally we add the expression itself.
  $code .= $exp . "\n;";
  
  # Reset the package namespace and evaluate the generated code block.
  Symbol::delete_package __PACKAGE__ . '::Scratch';
  my $outcome = eval $code ? 1 : 0;

  if ( my $error = $@ ) {
  
    # Some error messages are changed on the fly to make them clearer...
    # hopefully.
    $error =~ s/Too many arguments for @{[__PACKAGE__]}::Scratch::(\S+)/Truth value '$1' not followed by boolean operator/;
  
    # An error occurred while evaluating our code; try to determine the
    # location of the error.
    if ( $error =~ /(at \(eval [0-9]+\) line ([0-9]+))/ ) {
      my ( $location_text, $error_line ) = ( $1, $2 );
      $error_line -= $our_lines;
      if ( $error_line > 0 ) {		# the error was in the expression, change the error message to be more descriptive
        $error =~ s/\Q$location_text\E/at line $error_line in logical expression/;
        croak $error;
      } else {				# woops
        croak "Eval::Logic internal error while evaluating expression: $error";
      }
    }
    
    # If we're still here we just repeat whatever error we got.
    croak $error;
    
  }
  
  # Make sure we always return 1 for true and 0 for false.
  return $outcome ? 1 : 0;
  
}

#
# General implementation of evaluate_if_(true|false)
#

sub _eval_if {
  my $self = shift;
  my $truth = shift;
  my @values = @_;
  my %tv = map { $_ => $truth ? 0 : 1 } @{$self->{tv}};
  foreach ( @values) { $tv{$_} = $truth }
  return $self->evaluate ( %tv );
}

=head1 AUTHOR

Sebastiaan Hoogeveen <pause-zebaz@nederhost.nl>

=head1 COPYRIGHT

Copyright (c) 2016 Sebastiaan Hoogeveen. All rights reserved. This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

See http://www.perl.com/perl/misc/Artistic.html

=cut

1;
