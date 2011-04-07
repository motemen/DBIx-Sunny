package DBIx::Sunny::Schema;

use strict;
use warnings;
use Carp qw/confess/;
use parent qw/Class::Data::Inheritable/;
use Class::Accessor::Lite;
use Data::Validator;
use DBIx::TransactionManager;
use DBI qw/:sql_types/;

Class::Accessor::Lite->mk_ro_accessors(qw/dbh readonly/);

__PACKAGE__->mk_classdata( '__validators' );
__PACKAGE__->mk_classdata( '__bind_keys' );

sub new {
    my $class = shift;
    my %args = @_;
    bless {
        readonly => delete $args{readonly},
        dbh => delete $args{dbh},
    }, $class;
};

sub select_one {
    my $class = shift;
    my @args = @_;
    $class->__setup_accessor(
        sub {
            my $cb = shift;
            my ( $sth, $ret ) = $cb->(@_);
            my $row = $sth->fetchrow_arrayref;
            return unless $row;
            return $row->[0];
        },
        @args
    );
}

sub select_row {
    my $class = shift;
    my @args = @_;
    $class->__setup_accessor(
        sub {
            my $cb = shift;
            my ( $sth, $ret ) = $cb->(@_);
            my $row = $sth->fetchrow_hashref;
            return unless $row;
            return $row;
        },
        @args
    );
}

sub select_all {
    my $class = shift;
    my @args = @_;
    $class->__setup_accessor(
        sub {
            my $do_query = shift;
            my ( $sth, $ret ) = $do_query->(@_);
            my @rows;
            while( my $row = $sth->fetchrow_hashref ) {
                push @rows, $row;
            }
            return \@rows;
        },
        @args
    );
}

sub query {
    my $class = shift;
    my @args = @_;
    $class->__setup_accessor(
        sub {
            my $do_query = shift;
            my $self = shift;
            Carp::croak "couldnot use query for readonly database handler" if $self->readonly;
            my ( $sth, $ret ) = $do_query->($self, @_);
            return $ret;
        },
        @args
    );
}

sub __setup_accessor {
    my $class = shift;
    my $cb = shift;
    my $method = shift;
    my $query = pop;
    my @rules = @_;
    my $validators = $class->__validators;
    if ( !$validators ) {
        $validators = $class->__validators({});
    }        
    $validators->{$method} = Data::Validator->new(@rules)->with( 'NoThrow');
    
    my @bind_keys;
    while(my($name, $rule) = splice @rules, 0, 2) {
        push @bind_keys, $name;
    }
    my $bind_keys = $class->__bind_keys;
    if ( !$bind_keys ) {
        $bind_keys = $class->__bind_keys({});
    }
    $bind_keys->{$method} = \@bind_keys;


    my $do_query = sub {
        my $self = shift;
        my $validator = $self->__validators->{$method};
        my $args = $validator->validate(@_);
        if ( $validator->has_errors ) {
            my $errors = $validator->clear_errors;
            my $message = "";
            foreach my $e (@{$errors}) {
                $message .= $e->{message} . "\n";
            }
            $message .= sprintf q!  ...   %s::%s(...) called!, ref $self, $method;
            local $Carp::CarpLevel = $Carp::CarpLevel + 3;
            confess $message;
        }
        my $sth = $self->dbh->prepare($query);
        my $i = 1;
        for my $key ( @{$self->__bind_keys->{$method}} ) {
            my $type = $validator->find_rule($key);
            my $bind_type = $type->{type}->is_a_type_of('Int') ? SQL_INTEGER :
                $type->{type}->is_a_type_of('Num') ? SQL_FLOAT : undef;
            if ( defined $bind_type ) {
                $sth->bind_param(
                    $i,
                    $args->{$key},
                    $bind_type
                );
            }
            else {
                $sth->bind_param(
                    $i,
                    $args->{$key},
                );
            }
            $i++;
        }
        my $ret = $sth->execute;
        return ($sth,$ret);
    };

    {
        no strict 'refs';
        *{"$class\::$method"} = sub {
            $cb->( $do_query, @_ );
        };
    }
}

sub txn_scope {
    my $self = shift;
    $self->{__txn} ||= DBIx::TransactionManager->new($self->dbh);
    $self->{__txn}->txn_scope( caller => [caller(0)] );
}

sub func {
    my $self = shift;
    $self->dbh->func(@_);
}

sub last_insert_id {
    my $self = shift;
    my $table = shift;
    $self->dbh->last_insert_id("","",$table,"");
}


1;
__END__

=encoding utf-8

=head1 NAME

DBIx::Sunny::Schema - SQL Class Builder

=head1 SYNOPSIS

  package MyProj::Data::DB;
  
  use parent qw/DBIx::Sunny::Schema/;
  use Mouse::Util::TypeConstraints;
  
  subtype 'Uint'
      => as 'Int'
      => where { $_ >= 0 };
  
  subtype 'Natural'
      => as 'Int'
      => where { $_ > 0 };
  
  enum 'Flag' => qw/1 0/;
  
  no Mouse::Util::TypeConstraints;

  __PACKAGE__->select_one(
      'max_id',
      'SELECT max(id) FROM member'
  );
  
  __PACKAGE__->select_row(
      'member',
      id => { isa => 'Natural' }
      'SELECT * FROM member WHERE id=?',
  );
  
  __PACAKGE__->select_all(
      'recent_article',
      public => { isa => 'Flag', default => 1 },
      offset => { isa => 'Uint', default => 0 },
      limit  => { isa => 'Uint', default => 10 },
      'SELECT * FROM articles WHERE public=? ORDER BY created_on LIMIT ?,?',
  );
  
  __PACKAGE__->query(
      'add_article',
      member_id => 'Natural',
      flag => { isa => 'Flag', default => '1' },
      subject => 'Str',
      body => 'Str',
      created_on => { isa => .. },
      <<SQL);
  INSERT INTO articles (member_id, public, subject, body, created_on) 
  VALUES ( ?, ?, ?, ?, ?)',
  SQL
  
  __PACKAGE__->select_one(
      'article_count_by_member',
      member_id => 'Natural',
      'SELECT COUNT(*) FROM articles WHERE member_id = ?',
  );
  
  __PACKAGE__->query(
      'update_member_article_count',
      article_count => 'Uint',
      id => 'Natural'
      'UPDATE member SET article_count = ? WHERE id = ?',
  );
    
  ...
  
  package main;
  
  use MyProj::Data::DB;
  use DBIx::Sunny;
  
  my $dbh = DBIx::Sunny->connect(...);
  my $db = MyProj::Data::DB->new(dbh=>$dbh,readonly=>0);
  
  my $max = $db->max_id;
  my $member_hashref = $db->member(id=>100); 
  # my $member = $db->member(id=>'abc');  #validator error
  
  my $article_arrayref = $db->recent_article( offset => 10 );
  
  {
      my $txn = $db->dbh->txn_scope;
      $db->add_article(
          member_id => $id,
          subject => $subject,
          body => $body,
          created_on => 
      );
      my $last_insert_id = $db->dbh->last_insert_id;
      my $count = $db->article_count_by_member( id => $id );
      $db->update_member_article_count(
          article_count => $count,
          id => $id
      );
      $txn->commit;
  }
  
=head1 DESCRIPTION

=head1 BUILDER METHODS

=over 4

=item __PACKAGE__->select_one( method_name, validators, sql );

=item __PACKAGE__->select_row( method_name, validators, sql );

=item __PACKAGE__->select_all( method_name, validators, sql );

=item __PACKAGE__->query( method_name, validators, sql );

=back

=head1 METHODS

=over 4

=item new({ dbh => DBI, readonly => ENUM(0,1) )

=item txn_scope

=item func(method)

=item last_insert_id(table)

=back

=head1 AUTHOR

Masahiro Nagano E<lt>kazeburo {at} gmail.comE<gt>

=head1 SEE ALSO

C<DBI>, C<DBIx::TransactionManager>, C<Data::Validator>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut